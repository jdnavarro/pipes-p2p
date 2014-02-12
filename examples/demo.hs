{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Concurrent
import Data.Foldable (traverse_)
import System.Directory (removeFile)
import Pipes.Network.P2P
import Network.Socket (SockAddr(..), iNADDR_ANY)


main :: IO ()
main = do
    let path1 = "/tmp/n1.socket"
        path2 = "/tmp/n2.socket"
        addr1 = SockAddrUnix path1
        addr2 = SockAddrUnix path2
        addr3 = SockAddrInet 1234 iNADDR_ANY
        addr4 = SockAddrInet 1235 iNADDR_ANY
        magic = 2741
    n1 <- node magic addr1
    n2 <- node magic addr2
    n3 <- node magic addr3
    n4 <- node magic addr4
    _ <- forkIO $ launch n1 []
    _ <- forkIO $ launch n2 [addr1]
    _ <- forkIO $ launch n3 [addr2,addr3]
    _ <- forkIO $ launch n4 [addr3]
    threadDelay $ 10 ^ (6::Int)
    traverse_ removeFile [path1,path2]
