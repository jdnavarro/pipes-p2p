{-# LANGUAGE LambdaCase #-}
module Pipes.Network.Internal where

import Control.Applicative ((<$>), (<*>), (*>))
import Data.ByteString (ByteString)
import Data.ByteString.Lazy (toStrict, fromStrict)
import Data.Binary (Binary(put,get), putWord8, getWord8)
import qualified Data.Binary as Binary(encode,decode)
import Network.Socket
  ( SockAddr(SockAddrInet, SockAddrInet6, SockAddrUnix)
  , PortNumber(PortNum)
  )

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
