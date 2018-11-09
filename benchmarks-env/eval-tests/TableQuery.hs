module TableQuery where

import Prelude hiding (lookup)
import System.Directory
import Data.List hiding (lookup)
import Data.List.Split
import Data.Map hiding (map, filter)

tableFile :: String
tableFile = "/home/celery/foo/yale/G2/benchmarks-env/id-file-pairs.txt"

wi15Dir :: String
wi15Dir = "/home/celery/foo/yale/G2/benchmarks-env/liquidhaskell-study/wi15/"

wi15SafeDir :: String
wi15SafeDir = wi15Dir ++ "safe/"

wi15UnsafeDir :: String
wi15UnsafeDir = wi15Dir ++ "unsafe/"

-- file -> id mapping
loadFileIdTable :: IO (Map String String)
loadFileIdTable = do
  raw <- readFile tableFile
  let pairs = read raw :: [(String, String)]
  let table = fromList $ map (\(a, b) -> (b, a)) pairs
  return table

-- Loads all the .log files
loadLogs :: IO [String]
loadLogs = do
  safes <- getDirectoryContents wi15SafeDir
  unsafes <- getDirectoryContents wi15UnsafeDir
  let logs = sort $ filter (isInfixOf ".log") $ safes ++ unsafes
  return logs

kindFromFile :: String -> Maybe String
kindFromFile file =
  if "KMeans.lhs" `isInfixOf` file
    then Just "KMeans"
  else if "List.lhs" `isInfixOf` file
    then Just "List"
  else if "MapReduce.lhs" `isInfixOf` file
    then Just "MapReduce"
  else
    Nothing

timeFromFile :: String -> Maybe String
timeFromFile file =
  case splitOn ".lhs" file of
    (_ : mTime : _) ->
      if "-2015" `isInfixOf` mTime
        then Just mTime
      else Nothing
    _ -> Nothing

-- Find the file corresponding to a log
fileFromLog :: String -> Maybe String
fileFromLog file =
  case splitOn ".log" file of
    (f : _) -> Just f
    _ -> Nothing

-- Filter out all the logs that belong to a particular id
filterIdLogs :: String -> Map String String -> [String] -> [String]
filterIdLogs id table logs =
  filter (\log -> case fileFromLog log of
              Just l -> Just id == lookup l table
              _ -> False) logs

-- Filter all the logs that are a particular kind
filterKindLogs :: String -> [String] -> [String]
filterKindLogs kind logs =
  filter (isInfixOf kind) logs

-- Get the logs for later file submissiions
afterLogs :: String -> Map String String -> [String] -> Maybe [String]
afterLogs file table logs = do
  id <- lookup file table
  kind <- kindFromFile file
  let idKindLogs = filterKindLogs kind $ filterIdLogs id table logs
  let afterLogs = filter (\l -> file < l) idKindLogs
  -- return afterLogs
  -- take the tail because otherwise it includes log of current file
  return $ tail afterLogs
  

