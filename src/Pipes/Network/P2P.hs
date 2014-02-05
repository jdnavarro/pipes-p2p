{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE NamedFieldPuns, RecordWildCards #-}
{-# LANGUAGE DeriveGeneric #-}
module Pipes.Network.P2P where

import Control.Applicative ((<$>), (<*>), pure)
import Control.Monad ((>=>), void, guard, forever)
import Control.Concurrent (forkIO, myThreadId)
import Control.Concurrent.MVar (MVar, newMVar, readMVar, modifyMVar_)
import Data.Monoid ((<>))
import GHC.Generics (Generic)

import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.ByteString.Lazy (toStrict, fromStrict)
import qualified Data.Binary as Binary(encode,decode)
import Data.Map (Map)
import qualified Data.Map as Map
import Network.Socket (SockAddr(SockAddrInet), inet_ntoa)

import Control.Error (MaybeT, runMaybeT, hoistMaybe)
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
  , Socket
  , fromSocket
  , connect
  , send
  , serve
  , recv
  , fromSocket
  , toSocket
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
             | RELAY String Address
               deriving (Show, Eq, Generic)

instance Binary Message

launch :: Node -> Address -> IO ()
launch n@Node{..} addr = do
    void . forkIO $ connectO n addr
    serve (hostPreference settings)
          (serviceName settings)
          (uncurry $ connectI n)

connectO :: Node -> Address -> IO ()
connectO n@Node{..} addr@(Address hn sn) = do
    connect hn sn $ \(sock, _) -> void . runMaybeT $ do
        -- handshake
        lift $ send sock (encode $ VER version)
        ver <- liftMaybe $ recv sock verLen
        ack <- liftMaybe $ recv sock ackLen
        guard $ decode ver <= version
        guard $ decode ack == ACK
        -- Request addresses, register and handle incoming messages
        lift $ do send sock $ encode GETADDR
                  handle n sock addr

connectI :: Node -> Socket -> SockAddr -> IO ()
connectI n@Node{..} sock sockAddr = void . runMaybeT $ do
    ver <- liftMaybe $ recv sock verLen
    guard $ decode ver <= version
    lift . send sock $ encode (VER version) <> encode ACK
    ack <- liftMaybe $ recv sock ackLen
    guard $ decode ack == ACK

    case sockAddr of
        (SockAddrInet port host) -> lift $ do
            hn <- inet_ntoa host
            let addr = Address hn (show port)
            handle n sock addr
        _ -> error "connectI: Only IPv4 is supported"

liftMaybe :: Monad m => m (Maybe c) -> MaybeT m c
liftMaybe = lift >=> hoistMaybe

-- TODO: How to get rid of this?
instance Error (DecodingError, Producer ByteString IO ())

handle :: Node -> Socket -> Address -> IO ()
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
             ACK -> return ()
             GETADDR -> do
                 conns <- liftIO $ readMVar connections
                 each (Map.keys conns) >-> P.map encode >-> toSocket sock
             ADDR addr'  -> do
                 conns <- liftIO $ readMVar connections
                 if Map.member addr' conns
                 then return ()
                 else liftIO $ connectO n addr'
             RELAY tid' addr' -> if tid' == tid
                                 then return ()
                                 else send sock (encode addr')
        )

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
