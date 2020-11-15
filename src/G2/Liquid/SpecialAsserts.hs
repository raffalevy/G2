{-# LANGUAGE OverloadedStrings #-}

module G2.Liquid.SpecialAsserts ( addSpecialAsserts
                                , addTrueAsserts
                                , addTrueAssertsAll
                                , addErrorAssumes
                                , arbErrorTickish
                                , assumeErrorTickish) where

import G2.Config
import G2.Language
import qualified G2.Language.ExprEnv as E
import qualified G2.Language.KnownValues as KV
import G2.Language.Monad
import G2.Liquid.Types

import qualified Data.HashSet as S
import qualified Data.Text as T

import Debug.Trace

-- | Adds an assert of false to the function called when a pattern match fails
addSpecialAsserts :: LHStateM ()
addSpecialAsserts = do
    pen <- KV.patErrorFunc <$> knownValues
    pe <- lookupE pen

    let e = case pe  of
            Just e2 -> e2
            Nothing -> Prim Undefined TyBottom

    let fc = FuncCall {funcName = pen, arguments = [], returns = Prim Undefined TyBottom}
    
    false <- mkFalseE
    let e' = Assert (Just fc) false e
    
    insertE pen e'

-- | Adds an Assert of True to any function without an assertion already,
-- excluding certain functions (namely dicts) that we never want to abstract
-- Furthermore, expands all Lambdas as much as possible, so that we get all the arguments
-- for the assertion. 
addTrueAsserts :: ExState s m => Name -> m ()
addTrueAsserts n = do
    ns <- return . maybe [] varNames =<< lookupE n
    tc <- return . tcDicts =<< typeClasses
    
    let tc' = map idName tc
        ns' = filter (`notElem` tc') ns
    
    mapWithKeyME (addTrueAsserts' ns')

addTrueAsserts' :: ExState s m => [Name] -> Name -> Expr -> m Expr
addTrueAsserts' ns n e
    | n `elem` ns = addTrueAssert'' n e
    | otherwise = return e

addTrueAssert'' :: ExState s m => Name -> Expr -> m Expr 
addTrueAssert'' n e = do
    insertInLamsE (\is e' ->
                case e' of
                    Let [(_, _)] (Assert _ _ _) -> return e'
                    _ -> do
                        true <- mkTrueE
                        r <- freshIdN (typeOf e')

                        let fc = FuncCall { funcName = n
                                          , arguments = map Var is
                                          , returns = (Var r)}
                            e'' = Let [(r, e')] $ Assert (Just fc) true (Var r)

                        return e''
                ) =<< etaExpandToE (numArgs e) e

addTrueAssertsAll :: ExState s m => m ()
addTrueAssertsAll = mapWithKeyME (addTrueAssert'')

--- [BlockErrors]
-- | Blocks calling error in the functions specified in the block_errors_in in
-- the Config, by wrapping the errors in Assume False.
addErrorAssumes :: Config -> LHStateM ()
addErrorAssumes config = mapWithKeyME (addErrorAssumes' (block_errors_method config) (block_errors_in config))

addErrorAssumes' :: BlockErrorsMethod -> S.HashSet (T.Text, Maybe T.Text) -> Name -> Expr -> LHStateM Expr
addErrorAssumes' be ns name@(Name n m _ _) e = do
    kv <- knownValues
    if (n, m) `S.member` ns then addErrorAssumes'' be kv (typeOf e) e else return e

addErrorAssumes'' :: BlockErrorsMethod -> KnownValues -> Type -> Expr -> LHStateM Expr
addErrorAssumes'' be kv _ v@(Var (Id n t))
    | KV.isErrorFunc kv n 
    , be == AssumeBlock = do
        flse <- mkFalseE
        return $ Assume Nothing (Tick assumeErrorTickish flse) v
    | KV.isErrorFunc kv n
    , be == ArbBlock = do
        d <- freshSeededStringN "d"
        let ast = spArgumentTypes $ PresType t
            rt = returnType $ PresType t

            lam_it = map (\as -> case as of
                                    AnonType t -> (TermL, Id d t)
                                    NamedType i -> (TypeL, i)) ast
        n <- trace ("ast = " ++ show ast ++ "\nrt = " ++ show rt) freshSeededStringN "t"
        return . mkLams lam_it
               . Tick arbErrorTickish
               $ Let [(Id n TYPE, Type rt)] v
addErrorAssumes'' be kv (TyForAll _ t) (Lam u i e) = return . Lam u i =<< modifyChildrenM (addErrorAssumes'' be kv t) e
addErrorAssumes'' be kv (TyFun _ t) (Lam u i e) = return . Lam u i =<< modifyChildrenM (addErrorAssumes'' be kv t) e
addErrorAssumes'' be kv t e = modifyChildrenM (addErrorAssumes'' be kv t) e

arbErrorTickish :: Tickish
arbErrorTickish = NamedLoc (Name "arb_error" Nothing 0 Nothing)

assumeErrorTickish :: Tickish
assumeErrorTickish = NamedLoc (Name "library_error" Nothing 0 Nothing)