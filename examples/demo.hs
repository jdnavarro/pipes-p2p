{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Exception (finally)
import Data.Foldable (traverse_)
import System.Directory (removeFile)
import Network.Socket (SockAddr(..), iNADDR_ANY)
import Pipes.Network.P2P

path1 = "/tmp/n1.socket"
path2 = "/tmp/n2.socket"

main :: IO ()
main = flip finally (traverse_ removeFile [path1,path2]) $ do
    let addr1 = SockAddrUnix path1
        addr2 = SockAddrUnix path2
        addr3 = SockAddrInet 1234 iNADDR_ANY
        addr4 = SockAddrInet 1235 iNADDR_ANY
        magic = 2741
    putStrLn "Node1:"
    n1 <- node Nothing magic addr1
    _ <- forkIO $ launch n1 []
    threadDelay $ 10 ^ (6::Int)
    putStrLn "Node2:"
    n2 <- node Nothing magic addr2
    _ <- forkIO $ launch n2 [addr1]
    threadDelay $ 10 ^ (6::Int)
    putStrLn "Node3:"
    n3 <- node Nothing magic addr3
    _ <- forkIO $ launch n3 [addr1,addr2]
    threadDelay $ 10 ^ (6::Int)
    putStrLn "Node4:"
    n4 <- node Nothing magic addr4
    _ <- forkIO $ launch n4 [addr3]
    threadDelay $ 100 ^ (6::Int)
