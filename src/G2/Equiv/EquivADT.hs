{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}

module G2.Equiv.EquivADT (
    proofObligations
  , Obligation (..)
  ) where

import G2.Language
import qualified G2.Language.ExprEnv as E
import qualified Data.HashSet as HS

import qualified Data.HashMap.Lazy as HM

import Control.Monad

import G2.Execution.NormalForms

import GHC.Generics (Generic)
import Data.Data
import Data.Hashable

-- the bool is True if guarded coinduction can be used
-- TODO do I need all of these typeclasses?
data Obligation = Ob Expr Expr
                  deriving (Show, Eq, Read, Generic, Typeable, Data)

instance Hashable Obligation

proofObligations :: HS.HashSet Name ->
                    State t ->
                    State t ->
                    Expr ->
                    Expr ->
                    Maybe (HS.HashSet Obligation)
proofObligations ns s1 s2 e1 e2 =
  exprPairing ns s1 s2 e1 e2 HS.empty [] []

exprPairing :: HS.HashSet Name -> -- ^ vars that should not be inlined on either side
               State t ->
               State t ->
               Expr ->
               Expr ->
               HS.HashSet Obligation -> -- ^ accumulator for output obligations
               [Name] -> -- ^ variables inlined previously on the LHS
               [Name] -> -- ^ variables inlined previously on the RHS
               Maybe (HS.HashSet Obligation)
exprPairing ns s1@(State {expr_env = h1}) s2@(State {expr_env = h2}) e1 e2 pairs n1 n2 =
  case (e1, e2) of
    _ | e1 == e2 -> Just pairs
    -- ignore all Ticks
    (Tick _ e1', _) -> exprPairing ns s1 s2 e1' e2 pairs n1 n2
    (_, Tick _ e2') -> exprPairing ns s1 s2 e1 e2' pairs n1 n2
    -- keeping track of inlined vars prevents looping
    (Var i1, Var i2) | (idName i1) `elem` n1
                     , (idName i2) `elem` n2 -> Just (HS.insert (Ob e1 e2) pairs)
    (Var i, _) | E.isSymbolic (idName i) h1 -> Just (HS.insert (Ob e1 e2) pairs)
               | m <- idName i
               , not $ m `elem` ns
               , Just e <- E.lookup m h1 -> exprPairing ns s1 s2 e e2 pairs (m:n1) n2
               | not $ (idName i) `elem` ns -> error "unmapped variable"
    (_, Var i) | E.isSymbolic (idName i) h2 -> Just (HS.insert (Ob e1 e2) pairs)
               | m <- idName i
               , not $ m `elem` ns
               , Just e <- E.lookup m h2 -> exprPairing ns s1 s2 e1 e pairs n1 (m:n2)
               | not $ (idName i) `elem` ns -> error "unmapped variable"
    -- See note in `moreRestrictive` regarding comparing DataCons
    (App _ _, App _ _)
        | (Data (DataCon d1 _)):l1 <- unApp e1
        , (Data (DataCon d2 _)):l2 <- unApp e2 ->
            if d1 == d2 then
                let ep = uncurry (exprPairing ns s1 s2)
                    ep' hs p = ep p hs n1 n2
                    l = zip l1 l2
                in foldM ep' pairs l
                else Nothing
    (Data (DataCon d1 _), Data (DataCon d2 _))
                       | d1 == d2 -> Just pairs
                       | otherwise -> Nothing
    (Prim p1 _, Prim p2 _) | p1 == Error || p1 == Undefined
                           , p2 == Error || p2 == Undefined -> Just pairs
    -- extra cases for avoiding Error problems
    (Prim p _, _) | (p == Error || p == Undefined)
                  , isExprValueForm h2 e2 -> Nothing
    (_, Prim p _) | (p == Error || p == Undefined)
                  , isExprValueForm h1 e1 -> Nothing
    (Prim _ _, _) -> Just (HS.insert (Ob e1 e2) pairs)
    (_, Prim _ _) -> Just (HS.insert (Ob e1 e2) pairs)
    -- TODO test equivalence of functions and arguments?
    -- Might cause the verifier to miss some important things
    -- doesn't seem to help with int-nat difference
    -- on top of that, it breaks expNat, even with these constraints
    {-
    (App f1 a1, App f2 a2)
                  | (Var i1):l1 <- unApp e1
                  , (Var i2):l2 <- unApp e2
                  , (idName i1) `elem` ns
                  , (idName i2) `elem` ns
                  , Just pairs' <- exprPairing ns s1 s2 a1 a2 pairs n1 n2 ->
                    exprPairing ns s1 s2 f1 f2 pairs' n1 n2
    -}
    (App _ _, _) -> Just (HS.insert (Ob e1 e2) pairs)
    (_, App _ _) -> Just (HS.insert (Ob e1 e2) pairs)
    (Lit l1, Lit l2) | l1 == l2 -> Just pairs
                     | otherwise -> Nothing
    (Lam _ _ _, _) -> Just (HS.insert (Ob e1 e2) pairs)
    (_, Lam _ _ _) -> Just (HS.insert (Ob e1 e2) pairs)
    -- assume that all types line up between the two expressions
    (Type _, Type _) -> Just pairs
    (Case _ _ _, _) -> Just (HS.insert (Ob e1 e2) pairs)
    (_, Case _ _ _) -> Just (HS.insert (Ob e1 e2) pairs)
    _ -> error $ "catch-all case\n" ++ show e1 ++ "\n" ++ show e2
