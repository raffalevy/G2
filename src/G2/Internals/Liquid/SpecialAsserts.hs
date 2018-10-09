module G2.Internals.Liquid.SpecialAsserts ( addSpecialAsserts
                                          , addTrueAsserts) where

import G2.Internals.Language
import qualified G2.Internals.Language.KnownValues as KV
import G2.Internals.Language.Monad
import G2.Internals.Liquid.Types

import Debug.Trace

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

-- Adds an Assert of True to any function without an assertion already,
-- excluding certain functions (namely dicts) that we never want to abstract
addTrueAsserts :: Id -> LHStateM ()
addTrueAsserts i = do
    ns <- return . maybe [] varNames =<< lookupE (idName i)
    tc <- return . tcDicts =<< typeClasses
    
    let tc' = map idName tc
        ns' = filter (`notElem` tc') ns
    
    mapWithKeyME (addTrueAsserts' ns')

addTrueAsserts' :: [Name] -> Name -> Expr -> LHStateM Expr
addTrueAsserts' ns n
    | n `elem` ns =
        insertInLamsE (\is e ->
                    case e of
                        Let [(_, _)] (Assert _ _ _) -> return e
                        _ -> do
                            true <- mkTrueE
                            r <- freshIdN (typeOf e)

                            let fc = FuncCall { funcName = n
                                              , arguments = map Var is
                                              , returns = (Var r)}
                                e' = Let [(r, e)] $ Assert (Just fc) true (Var r)

                            return e'
                    )
    | otherwise = return