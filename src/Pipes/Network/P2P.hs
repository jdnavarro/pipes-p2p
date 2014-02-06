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
import Data.Word (Word8)

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
import Pipes.Binary (Binary(put,get), decoded, DecodingError)
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
  --, connect
  , send
  -- , serve
  , recv
  , fromSocket
  , toSocket
  )

type Mailbox = (Output Message, Input Message)

data Node = Node
    { address     :: SockAddr
    , connections :: MVar (Map SockAddr Socket)
    , broadcaster :: MVar Mailbox
    }

node :: SockAddr -> IO Node
node addr = Node addr <$> newMVar Map.empty <*> (newMVar =<< spawn Unbounded)

instance Binary SockAddr where
    put = undefined
    get = undefined

data Message = GETADDR
             | ADDR SockAddr
             | ME SockAddr
             | ACK
             | RELAY String SockAddr
               deriving (Show, Eq, Generic)

instance Binary Message

launch :: Node -> SockAddr -> IO ()
launch n@Node{..} addr = do
    void . forkIO $ connectO n addr
    serve address (connectI n)

connectO :: Node -> SockAddr -> IO ()
connectO n@Node{..} addr = void . runMaybeT $ do
    sock <- liftIO $ newSocket addr
    -- handshake
    lift $ send sock (encode $ ME address)
    oaddr <- liftMaybe $ recv sock len
    ack <- liftMaybe $ recv sock ackLen
    guard $ decode oaddr == addr
    guard $ decode ack == ACK
    -- Request addresses, register and handle incoming messages
    lift $ do send sock $ encode GETADDR
              handle n sock addr

connectI :: Node -> SockAddr -> Socket -> IO ()
connectI n@Node{..} addr sock = void . runMaybeT $ do
    oaddr <- liftMaybe $ recv sock len
    guard $ decode oaddr == addr
    lift . send sock $ encode (ME address) <> encode ACK
    ack <- liftMaybe $ recv sock ackLen
    guard $ decode ack == ACK

liftMaybe :: Monad m => m (Maybe c) -> MaybeT m c
liftMaybe = lift >=> hoistMaybe

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

len :: Int
len = B.length $ encode (1 :: Word8)

encode :: Binary a => a -> ByteString
encode = toStrict . Binary.encode

decode :: Binary a => ByteString -> a
decode = Binary.decode . fromStrict

newSocket :: SockAddr -> IO Socket
newSocket = undefined

serve :: SockAddr -> (SockAddr -> Socket -> IO ()) -> IO ()
serve = undefined
