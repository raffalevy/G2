module G2.Lib.Printers where

import qualified G2.Internals.Language.SymLinks as Sym
import G2.Internals.Language.Naming
import G2.Internals.Language.Syntax
import G2.Internals.Language.Support
import G2.Internals.Execution.Support
import G2.Internals.Execution.Rules

import Data.List
import qualified Data.Map as M

sp2 :: String
sp2 = "  "

sp4 :: String
sp4 = sp2 ++ sp2

mkRawStateStr :: State -> String
mkRawStateStr state = intercalate "\n" li
  where tenv_str  = intercalate "\n" $ map show $ M.toList $ type_env state
        eenv_str  = intercalate "\n" $ map show $ M.toList $ expr_env state
        cexpr_str = show $ curr_expr state
        pc_str    = intercalate "\n" $ map show $ path_conds state
        slt_str   = show $ sym_links state
        fintp_str = show $ func_table state
        dashes = "------"
        li = [ "BEGIN STATE"
             , "[type_env]", tenv_str, dashes
             , "[expr_env]", eenv_str, dashes
             , "[curr_expr]", cexpr_str, dashes
             , "[path_conds]", pc_str, dashes
             , "[sym_links]", slt_str, dashes
             , "[func_table]", fintp_str
             , "END STATE" ]


mkStateStr :: State -> String
mkStateStr s = intercalate "\n\n" li
  where li = ["> Type Env:\n" ++ ts,  "> Expr Env:\n" ++ es
             ,"> Curr Expr:\n" ++ xs, "> Path Constraints:\n" ++ ps
             ,"> Sym Link Table:\n" ++ sl
             ,"> Func Sym Link Table:\n" ++ fl]
        ts = mkTypeEnvStr . type_env $ s
        es = mkExprEnvStr . expr_env $ s
        xs = mkExprStr . curr_expr $ s
        ps = mkPCStr . path_conds $ s
        sl = mkSLTStr . sym_links $ s
        fl = mkFuncSLTStr . func_table $ s

mkStatesStr :: [State] -> String
mkStatesStr []     = ""
mkStatesStr [s] = mkStateStr s
mkStatesStr (s:ss) = mkStateStr s ++ divLn ++ mkStatesStr ss
  where divLn = "\n--------------\n"

mkTypeEnvStr :: TypeEnv -> String
mkTypeEnvStr tenv = intercalate "\n" (map ntStr (M.toList tenv))
  where
        ntStr :: (Name, AlgDataTy) -> String
        ntStr (n, t) = show n ++ "\n" ++ sp4 ++ show t

mkExprEnvStr :: ExprEnv -> String
mkExprEnvStr eenv = intercalate "\n" (map neStr (M.toList eenv))
  where
        neStr :: (Name, Expr) -> String
        neStr (n, e) = show n ++ "\n" ++ sp4 ++ mkExprStr e


mkExprStr :: Expr -> String
mkExprStr ex = mkExprStr' ex 0
    where
        mkExprStr' :: Expr -> Int -> String
        mkExprStr' (Var ids) i = off i ++ "Var " ++ mkIdStr ids
        mkExprStr' (Lam ids e) i = 
            let
                e' = mkExprStr' e (i + 1)
            in
            off i ++  "Lam (" ++ mkIdStr ids ++ "\n" ++ e' ++ ")"
        mkExprStr' (Let ne e) i =
            let
                ne' = concatMap (\(ids, e') -> mkIdStr ids ++ " =\n" ++ mkExprStr' e' (i + 1)) ne
            in
            off i ++ "Let (\n" ++ off (i + 1) ++ ne' ++ ")" ++ mkExprStr' e (i + 1)
        mkExprStr' (App e1 e2) i = 
            let
                e1' = mkExprStr' e1 (i + 1)
                e2' = mkExprStr' e2 (i + 1)
            in
            off i ++ "App (\n" ++ e1' ++ "\n" ++ e2' ++ "\n" ++ off i ++ ")"
        mkExprStr' (Case e1 ids ae) i = 
            let
                e1' = mkExprStr' e1 (i + 1)
                ae' = intercalate "\n" $ map (\a -> mkAltStr a  (i + 1)) ae
            in
            off i ++ "Case (\n" ++ e1'  ++ " " ++ (mkIdStr ids) ++ "\n" ++ ae' ++ " )"
        mkExprStr' (Type t) i = off i ++ "Type (" ++ mkTypeStr t (i + 1) ++ ")"
        mkExprStr' x i = off i ++ show x


        mkAltStr :: Alt -> Int -> String
        mkAltStr (Alt am e) i = off i ++ "(" ++ show am ++ "\n" ++ off i ++ mkExprStr e ++ ")\n"

        off :: Int -> String
        off i = duplicate "   " i


mkTypeStr :: Type -> Int -> String
mkTypeStr ty ind = mkTypeStr' ty ind False
    where
        mkTypeStr' :: Type -> Int -> Bool -> String
        mkTypeStr' (TyFun t1 t2) i b = tPat t1 t2 "TyFun" i b 
        mkTypeStr' (TyApp t1 t2) i b = tPat t1 t2 "TyApp" i b 
        mkTypeStr' (TyConApp n tx) i b = 
            let li = intercalate ", " . map (\t' -> mkTypeStr' t' (i + 1) b) $ tx in
                off i b ++ "TyConApp " ++ show n ++ " [" ++ li ++ "]"
        mkTypeStr' (TyForAll n t) i b = off i b ++ "TyForAll " ++ show n ++
                                        "(" ++ mkTypeStr' t (i + 1) b ++ ")"
        mkTypeStr' t _ b = (if b then " " else "") ++ show t

        tPat :: Type -> Type -> String -> Int -> Bool -> String
        tPat t1 t2 s i b = off i b ++ s ++ " (" 
                            ++ mkTypeStr' t1 (i + 1) True 
                            ++ mkTypeStr' t2 (i + 1) True ++ off i True ++  ")"

        off :: Int -> Bool -> String
        off i b = if b then "\n" ++ duplicate "   " i else ""


mkIdStr :: Id -> String
mkIdStr (Id n t) = show n ++ " (" ++ show t ++ ")"

-- Primitive for now because I'm low on battery.
mkPCStr :: [PathCond] -> String
mkPCStr = intercalate "\n" . map mkPCStr'
    where
        mkPCStr' :: PathCond -> String
        mkPCStr' (AltCond a e b) =
            "PC: (" ++ mkExprStr e ++ (if b then " = " else "/=") ++ show a
        mkPCStr' (ExtCond e b) =
            "PC: " ++ (if b then "" else "not ") ++ "(" ++ mkExprStr e ++ ")"

{-
mkPCStr [] = ""
mkPCStr [(e, a, b)] = mkExprStr e ++ (if b then " = " else " != ") ++ show a
mkPCStr ((e, a, b):ps) = mkExprStr e ++ (if b then " = " else " != ") ++ show a++ "\n--AND--\n" ++ mkPCStr ps
-}

mkSLTStr :: SymLinks -> String
mkSLTStr = intercalate "\n" . map (\(k, (n, t, i)) -> 
                                                show k ++ " <- " ++ show n ++ "  (" ++ show t ++ ")"
                                                ++ case i of
                                                        Just x -> "  " ++ show x
                                                        Nothing -> "") . M.toList . Sym.map' id

mkFuncSLTStr :: FuncInterps -> String
mkFuncSLTStr = show

mkExprHaskell :: Expr -> String
mkExprHaskell ex = mkExprHaskell' ex 0
    where
        mkExprHaskell' :: Expr -> Int -> String
        mkExprHaskell' (Var ids) _ = mkIdStr ids
        mkExprHaskell' (Lit c) _ = mkLitHaskell c
        mkExprHaskell' (Lam ids e) i = "\\" ++ mkIdStr ids ++ " -> " ++ mkExprHaskell' e i
        mkExprHaskell' (App e1 e2@(App _ _)) i = mkExprHaskell' e1 i ++ " (" ++ mkExprHaskell' e2 i ++ ")"
        mkExprHaskell' (App e1 e2) i = mkExprHaskell' e1 i ++ " " ++ mkExprHaskell' e2 i
        mkExprHaskell' (Data (DataCon n _ _)) _ = show n
        mkExprHaskell' (Case e _ ae) i = off (i + 1) ++ "\ncase " ++ (mkExprHaskell' e i) ++ " of\n" 
                                        ++ intercalate "\n" (map (mkAltHaskell (i + 2)) ae)
        mkExprHaskell' (Type _) _ = ""
        mkExprHaskell' e _ = show e ++ " NOT SUPPORTED"

        mkAltHaskell :: Int -> Alt -> String
        mkAltHaskell i (Alt am e) =
            off i ++ mkAltMatchHaskell am ++ " -> " ++ mkExprHaskell' e i

        mkAltMatchHaskell :: AltMatch -> String
        mkAltMatchHaskell (DataAlt dc ids) = mkDataConHaskell dc ++ " " ++ intercalate " "  (map mkIdStr ids)
        mkAltMatchHaskell (LitAlt l) = mkLitHaskell l
        mkAltMatchHaskell Default = "_"

        mkDataConHaskell :: DataCon -> String
        mkDataConHaskell (DataCon n _ _) = show n
        mkDataConHaskell (PrimCon _) = ""

        off :: Int -> String
        off i = duplicate "   " i

mkLitHaskell :: Lit -> String
mkLitHaskell (LitInt i) = show i
mkLitHaskell (LitFloat r) = "(" ++ show r ++ ")"
mkLitHaskell (LitDouble r) = "(" ++ show r ++ ")"
mkLitHaskell (LitChar c) = [c]
mkLitHaskell (LitString s) = s
mkLitHaskell (LitBool b) = show b

duplicate :: String -> Int -> String
duplicate _ 0 = ""
duplicate s n = s ++ duplicate s (n - 1)

injNewLine :: [String] -> String
injNewLine strs = intercalate "\n" strs

injTuple :: [String] -> String
injTuple strs = "(" ++ (intercalate "," strs) ++ ")"

-- | More raw version of state dumps.
pprExecStateStr :: ExecState -> String
pprExecStateStr ex_state = injNewLine acc_strs
  where
    eenv_str = pprExecEEnvStr (exec_eenv ex_state)
    stack_str = pprExecStackStr (exec_stack ex_state)
    code_str = pprExecCodeStr (exec_code ex_state)
    names_str = pprExecNamesStr (exec_names ex_state)
    paths_str = pprPathsStr (exec_paths ex_state)
    acc_strs = [ ">>>>> [State] >>>>>>>>>>>>>>>>>>>>>"
               , "----- [Env] -----------------------"
               , eenv_str
               , "----- [Stack] ---------------------"
               , stack_str
               , "----- [Code] ----------------------"
               , code_str
               , "----- [Names] ---------------------"
               , names_str
               , "----- [Paths] ---------------------"
               , paths_str
               , "<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<" ]

pprExecEEnvStr :: ExecExprEnv -> String
pprExecEEnvStr eenv = injNewLine kv_strs
  where
    kv_strs = map show $ execExprEnvToList eenv

pprExecStackStr :: ExecStack -> String
pprExecStackStr stack = injNewLine frame_strs
  where
    frame_strs = map pprExecFrameStr $ execStackToList stack

pprExecFrameStr :: Frame -> String
pprExecFrameStr frame = show frame

pprExecCodeStr :: ExecCode -> String
pprExecCodeStr code = show code

pprExecNamesStr :: NameGen -> String
pprExecNamesStr _ = ""

pprPathsStr :: [PathCond] -> String
pprPathsStr paths = injNewLine cond_strs
  where
    cond_strs = map pprExecCondStr paths

pprPathCondStr :: PathCond -> String
pprPathCondStr (AltCond am expr b) = injTuple acc_strs
  where
    am_str = show am
    expr_str = show expr
    b_str = show b
    acc_strs = [am_str, expr_str, b_str]
pprExecCondStr (ExtCond am b) = injTuple acc_strs
  where
    am_str = show am
    b_str = show b
    acc_strs = [am_str, b_str]

pprRunHistStr :: ([Rule], ExecState) -> String
pprRunHistStr (rules, ex_state) = injNewLine acc_strs
  where
    rules_str = show rules
    state_str = pprExecStateStr ex_state
    acc_strs = [rules_str, state_str]
