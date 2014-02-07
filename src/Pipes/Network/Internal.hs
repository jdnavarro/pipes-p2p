{-# LANGUAGE LambdaCase #-}
module Pipes.Network.Internal where

import Control.Applicative ((<$>), (<*>), (*>))
import Control.Monad (forever)
import Control.Exception (bracket, bracketOnError, throwIO)
import Control.Concurrent (ThreadId, forkFinally)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy (toStrict, fromStrict)
import Data.Binary (Binary(put,get), putWord8, getWord8)
import qualified Data.Binary as Binary(encode,decode)
import qualified Network.Socket as NS
import Network.Socket
  ( SockAddr(SockAddrInet, SockAddrInet6, SockAddrUnix)
  , SocketType(Stream)
  , Family(AF_INET, AF_INET6, AF_UNIX)
  , PortNumber(PortNum)
  , Socket
  , defaultProtocol
  )

serve :: SockAddr -> (Socket -> IO ()) -> IO ()
serve addr k = listen addr $ \sock -> forever $ acceptFork sock k

listen :: SockAddr -> (Socket -> IO r) -> IO r
listen addr = bracket listen' NS.close
  where
    listen' = do sock <- bind addr
                 NS.listen sock $ max 2048 NS.maxListenQueue
                 return sock

bind :: SockAddr -> IO Socket
bind addr = bracketOnError (newSocket addr) NS.close $ \sock -> do
    NS.setSocketOption sock NS.NoDelay 1
    NS.setSocketOption sock NS.ReuseAddr 1
    NS.bindSocket sock addr
    return sock

acceptFork :: Socket -> (Socket -> IO ()) -> IO ThreadId
acceptFork lsock k = do
    (csock,_) <- NS.accept lsock
    forkFinally (k csock) (\ea -> NS.close csock >> either throwIO return ea)

connect :: SockAddr -> (Socket -> IO r) -> IO r
connect addr = bracket connect' NS.close
  where
    connect' = do sock <- newSocket addr
                  NS.connect sock addr
                  return sock

newSocket :: SockAddr -> IO Socket
newSocket (SockAddrInet  {}) = NS.socket AF_INET  Stream defaultProtocol
newSocket (SockAddrInet6 {}) = NS.socket AF_INET6 Stream defaultProtocol
newSocket (SockAddrUnix  {}) = NS.socket AF_UNIX  Stream defaultProtocol

instance Binary SockAddr where
    put (SockAddrInet (PortNum port) host) = putWord8 0 *> put (port, host)
    put (SockAddrInet6 (PortNum port) flow host scope) =
        putWord8 1 *> put (port, flow, host, scope)
    put (SockAddrUnix str) = putWord8 2 *> put str

    get = getWord8 >>= \case
              0 -> SockAddrInet <$> PortNum <$> get <*> get
              1 -> SockAddrInet6 <$> PortNum <$> get <*> get <*> get <*> get
              2 -> SockAddrUnix <$> get

encode :: Binary a => a -> ByteString
encode = toStrict . Binary.encode

decode :: Binary a => ByteString -> a
decode = Binary.decode . fromStrict
