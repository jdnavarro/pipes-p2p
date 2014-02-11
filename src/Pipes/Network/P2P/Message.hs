{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
module Pipes.Network.P2P.Message where

import Control.Applicative ((<$>), (<*>), (*>))
import Data.Monoid ((<>))
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.ByteString.Lazy (toStrict, fromStrict)
import Data.Binary (Binary(put,get), putWord8, getWord8)
import qualified Data.Binary as Binary(encode,decode)
import Control.Concurrent (ThreadId)
import GHC.Generics (Generic)
import Network.Socket
  ( SockAddr(SockAddrInet, SockAddrInet6, SockAddrUnix)
  , PortNumber(PortNum)
  )

data Header = Header Int Int deriving (Show, Generic)

instance Binary Header

hSize :: Int
hSize = B.length . encode $ Header 0 0

data Payload = GETADDR
             | ADDR SockAddr
             | ME SockAddr
             | ACK
               deriving (Show, Eq, Generic)

instance Binary Payload

data Message = Message Header Payload deriving (Show, Generic)

instance Binary Message

serialize :: Int -> Payload -> ByteString
serialize magic payload = encode (Header magic $ B.length bs) <> bs
  where
    bs = encode payload

data Relay = Relay ThreadId SockAddr

instance Binary SockAddr where
    put (SockAddrInet (PortNum port) host) = putWord8 0 *> put (port, host)
    put (SockAddrInet6 (PortNum port) flow host scope) =
        putWord8 1 *> put (port, flow, host, scope)
    put (SockAddrUnix str) = putWord8 2 *> put str

    get = getWord8 >>= \case
              0 -> SockAddrInet <$> PortNum <$> get <*> get
              1 -> SockAddrInet6 <$> PortNum <$> get <*> get <*> get <*> get
              _ -> SockAddrUnix <$> get

encode :: Binary a => a -> ByteString
encode = toStrict . Binary.encode

decode :: Binary a => ByteString -> a
decode = Binary.decode . fromStrict
