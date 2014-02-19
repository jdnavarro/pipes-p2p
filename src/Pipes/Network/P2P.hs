{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleInstances #-}
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
import Control.Concurrent (myThreadId)
import Control.Concurrent.MVar (MVar, newMVar, readMVar, modifyMVar_)
import Control.Concurrent.Async (async, link)
import qualified Data.ByteString.Char8 as B8
import Data.Set (Set, union)
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
    , peers       :: MVar (Set Address)
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
                   <$> liftIO (newMVar Set.empty)
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
    lift $ handle (Addr addr)

incoming :: (Functor m, MonadIO m, MonadCatch m) => NodeConnT m ()
incoming = void . runMaybeT $ do
    NodeConn Node{address, peers} _ _ <- ask
    fetch >>= \case
        ME addr@(Addr _) -> do
           ps <- liftIO $ readMVar peers
           when (Set.notMember addr ps)
                (do deliver $ ME address
                    deliver ACK
                    expect ACK
                    lift $ handle addr)
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

register :: MonadIO m => Address -> NodeConnT m ()
register addr = do
    NodeConn Node{peers, logger} _ _ <- ask
    liftIO . modifyMVar_ peers $ pure . Set.insert addr
    liftIO $ logger True addr

unregister :: MonadIO m => Address -> NodeConnT m ()
unregister addr = do
    NodeConn Node{peers, logger} _ _ <- ask
    liftIO . modifyMVar_ peers $ pure . Set.delete addr
    liftIO $ logger False addr

handle :: (MonadIO m, MonadCatch m) => Address -> NodeConnT m ()
handle addr = bracket_ (register addr) (unregister addr) $ do
    NodeConn Node{magic, broadcaster} _ sock <- ask
    (ol, il) <- liftIO $ spawn Unbounded
    liftIO $ do
        let (obc, ibc) = broadcaster
        tid <- myThreadId
        void . atomically . Pipes.Concurrent.send obc $ Relay tid addr
        a1 <- async $ do
            runEffect $ socketReader magic sock >-> P.map Right >-> toOutput ol
            performGC
        link a1
        a2 <- async $ do
            runEffect $ fromInput ibc >-> P.map Left >-> toOutput ol
            performGC
        link a2
    runEffect $ fromInput il >-> handler addr

handler :: (MonadIO m, MonadReader NodeConn m)
        => Address
        -> Consumer (Either Relay Payload) m r
handler addr = do
    NodeConn n@Node{magic, peers} _ sock <- ask
    tid <- liftIO myThreadId
    forever $ await >>= \case
        Right GETADDR -> do
            ps <- liftIO $ Set.delete addr <$> readMVar peers
            runEffect $ each (Set.toList ps)
                    >-> P.map (serialize magic . ADDR)
                    >-> toSocket sock
        Right (ADDR a@(Addr a')) -> do
            ps <- liftIO $ readMVar peers
            unless (Set.null $ Set.fromList [a, addr] `union` ps)
                   (liftIO . void $ connectFork a'
                                  $ runNodeConnT n outgoing a')
        Left (Relay tid' a) ->
            unless (tid' == tid)
                   (liftIO . send sock . serialize magic $ ADDR a)
        _ -> return ()
