{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE NamedFieldPuns, RecordWildCards #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
module Pipes.Network.P2P where

import Control.Applicative ((<$>), (<*>), pure)
import Control.Monad (void, guard, forever)
import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.MVar (MVar, newMVar, readMVar, modifyMVar_)
import GHC.Generics (Generic)
import Control.Exception (finally)
import Data.Foldable (for_)

import Control.Concurrent.Async (concurrently)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Map (Map)
import qualified Data.Map as Map

import Lens.Family2 ((^.))

import Pipes
import qualified Pipes.Prelude as P
import Control.Monad.Trans.Error
import Pipes.Lift (errorP, runErrorP)
import Pipes.Binary (Binary, decoded, DecodingError)
import qualified Pipes.Concurrent
import Pipes.Concurrent
  ( Buffer(Unbounded)
  , Output
  , Input
  , spawn
  , toOutput
  , fromInput
  , atomically
  )
import Pipes.Network.TCP
  ( fromSocket
  , toSocket
  )
import Network.Simple.SockAddr
  ( Socket
  , SockAddr
  , serve
  , connectFork
  , send
  , recv
  )

import Pipes.Network.Internal

type Mailbox = (Output Relay, Input Relay)

data Node = Node
    { address     :: SockAddr
    , connections :: MVar (Map SockAddr Socket)
    , broadcaster :: Mailbox
    }

node :: SockAddr -> IO Node
node addr = Node addr <$> newMVar Map.empty <*> spawn Unbounded

data Message = GETADDR
             | ADDR SockAddr
             | ME SockAddr
             | ACK
               deriving (Show, Eq, Generic)

data Relay = Relay ThreadId SockAddr

instance Binary Message

launch :: Node -> [SockAddr] -> IO ()
launch n@Node{..} addrs = do
    for_ addrs $ \a -> connectFork a $ outgoing n a
    serve address $ incoming n

outgoing :: Node -> SockAddr -> Socket -> IO ()
outgoing n@Node{..} addr sock = void $ do
    -- handshake
    send sock (encode $ ME address)
    oaddr <- recv sock (B.length $ encode addr)
    ack <- recv sock ackLen
    guard $ decode oaddr == addr
    guard $ decode ack == ACK
    send sock $ encode GETADDR
    handle n sock addr

incoming :: Node -> SockAddr -> Socket -> IO ()
incoming n@Node{..} addr sock = void $ do
    _oaddr <- recv sock (B.length $ encode addr)
    send sock $ encode (ME address, ACK)
    -- guard $ decode oaddr == addr
    ack <- recv sock ackLen
    guard $ decode ack == ACK
    handle n sock addr

-- TODO: How to get rid of this?
instance Error (DecodingError, Producer ByteString IO ())

handle :: Node -> Socket -> SockAddr -> IO ()
handle n@Node{..} sock addr =
  -- TODO: Make sure no issues with async exceptions
    flip finally (modifyMVar_ connections (pure . Map.delete addr)) $ do
        modifyMVar_ connections $ pure . Map.insert addr sock
        let (outbc, inbc) = broadcaster

        tid <- myThreadId
        void . atomically . Pipes.Concurrent.send outbc $ Relay tid addr

        (outr, inr) <- spawn Unbounded
        let socketReader = runEffect . void . runErrorP
                         $ errorP (fromSocket sock 4096 ^. decoded)
                       >-> P.map Right >-> toOutput outr
            broadcastReader = runEffect $ fromInput inbc
                          >-> P.map Left >-> toOutput outr
        void $ concurrently socketReader broadcastReader

        runEffect $ fromInput inr >-> forever (
            await >>= \case
                Right GETADDR -> do
                    conns <- liftIO $ readMVar connections
                    each (Map.keys conns) >-> P.map encode >-> toSocket sock
                Right (ADDR addr') -> do
                    conns <- liftIO $ readMVar connections
                    if Map.member addr' conns
                    then return ()
                    else liftIO . void . connectFork addr' $ outgoing n addr'
                Left (Relay tid' addr') -> if tid' == tid
                                    then return ()
                                    else liftIO . send sock $ encode addr'
                _ -> return ()
         )


ackLen :: Int
ackLen = B.length $ encode ACK
