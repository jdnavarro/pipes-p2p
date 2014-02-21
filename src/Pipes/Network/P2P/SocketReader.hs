module Pipes.Network.P2P.SocketReader (socketReader) where

import Control.Monad (forever, unless)
import Data.Foldable (forM_)
import Data.ByteString (ByteString)
import Pipes (Proxy, Pipe, Producer, MonadIO, yield, await)
import Pipes.Core ((>+>), request, respond)
import Network.Simple.SockAddr (Socket)
import Pipes.Network.TCP (fromSocketN)

import Pipes.Network.P2P.Message

socketReader :: MonadIO m => Int -> Socket -> Producer Message m ()
socketReader magic sock = fromSocketN sock >+> beheader magic >+> decoder $ ()

decoder :: MonadIO m => () -> Pipe ByteString Message m ()
decoder () = forever $ do
    pbs <- await
    forM_ (decode pbs) yield

beheader :: MonadIO m => Int -> () -> Proxy Int ByteString () ByteString m ()
beheader magic () = forever $ do
    hbs <- request hSize
    case decode hbs of
        Nothing -> return ()
        Just (Header magic' nbytes) -> unless (magic /= magic')
                                     $ request nbytes >>= respond
