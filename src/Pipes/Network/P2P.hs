{-# LANGUAGE NamedFieldPuns, RecordWildCards #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
module Pipes.Network.P2P where

import Control.Error
import Control.Applicative (pure)
import Control.Monad ((>=>), void, guard)
-- import Data.Monoid (mappend)
import Control.Concurrent (ThreadId, myThreadId, forkIO)
import Control.Concurrent.MVar
import GHC.Generics (Generic)
import qualified Data.Binary as Binary
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.ByteString.Lazy (toStrict, fromStrict)
import Data.Map (Map)
import qualified Data.Map as Map
import Pipes
import Pipes.Lift (errorP)
import Pipes.Binary (Binary(put,get), decoded)
import Pipes.Concurrent (Output, Input, Buffer(Unbounded), toOutput)
import Pipes.Network.TCP
  ( HostPreference
  , HostName
  , ServiceName
  , fromSocket
  , connect
  , send
  , serve
  , recv
  , fromSocket
  , Socket
  , SockAddr
  )
import Lens.Family2 ((^.))

instance Binary HostPreference where
    put = undefined
    get = undefined

type Mailbox = (Output Message, Input Message)

data Node = Node
    { settings    :: Settings
    , connections :: MVar (Map ThreadId Connection)
    , broadcaster :: MVar Mailbox
    }

data Settings = Settings
    { preference :: HostPreference
    , service    :: ServiceName
    } deriving (Show, Eq, Generic)

instance Binary Settings

data Connection = Connection
    { sock    :: Socket
    , sockAdd :: SockAddr
    }

instance Binary SockAddr where
    put = undefined
    get = undefined

data Message = GETADDR
             | ADDR SockAddr
             | VER Int
             | ACK
               deriving (Show, Eq, Generic)

instance Binary Message

type Seed = (HostName, ServiceName)

-- | Launch a node.
launch :: Node -> Seed -> IO ()
launch node@Node{..} (hn, sn) = do
    serve (preference settings) (service settings) undefined -- (handle node . fst)
    void . forkIO . connect hn sn $ \(sock, sockAddr) -> void . runMaybeT $ do
        -- handshake
        lift $ send sock (encode $ VER version)
        let liftMay = lift >=> hoistMaybe
        ver <- liftMay $ recv sock verLen
        ack <- liftMay $ recv sock ackLen
        guard $ decode ver <= version
        guard $ decode ack == ACK

        -- Request addresses, register and handle incoming messages
        lift $ do send sock $ encode GETADDR
                  -- mb@(output, _) <- spawn Unbounded
                  -- modifyMVar_ broadcaster $ pure . first (mappend output)
                  tid <- myThreadId
                  let conn = Connection sock sockAddr
                  modifyMVar_ connections $ pure . Map.insert tid conn
                  handle node conn

handle :: Node -> Connection -> IO ()
handle Node{..} Connection{..} = go
  where
    go = do (output, input) <- readMVar broadcaster
            let p = errorP (fromSocket sock 4096 ^. decoded)  >-> toOutput output
            return ()

ackLen :: Int
ackLen = B.length $ encode ACK

verLen :: Int
verLen = B.length $ encode version

version :: Int
version = 2

encode :: Binary a => a -> ByteString
encode = toStrict . Binary.encode

decode :: Binary a => ByteString -> a
decode = Binary.decode . fromStrict
