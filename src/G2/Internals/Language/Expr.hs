{-# LANGUAGE IncoherentInstances #-}
{-# LANGUAGE FlexibleContexts #-}

module G2.Internals.Language.Expr ( module G2.Internals.Language.Casts
                                  , replaceVar
                                  , unApp
                                  , mkApp
                                  , mkTrue
                                  , mkFalse
                                  , mkLamBindings
                                  , insertInLams
                                  , replaceASTs
                                  , args
                                  , nthArg
                                  , vars
                                  , varNames
                                  , varId
                                  , symbVars
                                  , freeVars
                                  , mkStrict) where

import G2.Internals.Language.AST
import G2.Internals.Language.Casts
import qualified G2.Internals.Language.ExprEnv as E
import G2.Internals.Language.Naming
import G2.Internals.Language.Support
import G2.Internals.Language.Syntax
import G2.Internals.Language.Typing

import Data.Foldable
import qualified Data.Map as M

replaceVar :: (ASTContainer m Expr) => Name -> Expr -> m -> m
replaceVar n re = modifyASTs (replaceVar' n re)

replaceVar' :: Name -> Expr -> Expr -> Expr
replaceVar' n re v@(Var (Id n' _)) = if n == n' then re else v
replaceVar' _ _ e = e

-- | unApp
-- Unravels the application spine.
unApp :: Expr -> [Expr]
unApp (App f a) = unApp f ++ [a]
unApp expr = [expr]

-- | mkApp
-- Turns the Expr list into an application spine
mkApp :: [Expr] -> Expr
mkApp [] = error "mkApp: empty list"
mkApp (e:[]) = e
mkApp (e1:e2:es) = mkApp (App e1 e2 : es)

mkTrue :: Expr
mkTrue = Lit $ LitBool True

mkFalse :: Expr
mkFalse = Lit $ LitBool False

mkIdentity :: Type -> Expr
mkIdentity t =
    let
        x = Id (Name "x" Nothing 0) t
    in
    Lam x (Var x)

mkLamBindings :: NameGen -> [(a, Maybe Name, Type)] -> (NameGen -> [(a, Id)] -> (Expr, NameGen))-> (Expr, NameGen)
mkLamBindings ng ats f = mkLamBindings' ng ats [] f

mkLamBindings' :: NameGen -> [(a, Maybe Name, Type)] -> [(a, Id)] -> (NameGen -> [(a, Id)] -> (Expr, NameGen))-> (Expr, NameGen)
mkLamBindings' ng [] fIds f =
  let
      (e, ng') = f ng (reverse fIds)
      e' = foldr (Lam) e (reverse $ map snd fIds)
  in
  (e', ng')
mkLamBindings' ng ((as, n, t):ats) fIds f =
    let
        (fId, ng') = case n of
            Just n' -> (Id n' t, ng)
            Nothing -> freshId t ng
    in
    mkLamBindings' ng' ats ((as, fId):fIds) f

-- Runs the given function f on the expression nested in the lambdas, and
-- rewraps the new expression with the Lambdas
insertInLams :: ([Id] -> Expr -> Expr) -> Expr -> Expr
insertInLams f = insertInLams' f []

insertInLams' :: ([Id] -> Expr -> Expr) -> [Id] -> Expr -> Expr
insertInLams' f xs (Lam i e)  = Lam i $ insertInLams' f (i:xs) e
insertInLams' f xs e = f (reverse xs) e

args :: Expr -> [Id]
args (Lam i e) = i:args e
args _ = []

nthArg :: Expr -> Int -> Id
nthArg e i = args e !! (i - 1)

--Returns all Vars in an ASTContainer
vars :: (ASTContainer m Expr) => m -> [Expr]
vars = evalASTs vars'

vars' :: Expr -> [Expr]
vars' v@(Var _) = [v]
vars' _ = []

varNames :: (ASTContainer m Expr) => m -> [Name]
varNames = evalASTs varNames'

varNames' :: Expr -> [Name]
varNames' (Var (Id n _)) = [n]
varNames' _ = []

varId :: Expr -> Maybe Id
varId (Var i) = Just i
varId _ = Nothing

symbVars :: (ASTContainer m Expr) => ExprEnv -> m -> [Expr]
symbVars eenv = filter (symbVars' eenv) . vars

symbVars' :: ExprEnv -> Expr -> Bool
symbVars' eenv (Var (Id n _)) = E.isSymbolic n eenv
symbVars' _ _ = False

-- | freeVars
-- Returns the free (unbound by a Lambda, Let, or the Expr Env) variables of an expr
freeVars :: ASTContainer m Expr => E.ExprEnv -> m -> [Id]
freeVars eenv = evalASTsM (freeVars' eenv)

freeVars' :: E.ExprEnv -> [Id] -> Expr -> ([Id], [Id])
freeVars' _ _ (Let b _) = (map fst b, [])
freeVars' _ _ (Lam b _) = ([b], [])
freeVars' eenv bound (Var i) =
    if E.member (idName i) eenv || i `elem` bound then
        ([], [])
    else
        ([], [i])
freeVars' _ _ _ = ([], [])

-- | mkStrict
-- Forces the complete evaluation of an expression
mkStrict :: (ASTContainer m Expr) => Walkers -> m -> m
mkStrict w = modifyContainedASTs (mkStrict' w)

mkStrict' :: Walkers -> Expr -> Expr
mkStrict' w e =
    let
        ret = returnType e
    in
    case ret of
        (TyConApp n ts) ->
            App (foldl' (App) (Var $ w M.! n) (map Type ts ++ map (typeToWalker w) ts)) e
        _ -> e


typeToWalker :: Walkers -> Type -> Expr
typeToWalker w (TyConApp n _) = Var $ w M.! n
typeToWalker _ TyInt = mkLitStrict TyInt TyLitInt I
typeToWalker _ TyFloat = mkLitStrict TyFloat TyLitFloat F
typeToWalker _ TyDouble = mkLitStrict TyDouble TyLitDouble D
typeToWalker _ TyChar = mkLitStrict TyChar TyLitChar C
typeToWalker _ t = mkIdentity t

mkLitStrict :: Type -> Type -> PrimCon -> Expr
mkLitStrict t lt p =
    let
        x = Id (Name "x" Nothing 0) t
        b = Id (Name "b" Nothing 0) t
        lb = Id (Name "lb" Nothing 0) lt

        alt = [Alt (DataAlt (PrimCon p) [lb]) $ App (Data (PrimCon p)) (Var lb)]
    in
    Lam x $ Case (Var x) b alt
