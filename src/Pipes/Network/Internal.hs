module Pipes.Network.Internal where

import Data.ByteString (ByteString)
import Data.ByteString.Lazy (toStrict, fromStrict)
import Network.Socket (SockAddr, Socket)
import Data.Binary (Binary(put,get))
import qualified Data.Binary as Binary(encode,decode)

instance Binary SockAddr where
    put = undefined
    get = undefined

newSocket :: SockAddr -> IO Socket
newSocket = undefined

serve :: SockAddr -> (SockAddr -> Socket -> IO ()) -> IO ()
serve = undefined

encode :: Binary a => a -> ByteString
encode = toStrict . Binary.encode

decode :: Binary a => ByteString -> a
decode = Binary.decode . fromStrict

