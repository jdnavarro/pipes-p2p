{-# LANGUAGE DeriveGeneric #-}
module Pipes.Network.P2P.Message
  ( Header(..)
  , Relay(..)
  , encode
  , decode
  , hSize
  , serialize
  ) where

import Data.Monoid ((<>))
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.ByteString.Lazy (toStrict, fromStrict)
import Data.Binary (Binary)
import qualified Data.Binary as Binary(encode,decodeOrFail)
import Control.Concurrent (ThreadId)
import GHC.Generics (Generic)
import Control.Error (hush)

data Header = Header Int Int deriving (Show, Generic)

instance Binary Header

hSize :: Int
hSize = B.length . encode $ Header 0 0

serialize :: Binary a => Int -> a -> ByteString
serialize magic msg = encode (Header magic $ B.length bs) <> bs
  where
    bs = encode msg

data Relay a = Relay ThreadId a deriving (Show)

encode :: Binary a => a -> ByteString
encode = toStrict . Binary.encode

decode :: Binary a => ByteString -> Maybe a
decode = fmap third . hush . Binary.decodeOrFail . fromStrict
  where
    third (_,_,x) = x
