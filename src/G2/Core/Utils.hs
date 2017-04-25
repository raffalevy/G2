{-# LANGUAGE FlexibleContexts #-}

module G2.Core.Utils where

import G2.Core.CoreManipulator
import G2.Core.Language

import Data.Char
import qualified Data.List as L
import qualified Data.Map as M
import qualified Data.Monoid as Mon

import qualified Debug.Trace as T

sp2 :: String
sp2 = "  "

sp4 :: String
sp4 = sp2 ++ sp2

mkStateStr :: State -> String
mkStateStr s = L.intercalate "\n\n" li
  where li = ["> Type Env:\n" ++ ts,  "> Expr Env:\n" ++ es
             ,"> Curr Expr:\n" ++ xs, "> Path Constraints:\n" ++ ps
             ,"> Sym Link Table:\n" ++ sl]
        ts = mkTypeEnvStr . tEnv $ s
        es = mkExprEnvStr . eEnv $ s
        xs = mkExprStr . cExpr $ s
        ps = mkPCStr . pc $ s
        sl = mkSLTStr . slt $ s

mkStatesStr :: [State] -> String
mkStatesStr []     = ""
mkStatesStr [s] = mkStateStr s
mkStatesStr (s:ss) = mkStateStr s ++ divLn ++ mkStatesStr ss
  where divLn = "\n--------------\n"

mkTypeEnvStr :: TEnv -> String
mkTypeEnvStr tenv = L.intercalate "\n" (map ntStr (M.toList tenv))
  where ntStr :: (Name, Type) -> String
        ntStr (n, t) = n ++ "\n" ++ sp4 ++ show t

mkExprEnvStr :: EEnv -> String
mkExprEnvStr eenv = L.intercalate "\n" (map neStr (M.toList eenv))
  where neStr :: (Name, Expr) -> String
        neStr (n, e) = n ++ "\n" ++ sp4 ++ mkExprStr e


mkExprStr :: Expr -> String
mkExprStr e = mkExprStr' e 0
    where
        mkExprStr' :: Expr -> Int -> String
        mkExprStr' (Var n t) i = off i ++ "Var " ++ n ++ " (" ++ mkTypeStr t (i + 1) ++")"
        mkExprStr' (Lam n e t) i = 
            let
                e' = mkExprStr' e (i + 1)
            in
            off i ++  "Lam (" ++ show n ++ "\n" ++ e' ++ " " ++ mkTypeStr t i ++")"
        mkExprStr' (App e1 e2) i = 
            let
                e1' = mkExprStr' e1 (i + 1)
                e2' = mkExprStr' e2 (i + 1)
            in
            off i ++ "App (\n" ++ e1' ++ "\n" ++ e2' ++ "\n" ++ off i ++ ")"
        mkExprStr' (Case e1 ae t) i = 
            let
                e1' = mkExprStr' e1 (i + 1)
                ae' = mkAltExprStr ae (i + 1)
            in
            off i ++ "Case (\n" ++ e1' ++ "\n" ++ ae' ++ " " ++ mkTypeStr t i ++ ")"
        mkExprStr' (Type t) i = off i ++ "Type (" ++ mkTypeStr t (i + 1) ++ ")"
        mkExprStr' x i = off i ++ show x


        mkAltExprStr :: [(Alt, Expr)] -> Int -> String
        mkAltExprStr [] _ = ""
        mkAltExprStr ((a, e):xs) i = off i ++ "(" ++ show a ++ ",\n" ++ 
                                        mkExprStr' e (i + 1) ++ ")\n" ++ mkAltExprStr xs i

        off :: Int -> String
        off i = duplicate "   " i


mkTypeStr :: Type -> Int -> String
mkTypeStr t i = mkTypeStr' t i False
    where
        mkTypeStr' :: Type -> Int -> Bool -> String
        mkTypeStr' (TyFun t1 t2) i  b = tPat t1 t2 "TyFun" i b 
        mkTypeStr' (TyApp t1 t2) i  b = tPat t1 t2 "TyApp" i b 
        mkTypeStr' (TyConApp n tx) i b = 
            let li = L.intercalate ", " . map (\t' -> mkTypeStr' t' (i + 1) b) $ tx in
                off i b ++ "TyConApp " ++ show n ++ " [" ++ li ++ "]"
        mkTypeStr' (TyForAll n t) i b = off i b ++ "TyForAll " ++ show n ++
                                        "(" ++ mkTypeStr' t (i + 1) b ++ ")"
        mkTypeStr' t i b = (if b then " " else "") ++ show t

        tPat :: Type -> Type -> String -> Int -> Bool -> String
        tPat t1 t2 s i b = off i b ++ s ++ " (" 
                            ++ mkTypeStr' t1 (i + 1) True 
                            ++ mkTypeStr' t2 (i + 1) True ++ off i True ++  ")"

        off :: Int -> Bool -> String
        off i b = if b then "\n" ++ duplicate "   " i else ""


-- Primitive for now because I'm low on battery.
mkPCStr :: PC -> String
mkPCStr [] = ""
mkPCStr [(e, a, b)] = mkExprStr e ++ (if b then " = " else " != ") ++ show a
mkPCStr ((e, a, b):ps) = mkExprStr e ++ (if b then " = " else " != ") ++ show a++ "\n--AND--\n" ++ mkPCStr ps

mkSLTStr :: SymLinkTable -> String
mkSLTStr = L.intercalate "\n" . map (\(k, (n, t, i)) -> 
                                                k ++ " <- " ++ n ++ "  (" ++ show t ++ ")"
                                                ++ case i of
                                                        Just x -> "  " ++ show x
                                                        Nothing -> "") . M.toList

mkExprHaskell :: Expr -> String
mkExprHaskell e = mkExprHaskell' e 0
    where 
        mkExprHaskell' :: Expr -> Int -> String
        mkExprHaskell' (Var n _) _ = n
        mkExprHaskell' (Const c) _ = mkConstHaskell c
        mkExprHaskell' (Lam n e _) i = "\\" ++ n ++ " -> " ++ mkExprHaskell' e i
        mkExprHaskell' (App e1 e2@(App _ _)) i = mkExprHaskell' e1 i ++ " (" ++ mkExprHaskell' e2 i ++ ")"
        mkExprHaskell' (App e1 e2) i = mkExprHaskell' e1 i ++ " " ++ mkExprHaskell' e2 i
        mkExprHaskell' (DCon (DC (n, _, _, _))) _ = n
        mkExprHaskell' (Case e ae _) i = off (i + 1) ++ "\ncase " ++ (mkExprHaskell' e i) ++ " of\n" 
                                        ++ L.intercalate "\n" (map (mkAltExprHaskell (i + 2)) ae)
        mkExprHaskell' (Type _) _ = ""
        mkExprHaskell' BAD _ = "BAD"
        mkExprHaskell' UNR _ = "UNR"

        mkAltExprHaskell :: Int -> (Alt, Expr) -> String
        mkAltExprHaskell i (Alt (DC (n, _, _, _), n'), e) = off i ++ n ++ " " ++ L.intercalate " " n' ++ " -> " ++ mkExprHaskell' e i

        off :: Int -> String
        off i = duplicate "   " i

mkConstHaskell :: Const -> String
mkConstHaskell (CInt i) = show i
mkConstHaskell (CFloat r) = show r
mkConstHaskell (CDouble r) = show r
mkConstHaskell (CChar c) = [c]
mkConstHaskell (CString s) = s
mkConstHaskell (COp n _) = n

duplicate :: String -> Int -> String
duplicate _ 0 = ""
duplicate s n = s ++ duplicate s (n - 1)

{- Type judgement

Really the only two cases here worth mentioning are App and DCon.

App: We must consider the possibility that the LHS is a function type, or not,
and pop off whatever we need as necessary, or wrap it in TyApp to not cause problems.

DCon: We reconstruct the function type that data constructors truly represent.
-}
typeOf :: Expr -> Type
typeOf (Var _ t) = t
typeOf (Const (CInt _))    = TyRawInt
typeOf (Const (CFloat _))  = TyRawFloat
typeOf (Const (CDouble _)) = TyRawDouble
typeOf (Const (CChar _))   = TyRawChar
typeOf (Const (CString _)) = TyRawString
typeOf (Const (COp _ t)) = t
typeOf (Lam _ _ t) = t
typeOf (App f a)   = case typeOf f of
                         TyFun l r -> r
                         t         -> TyApp t (typeOf a)
typeOf (DCon (DC (n,_,t,a))) = let a' = reverse (a ++ [t])
                          in foldl1 (\a r -> TyFun r a) a'
typeOf (Case _ _ t) = t
typeOf (Type t) = t
typeOf _ = TyBottom

constructors :: TEnv -> [Name]
constructors = evalDataConType (\(DC (n, _, _, _)) -> [n])

--Returns if e1, e2 are equal up to renaming of all variables
exprEqUpToName :: Expr -> Expr -> Bool
exprEqUpToName (Var _ t) (Var _ t') = t == t'
exprEqUpToName (Const c) (Const c') = c == c'
exprEqUpToName (Lam _ e _) (Lam _ e' _) = exprEqUpToName e e'
exprEqUpToName (App e1 e2) (App e1' e2') = exprEqUpToName e1 e1' && exprEqUpToName e2 e2'
exprEqUpToName (DCon dc) (DCon dc') = dcEqUpToName dc dc'
exprEqUpToName (Case e ae t) (Case e' ae' t') = exprEqUpToName e e' && aeEqUpToName ae ae' && t == t'
    where
        aeEqUpToName :: [(Alt, Expr)] -> [(Alt, Expr)] -> Bool
        aeEqUpToName [] [] = True
        aeEqUpToName ((Alt (dc, n), e):ae) ((Alt (dc', n'), e'):ae') =  dcEqUpToName dc dc' && length n == length n'
        aeEqUpToName _ _ = False
exprEqUpToName (Type t) (Type t') = t== t'
exprEqUpToName e1 e2 = e1 == e2

dcEqUpToName :: DataCon -> DataCon -> Bool
dcEqUpToName (DC (_, _, t, ts)) (DC (_, _, t', ts')) = t == t' && ts == ts'


-- Replace a name with a new one in an Expr.
replace :: Expr -> [Name] -> Name -> Name -> Expr
replace e env old new = modify'' (replace' old new) e env
    where
        replace' :: Name -> Name -> [Name] -> Expr -> (Expr, [Name])
        replace' old new _ (Var n t) = if n == old then (Var new t, []) else (Var n t, [])
        replace' old new env (Lam n e t)  =
            let 
                fvs  = freeVars (n:env) e
                bads = fvs ++ env ++ [old, new]
                n'   = fresh n bads
            in
            (Lam n' (replace e bads n n') t, bads)
        replace' _ _ _ t = (t, [])

-- Replace a whole list of names with new ones in an Expr via folding.
replaceList :: Expr -> [Name] -> [Name] -> [Name] -> Expr
replaceList expr env olds news = foldl (\e (n, n') -> replace e env n n')
                                      expr $ zip olds news

-- Generates a fresh name given an old name and a list of INVALID names
fresh :: Name -> [Name] -> Name
fresh n bads = let maxnum = L.maximum $ 0:(map getnum bads)
               in filter (not . isDigit) n ++ show (maxnum + 1)
  where getnum str = let raw = filter isDigit str
                     in case raw of
                         [] -> 0
                         xs -> read xs :: Integer
-- fresh :: Name -> [Name] -> Name
-- fresh o ns = let r = foldl (\s c -> if s == c then s ++ [head c] else s) o ns
--              in if r `elem` ns then fresh r ns else r 

-- Generates a list of fresh names. Ensures no conflict with original old list.
freshList :: [Name] -> [Name] -> [Name]
freshList os ns = snd $ foldl (\(bads, ress) o ->
                                    let o' = fresh o bads
                                    in (o':bads, ress++[o']))
                              (ns ++ os, []) os

-- Generates a list of fresh names based on a name. Ensuring no conflict with original old list or new names.
numFresh :: Name -> Int -> [Name] -> [Name]
numFresh _ 0 _ = []
numFresh n i ns = let f = fresh n ns in f:numFresh n (i - 1) (f:ns) 

-- Returns free variables of an expression with respect to list of bounded vars.
-- freeVars :: [Name] -> Expr -> [Name]
-- freeVars bvs (Var n t)     = if n `elem` bvs then [] else [n]
-- freeVars bvs (Const c)     = []
-- freeVars bvs (Lam n e t)   = freeVars (n:bvs) e
-- freeVars bvs (App f a)     = L.nub (freeVars bvs f ++ freeVars bvs a)
-- freeVars bvs (DCon dc)     = []
-- freeVars bvs (Case m as t) = L.nub (freeVars bvs m ++ as_fvs)
--     where a_fv (Alt (dc, pars), ae) = freeVars (pars ++ bvs) ae
--           as_fvs = L.nub (concatMap a_fv as)
-- freeVars bvs (Type t) = []
-- freeVars bvs BAD = []
-- freeVars bvs UNR = []

freeVars :: Manipulatable Expr m => [Name] -> m -> [Name]
freeVars bv e = snd . evalUntil'' freeVars' e $ (bv, [])
    where
        freeVars' :: ([Name], [Name]) -> Expr -> (([Name], [Name]), Bool)
        freeVars' (bv, fr) (Var n' _) = if n' `elem` bv then (([], []), True) else (([], [n']), True)
        freeVars' (bv, fr) (Lam n' _ _) = (([n'], []), True)
        freeVars' (bv, fr) (Case m as t) = (([], L.nub (freeVars bv m ++ as_fvs)), False)
            where a_fv (Alt (dc, pars), ae) = freeVars (pars ++ bv) ae
                  as_fvs = L.nub (concatMap a_fv as)
        freeVars' _ _ = (([], []), True)

--Returns all names used in a State
names :: State -> [Name]
names s =
    L.nub (eval (exprNames) s ++ eval (typeNames) s ++ evalDataConExpr dataConNames s)
    where
        exprNames :: Expr -> [Name]
        exprNames (Var n _) = [n]
        exprNames (Lam n _ _) = [n]
        exprNames (Case _ ae _) = L.concatMap (\(Alt (d, n)) -> n) . map fst $ ae
        exprNames _ = []

        typeNames :: Type -> [Name]
        typeNames (TyVar n) = [n]
        typeNames (TyConApp n _) = [n]
        typeNames (TyAlg n _) = [n]
        typeNames (TyForAll n _) = [n]
        typeNames _ = []

        dataConNames :: DataCon -> [Name]
        dataConNames (DC (n, _, _, _)) = [n]

--Takes e e1 e2.  In e, replaces all occurences of e1 with e2
replaceM :: (Manipulatable e m, Eq e) => m -> e -> e -> m
replaceM e e1 e2 = modify (\e' -> if e1 == e' then e2 else e') e

-- Symbolic Link Table functions:
sltLookup :: Name -> SymLinkTable -> Maybe (Name, Type, Maybe Int)
sltLookup = M.lookup

sltBackLookup :: Name -> SymLinkTable -> [(Name, Type, Maybe Int)]
sltBackLookup old slt = map snd $ filter (\(n,(o, _, _)) -> old == o) $ M.toList slt

updateSymLinkTable :: Name -> (Name, Type, Maybe Int) -> SymLinkTable -> SymLinkTable
updateSymLinkTable = M.insert

-- M.insert new old slt

updateSymLinkTableList :: [Name] -> [Name] -> SymLinkTable -> SymLinkTable
updateSymLinkTableList news olds slt = foldl (\s (k, v) -> updateSymLinkTable k v s) slt (zip news modEntries)
    where oldsLookup = map (\o -> sltLookup o slt) olds -- entries exist?
          modEntries = map (\(o, r) -> case r of
                                Nothing -> (o, TyBottom, Nothing) -- First insertion
                                Just p  -> p) (zip olds oldsLookup)

-- Unroll cascading lambda expressions.
unlam :: Expr -> ([(Name, Type)], Expr)
unlam (Lam a e t) = let (p, e')   = unlam e
                        TyFun l r = t
                    in ((a, l):p, e')
unlam e   = ([], e)

--Find the number of Expr or Type's in a Manipulatable type.
countExpr :: Manipulatable Expr m => m -> Int
countExpr e = Mon.getSum . evalE (\_ -> Mon.Sum 1) $ e

countTypes :: Manipulatable Type m => m -> Int
countTypes t = Mon.getSum . evalT (\_ -> Mon.Sum 1) $ t

--Given an App of Lambda, returns the number of arguments to completely evaluate
--the top level contained expression
--Given a different Expr, returns 0
exprArgCount :: Expr -> Int
exprArgCount (Lam _ e _) = exprArgCount e
exprArgCount (App a _) = 1 + exprArgCount a
exprArgCount _ = 0

--Given a TyFun, returns the ith argument
--If not ith argument, or not a TyFun, errors
ithArgType :: Type -> Int -> Type
ithArgType (TyFun t _) 1 = t
ithArgType (TyFun _ t) n = ithArgType t (n - 1) 
ithArgType t i = error ("Type " ++ show t ++ " passed to TyFun") 

--Given a TyFun, returns the number of arguments to completely evaluate
--Given a different type, returns 0
typeArgCount :: Type -> Int
typeArgCount t@(TyFun _ _) = typeArgCount' t
    where
        typeArgCount' :: Type -> Int
        typeArgCount' (TyFun _ t@(TyFun _ _)) = 1 + typeArgCount' t
        typeArgCount' (TyFun _ _) = 1
        typeArgCount' _ = 0
typeArgCount _ = 0

--Given an app, gets all arguments passed to the function nested in that app as a list.
--If not an app, returns an empty list
getAppArgs :: Expr -> [Expr]
getAppArgs a = reverse . getAppArgs' $ a
    where
        getAppArgs' (App a'@(App _ _) a) = a:getAppArgs' a'
        getAppArgs' (App _ a) = [a]
        getAppArgs' _ = []

--Given an app, returns Just the bottomost, leftist contained function
--Otherwise, returns Nothing
getAppFunc :: Expr -> Maybe Expr
getAppFunc (App a@(App _ _) _) = getAppFunc a
getAppFunc (App a _) = Just a
getAppFunc _ = Nothing

--Given a function name, Expr, and an argument number, i, returns a list of the
--Expr passed into the ith argument
--(This is not the most efficient implementation...
--should search down, then move up, not search down repeatedly from each Expr.
--Not a top concern right now)
findIthArg :: (Manipulatable Expr m) => Name -> m -> Int -> [Expr]
findIthArg n e i = eval (ithArg' n i) e
    where
        ithArg' :: Name -> Int -> Expr -> [Expr]
        ithArg' n i (App e e') =  if varIDown n i e then [e'] else []
        ithArg' _ _ _ = []

        varIDown :: Name -> Int -> Expr -> Bool
        varIDown n 0 (Var n' _) = n == n'
        varIDown n i (App e e') = varIDown n (i - 1) e
        varIDown _ _ _ = False

--Finds and returns a list of each call to a function, and all associated arguments
findAllCalls :: (Manipulatable Expr m) => m -> [Expr]
findAllCalls e = evalUntil findAllCalls' e
    where
        findAllCalls' :: Expr -> ([Expr], Bool)
        findAllCalls' a@(App e e') =
            let
                --We have to go down the right hand side of each expression, in case function called in argument
                res = callOnRight e ++ findAllCalls e'
            in
            if varDown e then (a:res, False) else ([], True)
        findAllCalls' _ = ([], True)

        varDown :: Expr -> Bool
        varDown (Var _ _) = True
        varDown (App e e') = varDown e
        varDown _ = False

        callOnRight :: Expr -> [Expr]
        callOnRight (App _ e) = findAllCalls e
        callOnRight _ = []

--Finds and returns a list of each call to a function with the given name, and all associated arguments
findAllCallsNamed :: (Manipulatable Expr m) => Name -> m -> [Expr]
findAllCallsNamed n e = filter (varDown n) . findAllCalls $ e--evalUntil (findAllCallsNamed' n) e
    where
        varDown :: Name -> Expr -> Bool
        varDown n (Var n' _) = n == n'
        varDown n (App e _) = varDown n e
        varDown _ _ = False

containsFunctions :: (Manipulatable Type m) => m -> Bool
containsFunctions = Mon.getAny . eval (Mon.Any .  containsFunctions')
    where
        containsFunctions' :: Type -> Bool
        containsFunctions' (TyFun _ _) = True
        containsFunctions' _ = False

--Contains functions that are not just type constructors
containsNonConsFunctions :: (Manipulatable Expr m) => TEnv -> m -> Bool
containsNonConsFunctions tenv = Mon.getAny . eval (Mon.Any . containsFunctions' tenv)
    where
        containsFunctions' :: TEnv -> Expr -> Bool
        containsFunctions' tenv (Var n _) = n `notElem` (constructors tenv)
        containsFunctions' _ _ = False