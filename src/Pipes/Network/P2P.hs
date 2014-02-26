{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Pipes.Network.P2P
  (
  -- * Node
    Node(..)
  , NodeConn(..)
  , NodeConnT
  , Connection(..)
  , Handlers(..)
  , node
  , launch
  , runNodeConn
  -- * handshake
  , deliver
  , expect
  , fetch
  -- * Re-exports
  , Relay(..)
  , serialize
  , MonadIO
  , liftIO
  , MonadCatch
  ) where

import Control.Applicative (Applicative, (<$>))
import Control.Monad (void, guard)
import Data.Foldable (for_)
import Control.Concurrent (myThreadId)
import Control.Concurrent.Async (async, link)
import Data.Binary (Binary)
import Control.Monad.Reader (ReaderT(..), MonadReader, runReaderT, ask)
import Control.Error (MaybeT, hoistMaybe)
import Control.Monad.Catch (MonadCatch, bracket_)
import Pipes (Producer, Consumer, (>->), runEffect, MonadIO, liftIO)
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



data Node a = Node
    { magic         :: Int
    , address       :: SockAddr
    , handlers      :: Handlers a
    , broadcaster   :: Mailbox a
    }

type Mailbox a = (Output (Relay a), Input (Relay a))

data Handlers a = Handlers
    { ohandshake   :: HandShaker a
    , ihandshake   :: HandShaker a
    , onConnect    :: Handler a
    , onDisconnect :: Handler a
    , msgConsumer  :: forall m . (MonadIO m, MonadCatch m)
                   => a -> Consumer (Either (Relay a) a) (NodeConnT a m) ()
    }

type HandShaker a = forall m . (Functor m, MonadIO m, MonadCatch m)
                 => NodeConnT a m (Maybe a)
type Handler a = forall m . MonadIO m => a -> m ()

data NodeConn a = NodeConn
    { getNode :: Node a
    , getConn :: Connection
    }

data Connection = Connection SockAddr Socket

newtype NodeConnT a m r = NodeConnT
    { runNodeConnT :: ReaderT (NodeConn a) m r
    } deriving ( Functor
               , Applicative
               , Monad
               , MonadIO
               , MonadCatch
               , MonadReader (NodeConn a)
               )

node :: (Functor m, Applicative m, MonadIO m, Binary a, Show a)
     => Int
     -> Handlers a
     -> SockAddr
     -> m (Node a)
node magic handlers addr =
    Node magic addr handlers <$> liftIO (spawn Unbounded)

launch :: (Functor m, Applicative m, MonadIO m, MonadCatch m, Binary a)
       => Node a -> [SockAddr] -> m ()
launch n@Node{address} addrs = do
    for_ addrs $ \addr -> connectFork addr $ runNodeConn n True addr
    serve address $ runNodeConn n False

runNodeConn :: (Functor m, MonadIO m, MonadCatch m, Binary a)
            => Node a
            -> Bool
            -> SockAddr
            -> Socket
            -> m ()
runNodeConn n isOut addr sock =
    runReaderT (runNodeConnT go) (NodeConn n $ Connection addr sock)
  where
    go = do NodeConn Node{handlers} _ <- ask
            (if isOut
             then ohandshake handlers
             else ihandshake handlers) >>= maybe (return ()) handle

deliver :: (Binary a, MonadIO m) => a -> MaybeT (NodeConnT a m) ()
deliver msg = do NodeConn (Node{magic}) (Connection _ sock) <- ask
                 liftIO . send sock $ serialize magic msg

expect :: (MonadIO m, Binary a, Eq a) => a -> MaybeT (NodeConnT a m) ()
expect msg = do
    msg' <- fetch
    guard $ msg == msg'

fetch :: (MonadIO m, Binary a) => MaybeT (NodeConnT a m) a
fetch = do
    NodeConn (Node{magic}) (Connection _ sock) <- ask
    headerBS <- liftIO $ recv sock hSize
    (Header magic' nbytes) <- hoistMaybe $ decode headerBS
    guard $ magic == magic'
    bs <- liftIO $ recv sock nbytes
    hoistMaybe $ decode bs

handle :: forall a m . (MonadIO m, MonadCatch m, Binary a)
       => a -> NodeConnT a m ()
handle msg = do
    NodeConn Node{magic, handlers, broadcaster} (Connection _ sock) <- ask
    let Handlers{onConnect, onDisconnect, msgConsumer} = handlers
    bracket_ (onConnect msg) (onDisconnect msg) $ do
        (ol, il) <- liftIO $ spawn Unbounded
        liftIO $ do
            let (obc, ibc) = broadcaster
            tid <- myThreadId
            void . atomically . Pipes.Concurrent.send obc $ Relay tid msg
            void . fmap link . async $ do
                runEffect $ (socketReader magic sock :: Producer a IO ())
                        >-> P.map Right >-> toOutput ol
                performGC
            void . fmap link . async $ do
                runEffect $ fromInput ibc >-> P.map Left >-> toOutput ol
                performGC
        runEffect $ fromInput il >-> msgConsumer msg
