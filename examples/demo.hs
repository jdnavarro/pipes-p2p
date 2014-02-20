{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Network.Socket (SockAddr(..), iNADDR_ANY)
import Pipes.Network.P2P

path1, path2 :: String
path1 = "/tmp/n1.socket"
path2 = "/tmp/n2.socket"

main :: IO ()
main = do
    let addr1 = SockAddrUnix path1
        addr2 = SockAddrUnix path2
        addr3 = SockAddrInet 1234 iNADDR_ANY
        addr4 = SockAddrInet 1235 iNADDR_ANY
        magic = 2741
    n1 <- node Nothing magic addr1
    n2 <- node Nothing magic addr2
    n3 <- node Nothing magic addr3
    n4 <- node Nothing magic addr4
    runNodes [(n1, []), (n2, [addr1]), (n3, [addr1, addr2]), (n4, [addr1])]
