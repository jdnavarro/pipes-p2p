{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE NamedFieldPuns, RecordWildCards #-}
{-# LANGUAGE DeriveGeneric #-}
module Pipes.Network.P2P where

import Control.Applicative ((<$>), (<*>), pure)
import Control.Monad (void, guard, forever)
import Control.Concurrent (forkIO, myThreadId)
import Control.Concurrent.MVar (MVar, newMVar, readMVar, modifyMVar_)
import Data.Monoid ((<>))
import GHC.Generics (Generic)

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
import Pipes.Concurrent
  ( Buffer(Unbounded)
  , Output
  , Input
  , spawn
  , toOutput
  , fromInput
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

type Mailbox = (Output Message, Input Message)

data Node = Node
    { address     :: SockAddr
    , connections :: MVar (Map SockAddr Socket)
    , broadcaster :: MVar Mailbox
    }

node :: SockAddr -> IO Node
node addr = Node addr <$> newMVar Map.empty <*> (newMVar =<< spawn Unbounded)

data Message = GETADDR
             | ADDR SockAddr
             | ME SockAddr
             | ACK
             | RELAY String SockAddr
               deriving (Show, Eq, Generic)

instance Binary Message

launch :: Node -> SockAddr -> IO ()
launch n@Node{..} addr = do
    void $ connectFork addr (connectO n addr)
    serve address (connectI n address)

connectO :: Node -> SockAddr -> Socket -> IO ()
connectO n@Node{..} addr sock = void $ do
    -- handshake
    send sock (encode $ ME address)
    len <- recv sock 1
    oaddr <- recv sock (decode len)
    ack <- recv sock ackLen
    guard $ decode oaddr == addr
    guard $ decode ack == ACK
    -- Request addresses, register and handle incoming messages
    send sock $ encode GETADDR
    handle n sock addr

connectI :: Node -> SockAddr -> Socket -> IO ()
connectI Node{..} addr sock = void $ do
    len <- recv sock 1
    oaddr <- recv sock (decode len)
    guard $ decode oaddr == addr
    send sock $ encode (ME address) <> encode ACK
    ack <- recv sock ackLen
    guard $ decode ack == ACK

-- TODO: How to get rid of this?
instance Error (DecodingError, Producer ByteString IO ())

handle :: Node -> Socket -> SockAddr -> IO ()
handle n@Node{..} sock addr = do
    modifyMVar_ connections $ pure . Map.insert addr sock
    (outbc, inbc) <- readMVar broadcaster
    tid <- show <$> myThreadId
    runEffect $ yield (RELAY tid addr) >-> toOutput outbc
    (outr , inr ) <- spawn Unbounded
    void . forkIO . runEffect . void . runErrorP
         $ errorP (fromSocket sock 4096 ^. decoded) >-> toOutput outr
    void . forkIO . runEffect $ fromInput inbc >-> toOutput outr
    runEffect $ fromInput inr >-> forever (do
        msg <- await
        case msg of
             GETADDR -> do
                 conns <- liftIO $ readMVar connections
                 each (Map.keys conns) >-> P.map encode >-> toSocket sock
             ADDR addr'  -> do
                 conns <- liftIO $ readMVar connections
                 if Map.member addr' conns
                 then return ()
                 else liftIO . void $ connectFork addr' (connectO n addr')
             RELAY tid' addr' -> if tid' == tid
                                 then return ()
                                 else liftIO $ send sock (encode addr')
             _ -> return ()
        )

ackLen :: Int
ackLen = B.length $ encode ACK
