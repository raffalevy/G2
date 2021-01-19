{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

module G2.Liquid.Inference.Interface ( inferenceCheck
                                     , inference) where

import G2.Config.Config as G2
import qualified G2.Initialization.Types as IT
import G2.Interface hiding (violated)
import G2.Language.CallGraph
import G2.Language.Expr
import qualified G2.Language.ExprEnv as E
import G2.Language.Naming
import G2.Language.Support
import G2.Language.Syntax
import G2.Language.Typing
import G2.Liquid.AddTyVars
import G2.Liquid.ConvertCurrExpr
import G2.Liquid.Inference.Config
import G2.Liquid.Inference.FuncConstraint as FC
import G2.Liquid.Inference.G2Calls
import G2.Liquid.Inference.Initalization
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
import qualified Data.Map as M
import Data.Either
import qualified Data.HashSet as S
import qualified Data.HashMap.Lazy as HM
import Data.List
import Data.Maybe
import qualified Data.Text as T

import qualified Language.Fixpoint.Types.Config as FP

import Debug.Trace
import G2.Lib.Printers

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

    let (lrs, g2config', infconfig') = initStateAndConfig exg2 main_mod g2config infconfig ghci


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

data InferenceRes = CEx [CounterExample]
                  | Env GeneratedSpecs FuncConstraints MaxSizeConstraints MeasureExs
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
    res <- inferenceL con ghci m_modname lrs nls emptyEvals meas_ex max_sz gs fc emptyFC emptyBlockedModels
    case res of
        CEx cex -> return $ Left cex
        Env gs _ _ _ -> return $ Right gs
        Raise r_meas_ex r_fc _ -> do
            incrMaxDepthM
            -- We might be missing some internal GHC types from our deep_seq walkers
            -- We filter them out to avoid an error
            let eenv = expr_env . state $ lr_state lrs
                check = filter (\n -> 
                                  case E.lookup n eenv of
                                      Just e -> isJust $ 
                                              mkStrict_maybe 
                                              (deepseq_walkers $ lr_binding lrs) 
                                              (Var (Id (Name "" Nothing 0 Nothing) (returnType e)))
                                      Nothing -> False) (head nls)
            liftIO . putStrLn $ "head nls =  " ++ show (head nls)
            liftIO . putStrLn $ "iterativeInference check =  " ++ show check
            ref <- getCEx ghci m_modname lrs gs check
            case ref of
                Left cex -> return $ Left cex
                Right fc' -> do
                    r_meas_ex' <- updateMeasureExs r_meas_ex lrs ghci fc'
                    iterativeInference con ghci m_modname lrs nls r_meas_ex' (incrMaxSize max_sz) gs (unionFC fc' r_fc)


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
           -> BlockedModels
           -> m InferenceRes
inferenceL con ghci m_modname lrs nls evals meas_ex max_sz senv fc max_fc blk_mdls = do
    let (fs, sf, below_sf) = case nls of
                        (fs_:sf_:be) -> (fs_, sf_, be)
                        ([fs_])-> (fs_, [], [])
                        [] -> ([], [], [])

    (resAtL, evals') <- inferenceB con ghci m_modname lrs nls evals meas_ex max_sz senv fc max_fc blk_mdls

    liftIO $ do
        putStrLn "-------"
        putStrLn $ "lengths = " ++ show (HM.map (length . nub) (blockedHashMap blk_mdls))
        putStrLn "-------"

    case resAtL of
        Env senv' n_fc n_mfc meas_ex' -> 
            case nls of
                [] -> return resAtL
                (_:nls') -> do
                    liftIO $ putStrLn "Down a level!"
                    let evals'' = foldr deleteEvalsForFunc evals' sf
                    inf_res <- inferenceL con ghci m_modname lrs nls' evals'' meas_ex' max_sz senv' (unionFC fc n_fc) (unionFC max_fc n_mfc) emptyBlockedModels
                    case inf_res of
                        Raise r_meas_ex r_fc r_max_fc -> do
                            liftIO $ putStrLn "Up a level!"
                            
                            inferenceL con ghci m_modname lrs nls evals' r_meas_ex max_sz senv r_fc r_max_fc blk_mdls
                        _ -> return inf_res
        _ -> return resAtL

inferenceB :: (ProgresserM m, InfConfigM m, MonadIO m, SMTConverter con ast out io)
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
           -> BlockedModels
           -> m (InferenceRes, Evals Bool)
inferenceB con ghci m_modname lrs nls evals meas_ex max_sz gs fc max_fc blk_mdls = do
    let (fs, sf, below_sf) = case nls of
                        (fs_:sf_:be) -> (fs_, sf_, be)
                        ([fs_])-> (fs_, [], [])
                        [] -> ([], [], [])

    let curr_ghci = addSpecsToGhcInfos ghci gs
    evals' <- updateEvals curr_ghci lrs fc evals
    synth_gs <- synthesize con curr_ghci lrs evals' meas_ex max_sz (unionFC max_fc fc) blk_mdls (concat below_sf) sf

    liftIO $ do
        putStrLn "-------"
        putStrLn $ "lengths = " ++ show (HM.map (length . nub) (blockedHashMap blk_mdls))
        putStrLn "-------"

    case synth_gs of
        SynthEnv envN sz smt_mdl blk_mdls' -> do
            let gs' = unionDroppingGS gs envN
                ghci' = addSpecsToGhcInfos ghci gs'
            liftIO $ do
                putStrLn "inferenceB"
                putStrLn $ "fs = " ++ show fs
                putStrLn $ "init gs' = " ++ show gs'

            res <- tryToVerify ghci'
            let res' = filterNamesTo fs res
            
            case res' of
                Safe -> return $ (Env gs' fc max_fc meas_ex, evals')
                Unsafe bad -> do
                    ref <- tryToGen (nub bad) (emptyFC, emptyFC) unionFC unionFC
                            [ refineUnsafe ghci m_modname lrs gs'
                            , searchBelowLevel ghci m_modname lrs res sf gs' ]
                    case ref of
                        Left cex -> return $ (CEx cex, evals')
                        Right (viol_fc, no_viol_fc) -> do
                            (below_fc, blk_mdls'') <- case hasNewFC viol_fc fc of
                                              NoNewFC -> do
                                                  let called_by_res = concatMap (calledByFunc lrs) bad
                                                  new_blk_mdls <- adjModel lrs bad sz smt_mdl blk_mdls'
                                                  return (emptyFC, new_blk_mdls)                                                
                                              NewFC -> return (emptyFC, blk_mdls')

                            let fc' = viol_fc `unionFC` no_viol_fc `unionFC` below_fc
                            liftIO $ putStrLn "Before genMeasureExs"
                            meas_ex' <- updateMeasureExs meas_ex lrs ghci fc'
                            liftIO $ putStrLn "After genMeasureExs"

                            inferenceB con ghci m_modname lrs nls evals' meas_ex' max_sz gs (unionFC fc fc') max_fc blk_mdls''
                Crash _ _ -> error "inferenceB: LiquidHaskell crashed"
        SynthFail sf_fc -> do
            liftIO . putStrLn $ "synthfail fc = " ++ (printFCs sf_fc)
            return $ (Raise meas_ex fc (unionFC max_fc sf_fc), evals')

tryToGen :: Monad m =>
            [n] -- ^ A list of values to produce results for
         -> (r, ex) -- ^ A default result, in case none of the strategies work, or we are passed an empty [n]
         -> (r -> r -> r) -- ^ Some way of combining results
         -> (ex -> ex -> ex) -- ^ Some way of joining extra results
         -> [n -> m (Either err (Maybe r, ex))] -- ^ A list of strategies, in order, to try and produce a result
         -> m (Either err (r, ex))
tryToGen [] def _ _ _ = return $ Right def
tryToGen (n:ns) def join_r join_ex fs = do
    gen1 <- tryToGen' n def join_ex fs
    case gen1 of
        Left err -> return $ Left err
        Right (r1, ex1) -> do
            gen2 <- tryToGen ns def join_r join_ex fs
            case gen2 of
                Left err -> return $ Left err
                Right (r2, ex2) -> return $ Right (r1 `join_r` r2, ex1 `join_ex` ex2) 

tryToGen' :: Monad m =>
             n
          -> (r, ex)
          -> (ex -> ex -> ex)
          -> [n -> m (Either err (Maybe r, ex))]
          -> m (Either err (r, ex))
tryToGen' _ def _ [] = return $ Right (def)
tryToGen' n def join_ex (f:fs) = do
    gen1 <- f n
    case gen1 of
        Left err -> return $ Left err
        Right (Just r, ex) -> return $ Right (r, ex)
        Right (Nothing, ex1) -> do
            gen2 <- tryToGen' n def join_ex fs
            case gen2 of
                Left err -> return $ Left err
                Right (r, ex2) -> return $ Right (r, ex1 `join_ex` ex2)

refineUnsafeAll :: (ProgresserM m, InfConfigM m, MonadIO m) => 
                    [GhcInfo]
                -> Maybe T.Text
                -> LiquidReadyState
                -> GeneratedSpecs
                -> [Name]
                -> m (Either [CounterExample] (Maybe FuncConstraints, FuncConstraints))
refineUnsafeAll ghci m_modname lrs gs bad = do
    res <- mapM (refineUnsafe ghci m_modname lrs gs) bad

    case fmap unzip $ partitionEithers res of
        (cex@(_:_), _) -> return . Left $ concat cex
        ([], (new_fcs, no_viol_fcs)) -> 
            let
                new_fcs' = unionsFC (catMaybes new_fcs)
            in
            return . Right $ (if nullFC new_fcs' then Nothing else Just new_fcs', unionsFC no_viol_fcs)

refineUnsafe :: (ProgresserM m, InfConfigM m, MonadIO m) => 
                [GhcInfo]
             -> Maybe T.Text
             -> LiquidReadyState
             -> GeneratedSpecs
             -> Name
             -> m (Either [CounterExample] (Maybe FuncConstraints, FuncConstraints))
refineUnsafe ghci m_modname lrs gs bad = do
    let merged_se_ghci = addSpecsToGhcInfos ghci gs

    liftIO $ mapM_ (print . gsTySigs . spec) merged_se_ghci

    (res, no_viol) <- genNewConstraints merged_se_ghci m_modname lrs (nameOcc bad)

    liftIO $ do
        putStrLn $ "--- Generated Counterexamples and Constraints for " ++ show bad ++ " ---"
        putStrLn "res = "
        printCE res

        putStrLn "no_viol = "
        mapM (putStrLn . printFC) no_viol


    let res' = filter (not . hasAbstractedArgError) res

    -- Either converts counterexamples to FuncConstraints, or returns them as errors to
    -- show to the user.
    new_fc <- checkNewConstraints ghci lrs res'

    case new_fc of
        Left cex -> return $ Left cex
        Right new_fc' -> do
            liftIO . putStrLn $ "new_fc' = " ++ printFCs new_fc'
            return $ Right (if nullFC new_fc' then Nothing else Just new_fc', fromListFC no_viol)

searchBelowLevel :: (ProgresserM m, InfConfigM m, MonadIO m) =>
                    [GhcInfo]
                 -> Maybe T.Text
                 -> LiquidReadyState
                 -> VerifyResult Name
                 -> [Name]
                 -> GeneratedSpecs
                 -> Name
                 -> m (Either [CounterExample] (Maybe FuncConstraints, FuncConstraints))
searchBelowLevel ghci m_modname lrs verify_res lev_below gs bad = do
    let called_by_res = calledByFunc lrs bad
    case filterNamesTo called_by_res $ filterNamesTo lev_below verify_res of
        Unsafe bad_sf -> do
            liftIO $ putStrLn "About to run second run of CEx generation"
            ref_sf <- withConfigs noCounterfactual $ refineUnsafeAll ghci m_modname lrs gs bad_sf
            case ref_sf of
                Left cex -> return ref_sf
                Right (viol_fc_sf, no_viol_fc_sf) ->
                    return $ Right (viol_fc_sf, no_viol_fc_sf)
        Safe -> return $ Right (Nothing, emptyFC)
        Crash _ _ -> error "inferenceB: LiquidHaskell crashed"

adjModel :: (MonadIO m, ProgresserM m) => 
            LiquidReadyState
         -> [Name]
         -> Size
         -> SMTModel
         -> BlockedModels
         -> m BlockedModels
adjModel lrs bad_funcs sz smt_mdl blk_mdls = do
    liftIO $ putStrLn "adjModel repeated_fc"
    let blk_mdls' =
            foldr
                (\n -> 
                    let
                        clls = calledByFunc lrs n
                    in
                    insertBlockedModel sz (MNOnly (n:clls)) smt_mdl)
                blk_mdls
                bad_funcs

    liftIO . putStrLn $ "blocked models = " ++ show blk_mdls'

    incrMaxCExM
    mapM (\(Name n m _ _) -> incrMaxTimeM (n, m)) bad_funcs
    return blk_mdls'

calledByFunc :: LiquidReadyState -> Name -> [Name]
calledByFunc lrs n = 
    let
        eenv = expr_env . state $ lr_state lrs
    in
    map zeroOutUnq
        . filter (isJust . flip E.lookup eenv)
        . maybe [] id
        . fmap varNames
        . fmap snd
        $ E.lookupNameMod (nameOcc n) (nameModule n) eenv

filterNamesTo ::  [Name] -> VerifyResult Name -> VerifyResult Name
filterNamesTo ns (Unsafe unsafe) = 
    case filter (\n -> toOccMod n `elem` ns_nm) unsafe of
        [] -> Safe
        unsafe' -> do
          Unsafe unsafe'
    where
        ns_nm = map toOccMod ns
        toOccMod (Name n m _ _) = (n, m)
filterNamesTo _ vr = vr

noCounterfactual :: Configs -> Configs
noCounterfactual cons@(Configs { g2_config = g2_c }) = cons { g2_config = g2_c { counterfactual = NotCounterfactual } }

genNewConstraints :: (ProgresserM m, InfConfigM m, MonadIO m) => [GhcInfo] -> Maybe T.Text -> LiquidReadyState -> T.Text -> m ([CounterExample], [FuncConstraint])
genNewConstraints ghci m lrs n = do
    liftIO . putStrLn $ "Generating constraints for " ++ T.unpack n
    ((exec_res, _), i) <- runLHInferenceCore n m lrs ghci
    let (exec_res', no_viol) = partition (true_assert . final_state) exec_res
        
        allCCons = noAbsStatesToCons i $ exec_res' ++ no_viol

    return $ (map (lhStateToCE i) exec_res', allCCons)

getCEx :: (ProgresserM m, InfConfigM m, MonadIO m) => [GhcInfo] -> Maybe T.Text -> LiquidReadyState
             -> GeneratedSpecs
             -> [Name] -> m (Either [CounterExample] FuncConstraints)
getCEx ghci m_modname lrs gs bad = do
    let merged_se_ghci = addSpecsToGhcInfos ghci gs

    liftIO $ mapM_ (print . gsTySigs . spec) merged_se_ghci

    let bad' = nub $ map nameOcc bad

    res <- mapM (checkForCEx merged_se_ghci m_modname lrs) bad'

    liftIO $ do
        putStrLn $ "getCEx res = "
        printCE $ concat res

    let res' = concat res

    -- Either converts counterexamples to FuncConstraints, or returns them as errors to
    -- show to the user.
    new_fc <- checkNewConstraints ghci lrs res'

    case new_fc of
        Left cex -> return $ Left cex
        Right new_fc' -> do
            liftIO . putStrLn $ "new_fc' = " ++ printFCs new_fc'
            return $ Right new_fc'

checkForCEx :: (ProgresserM m, InfConfigM m, MonadIO m) => [GhcInfo] -> Maybe T.Text -> LiquidReadyState -> T.Text -> m [CounterExample]
checkForCEx ghci m lrs n = do
    liftIO . putStrLn $ "Checking CEx for " ++ T.unpack n
    ((exec_res, _), i) <- runLHCExSearch n m lrs ghci
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
        _ -> return . Right . unionsFC . map fromSingletonFC $ (rights res) ++ res2

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

synthesize :: (InfConfigM m, MonadIO m, SMTConverter con ast out io)
           => con -> [GhcInfo] -> LiquidReadyState -> Evals Bool -> MeasureExs
           -> MaxSize -> FuncConstraints -> BlockedModels -> [Name] -> [Name] -> m SynthRes
synthesize con ghci lrs evals meas_ex max_sz fc blk_mdls to_be for_funcs = do
    liftIO . putStrLn $ "all fc = " ++ printFCs fc
    liaSynth con ghci lrs evals meas_ex max_sz fc blk_mdls to_be for_funcs

updateEvals :: (InfConfigM m, MonadIO m) => [GhcInfo] -> LiquidReadyState -> FuncConstraints -> Evals Bool -> m (Evals Bool)
updateEvals ghci lrs fc evals = do
    let cs = allCallsFC fc

    liftIO $ putStrLn "Before check func calls"
    evals' <- preEvals evals lrs ghci cs
    liftIO $ putStrLn "After pre"
    evals'' <- postEvals evals' lrs ghci cs
    liftIO $ putStrLn "After check func calls"

    return evals''


data NewFC = NewFC | NoNewFC
           deriving Show

hasNewFC :: FuncConstraints -> FuncConstraints -> NewFC
hasNewFC fc1 fc2
    | not . nullFC $ differenceFC fc1 fc2 = NewFC
    | otherwise = NoNewFC

-- | Converts counterexamples into constraints that block the current specification set
cexsToBlockingFC :: (InfConfigM m, MonadIO m) => LiquidReadyState -> [GhcInfo] -> CounterExample -> m (Either CounterExample FuncConstraint)
cexsToBlockingFC _ _ (DirectCounter dfc fcs@(_:_))
    | (_:_, no_err_fcs) <- partition (hasArgError . abstract) fcs = undefined
    | isError (returns (abstract dfc)) = do
        infconfig <- infConfigM
        let fcs' = filter (\fc -> abstractedMod fc `S.member` modules infconfig) fcs

        let rhs = OrFC $ map (\(Abstracted { abstract = fc }) -> 
                        ImpliesFC (Call Pre fc) (NotFC (Call Post fc))) fcs'

        return . Right $ ImpliesFC (Call Pre (abstract dfc)) rhs
    | otherwise = do
        infconfig <- infConfigM
        let fcs' = filter (\fc -> abstractedMod fc `S.member` modules infconfig) fcs

        let lhs = AndFC [Call Pre (abstract dfc), NotFC (Call Post (abstract dfc))]
            rhs = OrFC $ map (\(Abstracted { abstract = fc }) -> 
                        ImpliesFC (Call Pre fc) (NotFC (Call Post fc))) fcs'

        if not . null $ fcs'
            then return . Right $ ImpliesFC lhs rhs
            else error "cexsToBlockingFC: Unhandled"
cexsToBlockingFC _ _ (CallsCounter dfc cfc fcs@(_:_))
    | (_:_, no_err_fcs) <- partition (hasArgError . abstract) fcs = undefined
    | otherwise = do
        infconfig <- infConfigM
        let fcs' = filter (\fc -> abstractedMod fc `S.member` modules infconfig) fcs

        let lhs = AndFC [Call Pre (abstract dfc), NotFC (Call Pre (abstract cfc))]
            rhs = OrFC $ map (\(Abstracted { abstract = fc }) -> 
                                ImpliesFC (Call Pre fc) (NotFC (Call Post fc))) fcs'

        if not . null $ fcs' 
            then return . Right $ ImpliesFC lhs rhs
            else error "cexsToBlockingFC: Should be unreachable! Non-refinable function abstracted!"    
cexsToBlockingFC lrs ghci cex@(DirectCounter dfc [])
    | isError (returns (real dfc)) = do
        if isExported lrs (funcName (real dfc))
            then return . Left $ cex
            else return . Right . NotFC $ Call Pre (real dfc)
    | isExported lrs (funcName (real dfc)) = do
        post_ref <- checkPost ghci lrs (real dfc)
        case post_ref of
            True -> return $ Right (Call All (real dfc))
            False -> return . Left $ cex
    | otherwise = return $ Right (Call All (real dfc))
cexsToBlockingFC lrs ghci cex@(CallsCounter dfc cfc [])
    | any isError (arguments (abstract cfc)) = do
        if
            | isExported lrs (funcName (real dfc))
            , isExported lrs (funcName (real cfc)) -> do
                called_pr <- checkPre ghci lrs (real cfc) -- TODO: Shouldn't be changing this?
                case called_pr of
                    True -> return . Right $ NotFC (Call Pre (real dfc))
                    False -> return . Left $ cex
            | isExported lrs (funcName (real dfc)) -> do
                called_pr <- checkPre ghci lrs (real cfc)
                case called_pr of
                    True -> return . Right $ NotFC (Call Pre (real dfc))
                    False -> return . Left $ cex
            | otherwise -> return . Right $ NotFC (Call Pre (real dfc))
    | otherwise = do
        if
            | isExported lrs (funcName (real dfc))
            , isExported lrs (funcName (real cfc)) -> do
                called_pr <- checkPre ghci lrs (real cfc) -- TODO: Shouldn't be changing this?
                case called_pr of
                    True -> return . Right $ ImpliesFC (Call Pre (real dfc)) (Call Pre (real cfc))
                    False -> return . Left $ cex
            | isExported lrs (funcName (real dfc)) -> do
                called_pr <- checkPre ghci lrs (real cfc)
                case called_pr of
                    True -> return . Right $ ImpliesFC (Call Pre (real dfc)) (Call Pre (real cfc))
                    False -> return . Left $ cex
            | otherwise -> do
                return . Right $ ImpliesFC (Call Pre (real dfc)) (Call Pre (real cfc))

-- Function constraints that don't block the current specification set, but which must be true
-- (i.e. the actual input and output for abstracted functions)
cexsToExtraFC :: InfConfigM m => CounterExample -> m [FuncConstraint]
cexsToExtraFC (DirectCounter dfc fcs@(_:_)) = do
    infconfig <- infConfigM
    let some_pre = ImpliesFC (Call Pre $ real dfc) $  OrFC (map (\fc -> Call Pre (real fc)) fcs)
        fcs' = filter (\fc -> abstractedMod fc `S.member` modules infconfig) fcs
    return $ some_pre:mapMaybe realToMaybeFC fcs'
cexsToExtraFC (CallsCounter dfc cfc fcs@(_:_)) = do
    infconfig <- infConfigM
    let some_pre = ImpliesFC (Call Pre $ real dfc) $  OrFC (map (\fc -> Call Pre (real fc)) fcs)
    let fcs' = filter (\fc -> abstractedMod fc `S.member` modules infconfig) fcs

    let abs = mapMaybe realToMaybeFC fcs'
        clls = if not . isError . returns . real $ cfc
                  then [Call All $ real cfc]
                  else []

    return $ some_pre:clls ++ abs
cexsToExtraFC (DirectCounter fc []) = return []
cexsToExtraFC (CallsCounter dfc cfc [])
    | isError (returns (real dfc)) = return []
    | isError (returns (real cfc)) = return []
    | any isError (arguments (real cfc)) = return []
    | otherwise =
        let
            call_all_dfc = Call All (real dfc)
            call_all_cfc = Call All (real cfc)
            imp_fc = ImpliesFC (Call Pre $ real dfc) (Call Pre $ real cfc)
        in
        return $ [call_all_dfc, call_all_cfc, imp_fc]

noAbsStatesToCons :: Id -> [ExecRes AbstractedInfo] -> [FuncConstraint]
noAbsStatesToCons i = concatMap (noAbsStatesToCons' i) -- . filter (null . abs_calls . track . final_state)

noAbsStatesToCons' :: Id -> ExecRes AbstractedInfo -> [FuncConstraint]
noAbsStatesToCons' i@(Id (Name _ m _ _) _) er =
    let
        pre_s = lhStateToPreFC i er
        clls = filter (\fc -> nameModule (funcName fc) == m) 
             . map (switchName (idName i))
             . filter (not . hasArgError)
             . func_calls_in_real
             . init_call
             . track
             $ final_state er

        preCons = map (ImpliesFC pre_s . Call Pre) clls
        -- A function may return error because it was passed an erroring higher order function.
        -- In this case, it would be incorrect to add a constraint that the function itself calls error.
        -- Thus, we simply get rid of constraints that call error. 
        callsCons = mapMaybe (\fc -> case isError (returns fc) of
                                      True -> Nothing -- NotFC (Call Pre fc)
                                      False -> Just (Call All fc)) clls
        callsCons' = if hits_lib_err_in_real (init_call . track . final_state $ er)
                                    then []
                                    else callsCons
    in
    preCons ++ callsCons'

switchName :: Name -> FuncCall -> FuncCall
switchName n fc = if funcName fc == initiallyCalledFuncName then fc { funcName = n } else fc

--------------------------------------------------------------------

realToMaybeFC :: Abstracted -> Maybe FuncConstraint
realToMaybeFC a@(Abstracted { real = fc }) 
    | hits_lib_err_in_real a = Nothing
    | otherwise = Just $ ImpliesFC (Call Pre fc) (Call Post fc)

isExported :: LiquidReadyState -> Name -> Bool
isExported lrs (Name n m _ _) =
    (n, m) `elem` map (\(Name n' m' _ _) -> (n', m')) (exported_funcs (lr_binding lrs))

hasUserSpec :: InfConfigM m => Name -> m Bool
hasUserSpec (Name n m _ _) = do
    infconfig <- infConfigM
    return $ (n, m) `S.member` pre_refined infconfig

notRetError :: FuncCall -> Bool
notRetError (FuncCall { returns = Prim Error _ }) = False
notRetError _ = True

lhStateToFC :: Id -> ExecRes AbstractedInfo -> FuncConstraint
lhStateToFC i (ExecRes { final_state = s@State { track = t }
                       , conc_args = inArg
                       , conc_out = ex}) = Call All (FuncCall (idName i) inArg ex)

lhStateToPreFC :: Id -> ExecRes AbstractedInfo -> FuncConstraint
lhStateToPreFC i (ExecRes { final_state = s@State { track = t }
                       , conc_args = inArg
                       , conc_out = ex}) = Call Pre (FuncCall (idName i) inArg ex)

insertsFC :: [FuncConstraint] -> FuncConstraints
insertsFC = foldr insertFC emptyFC

abstractedMod :: Abstracted -> Maybe T.Text
abstractedMod = nameModule . funcName . abstract

hasAbstractedArgError :: CounterExample -> Bool
hasAbstractedArgError (DirectCounter _ abs) = any (hasArgError . real) abs
hasAbstractedArgError (CallsCounter _ _ abs) = any (hasArgError . real) abs

hasArgError :: FuncCall -> Bool
hasArgError = any isError . arguments

isError :: Expr -> Bool
isError (Prim Error _) = True
isError (Prim Undefined _) = True
isError _ = False