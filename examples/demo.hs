{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Concurrent
import Data.Foldable
import Control.Exception
import Network.Socket (SockAddr(..), iNADDR_ANY)
import Pipes.Network.P2P

path1,path2 :: String
path1 = "/tmp/n1.socket"
path2 = "/tmp/n2.socket"

addr1,addr2,addr3,addr4 :: SockAddr
addr1 = SockAddrUnix path1
addr2 = SockAddrUnix path2
addr3 = SockAddrInet 1234 iNADDR_ANY
addr4 = SockAddrInet 1235 iNADDR_ANY

magic :: Int
magic = 2741

main :: IO ()
main = do
    n1 <- node Nothing magic addr1
    n2 <- node Nothing magic addr2
    n3 <- node Nothing magic addr3
    n4 <- node Nothing magic addr4
    t1 <- forkIO (launch n1 [])
    threadDelay 10000
    t2 <- forkIO (launch n2 [addr1])
    threadDelay 10000
    t3 <- forkIO (launch n3 [addr1, addr2])
    threadDelay 10000
    launch n4 [addr1] `finally` traverse_ killThread [t1,t2,t3]
