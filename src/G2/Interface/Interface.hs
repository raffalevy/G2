{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}

module G2.Interface.Interface ( MkCurrExpr
                              , MkArgTypes
                              , IT.SimpleState
                              , doTimeout
                              , maybeDoTimeout

                              , initState
                              , initStateWithCall
                              , initState'
                              , initStateWithCall'
                              , initStateFromSimpleState
                              , initStateFromSimpleState'
                              , initStateFromSimpleStateWithCall
                              , initSimpleState

                              , mkArgTys
                              
                              , initRedHaltOrd
                              , initSolver
                              , initSolverInfinite
                              
                              , initialStateFromFileSimple
                              , initialStateFromFile

                              , runG2FromFile
                              , runG2WithConfig
                              , runG2WithSomes
                              , runG2Pre
                              , runG2Post
                              , runG2ThroughExecution
                              , runExecution
                              , runG2Solving
                              , runG2
                              , Config) where

import G2.Config.Config

import G2.Language

import G2.Initialization.Interface
import G2.Initialization.KnownValues
import G2.Initialization.MkCurrExpr
import qualified G2.Initialization.Types as IT

import G2.Preprocessing.Interface

import G2.Execution.Interface
import G2.Execution.Reducer
import G2.Execution.PrimitiveEval
import G2.Execution.Memory
import G2.Execution.Merging.MergingHelpers

import G2.Interface.OutputTypes

import G2.Translation

import G2.Solver

import G2.Postprocessing.Interface

import qualified G2.Language.ExprEnv as E
import qualified G2.Language.PathConds as PC
import qualified G2.Language.Stack as Stack

import qualified Data.HashMap.Lazy as HM
import qualified Data.HashSet as S
import qualified Data.Map as M
import Data.Maybe
import qualified Data.Text as T

import System.Timeout

import G2.Lib.Printers

type AssumeFunc = T.Text
type AssertFunc = T.Text
type ReachFunc = T.Text

type StartFunc = T.Text
type ModuleName = Maybe T.Text 

type MkArgTypes = IT.SimpleState -> [Type]
type MkCurrExpr = TypeClasses -> NameGen -> ExprEnv -> Walkers
                     -> KnownValues -> Config -> (Expr, [Id], [Expr], NameGen)

doTimeout :: Int -> IO a -> IO (Maybe a)
doTimeout secs action = do
  res <- timeout (secs * 1000 * 1000) action -- timeout takes micros.
  case res of
    Just _ -> return res
    Nothing -> do
      putStrLn "Timeout!"
      return Nothing

maybeDoTimeout :: Maybe Int -> IO a -> IO (Maybe a)
maybeDoTimeout (Just secs) = doTimeout secs
maybeDoTimeout Nothing = fmap Just


{-# INLINE initStateWithCall #-}
initStateWithCall :: ExtractedG2
                  -> Bool
                  -> StartFunc
                  -> ModuleName
                  -> (Id -> MkCurrExpr)
                  -> (Expr -> MkArgTypes)
                  -> Config
                  -> (State (), Bindings)
initStateWithCall exg2 useAssert f m_mod mkCurr argTys config =
    let
        s = initSimpleState exg2

        (ie, fe) = case findFunc f m_mod (IT.expr_env s) of
                        Left ie' -> ie'
                        Right errs -> error errs
    in
    initStateFromSimpleState s useAssert (mkCurr ie) (argTys fe) config

{-# INLINE initState #-}
initState :: ExtractedG2 -> Bool
          -> MkCurrExpr -> MkArgTypes
          -> Config -> (State (), Bindings)
initState exg2 useAssert mkCurr argTys config =
    let
        s = initSimpleState exg2
    in
    initStateFromSimpleState s useAssert mkCurr argTys config

{-# INLINE initStateWithCall' #-}
initStateWithCall' :: ExtractedG2
                   -> StartFunc
                   -> ModuleName
                   -> (Id -> MkCurrExpr)
                   -> (Expr -> MkArgTypes)
                   -> Config
                   -> (State (), Bindings)
initStateWithCall' exg2 =
    initStateWithCall exg2 False

{-# INLINE initState' #-}
initState' :: ExtractedG2
           -> MkCurrExpr
           -> MkArgTypes
           -> Config
           -> (State (), Bindings)
initState' exg2 mkCurr =
    initState exg2 False mkCurr

{-# INLINE initStateFromSimpleStateWithCall #-}
initStateFromSimpleStateWithCall :: IT.SimpleState
                                 -> Bool
                                 -> StartFunc
                                 -> ModuleName
                                 -> (Id -> MkCurrExpr)
                                 -> (Expr -> MkArgTypes)
                                 -> Config
                                 -> (State (), Id, Bindings)
initStateFromSimpleStateWithCall simp_s useAssert f m_mod mkCurr argTys config =
    let
        (ie, fe) = case findFunc f m_mod (IT.expr_env simp_s) of
                        Left ie' -> ie'
                        Right errs -> error errs
    
        (s, b) = initStateFromSimpleState simp_s useAssert (mkCurr ie) (argTys fe) config
    in
    (s, ie, b)

initStateFromSimpleState :: IT.SimpleState
                         -> Bool
                         -> MkCurrExpr
                         -> MkArgTypes
                         -> Config
                         -> (State (), Bindings)
initStateFromSimpleState s useAssert mkCurr argTys config =
    let
        ts = argTys s

        (s', ds_walkers) = runInitialization2 s ts
        eenv' = IT.expr_env s'
        tenv' = IT.type_env s'
        ng' = IT.name_gen s'
        kv' = IT.known_values s'
        tc' = IT.type_classes s'

        (ce, is, f_i, ng'') = mkCurr tc' ng' eenv' ds_walkers kv' config
    in
    (State {
      expr_env = foldr (\i@(Id n _) -> E.insertSymbolic n i) eenv' is
    , type_env = tenv'
    , curr_expr = CurrExpr Evaluate ce
    , path_conds = PC.fromList []
    , non_red_path_conds = []
    , true_assert = if useAssert then False else True
    , assert_ids = Nothing
    , type_classes = tc'
    , symbolic_ids = S.fromList is
    , exec_stack = Stack.empty
    , model = HM.empty
    , known_values = kv'
    , rules = []
    , num_steps = 0
    , track = ()
    , tags = S.empty
    }
    , Bindings {
    deepseq_walkers = ds_walkers
    , fixed_inputs = f_i
    , arb_value_gen = arbValueInit
    , cleaned_names = HM.empty
    , input_names = map idName is
    , higher_order_inst = S.fromList $ IT.exports s
    , rewrite_rules = IT.rewrite_rules s
    , name_gen = ng''
    , exported_funcs = IT.exports s 
    , last_merge_point = MP 0 })

mkArgTys :: Expr -> MkArgTypes
mkArgTys e simp_s =
    snd $ instantiateArgTypes (IT.type_classes simp_s) (IT.known_values simp_s) e

{-# INLINE initStateFromSimpleState' #-}
initStateFromSimpleState' :: IT.SimpleState
                          -> StartFunc
                          -> ModuleName
                          -> Config
                          -> (State (), Bindings)
initStateFromSimpleState' s sf m_mod =
    let
        (ie, fe) = case findFunc sf m_mod (IT.expr_env s) of
                          Left ie' -> ie'
                          Right errs -> error errs
    in
    initStateFromSimpleState s False (mkCurrExpr Nothing Nothing ie) (mkArgTys fe)

{-# INLINE initSimpleState #-}
initSimpleState :: ExtractedG2
                -> IT.SimpleState
initSimpleState (ExtractedG2 { exg2_binds = prog
                             , exg2_tycons = prog_typ
                             , exg2_classes = cls
                             , exg2_exports = es
                             , exg2_rules = rs }) =
    let
        eenv = mkExprEnv prog
        tenv = mkTypeEnv prog_typ
        tc = initTypeClasses cls
        kv = initKnownValues eenv tenv tc
        ng = mkNameGen (prog, prog_typ)

        s = IT.SimpleState { IT.expr_env = eenv
                           , IT.type_env = tenv
                           , IT.name_gen = ng
                           , IT.known_values = kv
                           , IT.type_classes = tc
                           , IT.rewrite_rules = rs
                           , IT.exports = es }
    in
    runInitialization1 s

initCheckReaches :: State t -> ModuleName -> Maybe ReachFunc -> State t
initCheckReaches s@(State { expr_env = eenv
                          , known_values = kv }) m_mod reaches =
    s {expr_env = checkReaches eenv kv reaches m_mod }

initRedHaltOrd :: (Solver solver, Simplifier simplifier) => solver -> simplifier -> Config -> (SomeReducer (), SomeHalter (), SomeOrderer ())
initRedHaltOrd solver simplifier config =
    let
        share = sharing config
        mergeStates = stateMerging config

        tr_ng = mkNameGen ()
        state_name = Name "state" Nothing 0 Nothing
    in
    if higherOrderSolver config == AllFuncs
        then (SomeReducer (NonRedPCRed)
                 <~| (case logStates config of
                        Just fp -> SomeReducer (StdRed share mergeStates solver simplifier :<~ Logger fp)
                        Nothing -> SomeReducer (StdRed share mergeStates solver simplifier))
             , SomeHalter
                 (SwitchEveryNHalter 20
                 :<~> MaxOutputsHalter (maxOutputs config)
                 :<~> ZeroHalter (steps config)
                 :<~> AcceptIfViolatedHalter)
             , SomeOrderer $ PickLeastUsedOrderer)
        else ( SomeReducer (NonRedPCRed :<~| TaggerRed state_name tr_ng)
                 <~| (case logStates config of
                        Just fp -> SomeReducer (StdRed share mergeStates solver simplifier :<~ Logger fp)
                        Nothing -> SomeReducer (StdRed share mergeStates solver simplifier))
             , SomeHalter
                 (DiscardIfAcceptedTag state_name
                 :<~> SwitchEveryNHalter 20
                 :<~> MaxOutputsHalter (maxOutputs config) 
                 :<~> ZeroHalter (steps config)
                 :<~> AcceptIfViolatedHalter)
             , SomeOrderer $ PickLeastUsedOrderer)

initSolver :: Config -> IO SomeSolver
initSolver = initSolver' arbValue

initSolverInfinite :: Config -> IO SomeSolver
initSolverInfinite con = initSolver' arbValueInfinite con

initSolver' :: ArbValueFunc -> Config -> IO SomeSolver
initSolver' avf config = do
    SomeSMTSolver con <- getSMTAV avf config
    return $ SomeSolver (GroupRelated avf (UndefinedHigherOrder :?> con))

mkExprEnv :: [(Id, Expr)] -> E.ExprEnv
mkExprEnv = E.fromExprList . map (\(i, e) -> (idName i, e))

mkTypeEnv :: [ProgramType] -> TypeEnv
mkTypeEnv = M.fromList . map (\(n, dcs) -> (n, dcs))

{-# INLINE initialStateFromFileSimple #-}
initialStateFromFileSimple :: [FilePath]
                   -> [FilePath]
                   -> [FilePath]
                   -> StartFunc
                   -> (Id -> MkCurrExpr)
                   -> (Expr -> MkArgTypes)
                   -> Config
                   -> IO (State (), Id, Bindings)
initialStateFromFileSimple proj src libs f mkCurr config =
    initialStateFromFile proj src libs Nothing False f mkCurr config

initialStateFromFile :: [FilePath]
                     -> [FilePath]
                     -> [FilePath]
                     -> Maybe ReachFunc
                     -> Bool
                     -> StartFunc
                     -> (Id -> MkCurrExpr)
                     -> (Expr -> MkArgTypes)
                     -> Config
                     -> IO (State (), Id, Bindings)
initialStateFromFile proj src libs m_reach def_assert f mkCurr argTys config = do
    (mb_modname, exg2) <- translateLoaded proj src libs simplTranslationConfig config

    let simp_state = initSimpleState exg2
        (ie, fe) = case findFunc f mb_modname (IT.expr_env simp_state) of
                        Left ie' -> ie'
                        Right errs -> error errs

        (init_s, bindings) = initStateFromSimpleState simp_state def_assert
                                                  (mkCurr ie) (argTys fe) config
    -- let (init_s, ent_f, bindings) = initState exg2 def_assert
    --                                 f mb_modname mkCurr argTys config
        reaches_state = initCheckReaches init_s mb_modname m_reach

    return (reaches_state, ie, bindings)

runG2FromFile :: [FilePath]
              -> [FilePath]
              -> [FilePath]
              -> Maybe AssumeFunc
              -> Maybe AssertFunc
              -> Maybe ReachFunc
              -> Bool
              -> StartFunc
              -> Config
              -> IO (([ExecRes ()], Bindings), Id)
runG2FromFile proj src libs m_assume m_assert m_reach def_assert f config = do
    (init_state, entry_f, bindings) <- initialStateFromFile proj src libs
                                    m_reach def_assert f (mkCurrExpr m_assume m_assert) (mkArgTys) config

    r <- runG2WithConfig init_state config bindings

    return (r, entry_f)

runG2WithConfig :: State () -> Config -> Bindings -> IO ([ExecRes ()], Bindings)
runG2WithConfig state config bindings = do
    let mergeStates = stateMerging config
    SomeSolver solver <- initSolver config
    let simplifier = IdSimplifier -- :<< EliminateAssumePCs

    (in_out, bindings') <- case initRedHaltOrd solver simplifier config of
                (red, hal, ord) ->
                    runG2WithSomes red hal ord solver simplifier mergeStates emptyMemConfig state bindings
    close solver

    return (in_out, bindings')

runG2WithSomes :: ( Named t
                  , Eq t
                  , Show t
                  , ASTContainer t Expr
                  , ASTContainer t Type
                  , Solver solver
                  , Simplifier simplifier)
               => (SomeReducer t)
               -> (SomeHalter t)
               -> (SomeOrderer t)
               -> solver
               -> simplifier
               -> Merging
               -> MemConfig
               -> State t
               -> Bindings
               -> IO ([ExecRes t], Bindings)
runG2WithSomes red hal ord solver simplifier mergeStates mem state bindings =
    case (red, hal, ord) of
        (SomeReducer red', SomeHalter hal', SomeOrderer ord') ->
            runG2 red' hal' ord' solver simplifier mergeStates mem state bindings

runG2Pre :: ( Named t
            , ASTContainer t Expr
            , ASTContainer t Type) => MemConfig -> State t -> Bindings -> (State t, Bindings)
runG2Pre mem s@(State { known_values = kv, type_classes = tc }) bindings =
    let
        (swept, bindings') = markAndSweepPreserving
                              ( names (lookupStructEqDicts kv tc) `addSearchNames` mem) s bindings
    in
    runPreprocessing swept bindings'

runG2Post :: ( Named t
             , Eq t
             , Show t
             , ASTContainer t Expr
             , ASTContainer t Type
             , Reducer r rv t
             , Halter h hv t
             , Orderer or sov b t
             , Solver solver
             , Simplifier simplifier) => r -> h -> or ->
             solver -> simplifier -> State t -> Bindings -> Merging -> IO ([ExecRes t], Bindings)
runG2Post red hal ord solver simplifier is bindings mergeStates = do
    (exec_states, bindings') <- runExecution red hal ord simplifier mergeStates is bindings
    sol_states <- mapM (runG2Solving solver simplifier bindings') exec_states

    return (catMaybes sol_states, bindings')

runG2ThroughExecution ::
    ( Eq t
    , Named t
    , ASTContainer t Expr
    , ASTContainer t Type
    , Reducer r rv t
    , Halter h hv t
    , Orderer or sov b t
    , Simplifier simplifier) => r -> h -> or -> simplifier ->
    Merging -> MemConfig -> State t -> Bindings -> IO ([State t], Bindings)
runG2ThroughExecution red hal ord simplifier merge mem is bindings = do
    let (is', bindings') = runG2Pre mem is bindings
    runExecution red hal ord simplifier merge is' bindings'


runG2Solving :: ( Named t
                , ASTContainer t Expr
                , ASTContainer t Type
                , Solver solver
                , Simplifier simplifier) =>
                solver -> simplifier -> Bindings -> State t -> IO (Maybe (ExecRes t))
runG2Solving solver simplifier bindings s@(State { known_values = kv })
    | true_assert s = do
        r <- solve solver s bindings (S.toList $ symbolic_ids s) (path_conds s)

        case r of
            SAT m -> do
                let m' = reverseSimplification simplifier s bindings m

                let s' = s { model = m' }

                let (es, e, ais) = subModel s' bindings
                    sm = ExecRes { final_state = s'
                                 , conc_args = es
                                 , conc_out = e
                                 , violated = ais}

                let sm' = runPostprocessing bindings sm

                let sm'' = ExecRes { final_state = final_state sm'
                                   , conc_args = fixed_inputs bindings ++ conc_args sm'
                                   , conc_out = evalPrims kv (conc_out sm')
                                   , violated = evalPrims kv (violated sm')}
                
                return $ Just sm''
            UNSAT _ -> return Nothing
            Unknown _ -> return Nothing

    | otherwise = return Nothing

-- | Runs G2, returning both fully executed states,
-- and states that have only been partially executed.
runG2 :: ( Named t
         , Eq t
         , Show t
         , ASTContainer t Expr
         , ASTContainer t Type
         , Reducer r rv t
         , Halter h hv t
         , Orderer or sov b t
         , Solver solver
         , Simplifier simplifier) => r -> h -> or ->
         solver -> simplifier -> Merging -> MemConfig -> State t -> Bindings -> IO ([ExecRes t], Bindings)
runG2 red hal ord solver simplifier mergeStates mem is bindings = do
    (exec_states, bindings') <- runG2ThroughExecution red hal ord simplifier mergeStates mem is bindings
    sol_states <- mapM (runG2Solving solver simplifier bindings') exec_states

    return (catMaybes sol_states, bindings')
