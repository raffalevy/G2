{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE TupleSections #-}

module G2.Liquid.Inference.Interface ( inferenceCheck
                                     , inference) where

import G2.Config.Config as G2
import qualified G2.Initialization.Types as IT
import G2.Interface hiding (violated)
import G2.Language.CallGraph
import qualified G2.Language.ExprEnv as E
import G2.Language.Naming
import G2.Language.Support
import G2.Language.Syntax
import G2.Liquid.AddTyVars
import G2.Liquid.Inference.Config
import G2.Liquid.Inference.FuncConstraint as FC
import G2.Liquid.Inference.G2Calls
import G2.Liquid.Inference.PolyRef
import G2.Liquid.Inference.Sygus
import G2.Liquid.Inference.GeneratedSpecs
import G2.Liquid.Inference.Verify
import G2.Liquid.Interface
import G2.Liquid.Types
import G2.Solver
import G2.Translation

import Language.Haskell.Liquid.Types as LH

import Control.Monad
import Control.Monad.Extra
import Control.Monad.IO.Class 
import Data.Either
import qualified Data.HashSet as S
import qualified Data.HashMap.Lazy as HM
import Data.List
import Data.Maybe
import qualified Data.Text as T

import qualified Language.Fixpoint.Types.Config as FP

-- Run inference, with an extra, final check of correctness at the end.
-- Assuming inference is working correctly, this check should neve fail.
inferenceCheck :: InferenceConfig -> G2.Config -> [FilePath] -> [FilePath] -> [FilePath] -> IO (Either [CounterExample] GeneratedSpecs)
inferenceCheck infconfig config proj fp lhlibs = do
    (ghci, lhconfig) <- getGHCI infconfig config proj fp lhlibs
    res <- inference' infconfig config lhconfig ghci proj fp lhlibs
    case res of
        Right gs -> do
            check_res <- checkGSCorrect infconfig lhconfig ghci gs
            case check_res of
                Safe -> return res
                _ -> error "inferenceCheck: Check failed"
        _ -> return res

inference :: InferenceConfig -> G2.Config -> [FilePath] -> [FilePath] -> [FilePath] -> IO (Either [CounterExample] GeneratedSpecs)
inference infconfig config proj fp lhlibs = do
    -- Initialize LiquidHaskell
    (ghci, lhconfig) <- getGHCI infconfig config proj fp lhlibs
    inference' infconfig config lhconfig ghci proj fp lhlibs

inference' :: InferenceConfig
           -> G2.Config
           -> LH.Config
           -> [GhcInfo]
           -> [FilePath]
           -> [FilePath]
           -> [FilePath]
           -> IO (Either [CounterExample] GeneratedSpecs)
inference' infconfig config lhconfig ghci proj fp lhlibs = do
    mapM (print . gsQualifiers . spec) ghci

    -- Initialize G2
    let g2config = config { mode = Liquid
                          , steps = 2000 }
        transConfig = simplTranslationConfig { simpl = False }
    (main_mod, exg2) <- translateLoaded proj fp lhlibs transConfig g2config

    let simp_s = initSimpleState exg2
        (g2config', infconfig') = adjustConfig main_mod simp_s g2config infconfig ghci

        lrs = createStateForInference simp_s g2config' ghci

        eenv = expr_env . state . lr_state $ lrs

        cg = getCallGraph $ eenv
        nls = filter (not . null)
             . map (filter (\(Name _ m _ _) -> m == main_mod))
             $ nameLevels cg 

    putStrLn $ "cg = " ++ show (filter (\(Name _ m _ _) -> m == main_mod) . functions $ getCallGraph eenv)
    putStrLn $ "nls = " ++ show nls

    let configs = Configs { g2_config = g2config', lh_config = lhconfig, inf_config = infconfig'}
        prog = newProgress

    SomeSMTSolver smt <- getSMT g2config'
    let infL = iterativeInference smt ghci main_mod lrs nls HM.empty initMaxSize emptyGS emptyFC

    runConfigs (runProgresser infL prog) configs

getGHCI :: InferenceConfig -> G2.Config -> [FilePath] -> [FilePath] -> [FilePath] -> IO ([GhcInfo], LH.Config)
getGHCI infconfig config proj fp lhlibs = do
    lhconfig <- defLHConfig proj lhlibs
    let lhconfig' = lhconfig { pruneUnsorted = True
                             -- Block qualifiers being auto-generated by LH
                             , maxParams = if keep_quals infconfig then maxParams lhconfig else 0
                             , eliminate = if keep_quals infconfig then eliminate lhconfig else FP.All
                             , higherorderqs = False
                             , scrapeImports = False
                             , scrapeInternals = False
                             , scrapeUsedImports = False }
    ghci <- ghcInfos Nothing lhconfig' fp
    return (ghci, lhconfig)

data InferenceRes = CEx [CounterExample]
                  | Env GeneratedSpecs
                  | Raise MeasureExs FuncConstraints MaxSizeConstraints
                  deriving (Show)

-- When we try to synthesize a specification for a function that we have already found a specification for,
-- we have to return to when we originally synthesized that specification.  We pass the newly aquired
-- FuncConstraints as RisignFuncConstraints
type RisingFuncConstraints = FuncConstraints

type Level = Int
type NameLevels = [[Name]]

type MaxSizeConstraints = FuncConstraints

iterativeInference :: (ProgresserM m, InfConfigM m, MonadIO m, SMTConverter con ast out io)
                   => con
                   -> [GhcInfo]
                   -> Maybe T.Text
                   -> LiquidReadyState
                   -> NameLevels
                   -> MeasureExs
                   -> MaxSize
                   -> GeneratedSpecs
                   -> FuncConstraints
                   -> m (Either [CounterExample] GeneratedSpecs)
iterativeInference con ghci m_modname lrs nls meas_ex max_sz gs fc = do
    res <- inferenceL con ghci m_modname lrs nls emptyEvals meas_ex max_sz gs fc emptyFC
    case res of
        CEx cex -> return $ Left cex
        Env gs -> return $ Right gs
        Raise r_meas_ex r_fc _ -> iterativeInference con ghci m_modname lrs nls r_meas_ex (incrMaxSize max_sz) gs r_fc


inferenceL :: (ProgresserM m, InfConfigM m, MonadIO m, SMTConverter con ast out io)
           => con
           -> [GhcInfo]
           -> Maybe T.Text
           -> LiquidReadyState
           -> NameLevels
           -> Evals Bool
           -> MeasureExs
           -> MaxSize
           -> GeneratedSpecs
           -> FuncConstraints
           -> MaxSizeConstraints
           -> m InferenceRes
inferenceL con ghci m_modname lrs nls evals meas_ex max_sz gs fc max_fc = do
    let (fs, sf) = case nls of
                        (fs_:sf_:_) -> (fs_, sf_)
                        ([fs_])-> (fs_, [])
                        [] -> ([], [])

    let curr_ghci = addSpecsToGhcInfos ghci gs
    evals' <- updateEvals curr_ghci lrs fc evals
    synth_gs <- synthesize con curr_ghci lrs evals' meas_ex max_sz fc sf

    case synth_gs of
        SynthEnv envN -> do
            let gs' = unionDroppingGS gs envN
                ghci' = addSpecsToGhcInfos ghci gs'
            liftIO $ do
                putStrLn "inferenceL"
                putStrLn $ "fs = " ++ show fs
                putStrLn $ "init gs' = " ++ show gs'
                mapM (print . gsTySigs . spec) ghci'

            res <- tryToVerifyOnly ghci' fs

            liftIO . putStrLn $ "res = " ++ show res
            
            case res of
                Safe ->
                    case nls of
                        (_:nls') -> do
                            liftIO $ putStrLn "Down a level!"
                            inf_res <- inferenceL con ghci m_modname lrs nls' emptyEvals meas_ex max_sz gs' fc max_fc
                            case inf_res of
                                Raise r_meas_ex r_fc r_max_fc -> do
                                    liftIO $ putStrLn "Up a level!"
                                    inferenceL con ghci m_modname lrs nls evals' r_meas_ex max_sz gs r_fc r_max_fc
                                _ -> return inf_res
                        [] -> return $ Env gs'
                Unsafe bad -> do
                    ref <- refineUnsafe ghci m_modname lrs gs' bad
                    case ref of
                        Left cex -> return $ CEx cex
                        Right fc' -> do
                            liftIO $ putStrLn "Before genMeasureExs"
                            meas_ex' <- updateMeasureExs meas_ex lrs ghci fc'
                            liftIO $ putStrLn "After genMeasureExs"
                            inferenceL con ghci m_modname lrs nls evals' meas_ex' max_sz gs (unionFC fc fc') max_fc
                Crash _ _ -> error "inferenceL: LiquidHaskell crashed"
        SynthFail fc' -> return $ Raise meas_ex fc (unionFC max_fc fc')


{-    let ignore = concat nls

    res <- tryHardToVerifyIgnoring ghci gs ignore


    case res of
        Right new_gs
            | (_:nls') <- nls -> do
                let ghci' = addSpecsToGhcInfos ghci new_gs
                
                raiseFCs level ghci m_modname lrs nls
                    =<< inferenceL (level + 1) ghci' m_modname lrs nls' WorkDown new_gs fc []
            | otherwise -> return $ GS new_gs
        Left bad -> do
            ref <- refineUnsafe ghci m_modname lrs wd gs bad

            -- If we got repeated assertions, increase the search depth
            -- case any (\n -> lookupAssertGS n gs == lookupAssertGS n synth_gs) try_to_synth of
            --     True -> mapM_ (incrMaxCExM . nameTuple) bad
            --     False -> return ()

            case ref of
                Left cex -> return $ CEx cex
                Right (new_fc, wd')  -> do
                    let pre_solved = notAppropFCs (concat nls) new_fc
                    case nullFC pre_solved of
                        False -> do

                            return $ FCs fc new_fc gs
                        True -> do
                            let merged_fc = unionFC fc new_fc

                            rel_funcs <- relFuncs nls new_fc

                            synth_gs <- synthesize ghci lrs gs merged_fc rel_funcs
                            increaseProgressing new_fc gs synth_gs rel_funcs
                            
                            inferenceL level ghci m_modname lrs nls wd' synth_gs merged_fc rel_funcs


raiseFCs :: (ProgresserM m, InfConfigM m, MonadIO m) =>  Level -> [GhcInfo] -> Maybe T.Text -> LiquidReadyState
         -> NameLevels -> InferenceRes -> m InferenceRes
raiseFCs level ghci m_modname lrs nls lev@(FCs fc new_fc gs) = do
    let
        -- If we have new FuncConstraints, we need to resynthesize,
        -- but otherwise we can just keep the exisiting specifications
        -- cons_on = map (funcName . constraint) $ toListFC new_fc
    rel_funcs <- relFuncs nls new_fc

    if nullFC (notAppropFCs (concat nls) new_fc)
        then do
            let merge_fc = unionFC fc new_fc
            synth_gs <- synthesize ghci lrs gs merge_fc rel_funcs
            increaseProgressing new_fc gs synth_gs rel_funcs
            inferenceL level ghci m_modname lrs nls WorkUp synth_gs merge_fc rel_funcs
        else return lev
raiseFCs _ _ _ _ _ lev = do
    return lev
-}

refineUnsafe :: (ProgresserM m, InfConfigM m, MonadIO m) => [GhcInfo] -> Maybe T.Text -> LiquidReadyState
             -> GeneratedSpecs
             -> [Name] -> m (Either [CounterExample] FuncConstraints)
refineUnsafe ghci m_modname lrs gs bad = do
    let merged_se_ghci = addSpecsToGhcInfos ghci gs

    liftIO $ mapM_ (print . gsTySigs . spec) merged_se_ghci

    let bad' = nub $ map nameOcc bad

    res <- mapM (genNewConstraints merged_se_ghci m_modname lrs) bad'

    liftIO . putStrLn $ "res = " ++ show res

    let res' = concat res

    -- Either converts counterexamples to FuncConstraints, or returns them as errors to
    -- show to the user.
    new_fc <- checkNewConstraints ghci lrs res'

    case new_fc of
        Left cex -> return $ Left cex
        Right new_fc' -> do
            liftIO . putStrLn $ "new_fc' = " ++ show new_fc'
            return $ Right new_fc'

{-
adjustOldFC :: FuncConstraints -- ^ Old FuncConstraints
            -> FuncConstraints -- ^ New FuncConstraints
            -> FuncConstraints
adjustOldFC old_fc new_fc =
    let
        constrained = map (funcName . constraint) $ toListFC new_fc
    in
    mapMaybeFC
        (\c -> case modification c of
                    SwitchImplies ns
                        | ns `intersect` constrained /= [] ->
                            Just $ c { bool_rel = BRImplies }
                    Delete ns
                        | ns `intersect` constrained /= [] -> Nothing
                    _ -> Just c) old_fc
-}

appropFCs :: [Name] -> FuncConstraints -> FuncConstraints
appropFCs potential = undefined
{-
    let
        nm_potential = map nameTuple potential
    in
    filterFC (flip elem nm_potential . nameTuple . funcName . constraint)
-}

notAppropFCs :: [Name] -> FuncConstraints -> FuncConstraints
notAppropFCs potential = undefined
{-
    let
        nm_potential = map nameTuple potential
    in
    filterFC (flip notElem nm_potential . nameTuple . funcName . constraint)
-}

createStateForInference :: SimpleState -> G2.Config -> [GhcInfo] -> LiquidReadyState
createStateForInference simp_s config ghci =
    let
        (simp_s', ph_tyvars) = if add_tyvars config
                                then fmap Just $ addTyVarsEEnvTEnv simp_s
                                else (simp_s, Nothing)
        (s, b) = initStateFromSimpleState simp_s' True 
                    (\_ ng _ _ _ _ -> (Prim Undefined TyBottom, [], [], ng))
                    (E.higherOrderExprs . IT.expr_env)
                    config
    in
    createLiquidReadyState s b ghci ph_tyvars config


genNewConstraints :: (ProgresserM m, InfConfigM m, MonadIO m) => [GhcInfo] -> Maybe T.Text -> LiquidReadyState -> T.Text -> m [CounterExample]
genNewConstraints ghci m lrs n = do
    liftIO . putStrLn $ "Generating constraints for " ++ T.unpack n
    ((exec_res, _), i) <- runLHInferenceCore n m lrs ghci
    let exec_res' = filter (true_assert . final_state) exec_res
    return $ map (lhStateToCE i) exec_res'

checkNewConstraints :: (InfConfigM m, MonadIO m) => [GhcInfo] -> LiquidReadyState -> [CounterExample] -> m (Either [CounterExample] FuncConstraints)
checkNewConstraints ghci lrs cexs = do
    g2config <- g2ConfigM
    infconfig <- infConfigM
    res <- mapM (cexsToBlockingFC lrs ghci) cexs
    res2 <- return . concat =<< mapM cexsToExtraFC cexs
    case lefts res of
        res'@(_:_) -> return . Left $ res'
        _ -> return . Right . filterErrors . unionsFC . map fromSingletonFC $ (rights res) ++ res2

updateMeasureExs :: (InfConfigM m, MonadIO m) => MeasureExs -> LiquidReadyState -> [GhcInfo] -> FuncConstraints -> m MeasureExs
updateMeasureExs meas_ex lrs ghci fcs =
    let
        es = concatMap (\fc ->
                    let
                        cons = allCalls fc
                        vls = concatMap (\c -> returns c:arguments c) cons 
                        ex_poly = concat . concatMap extractValues . concatMap extractExprPolyBound $ vls
                    in
                    vls ++ ex_poly
                ) (toListFC fcs)
    in
    evalMeasures meas_ex lrs ghci es

increaseProgressing :: ProgresserM m => FuncConstraints -> GeneratedSpecs -> GeneratedSpecs -> [Name] -> m ()
increaseProgressing fc gs synth_gs synthed = undefined {- do
    -- If we got repeated assertions, increase the search depth
    case any (\n -> lookupAssertGS n gs == lookupAssertGS n synth_gs) synthed of
        True -> mapM_ (incrMaxCExM . nameTuple) (map generated_by $ toListFC fc)
        False -> return ()
-}

synthesize :: (InfConfigM m, MonadIO m, SMTConverter con ast out io)
           => con -> [GhcInfo] -> LiquidReadyState -> Evals Bool -> MeasureExs
           -> MaxSize -> FuncConstraints -> [Name] -> m SynthRes
synthesize con ghci lrs evals meas_ex max_sz fc for_funcs =
    liaSynth con ghci lrs evals meas_ex max_sz fc for_funcs

updateEvals :: (InfConfigM m, MonadIO m) => [GhcInfo] -> LiquidReadyState -> FuncConstraints -> Evals Bool -> m (Evals Bool)
updateEvals ghci lrs fc evals = do
    let cs = allCallsFC fc

    liftIO $ putStrLn "Before check func calls"
    evals' <- preEvals evals lrs ghci cs
    liftIO $ putStrLn "After pre"
    evals'' <- postEvals evals' lrs ghci cs
    liftIO $ putStrLn "After check func calls"

    return evals''

-- | Converts counterexamples into constraints that block the current specification set
cexsToBlockingFC :: (InfConfigM m, MonadIO m) => LiquidReadyState -> [GhcInfo] -> CounterExample -> m (Either CounterExample FuncConstraint)
cexsToBlockingFC _ _ (DirectCounter dfc fcs@(_:_)) = do
    infconfig <- infConfigM
    let fcs' = filter (\fc -> abstractedMod fc `S.member` modules infconfig) fcs

    let lhs = AndFC [Call Pre dfc, NotFC (Call Post dfc)]
        rhs = OrFC $ map (\(Abstracted { abstract = fc }) -> 
                            ImpliesFC (Call Pre fc) (NotFC (Call Post fc))) fcs'

    if not . null $ fcs'
        then return . Right $ ImpliesFC lhs rhs
        else error "cexsToBlockingFC: Unhandled"
cexsToBlockingFC _ _ (CallsCounter dfc cfc fcs@(_:_)) = do
    infconfig <- infConfigM
    let fcs' = filter (\fc -> abstractedMod fc `S.member` modules infconfig) fcs

    let lhs = AndFC [Call Pre dfc, NotFC (Call Pre (abstract cfc))]
        rhs = OrFC $ map (\(Abstracted { abstract = fc }) -> 
                            ImpliesFC (Call Pre fc) (NotFC (Call Post fc))) fcs'

    if not . null $ fcs' 
        then return . Right $ ImpliesFC lhs rhs
        else error "cexsToBlockingFC: Should be unreachable! Non-refinable function abstracted!"    
cexsToBlockingFC lrs ghci cex@(DirectCounter dfc [])
    | isError (returns dfc) = do
        if isExported lrs (funcName dfc)
            then return . Left $ cex
            else return . Right . NotFC $ Call Pre dfc
    | isExported lrs (funcName dfc) = do
        post_ref <- checkPost ghci lrs dfc
        case post_ref of
            True -> return $ Right (Call All dfc)
            False -> return . Left $ cex
    | otherwise = return $ Right (Call All dfc)
cexsToBlockingFC lrs ghci cex@(CallsCounter dfc cfc [])
    | any isError (arguments (abstract cfc)) = do
        if
            | isExported lrs (funcName dfc)
            , isExported lrs (funcName (real cfc)) -> do
                called_pr <- checkPre ghci lrs (real cfc) -- TODO: Shouldn't be changing this?
                case called_pr of
                    True -> return . Right $ NotFC (Call Pre dfc)
                    False -> return . Left $ cex
            | isExported lrs (funcName dfc) -> do
                called_pr <- checkPre ghci lrs (real cfc)
                case called_pr of
                    True -> return . Right $ NotFC (Call Pre dfc)
                    False -> return . Left $ cex
            | otherwise -> return . Right $ NotFC (Call Pre dfc)
    | otherwise = do
        if
            | isExported lrs (funcName dfc)
            , isExported lrs (funcName (real cfc)) -> do
                called_pr <- checkPre ghci lrs (real cfc) -- TODO: Shouldn't be changing this?
                case called_pr of
                    True -> return . Right $ ImpliesFC (Call Pre dfc) (Call Pre (abstract cfc))
                    False -> return . Left $ cex
            | isExported lrs (funcName dfc) -> do
                called_pr <- checkPre ghci lrs (real cfc)
                case called_pr of
                    True -> return . Right $ ImpliesFC (Call Pre dfc) (Call Pre (abstract cfc))
                    False -> return . Left $ cex
            | otherwise -> return . Right $ ImpliesFC (Call Pre dfc) (Call Pre (abstract cfc))

-- Function constraints that don't block the current specification set, but which must be true
-- (i.e. the actual input and output for abstracted functions)
cexsToExtraFC :: InfConfigM m => CounterExample -> m [FuncConstraint]
cexsToExtraFC (DirectCounter _ fcs@(_:_)) = do
    infconfig <- infConfigM
    let fcs' = filter (\fc -> abstractedMod fc `S.member` modules infconfig) fcs
    return $ map (\(Abstracted { real = fc }) -> ImpliesFC (Call Pre fc) (Call Post fc)) fcs'
cexsToExtraFC (CallsCounter _ cfc fcs@(_:_)) = do
    infconfig <- infConfigM
    let fcs' = filter (\fc -> abstractedMod fc `S.member` modules infconfig) fcs

    let abs = map (\(Abstracted { real = fc }) -> ImpliesFC (Call Pre fc) (Call Post fc)) fcs'
        clls = Call All $ real cfc

    return $ clls:abs
cexsToExtraFC (DirectCounter fc []) = return []
cexsToExtraFC (CallsCounter dfc cfc [])
    | isError (returns dfc) = return []
    | isError (returns (real cfc)) = return []
    | any isError (arguments (real cfc)) = return []
    | otherwise =
        let
            call_all_dfc = Call All dfc
            call_all_cfc = Call All (real cfc)
            imp_fc = ImpliesFC (Call Pre dfc) (Call Pre $ real cfc)
        in
        return $ [call_all_dfc, call_all_cfc, imp_fc]

isExported :: LiquidReadyState -> Name -> Bool
isExported lrs n = n `elem` exported_funcs (lr_binding lrs)

{-
cexsToFuncConstraints :: InfConfigM m => LiquidReadyState -> [GhcInfo] -> WorkingDir -> CounterExample -> m (Either CounterExample FuncConstraints)
cexsToFuncConstraints _ _ _ (DirectCounter dfc fcs@(_:_)) = do
    infconfig <- infConfigM
    let fcs' = filter (\fc -> abstractedMod fc `S.member` modules infconfig) fcs

    real_cons <- mapMaybeM (mkRealFCFromAbstracted imp (funcName dfc)) fcs'
    abs_cons <- mapMaybeM (mkAbstractFCFromAbstracted del (funcName dfc)) fcs'

    if not . null $ fcs'
        then return . Right . insertsFC $ real_cons ++ abs_cons
        else error "cexsToFuncConstraints: unhandled 1"
    where
        imp _ = SwitchImplies [funcName dfc]
        del _ = Delete [funcName dfc]
cexsToFuncConstraints _ _ _ (CallsCounter dfc cfc fcs@(_:_)) = do
    infconfig <- infConfigM
    let fcs' = filter (\fc -> abstractedMod fc `S.member` modules infconfig) fcs

    callee_cons <- mkRealFCFromAbstracted imp (funcName dfc) cfc
    real_cons <- mapMaybeM (mkRealFCFromAbstracted imp (funcName dfc)) fcs'
    abs_cons <- mapMaybeM (mkAbstractFCFromAbstracted del (funcName dfc)) fcs'

    if not . null $ fcs' 
        then return . Right . insertsFC
                            $ maybeToList callee_cons ++ real_cons ++ abs_cons
        else error "cexsToFuncConstraints: Should be unreachable! Non-refinable function abstracted!"
    where
        imp n = SwitchImplies $ funcName dfc:delete n ns
        del _ = Delete $ [funcName dfc, funcName $ abstract cfc] ++ ns

        ns = nub $ map (funcName . abstract) fcs
cexsToFuncConstraints lrs ghci _ cex@(DirectCounter fc []) = do
    let Name n m _ _ = funcName fc
    infconfig <- infConfigM
    case (n, m) `S.member` pre_refined infconfig of
        False ->
            return . Right . insertsFC $
                                [FC { polarity = if notRetError fc then Pos else Neg
                                    , generated_by = funcName fc
                                    , violated = Post
                                    , modification = SwitchImplies [funcName fc]
                                    , bool_rel = BRImplies
                                    , constraint = fc} ]
        True -> return . Left $ cex
cexsToFuncConstraints lrs ghci wd cex@(CallsCounter caller_fc called_fc []) = do
    caller_pr <- hasUserSpec (funcName caller_fc)
    called_pr <- hasUserSpec (funcName $ real called_fc)

    case (caller_pr, called_pr) of
        (True, True) -> return .  Left $ cex
        (False, True) ->  return . Right . insertsFC $
                                                  [FC { polarity = Neg
                                                      , generated_by = funcName caller_fc
                                                      , violated = Pre
                                                      , modification = None -- [funcName called_fc]
                                                      , bool_rel = BRImplies 
                                                      , constraint = caller_fc } ]
        (True, False) -> return . Right . insertsFC $
                                                 [FC { polarity = if notRetError (real called_fc) then Pos else Neg
                                                     , generated_by = funcName caller_fc
                                                     , violated = Pre
                                                     , modification = None -- [funcName caller_fc]
                                                     , bool_rel = if notRetError (real called_fc) then BRAnd else BRImplies
                                                     , constraint = real called_fc } ]
        (False, False)
            | wd == WorkUp -> 
                           return . Right . insertsFC $
                                                    [ FC { polarity = Neg
                                                         , generated_by = funcName caller_fc
                                                         , violated = Pre
                                                         , modification = Delete [funcName $ real called_fc]
                                                         , bool_rel = BRImplies
                                                         , constraint = caller_fc {returns = Prim Error TyBottom} }
                                                         , FC { polarity = if notRetError caller_fc then Pos else Neg
                                                              , generated_by = funcName caller_fc
                                                              , violated = Pre
                                                              , modification = None
                                                              , bool_rel = BRImplies
                                                              , constraint = caller_fc }  ]
            | otherwise -> return . Right . insertsFC $
                                                   [FC { polarity = if notRetError (real called_fc) then Pos else Neg
                                                       , generated_by = funcName caller_fc
                                                       , violated = Pre
                                                       , modification = SwitchImplies [funcName caller_fc]
                                                       , bool_rel = if notRetError (real called_fc) then BRAnd else BRImplies
                                                       , constraint = real called_fc } ]

mkRealFCFromAbstracted :: InfConfigM m => (Name -> Modification) -> Name -> Abstracted -> m (Maybe FuncConstraint)
mkRealFCFromAbstracted md gb ce = do
    let fc = real ce
    user_def <- hasUserSpec $ funcName fc

    if not (hits_lib_err_in_real ce) && not user_def
        then
            return . Just $ FC { polarity = if notRetError fc then Pos else Neg
                               , generated_by = gb
                               , violated = Post
                               , modification = md (funcName fc)
                               , bool_rel = if notRetError fc then BRAnd else BRImplies
                               , constraint = fc }
        else return Nothing 

-- | If the real fc returns an error, we know that our precondition has to be
-- strengthened to block the input.
-- Thus, creating an abstract counterexample would be (at best) redundant.
mkAbstractFCFromAbstracted :: InfConfigM m => (Name -> Modification) -> Name -> Abstracted -> m (Maybe FuncConstraint)
mkAbstractFCFromAbstracted md gb ce = do
    let fc = abstract ce
    user_def <- hasUserSpec $ funcName fc

    if (notRetError (real ce) || hits_lib_err_in_real ce) && not user_def
        then
            return . Just $ FC { polarity = Neg
                               , generated_by = gb
                               , violated = Post
                               , modification = md (funcName fc)
                               , bool_rel = BRImplies
                               , constraint = fc } 
        else return Nothing
-}

hasUserSpec :: InfConfigM m => Name -> m Bool
hasUserSpec (Name n m _ _) = do
    infconfig <- infConfigM
    return $ (n, m) `S.member` pre_refined infconfig

getDirectCaller :: CounterExample -> Maybe FuncCall
getDirectCaller (CallsCounter f _ []) = Just f
getDirectCaller _ = Nothing

getDirectCalled :: CounterExample -> Maybe FuncCall
getDirectCalled (CallsCounter _ f []) = Just (abstract f)
getDirectCalled _ = Nothing

notRetError :: FuncCall -> Bool
notRetError (FuncCall { returns = Prim Error _ }) = False
notRetError _ = True

insertsFC :: [FuncConstraint] -> FuncConstraints
insertsFC = foldr insertFC emptyFC

abstractedMod :: Abstracted -> Maybe T.Text
abstractedMod = nameModule . funcName . abstract

filterErrors :: FuncConstraints -> FuncConstraints
filterErrors = id -- filterFC filterErrors'

filterErrors' :: FuncConstraint -> Bool
filterErrors' fc = undefined
{-
    let
        c = constraint fc

        as = not . any isError $ arguments c
    in
    as
    where
        isError (Prim Error _) = True
        isError _ = False
-}

isError :: Expr -> Bool
isError (Prim Error _) = True
isError (Prim Undefined _) = True
isError _ = False

relFuncs :: InfConfigM m => NameLevels -> FuncConstraints -> m [Name]
relFuncs nls fc = undefined {- do
    let immed_rel_fc = case nls of
                            (nl:_) -> appropFCs nl fc
                            _ -> emptyFC

    infconfig <- infConfigM
    return 
       . filter (\(Name _ m _ _) -> m `S.member` (modules infconfig))
       . nubBy (\n1 n2 -> nameOcc n1 == nameOcc n2)
       . map (funcName . constraint)
       . toListFC $ immed_rel_fc 
-}
