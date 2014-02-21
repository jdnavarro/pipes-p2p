{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
module Pipes.Network.P2P (node, launch) where

import Prelude hiding (log)
import Control.Applicative (Applicative, (<$>), (<*>), pure)
import Control.Monad (void, guard, forever, when, unless)
import Data.Monoid ((<>))
import Data.Foldable (for_)
import Control.Concurrent (ThreadId, myThreadId, killThread)
import Control.Concurrent.MVar (MVar, newMVar, readMVar, modifyMVar_)
import Control.Concurrent.Async (async, link)
import qualified Data.ByteString.Char8 as B8
import Data.Map (Map)
import qualified Data.Map.Strict as Map
import Data.Set (union)
import qualified Data.Set as Set
import Control.Monad.Reader (ReaderT, MonadReader, runReaderT, ask)
import Control.Monad.Trans (MonadIO, liftIO, lift)
import Control.Error (MaybeT, fromMaybe, runMaybeT, hoistMaybe)
import Control.Monad.Catch (MonadCatch, bracket_)
import Pipes (Consumer, (>->), runEffect, await, each)
import qualified Pipes.Prelude as P
import qualified Pipes.Concurrent
import Pipes.Concurrent
  ( Buffer(Unbounded)
  , Output
  , Input
  , spawn
  , toOutput
  , fromInput
  , atomically
  , performGC
  )
import Pipes.Network.TCP (toSocket)
import Network.Simple.SockAddr
  ( Socket
  , SockAddr
  , serve
  , connectFork
  , send
  , recv
  )
import Pipes.Network.P2P.Message
import Pipes.Network.P2P.SocketReader

type Mailbox = (Output Relay, Input Relay)

type Logger = Bool -> Address -> IO ()

data Node = Node
    { magic       :: Int
    , address     :: Address
    , logger      :: Logger
    , peers       :: MVar (Map Address ThreadId)
    , broadcaster :: Mailbox
    }

data NodeConn = NodeConn Node SockAddr Socket

newtype NodeConnT m r = NodeConnT
    { unNodeConnT :: ReaderT NodeConn m r
    } deriving ( Functor
               , Applicative
               , Monad
               , MonadIO
               , MonadCatch
               , MonadReader NodeConn
               )

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
launch n@Node{address} addrs = do
    for_ addrs $ \addr -> connectFork addr $ runNodeConnT n outgoing addr
    serve (getSockAddr address) $ runNodeConnT n incoming

outgoing :: (Functor m, MonadIO m, MonadCatch m) => NodeConnT m ()
outgoing = void . runMaybeT $ do
    NodeConn Node{address} addr _ <- ask
    deliver $ ME address
    expect . ME $ Addr addr
    deliver ACK
    expect ACK
    deliver GETADDR
    tid <- liftIO myThreadId
    lift $ handle (Addr addr) tid

incoming :: (Functor m, MonadIO m, MonadCatch m) => NodeConnT m ()
incoming = void . runMaybeT $ do
    NodeConn Node{address, peers} _ _ <- ask
    fetch >>= \case
        ME addr@(Addr _) -> do
           ps <- liftIO $ readMVar peers
           when (Map.notMember addr ps)
                (do deliver $ ME address
                    deliver ACK
                    expect ACK
                    tid <- liftIO myThreadId
                    lift $ handle addr tid)
        _ -> return ()

deliver :: MonadIO m => Message -> MaybeT (NodeConnT m) ()
deliver msg = do NodeConn Node{magic} _ sock <- ask
                 liftIO . send sock $ serialize magic msg

expect :: MonadIO m => Message -> MaybeT (NodeConnT m) ()
expect msg = do
    msg' <- fetch
    guard $ msg == msg'

fetch :: MonadIO m => MaybeT (NodeConnT m) Message
fetch = do
    NodeConn Node{magic} _ sock <- ask
    headerBS <- liftIO $ recv sock hSize
    (Header magic' nbytes) <- hoistMaybe $ decode headerBS
    guard $ magic == magic'
    bs <- liftIO $ recv sock nbytes
    hoistMaybe $ decode bs

register :: MonadIO m => Address -> ThreadId -> NodeConnT m ()
register addr tid = do
    NodeConn Node{peers, logger} _ _ <- ask
    liftIO . modifyMVar_ peers $ pure . Map.insert addr tid
    liftIO $ logger True addr

-- | Assumes the thread has already been killed
unregister :: MonadIO m => Address -> ThreadId -> NodeConnT m ()
unregister addr tid = do
    NodeConn Node{peers, logger} _ _ <- ask
    liftIO $ do killThread tid
                modifyMVar_ peers $ pure . Map.delete addr
                logger False addr

handle :: (MonadIO m, MonadCatch m) => Address -> ThreadId -> NodeConnT m ()
handle addr tid = bracket_ (register addr tid) (unregister addr tid) $ do
    NodeConn Node{magic, broadcaster} _ sock <- ask
    (ol, il) <- liftIO $ spawn Unbounded
    liftIO $ do
        let (obc, ibc) = broadcaster
        void . atomically . Pipes.Concurrent.send obc $ Relay tid addr
        void . fmap link . async $ do
            runEffect $ socketReader magic sock >-> P.map Right >-> toOutput ol
            performGC
        void . fmap link . async $ do
            runEffect $ fromInput ibc >-> P.map Left >-> toOutput ol
            performGC
    runEffect $ fromInput il >-> handler addr

handler :: (MonadIO m, MonadReader NodeConn m)
        => Address
        -> Consumer (Either Relay Message) m r
handler addr = do
    NodeConn n@Node{magic, peers} _ sock <- ask
    tid <- liftIO myThreadId
    forever $ await >>= \case
        Right GETADDR -> do
            ps <- liftIO $ Map.delete addr <$> readMVar peers
            runEffect $ each (Map.keys ps)
                    >-> P.map (serialize magic . ADDR)
                    >-> toSocket sock
        Right (ADDR a@(Addr a')) -> do
            ps <- liftIO $ readMVar peers
            unless (Set.null $ Set.fromList [a, addr] `union` Map.keysSet ps)
                   (liftIO . void $ connectFork a'
                                  $ runNodeConnT n outgoing a')
        Left (Relay tid' a) ->
            unless (tid' == tid)
                   (liftIO . send sock . serialize magic $ ADDR a)
        _ -> return ()
