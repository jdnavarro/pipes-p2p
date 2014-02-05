{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE NamedFieldPuns, RecordWildCards #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
module Pipes.Network.P2P where

import Control.Error
import Control.Applicative ((<$>), (<*>), pure)
import Control.Monad ((>=>), void, guard)
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import GHC.Generics (Generic)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.ByteString.Lazy (toStrict, fromStrict)
import qualified Data.Binary as Binary(encode,decode)
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
  ( HostPreference
  , HostName
  , ServiceName
  , fromSocket
  , connect
  , send
  , serve
  , recv
  , fromSocket
  , toSocket
  , Socket
  )

type Mailbox = (Output Message, Input Message)

data Node = Node
    { settings    :: Settings
    , connections :: MVar (Map Address Socket)
    , broadcaster :: MVar Mailbox
    }

node :: Settings -> IO Node
node settings = Node settings
            <$> newMVar Map.empty
            <*> (newMVar =<< spawn Unbounded)

data Settings = Settings
    { hostPreference :: HostPreference
    , serviceName    :: ServiceName
    } deriving (Show, Eq, Generic)

data Address = Address HostName ServiceName
               deriving (Show, Eq, Ord, Generic)

instance Binary Address

data Message = GETADDR
             | ADDR Address
             | VER Int
             | ACK
             | RELAY Address
               deriving (Show, Eq, Generic)

instance Binary Message

launch :: Node -> Address -> IO ()
launch n@Node{..} addr = connectO n addr >>
    serve (hostPreference settings)
          (serviceName settings)
          (connectI n . fst)

connectO :: Node -> Address -> IO ()
connectO n@Node{..} addr@(Address hn sn) =
    void . forkIO . connect hn sn $ \(sock, _) -> void . runMaybeT $ do
        -- handshake
        lift $ send sock (encode $ VER version)
        let liftMaybe = lift >=> hoistMaybe
        ver <- liftMaybe $ recv sock verLen
        ack <- liftMaybe $ recv sock ackLen
        guard $ decode ver <= version
        guard $ decode ack == ACK
        -- Request addresses, register and handle incoming messages
        lift $ do send sock $ encode GETADDR
                  modifyMVar_ connections $ pure . Map.insert addr sock
                  handle n sock

connectI :: Node -> Socket -> IO ()
connectI = undefined

-- TODO: How to get rid of this?
instance Error (DecodingError, Producer ByteString IO ())

handle :: Node -> Socket -> IO ()
handle n@Node{..} sock = void . forkIO $ do
    (_, inbc) <- readMVar broadcaster
    (outr, inr) <- spawn Unbounded
    void . forkIO . runEffect . void . runErrorP
         $ errorP (fromSocket sock 4096 ^. decoded) >-> toOutput outr
    void . forkIO . runEffect $ fromInput inbc >-> toOutput outr
    runEffect $ fromInput inr >-> do
        msg <- await
        case msg of
             ACK        -> return ()
             GETADDR    -> do conns <- liftIO $ readMVar connections
                              each (Map.keys conns) >-> P.map encode >-> toSocket sock
             ADDR addr  -> do conns <- liftIO $ readMVar connections
                              if Map.member addr conns
                              then return ()
                              else liftIO $ connectO n addr
             RELAY addr -> send sock (encode addr) -- TODO: Guard against same connection relay

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
