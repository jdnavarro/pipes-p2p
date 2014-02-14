{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
module Pipes.Network.P2P.Message where

import Control.Applicative ((<$>), (<*>), (*>))
import Data.Monoid ((<>))
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.ByteString.Lazy (toStrict, fromStrict)
import Data.Binary (Binary(put,get), putWord8, getWord8)
import qualified Data.Binary as Binary(encode,decodeOrFail)
import Control.Concurrent (ThreadId)
import GHC.Generics (Generic)
import Network.Socket
  ( SockAddr(SockAddrInet, SockAddrInet6, SockAddrUnix)
  , PortNumber(PortNum)
  )
import Control.Error (hush)

data Header = Header Int Int deriving (Show, Generic)

instance Binary Header

hSize :: Int
hSize = B.length . encode $ Header 0 0

data Payload = GETADDR
             | ADDR Address
             | ME Address
             | ACK
               deriving (Show, Eq, Generic)

instance Binary Payload

data Message = Message Header Payload deriving (Show, Generic)

instance Binary Message

serialize :: Int -> Payload -> ByteString
serialize magic payload = encode (Header magic $ B.length bs) <> bs
  where
    bs = encode payload

data Relay = Relay ThreadId Address

newtype Address = Addr SockAddr deriving (Show, Eq, Ord)

getSockAddr :: Address -> SockAddr
getSockAddr (Addr a) = a

instance Binary Address where
    put (Addr (SockAddrInet (PortNum port) host)) =
        putWord8 0 *> put (port, host)
    put (Addr (SockAddrInet6 (PortNum port) flow host scope)) =
        putWord8 1 *> put (port, flow, host, scope)
    put (Addr (SockAddrUnix str)) = putWord8 2 *> put str

    get = getWord8 >>= \case
              0 -> Addr <$> (SockAddrInet <$> PortNum <$> get <*> get)
              1 -> Addr <$> (SockAddrInet6 <$> PortNum <$> get <*> get <*> get <*> get)
              _ -> Addr <$> SockAddrUnix <$> get

encode :: Binary a => a -> ByteString
encode = toStrict . Binary.encode

decode :: Binary a => ByteString -> Maybe a
decode = fmap third . hush . Binary.decodeOrFail . fromStrict
  where
    third (_,_,x) = x
