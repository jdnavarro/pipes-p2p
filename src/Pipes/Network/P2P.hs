{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

{-| Use 'node' to create a 'Node' with your desired settings and then 'launch'
    it.
-}

module Pipes.Network.P2P
  (
  -- * Nodes and Connections
    Node(..)
  , node
  , NodeConn(..)
  , NodeConnT
  , Connection(..)
  , Handlers(..)
  , launch
  , runNodeConn
  -- * Handshaking utilities
  , deliver
  , expect
  , fetch
  -- * Messaging
  , Relay(..)
  , serialize
  -- * Re-exports
  , MonadIO
  , liftIO
  , MonadCatch
  ) where

import Control.Applicative (Applicative, (<$>))
import Control.Monad (forever, void, unless, guard)
import Data.Monoid ((<>))
import Data.Foldable (for_, forM_)
import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.Async (async, link)
import GHC.Generics (Generic)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.ByteString.Lazy (toStrict, fromStrict)
import Data.Binary (Binary)
import qualified Data.Binary as Binary(encode,decodeOrFail)
import Control.Monad.Reader (ReaderT(..), MonadReader, runReaderT, ask)
import Control.Error (MaybeT, hoistMaybe, hush)
import Control.Monad.Catch (MonadCatch, bracket_)
import Pipes
  ( Pipe
  , Producer
  , Consumer
  , (>->)
  , runEffect
  , yield
  , await
  , MonadIO
  , liftIO
  )
import Pipes.Core (Proxy, (>+>), request, respond)
import qualified Pipes.Prelude as P
import Pipes.Network.TCP (fromSocketN)
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

-- * Node and Connections

{-| A P2P node.

    The constructor is exported for pattern matching purposes. Under normal
    circumstances, you should use 'node' for 'Node' creation.
-}
data Node a = Node
    { magic       :: Int
    -- ^ Magic bytes.
    , address     :: SockAddr
    -- ^ Listening address.
    , handlers    :: Handlers a
    -- ^ Functions to define the behavior of the 'Node'.
    , broadcaster :: Mailbox a
    -- ^ 'MailBox' to relay internal messages.
    }

-- | Smart constructor to create a 'Node'.
node :: (Functor m, Applicative m, MonadIO m, Binary a, Show a)
     => Int
     -- ^ Magic bytes.
     -> SockAddr
     -- ^ Listening address.
     -> Handlers a
     -- ^ Functions to define the behavior of the 'Node'.
     -> m (Node a)
node magic addr handlers =
    Node magic addr handlers <$> liftIO (spawn Unbounded)
{-# INLINABLE node #-}

-- | Functions to define the behavior of a 'Node'.
data Handlers a = Handlers
    { ohandshake   :: HandShaker a
    -- ^ What to do for an outgoing connection handshake.
    , ihandshake   :: HandShaker a
    -- ^ What to do for an incoming connection handshake.
    , onConnect    :: Handler a
    -- ^ Action to perform after a connection has been established.
    , onDisconnect :: Handler a
    -- ^ Action to perform after a connection has ended.
    , msgConsumer  :: forall m . (MonadIO m, MonadCatch m)
                   => a -> Consumer (Either (Relay a) a) (NodeConnT a m) ()
    -- ^ This consumes incoming messages either from other connections in the
    --   node, as @'Left' ('Relay' a)@, or from the current connected socket,
    --   as @'Right' a@.
    --   This is only used after a handshake has been successful.
    }

-- | Convenient data type to put together a 'Node' and a 'Connection'.
data NodeConn a = NodeConn (Node a) (Connection)

{-| Convenient data type to put together a network address and its
    corresponding socket.
-}
data Connection = Connection SockAddr Socket

-- | Convenient wrapper for a 'ReaderT' monad containing a 'NodeConn'.
newtype NodeConnT a m r = NodeConnT
    { runNodeConnT :: ReaderT (NodeConn a) m r
    } deriving ( Functor
               , Applicative
               , Monad
               , MonadIO
               , MonadCatch
               , MonadReader (NodeConn a)
               )

-- | Launch a 'Node'.
launch :: (Functor m, Applicative m, MonadIO m, MonadCatch m, Binary a)
       => Node a
       -- ^
       -> [SockAddr]
       -- ^ Addresses to try to connect on launch.
       -> m ()
launch n@Node{address} addrs = do
    for_ addrs $ \addr -> connectFork addr $ runNodeConn n True addr
    serve address $ runNodeConn n False
{-# INLINABLE launch #-}

-- | Connect a 'Node' to the given pair of 'SockAddr', 'Socket'.
runNodeConn :: (Functor m, MonadIO m, MonadCatch m, Binary a)
            => Node a
            -- ^
            -> Bool
            -- ^ Whether this is an outgoing connection.
            -> SockAddr
            -- ^ Address to connect to.
            -> Socket
            -- ^ Socket to connect to.
            -> m ()
runNodeConn n isOut addr sock =
    runReaderT (runNodeConnT go) (NodeConn n $ Connection addr sock)
  where
    go = do NodeConn Node{handlers} _ <- ask
            (if isOut
             then ohandshake handlers
             else ihandshake handlers) >>= maybe (return ()) handle
{-# INLINABLE runNodeConn #-}

-- * Handshaking utilities

{-| Send an expected message.

    The message is automatically serialized and prepended with the magic
    bytes.
-}
deliver :: (Binary a, MonadIO m)
        => a
        -- ^ Message
        -> MaybeT (NodeConnT a m) ()
deliver msg = do NodeConn (Node{magic}) (Connection _ sock) <- ask
                 liftIO . send sock $ serialize magic msg
{-# INLINABLE deliver #-}

{-| Receive a message and make sure it's the same as the expected message.

    The message is automatically deserialized and checked for the correct
    magic bytes.
-}
expect :: (MonadIO m, Binary a, Eq a)
       => a
       -- ^ Message
       -> MaybeT (NodeConnT a m) ()
expect msg = do
    msg' <- fetch
    guard $ msg == msg'
{-# INLINABLE expect #-}

{-| Fetch next message.

    The message is automatically deserialized and checked for the correct magic
    bytes. Uses the length bytes in the header to pull the exact number of
    bytes of the message.
-}
fetch :: (MonadIO m, Binary a) => MaybeT (NodeConnT a m) a
fetch = do
    NodeConn (Node{magic}) (Connection _ sock) <- ask
    headerBS <- recv sock hSize
    (Header magic' nbytes) <- hoistMaybe $ decode headerBS
    guard $ magic == magic'
    bs <- liftIO $ recv sock nbytes
    hoistMaybe $ decode bs
{-# INLINABLE fetch #-}

-- * Messaging

-- | Internal message to relay to the rest of connections in the node.
data Relay a = Relay ThreadId a deriving (Show)

-- | Serializes and prepends a 'Header' to a message.
serialize :: Binary a
          => Int -- ^ Magic bytes.
          -> a   -- ^ Message.
          -> ByteString
serialize magic msg = encode (Header magic $ B.length bs) <> bs
  where
    bs = encode msg
{-# INLINE serialize #-}

-- * Internal

type Mailbox a = (Output (Relay a), Input (Relay a))
type HandShaker a = forall m . (Functor m, MonadIO m, MonadCatch m)
                 => NodeConnT a m (Maybe a)
type Handler a = forall m . MonadIO m => a -> m ()


-- | Coordinates the handlers in the 'Node'.
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

-- ** Header

data Header = Header Int Int deriving (Show, Generic)

instance Binary Header

hSize :: Int
hSize = B.length . encode $ Header 0 0
{-# INLINE hSize #-}

-- ** Socket reader

socketReader :: (MonadIO m, Binary a) => Int -> Socket -> Producer a m ()
socketReader magic sock = fromSocketN sock >+> beheader magic >+> decoder $ ()
{-# INLINABLE socketReader #-}

decoder :: (MonadIO m, Binary a) => () -> Pipe ByteString a m ()
decoder () = forever $ do
    pbs <- await
    forM_ (decode pbs) yield
{-# INLINABLE decoder #-}

beheader :: MonadIO m => Int -> () -> Proxy Int ByteString () ByteString m ()
beheader magic () = forever $ do
    hbs <- request hSize
    case decode hbs of
        Nothing -> return ()
        Just (Header magic' nbytes) -> unless (magic /= magic')
                                     $ request nbytes >>= respond
{-# INLINABLE beheader #-}

-- ** Strict Binary

encode :: Binary a => a -> ByteString
encode = toStrict . Binary.encode
{-# INLINE encode #-}

decode :: Binary a => ByteString -> Maybe a
decode = fmap third . hush . Binary.decodeOrFail . fromStrict
  where
    third (_,_,x) = x
{-# INLINE decode #-}
