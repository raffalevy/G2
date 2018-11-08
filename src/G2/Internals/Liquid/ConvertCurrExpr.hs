{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TupleSections #-}

module G2.Internals.Liquid.ConvertCurrExpr (convertCurrExpr) where

import G2.Internals.Language
import G2.Internals.Language.Monad

import G2.Internals.Liquid.Conversion
import G2.Internals.Liquid.Types

import Control.Monad.Extra
import Data.Monoid
import qualified Data.Map as M
import Data.Maybe

import Debug.Trace

convertCurrExpr :: Id -> LHStateM [Name]
convertCurrExpr ifi = do
    ifi' <- modifyInputExpr ifi
    addCurrExprAssumption ifi
    return ifi'

-- We create a copy of the input function which is modified to:
--  (1) Call a different copy of each of it's internal functions.
--      This allows us to only nondeterministically branch into abstract
--      counterexamples from the initial function call
--      
--  (2) Call all functions in let bindings.  I.e., the following:
--          Just (f x)
--      would be changed to:
--      let fx = f x in Just fx
--      This way, if we reference the output in both the refinement and the body,
--      it'll only be computed once.  This is NOT just for efficiency.
--      Since the choice is nondeterministic, this is the only way to ensure that
--      we don't make two different choices, and get two different values.
modifyInputExpr :: Id -> LHStateM [Name]
modifyInputExpr i@(Id n _) = do
    (CurrExpr er ce) <- currExpr

    e <- lookupE n
    case e of
        Just je -> do
            (newI, ns) <- modifyInputExpr' i je

            let ce' = replaceASTs (Var i) (Var newI) ce

            putCurrExpr (CurrExpr er ce')
            return ns
        Nothing -> return []

-- Actually does the work of modify the function for modifyInputExpr
-- Inserts the new function in the ExprEnv, and returns the Id
modifyInputExpr' :: Id -> Expr -> LHStateM (Id, [Name])
modifyInputExpr' i e = do
    (e', ns) <- rebindFuncs e
    e'' <- adjustLetsForAbstract e'
    e''' <- letLiftFuncs e''

    newI <- freshSeededIdN (idName i) (typeOf i)
    insertE (idName newI) e'''

    return (newI, ns)

rebindFuncs :: Expr -> LHStateM (Expr, [Name])
rebindFuncs e = do
    vs <- mapMaybeM (\i -> fmap (i,) <$> lookupE (idName i)) $ varIds e
    nvs <- mapM (\(Id n t, _) -> freshSeededIdN n t) vs
    
    mapM_ (\(n, e_) -> insertE n (rewriteAssertName n e_)) $ zip (map idName nvs) (map snd vs)

    let e' = foldr (uncurry replaceASTs) e $ zip (map (Var . fst) vs) (map Var nvs)

    return (e', map idName nvs)
    where
        rewriteAssertName :: Name -> Expr -> Expr
        rewriteAssertName n (Assert (Just fc) e1 e2) = Assert (Just $ fc {funcName = n}) e1 e2
        rewriteAssertName n e1 = modifyChildren (rewriteAssertName n) e1


-- Modifies Let's in the CurrExpr to have Asserts in functions, if they are self recursive.
-- Furthermore, distinguishes between the first call to a function,
-- and those that are recursive.
adjustLetsForAbstract :: Expr -> LHStateM Expr 
adjustLetsForAbstract = modifyM adjustLetsForAbstract'

adjustLetsForAbstract' :: Expr -> LHStateM Expr 
adjustLetsForAbstract' (Let b e) = do
    b' <- return . concat =<< mapM (uncurry adjustLetsForAbstract'') b
    return $ Let b' e
adjustLetsForAbstract' e = return e

adjustLetsForAbstract'' :: Id -> Expr -> LHStateM [(Id, Expr)]
adjustLetsForAbstract'' i e
    | hasFuncType i
    , selfRecursive e = do
        i' <- freshIdN (typeOf i)
        let ce = replaceASTs (Var i) (Var i') e


        e' <- insertInLamsE (\as ee -> do
                    r <- freshIdN (typeOf ee)
                    let fc = FuncCall { funcName = idName i, arguments = map Var as, returns = Var r}
                    true <- mkTrueE

                    return $ Let [(r, ee)] $ Assert (Just fc) true (Var r)) ce

        trace (show i) return [(i, e'), (i', ce)]
    | otherwise = return [(i, e)]
    where
        selfRecursive :: Expr -> Bool
        selfRecursive (Var i') = i == i'
        selfRecursive e = getAny $ evalChildren (Any . selfRecursive) e

-- We want to get all function calls into Let Bindings.
-- This is a bit tricky- we can't just get all calls at once,
-- stick them in a let binding, and then rewrite, because the calls may be nested.
-- So we gather them up, one by one, and rewrite as we go.
-- Furthermore, we have to be careful to not move bindings from Lambdas/other Let's
-- out of scope.
letLiftFuncs :: Expr -> LHStateM Expr
letLiftFuncs = modifyAppTopE letLiftFuncs'

letLiftFuncs' :: Expr -> LHStateM Expr
letLiftFuncs' e
    | ars <- passedArgs e
    , any (\case { Var _ -> False; _ -> True }) ars = do
        let c = appCenter e
        is <- freshIdsN $ map typeOf ars

        return . Let (zip is ars) . mkApp $ c:map Var is
    | otherwise = return e

-- We add an assumption about the inputs to the current expression
-- This prevents us from finding a violation of the output refinement type
-- that requires a violation of the input refinement type
addCurrExprAssumption :: Id -> LHStateM ()
addCurrExprAssumption ifi = do
    (CurrExpr er ce) <- currExpr

    assumpt <- lookupAssumptionM (idName ifi)
    fi <- fixedInputs
    is <- inputIds

    lh <- mapM (lhTCDict'' M.empty) $ mapMaybe typeType fi

    let (typs, ars) = span isType $ fi ++ map Var is

    case assumpt of
        Just assumpt' -> do
            let appAssumpt = mkApp $ assumpt':typs ++ lh ++ ars
            let ce' = Assume appAssumpt ce
            putCurrExpr (CurrExpr er ce')
        Nothing -> return ()

isType :: Expr -> Bool
isType (Type _) = True
isType _ = False

typeType :: Expr -> Maybe Type
typeType (Type t) = Just t
typeType _ = Nothing
