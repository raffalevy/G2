module G2.Liquid.Inference.Interface (inference) where

import G2.Config.Config as G2
import G2.Execution.Memory
import G2.Interface
import qualified G2.Language.ExprEnv as E
import G2.Language.Naming
import G2.Language.Support
import G2.Language.Syntax
import G2.Liquid.AddTyVars
import G2.Liquid.Inference.Config
import G2.Liquid.Inference.FuncConstraint
import G2.Liquid.Inference.G2Calls
import G2.Liquid.Inference.PolyRef
import G2.Liquid.Helpers
import G2.Liquid.Inference.RefSynth
import G2.Liquid.Inference.GeneratedSpecs
import G2.Liquid.Inference.Verify
import G2.Liquid.Interface
import G2.Liquid.Types
import G2.Translation

import Language.Haskell.Liquid.Types as LH

import Control.Monad
import Data.Either
import qualified Data.HashSet as S
import Data.List
import qualified Data.Text as T

import Language.Haskell.Liquid.Types

inference :: InferenceConfig -> G2.Config -> [FilePath] -> [FilePath] -> [FilePath] -> IO (Either [CounterExample] GeneratedSpecs)
inference infconfig config proj fp lhlibs = do
    -- Initialize LiquidHaskell
    lhconfig <- lhConfig proj lhlibs
    let lhconfig' = lhconfig { pruneUnsorted = True }
    ghci <- ghcInfos Nothing lhconfig' fp

    -- Initialize G2
    let g2config = config { mode = Liquid
                          , steps = 2000 }
        transConfig = simplTranslationConfig { simpl = False }
    exg2@(main_mod, _) <- translateLoaded proj fp lhlibs transConfig g2config

    let simp_s = initSimpleState (snd exg2)
        (g2config', infconfig') = adjustConfig main_mod simp_s g2config infconfig

        lrs = createStateForInference simp_s g2config' ghci

    inference' infconfig' g2config' lhconfig' ghci (fst exg2) lrs emptyGS emptyFC 

inference' :: InferenceConfig -> G2.Config -> LH.Config -> [GhcInfo] -> Maybe T.Text -> LiquidReadyState
           -> GeneratedSpecs -> FuncConstraints -> IO (Either [CounterExample] GeneratedSpecs)
inference' infconfig g2config lhconfig ghci m_modname lrs gs fc = do
    print gs

    let merged_ghci = addSpecsToGhcInfos ghci gs
    mapM_ (print . gsTySigs . spec) merged_ghci

    res <- verify lhconfig merged_ghci

    case res of
        Safe -> return $ Right gs
        Crash ci err -> error $ "Crash\n" ++ show ci ++ "\n" ++ err
        Unsafe bad -> do
            -- Generate constraints
            let bad' = nub $ map nameOcc bad

            putStrLn $ "bad' = " ++ show bad'

            res <- mapM (genNewConstraints merged_ghci m_modname lrs infconfig g2config) bad'

            putStrLn $ "res"
            printCE $ concat res

            putStrLn "Before checkNewConstraints"
            new_fc <- checkNewConstraints ghci lrs infconfig g2config (concat res)
            putStrLn $ "After checkNewConstraints" ++ "\nlength res = " ++ show (length (concat res))
                            ++ "\nlength new_fc = " ++ show (length new_fc)
            case new_fc of
                Left ce -> return . Left $ ce
                Right new_fc' -> do
                    let new_fc_funcs = filter (\(Name _ m _ _) -> m `S.member` (modules infconfig))
                                     . nub $ map (funcName . constraint) new_fc'

                        fc' = foldr insertFC fc new_fc'

                    putStrLn $ "new_fc_funcs = " ++ show new_fc_funcs

                    -- Synthesize
                    -- putStrLn $ "fc' = " ++ show fc'
                    putStrLn $ "new_fc_funcs = " ++ show new_fc_funcs
                    putStrLn "Before genMeasureExs"
                    meas_ex <- genMeasureExs lrs merged_ghci g2config fc'
                    putStrLn "After genMeasureExs"
                    gs' <- foldM (synthesize infconfig ghci lrs meas_ex fc') gs new_fc_funcs
                    
                    inference' infconfig g2config lhconfig ghci m_modname lrs gs' fc'

createStateForInference :: SimpleState -> G2.Config -> [GhcInfo] -> LiquidReadyState
createStateForInference simp_s config ghci =
    let
        (simp_s', ph_tyvars) = if add_tyvars config
                                then fmap Just $ addTyVarsEEnvTEnv simp_s
                                else (simp_s, Nothing)
        (s, b) = initStateFromSimpleState simp_s' True 
                    (\_ ng _ _ _ _ -> (Prim Undefined TyBottom, [], [], ng))
                    (\_ -> [])
                    config
    in
    createLiquidReadyState s b ghci ph_tyvars config


genNewConstraints :: [GhcInfo] -> Maybe T.Text -> LiquidReadyState -> InferenceConfig -> G2.Config -> T.Text -> IO [CounterExample]
genNewConstraints ghci m lrs infconfig g2config n = do
    ((exec_res, _), i) <- runLHInferenceCore n m lrs ghci infconfig g2config
    return $ map (lhStateToCE i) exec_res

checkNewConstraints :: [GhcInfo] -> LiquidReadyState -> InferenceConfig ->  G2.Config -> [CounterExample] -> IO (Either [CounterExample] [FuncConstraint])
checkNewConstraints ghci lrs infconfig g2config cexs = do
    res <- mapM (cexsToFuncConstraints lrs ghci infconfig g2config) cexs
    case lefts res of
        res'@(_:_) -> return . Left $ res'
        _ -> return . Right . filterErrors . concat . rights $ res

genMeasureExs :: LiquidReadyState -> [GhcInfo] -> G2.Config -> FuncConstraints -> IO MeasureExs
genMeasureExs lrs ghci g2config fcs =
    let
        es = concatMap (\fc ->
                    let
                        cons = constraint fc
                        ex_poly = concat $ concatMap extractValues $ extractExprPolyBound (returns cons)
                    in
                    returns cons:arguments cons ++ ex_poly
                ) (allFC fcs)
    in
    evalMeasures lrs ghci g2config es

synthesize :: InferenceConfig -> [GhcInfo] -> LiquidReadyState -> MeasureExs -> FuncConstraints -> GeneratedSpecs -> Name -> IO GeneratedSpecs
synthesize infconfig ghci lrs meas_ex fc gs n = do
    let eenv = expr_env . state $ lr_state lrs
        tc = type_classes . state $ lr_state lrs

        fc_of_n = lookupFC n fc
        spec = case findFuncSpec ghci n of
                Just spec' -> spec'
                Nothing -> error $ "synthesize: No spec found for " ++ show n
        e = case E.occLookup (nameOcc n) (nameModule n) eenv of
                Just e' -> e'
                Nothing -> error $ "synthesize: No expr found"

        meas = lrsMeasures ghci lrs

    print $ "Synthesize spec for " ++ show n
    new_spec <- refSynth infconfig spec e tc meas meas_ex fc_of_n (measureSymbols ghci)

    case new_spec of
        Just new_spec' -> do
            putStrLn $ "spec = " ++ show spec
            putStrLn $ "new_spec = " ++ show new_spec'

            return $ insertGS n new_spec' gs
        Nothing -> return gs

-- | Converts counterexamples into constraints that the refinements must allow for, or rule out.
cexsToFuncConstraints :: LiquidReadyState -> [GhcInfo] -> InferenceConfig -> G2.Config -> CounterExample -> IO (Either CounterExample [FuncConstraint])
cexsToFuncConstraints _ _ infconfig _ (DirectCounter dfc fcs@(_:_))
    | not . null $ fcs' =
        return . Right $ map (Pos . real) fcs ++ map (Neg . abstract) fcs'
    | otherwise = return . Right $ [] -- [Pos dfc]
    where
        fcs' = filter (\fc -> abstractedMod fc `S.member` modules infconfig) fcs
cexsToFuncConstraints _ _ infconfig _ (CallsCounter dfc _ fcs@(_:_))
    | not . null $ fcs' =
        return . Right $ map (Pos . real) fcs ++ map (Neg . abstract) fcs'
    | otherwise = return $ Right [] -- error $ "cexsToFuncConstraints" ++ show (map abstractedMod fcs) -- return . Right $ [Pos dfc] 
    where
        fcs' = filter (\fc -> abstractedMod fc `S.member` modules infconfig) fcs
cexsToFuncConstraints lrs ghci _ g2config cex@(DirectCounter fc []) = do
    v_cex <- checkCounterexample lrs ghci g2config fc
    case v_cex of
        True -> return . Right $ [Pos fc]
        False -> return . Left $ cex
cexsToFuncConstraints lrs ghci _ g2config cex@(CallsCounter _ fc []) = do
    v_cex <- checkCounterexample lrs ghci g2config fc
    case v_cex of
        True -> return . Right $ [Pos fc]
        False -> return . Left $ cex

abstractedMod :: Abstracted -> Maybe T.Text
abstractedMod = nameModule . funcName . abstract

filterErrors :: [FuncConstraint] -> [FuncConstraint]
filterErrors = filter filterErrors'

filterErrors' :: FuncConstraint -> Bool
filterErrors' fc =
    let
        c = constraint fc

        as = not . any isError $ arguments c
        r = not . isError . returns $ c
    in
    as && r
    where
        isError (Prim Error _) = True
        isError _ = False
