{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}

module G2.Internals.Language.PathConds ( PathCond (..)
                                       , PathConds
                                       , empty
                                       , fromList
                                       , insert
                                       , number
                                       , relevant
                                       , scc
                                       , toList) where

import G2.Internals.Language.AST
import G2.Internals.Language.Naming
import G2.Internals.Language.Syntax

import Data.Coerce
import qualified Data.Map as M
import Data.Maybe

-- | You can visualize a PathConds as [PathCond] (accessible via toList)
--
-- In the implementation:
-- Each name (Just n) maps to some (but not neccessarily all) of the PathCond's that
-- contain n, and a list of all names that appear in some PathCond alongside
-- the name n
-- PathConds that contain no names are stored in Nothing
--
-- You can visualize this as a graph, with Names and Nothing as Nodes
-- Edges exist in a PathConds pcs netween a name n, and any names in
-- snd $ M.lookup n (toMap pcs)
newtype PathConds = PathConds (M.Map (Maybe Name) ([PathCond], [Name]))
                    deriving (Show, Eq, Read)

-- | Path conditions represent logical constraints on our current execution
-- path. We can have path constraints enforced due to case/alt branching, due
-- to assertion / assumptions made, or some externally coded factors.
data PathCond = AltCond AltMatch Expr Bool
              | ExtCond Expr Bool
              | ConsCond DataCon Expr Bool
              | PCExists Id
              deriving (Show, Eq, Read)

toMap :: PathConds -> M.Map (Maybe Name) ([PathCond], [Name])
toMap = coerce

empty :: PathConds
empty = PathConds M.empty

fromList :: [PathCond] -> PathConds
fromList = coerce . foldr insert empty

-- Each name n maps to all other names that are in any PathCond containing n
-- However, each n does NOT neccessarily map to all PCs containing n- instead each
-- PC is associated with only one name.
-- This is ok, because the PCs can only be externally accessed by toList (which 
-- returns all PCs anyway) or scc (which forces exploration over all shared names)
insert :: PathCond -> PathConds -> PathConds
insert p (PathConds pcs) =
    let
        ns = varNamesInPC p

        (hd, insertAt) = case ns of
            [] -> (Nothing, [Nothing])
            (h:_) -> (Just h, map Just ns)
    in
    PathConds $ M.adjust (\(p', ns') -> (p:p', ns')) hd
              $ foldr (M.alter (insert' ns)) pcs insertAt

insert' :: [Name] -> Maybe ([PathCond], [Name]) -> Maybe ([PathCond], [Name])
insert' ns Nothing = Just ([], ns)
insert' ns (Just (p', ns')) = Just (p', ns ++ ns')

number :: PathConds -> Int
number = length . toList

-- | Filters a PathConds to only those PathCond's that potentially impact the
-- given PathCond's satisfiability (i.e. they are somehow linked by variable names)
relevant :: [PathCond] -> PathConds -> PathConds
relevant pc pcs = scc (concatMap varNamesInPC pc) pcs

varNamesInPC :: PathCond -> [Name]
varNamesInPC (AltCond a e _) = varNamesInAltMatch a ++ varNames e
varNamesInPC (ExtCond e _) = varNames e
varNamesInPC (ConsCond _ e _) = varNames e
varNamesInPC (PCExists _) = []

varNamesInAltMatch :: AltMatch -> [Name]
varNamesInAltMatch (DataAlt _ i) = names i
varNamesInAltMatch _ = []

varNames :: (ASTContainer m Expr) => m -> [Name]
varNames = evalASTs varNames'

varNames' :: Expr -> [Name]
varNames' (Var (Id n _)) = [n]
varNames' _ = []

scc :: [Name] -> PathConds -> PathConds
scc ns (PathConds pc) = PathConds $ scc' ns pc M.empty

scc' :: [Name] -> (M.Map (Maybe Name) ([PathCond], [Name])) -> (M.Map (Maybe Name) ([PathCond], [Name])) -> (M.Map (Maybe Name) ([PathCond], [Name]))
scc' [] _ pc = pc
scc' (n:ns) pc newpc =
    -- Check if we already inserted the name information
    case M.lookup (Just n) newpc of
        Just _ -> scc' ns pc newpc
        Nothing ->
            -- If we didn't, lookup info to insert,
            -- and add names to the list of names to search
            case M.lookup (Just n) pc of
                Just pcn@(_, ns') -> scc' (ns ++ ns') pc (M.insert (Just n) pcn newpc)
                Nothing -> scc' ns pc newpc

toList :: PathConds -> [PathCond]
toList = concatMap fst . M.elems . toMap

instance ASTContainer PathConds Expr where
    containedASTs = containedASTs . toMap
    
    modifyContainedASTs f = coerce . modifyContainedASTs f . toMap

instance ASTContainer PathConds Type where
    containedASTs = containedASTs . toMap

    modifyContainedASTs f = coerce . modifyContainedASTs f . toMap

instance ASTContainer PathCond Expr where
    containedASTs (ExtCond e _ )   = [e]
    containedASTs (AltCond _ e _) = [e]
    containedASTs (ConsCond _ e _) = [e]
    containedASTs (PCExists _) = []

    modifyContainedASTs f (ExtCond e b) = ExtCond (modifyContainedASTs f e) b
    modifyContainedASTs f (AltCond a e b) =
        AltCond (modifyContainedASTs f a) (modifyContainedASTs f e) b
    modifyContainedASTs f (ConsCond dc e b) =
        ConsCond (modifyContainedASTs f dc) (modifyContainedASTs f e) b
    modifyContainedASTs _ pc = pc

instance ASTContainer PathCond Type where
    containedASTs (ExtCond e _)   = containedASTs e
    containedASTs (AltCond e a _) = containedASTs e ++ containedASTs a
    containedASTs (ConsCond dcl e _) = containedASTs dcl ++ containedASTs e
    containedASTs (PCExists i) = containedASTs i

    modifyContainedASTs f (ExtCond e b) = ExtCond e' b
      where e' = modifyContainedASTs f e
    modifyContainedASTs f (AltCond e a b) = AltCond e' a' b
      where e' = modifyContainedASTs f e
            a' = modifyContainedASTs f a
    modifyContainedASTs f (ConsCond dc e b) =
        ConsCond (modifyContainedASTs f dc) (modifyContainedASTs f e) b
    modifyContainedASTs f (PCExists i) = PCExists (modifyContainedASTs f i)

instance Named PathConds where
    names (PathConds pc) = (catMaybes $ M.keys pc) ++ concatMap (\(p, n) -> names p ++ n) pc

    rename old new (PathConds pc) =
        PathConds . M.mapKeys (\k -> if k == (Just old) then (Just new) else k)
                  $ rename old new pc

instance Named PathCond where
    names (AltCond am e _) = names am ++ names e
    names (ExtCond e _) = names e
    names (ConsCond d e _) = names d ++  names e
    names (PCExists i) = names i

    rename old new (AltCond am e b) = AltCond (rename old new am) (rename old new e) b
    rename old new (ExtCond e b) = ExtCond (rename old new e) b
    rename old new (ConsCond d e b) = ConsCond (rename old new d) (rename old new e) b
    rename old new (PCExists i) = PCExists (rename old new i)