{-# LANGUAGE QuasiQuotes #-}

module Main where

import G2.QuasiQuotes.QuasiQuotes
import MiniLib

import G2.QuasiQuotes.Parser

import DeBruijn.Test
import Arithmetics.Test
import Lambda.Test
import NQueens.Test

import Data.Time.Clock


timeIOAction :: Show a => IO a -> IO ()
timeIOAction action = do
  start <- getCurrentTime
  r <- action
  end <- getCurrentTime
  let diff = diffUTCTime end start
  print r
  putStrLn $ "time: " ++ show diff
  

arithmeticsTests :: IO ()
arithmeticsTests = do
  putStrLn "---------------------"
  putStrLn "arithmeticsTests ----"

  putStrLn "-- productTest"
  timeIOAction productTest

  putStrLn "---------------------\n\n"


lambdaTests :: IO ()
lambdaTests = do
  putStrLn "---------------------"
  putStrLn "lambdaTests ---------"

  putStrLn "-- lambdaTest1"
  timeIOAction lambdaTest1

  putStrLn "-- lambdaTest2"
  timeIOAction lambdaTest2

  putStrLn "---------------------\n\n"
  return ()


nqueensTests :: IO ()
nqueensTests = do
  putStrLn "---------------------"
  putStrLn "nqueensTests --------"

  putStrLn "-- queensTestN 4"
  timeIOAction $ queensTestN 4

  putStrLn "-- queensTestN 5"
  timeIOAction $ queensTestN 5

  putStrLn "-- queensTestN 6"
  timeIOAction $ queensTestN 6

  putStrLn "---------------------\n\n"
  return ()


debruijnTests :: IO ()
debruijnTests = do
  putStrLn "---------------------"
  putStrLn "debruijnTests -------"

  putStrLn "-- solveDeBruijnI"
  timeIOAction $ solveDeBruijnI

  putStrLn "-- solveDeBruijnK"
  timeIOAction $ solveDeBruijnK

  putStrLn "---------------------\n\n"
  return ()




main :: IO ()
main = do
    putStrLn "main: compiles!"

    timeIOAction $ solveDeBruijnI
    timeIOAction $ solveDeBruijnK
    -- arithmeticsTests
    -- lambdaTests
    -- nqueensTests
    -- debruijnTests


    putStrLn "main: done"


    -- print =<< queensTestN 6
    -- print =<< solveDeBruijnI
    -- print =<< solveDeBruijnK
    -- print =<< lambdaTest2
    
    -- putStrLn "-- Basic Test --"
    -- r <- f 8 10
    -- print r

    -- r2 <- g 7
    -- print r2

    -- r3 <- h 11
    -- print r3
    
    -- putStrLn "\n-- Bool Test --"
    -- print =<< boolTest 2
    -- print =<< boolTest 4

    -- putStrLn "\n-- maybeOrdering Test --"
    -- print =<< maybeOrderingTest (Just LT)

    -- putStrLn "\n-- Rearrange Tuples Test --"
    -- print =<< rearrangeTuples (4, 5) (-6, -4)

    -- putStrLn "\n-- Float Test --"
    -- print =<< floatTest (6.7) (9.5)

    -- putStrLn "\n-- Double Test --"
    -- print =<< doubleTest (2.2) (4.9)

    -- putStrLn "\n-- String Test --"
    -- print =<< stringTest "hiiiiiiiiiiiiiiiit!"

    -- putStrLn "\n-- Import Test --"
    -- print =<< importTest 5

    -- putStrLn "\n-- Infinite Test --"
    -- print =<< infiniteTest [5..]

    -- putStrLn "\n-- Infinite Test 2 --"
    -- print =<< infiniteTest2 [5..] 3

    -- putStrLn "\n-- Infinite Return --"
    -- ir <- infiniteReturn 8
    -- print $ fmap (headInf . tailInf) ir

-- fBad1 :: Float -> Int -> IO (Maybe Int)
-- fBad1 = [g2|(\y z -> \x ? x + 2 == y + z) :: Int -> Int -> Int -> Bool|]

-- fBad2 :: Int -> Int -> IO (Maybe Float)
-- fBad2 = [g2|(\y z -> \x ? x + 2 == y + z) :: Int -> Int -> Int -> Bool|]

-- f :: Int -> Int -> IO (Maybe Int)
-- f = [g2|\(y :: Int) (z :: Int) -> ?(x :: Int) | x + 2 == y + z|]

-- g :: Int  -> IO (Maybe (Int, Int))
-- g = [g2|\(a :: Int) -> ?(x :: Int) ?(y :: Int) | x < a && a < y && y - x > 10|]

-- h :: Int -> IO (Maybe [Int])
-- h = [g2|\(total :: Int) -> ?(lst :: [Int]) | sum lst == total && length lst >= 2|]

-- boolTest :: Int -> IO (Maybe Bool)
-- boolTest = [g2|\(i ::Int) -> ?(b :: Bool) | (i == 4) == b|]

-- maybeOrderingTest :: Maybe Ordering -> IO (Maybe (Maybe Ordering))
-- maybeOrderingTest = [g2|\(m1 :: Maybe Ordering) -> ?(m2 :: Maybe Ordering) | (fmap succ m1 == m2)|]

-- rearrangeTuples :: (Int, Int) -> (Int, Int) -> IO (Maybe (Int, Int))
-- rearrangeTuples = [g2|\(ux :: (Int, Int)) (yz :: (Int, Int)) -> ?(ab :: (Int, Int)) |
--                         let
--                             (u, x) = ux
--                             (y, z) = yz
--                             (a, b) = ab
--                         in
--                         (a == u || a == y)
--                             && (b == x || b == z) && (a + b == 0 )|]

-- floatTest :: Float -> Float -> IO (Maybe Float)
-- floatTest = [g2|\(f1 :: Float) (f2 :: Float) -> ?(f3 :: Float) | f1 < f3 && f3 < f2|]

-- doubleTest :: Double -> Double -> IO (Maybe Double)
-- doubleTest = [g2|\(d1 :: Double) (d2 :: Double) -> ?(d3 :: Double) | d1 <= d3 && d3 <= d2|]

-- stringTest :: String -> IO (Maybe String)
-- stringTest = [g2|\(str1 :: String) -> ?(str2 :: String) | str1 == str2 ++ "!"|]

-- importTest :: Int -> IO (Maybe Int)
-- importTest = [g2|\(x :: Int) -> ?(ans :: Int) | addTwo x == ans|]

-- infiniteTest :: [Int] -> IO (Maybe Int)
-- infiniteTest = [g2|\(xs :: [Int]) -> ?(x :: Int) | x == head xs|]

-- infiniteTest2 :: [Int] -> Int -> IO (Maybe [Int])
-- infiniteTest2 = [g2|\(xs :: [Int]) (t :: Int) -> ?(ys :: [Int]) | ys == take t xs|]

-- infiniteReturn ::  Int -> IO (Maybe (InfList Int))
-- infiniteReturn = [g2|\(t :: Int) -> ?(ys :: InfList Int) | headInf ys == t |]
