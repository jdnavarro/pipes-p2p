{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns, RecordWildCards #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
module Pipes.Network.P2P
  ( node
  , launch
  ) where

import Prelude hiding (log)
import Control.Applicative (Applicative, (<$>), (<*>), pure)
import Control.Monad (void, guard, forever, when, unless)
import Data.Monoid ((<>))
import Control.Concurrent (myThreadId)
import Control.Concurrent.MVar (MVar, newMVar, readMVar, modifyMVar_)
import Control.Exception (finally)
import Data.Foldable (for_)

import Control.Concurrent.Async (concurrently)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as B8
import Data.Map (Map)
import qualified Data.Map as Map
import Control.Monad.Trans (MonadIO, liftIO, lift)
import Control.Monad.Error (Error)
import Control.Monad.Reader (ReaderT, MonadReader, runReaderT, ask)

import Control.Error (MaybeT, fromMaybe, runMaybeT, hoistMaybe)
import Control.Monad.Catch (MonadCatch)
import Lens.Family2 ((^.))

import Pipes (Producer, Consumer, (>->), runEffect, await, each)
import qualified Pipes.Prelude as P
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

type Logger = Bool -> Address -> IO ()

data Node = Node
    { magic       :: Int
    , address     :: Address
    , logger      :: Logger
    , connections :: MVar (Map Address Socket)
    , broadcaster :: Mailbox
    }

data NodeConn = NodeConn Node SockAddr Socket

newtype NodeConnT m r = NodeConnT
    { unNodeConnT :: ReaderT NodeConn m r
    } deriving (Functor, Applicative, Monad, MonadIO, MonadReader NodeConn)

runNodeConnT :: MonadIO m => Node -> NodeConnT m a -> SockAddr -> Socket -> m a
runNodeConnT n nt addr sock =
    runReaderT (unNodeConnT nt) (NodeConn n addr sock)

node :: (Functor m, Applicative m, MonadIO m)
     => Maybe Logger
     -> Int
     -> SockAddr
     -> m Node
node mlog magic addr = Node magic (Addr addr) log
                   <$> liftIO (newMVar Map.empty)
                   <*> liftIO (spawn Unbounded)
  where
    log = fromMaybe defaultLogger mlog
    defaultLogger flag (Addr addr') =
        B8.putStrLn $ "Node "
                   <> B8.pack (show addr)
                   <> ": "
                   <> "Address "
                   <> (if flag
                       then "added: "
                       else "deleted: ")
                   <> B8.pack (show addr')

launch :: (Functor m, Applicative m, MonadIO m, MonadCatch m)
       => Node
       -> [SockAddr]
       -> m ()
launch n@Node{..} addrs = do
    for_ addrs $ \addr -> connectFork addr $ runNodeConnT n outgoing addr
    serve (getSockAddr address) $ runNodeConnT n incoming

outgoing :: (Functor m, MonadIO m) => NodeConnT m ()
outgoing = void $ runMaybeT (do
    NodeConn Node{address} addr _ <- ask
    deliver $ ME address
    expect . ME $ Addr addr
    deliver ACK
    expect ACK
    deliver GETADDR) >> handle

incoming :: (Functor m, MonadIO m) => NodeConnT m ()
incoming = void . runMaybeT $ do
    NodeConn Node{address} _ _ <- ask
    fetch >>= \case
        ME (Addr _) -> deliver (ME address)
                    >> deliver ACK
                    >> expect ACK
                    >> lift handle
        _ -> return ()

deliver :: MonadIO m => Payload -> MaybeT (NodeConnT m) ()
deliver payload = do NodeConn Node{magic} _ sock <- ask
                     liftIO . send sock $ serialize magic payload

expect :: MonadIO m => Payload -> MaybeT (NodeConnT m) ()
expect payload = do
    payload' <- fetch
    guard $ payload == payload'

fetch :: MonadIO m => MaybeT (NodeConnT m) Payload
fetch = do
    NodeConn Node{magic} _ sock <- ask
    headerBS <- liftIO $ recv sock hSize
    (Header magic' nbytes) <- hoistMaybe $ decode headerBS
    guard $ magic == magic'
    bs <- liftIO $ recv sock nbytes
    hoistMaybe $ decode bs

-- TODO: How to get rid of this?
instance Error (DecodingError, Producer ByteString IO ())

handle :: MonadIO m => NodeConnT m ()
handle = do
    NodeConn Node{connections, logger, broadcaster} addr sock <- ask
    (ol, il) <- liftIO $ spawn Unbounded
    liftIO $ flip finally (modifyMVar_ connections (pure . Map.delete (Addr addr))
          >> logger False (Addr addr)) $ do
        let (obc, ibc) = broadcaster
        tid <- myThreadId

        -- Insert address
        modifyMVar_ connections $ pure . Map.insert (Addr addr) sock
        logger True (Addr addr)

        -- Broadcast new connected address
        void . atomically . Pipes.Concurrent.send obc $ Relay tid addr

        void $ concurrently
               (runEffect . void . runErrorP
                          $ errorP (fromSocket sock 4096 ^. decoded)
                        >-> P.map Right
                        >-> toOutput ol)
               (runEffect $ fromInput ibc >-> P.map Left >-> toOutput ol)
    runEffect $ fromInput il >-> handler

handler :: (MonadIO m, MonadReader NodeConn m)
        => Consumer (Either Relay Payload) m r
handler = do
    NodeConn n@Node{connections} _ sock <- ask
    tid <- liftIO myThreadId
    forever $ await >>= \case
        Right GETADDR -> do
            conns <- liftIO $ readMVar connections
            each (Map.keys conns) >-> P.map encode >-> toSocket sock
        Right (ADDR (Addr addr')) -> do
            conns <- liftIO $ readMVar connections
            when (Map.member (Addr addr') conns)
                 (liftIO . void $ connectFork addr' (runNodeConnT n outgoing addr'))
        Left (Relay tid' addr') -> unless
            (tid' == tid) (liftIO . send sock $ encode (Addr addr'))
        _ -> return ()
