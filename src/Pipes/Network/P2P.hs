{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE NamedFieldPuns, RecordWildCards #-}
{-# LANGUAGE LambdaCase #-}
module Pipes.Network.P2P where

import Control.Applicative ((<$>), (<*>), pure)
import Control.Monad (void, guard, forever)
import Control.Concurrent (myThreadId)
import Control.Concurrent.MVar (MVar, newMVar, readMVar, modifyMVar_)
import Control.Exception (finally)
import Data.Foldable (for_)

import Control.Concurrent.Async (concurrently)
import Data.ByteString (ByteString)
import Data.Map (Map)
import qualified Data.Map as Map

import Lens.Family2 ((^.))

import Pipes
import qualified Pipes.Prelude as P
import Control.Monad.Trans.Error
import Pipes.Lift (errorP, runErrorP)
import Pipes.Binary (decoded, DecodingError)
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

import Pipes.Network.P2P.Message

type Mailbox = (Output Relay, Input Relay)

data Node = Node
    { magic       :: Int
    , address     :: Address
    , connections :: MVar (Map Address Socket)
    , broadcaster :: Mailbox
    }

node :: SockAddr -> IO Node
node addr = Node 26513 (Addr addr) <$> newMVar Map.empty <*> spawn Unbounded

launch :: Node -> [SockAddr] -> IO ()
launch n@Node{..} addrs = do
    for_ addrs $ \a -> connectFork a $ outgoing n a
    serve (getSockAddr address) $ incoming n

outgoing :: Node -> SockAddr -> Socket -> IO ()
outgoing n@Node{..} addr sock = void $ do
    send sock . serialize magic $ ME address

    headerBS <- recv sock hSize
    let (Header _ nbytes) = decode headerBS
    oaddrBS <- recv sock nbytes
    guard $ decode oaddrBS == Addr addr
    send sock $ encode ACK

    headerBS' <- recv sock hSize
    let (Header _ nbytes') = decode headerBS'
    ack <- recv sock nbytes'
    guard $ decode ack == ACK

    send sock $ encode GETADDR

    handle n sock addr

incoming :: Node -> SockAddr -> Socket -> IO ()
incoming n@Node{..} addr sock = void $ do
    headerBS <- recv sock hSize
    let (Header _ nbytes) = decode headerBS
    _oaddrBS <- recv sock nbytes
    send sock . serialize magic $ ME address
    send sock $ encode ACK

    headerBS' <- recv sock hSize
    let (Header _ nbytes') = decode headerBS'
    ack <- recv sock nbytes'
    guard $ decode ack == ACK

    handle n sock addr

-- TODO: How to get rid of this?
instance Error (DecodingError, Producer ByteString IO ())

handle :: Node -> Socket -> SockAddr -> IO ()
handle n@Node{..} sock addr =
  -- TODO: Make sure no issues with async exceptions
    flip finally (modifyMVar_ connections (pure . Map.delete (Addr addr))) $ do
        modifyMVar_ connections $ pure . Map.insert (Addr addr) sock
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
                Right (ADDR (Addr addr')) -> do
                    conns <- liftIO $ readMVar connections
                    if Map.member (Addr addr') conns
                    then return ()
                    else liftIO . void . connectFork addr' $ outgoing n addr'
                Left (Relay tid' addr') -> if tid' == tid
                                    then return ()
                                    else liftIO . send sock $ encode (Addr addr')
                _ -> return ()
         )
