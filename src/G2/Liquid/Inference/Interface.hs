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
import G2.Liquid.Inference.FuncConstraint as FC
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
import Language.Fixpoint.Types hiding (Safe, Unsafe, Crash)

import Control.Monad
import Data.Either
import qualified Data.HashSet as S
import Data.List
import Data.Monoid
import qualified Data.Text as T

import Language.Haskell.Liquid.Types
import Language.Haskell.Liquid.Types.RefType
import qualified Language.Fixpoint.Types.Config as FP

import Var (Var, varName, varType)

inference :: InferenceConfig -> G2.Config -> [FilePath] -> [FilePath] -> [FilePath] -> IO (Either [CounterExample] GeneratedSpecs)
inference infconfig config proj fp lhlibs = do
    -- Initialize LiquidHaskell
    lhconfig <- lhConfig proj lhlibs
    let lhconfig' = lhconfig { pruneUnsorted = True
                             -- Block qualifiers being auto-generated by LH (for fair comparison)
                             , maxParams = 0
                             , eliminate = FP.All
                             , higherorderqs = False
                             , scrapeImports = False
                             , scrapeInternals = False
                             , scrapeUsedImports = False }
    ghci <- ghcInfos Nothing lhconfig' fp

    mapM (print . gsQualifiers . spec) ghci

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
    putStrLn $ "\ngenerated specs = " ++ show gs ++ "\n"

    let merged_verify_with_quals_ghci = addQualifiersToGhcInfos gs $ addSpecsToGhcInfos ghci gs

    putStrLn $ "gsTySigs ghci_here = " ++ show (map (gsTySigs . spec) merged_verify_with_quals_ghci)
    putStrLn $ "gsAsmSigs ghci_here = " ++ show (map (gsAsmSigs . spec) merged_verify_with_quals_ghci)

    res_quals <- verify lhconfig merged_verify_with_quals_ghci

    case res_quals of
        Safe 
            | nullAssumeGS gs -> return $ Right gs
            | otherwise -> inference' infconfig g2config lhconfig ghci m_modname lrs (switchAssumesToAsserts gs) fc
        Crash ci err -> error $ "Crash\n" ++ show ci ++ "\n" ++ err
        Unsafe x -> do putStrLn ("x = " ++ show x); refineUnsafe infconfig g2config lhconfig ghci m_modname lrs gs fc

refineUnsafe :: InferenceConfig -> G2.Config -> LH.Config -> [GhcInfo] -> Maybe T.Text -> LiquidReadyState
             -> GeneratedSpecs -> FuncConstraints -> IO (Either [CounterExample] GeneratedSpecs)
refineUnsafe infconfig g2config lhconfig ghci m_modname lrs gs fc = do
    let merged_verify_with_asserts_ghci = addQualifiersToGhcInfos gs $ addSpecsToGhcInfos ghci gs
        merged_se_ghci = addSpecsToGhcInfos ghci (switchAssumesToAsserts gs)

    mapM_ (\ghci -> do
            putStrLn "All Asserts:"
            print . gsTySigs . spec $ ghci) merged_se_ghci

    res_asserts <- verify lhconfig merged_verify_with_asserts_ghci
    
    case res_asserts of
        Unsafe bad -> do
            -- Generate constraints
            let bad' = nub $ map nameOcc bad

            putStrLn $ "bad' = " ++ show bad'

            res <- mapM (genNewConstraints merged_se_ghci m_modname lrs infconfig g2config) bad'

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
                                     . nub . map (funcName . constraint) $ allFC new_fc'

                        fc' = unionFC fc new_fc'

                    let gs' = filterAssertsKey (\n -> n `elem` map constraining (allFC fc')) gs

                    putStrLn $ "new_fc_funcs = " ++ show new_fc_funcs

                    -- Synthesize
                    -- putStrLn $ "fc' = " ++ show fc'
                    putStrLn $ "new_fc_funcs = " ++ show new_fc_funcs
                    putStrLn "Before genMeasureExs"
                    meas_ex <- genMeasureExs lrs merged_se_ghci g2config fc'
                    putStrLn "After genMeasureExs"
                    -- ghci' <- foldM (synthesize infconfig lrs meas_ex fc') ghci new_fc_funcs
                    gs'' <- foldM (synthesize infconfig ghci lrs meas_ex fc') gs' new_fc_funcs
                    
                    inference' infconfig g2config lhconfig ghci m_modname lrs gs'' fc'
        _ -> error $ "refineUnsafe: result other than Unsafe: "
                        ++ case res_asserts of {Safe -> "Safe"; Crash _ _-> "Crash"; Unsafe _ -> "Unsafe"}

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

checkNewConstraints :: [GhcInfo] -> LiquidReadyState -> InferenceConfig ->  G2.Config -> [CounterExample] -> IO (Either [CounterExample] FuncConstraints)
checkNewConstraints ghci lrs infconfig g2config cexs = do
    res <- mapM (cexsToFuncConstraints lrs ghci infconfig g2config) cexs
    case lefts res of
        res'@(_:_) -> return . Left $ res'
        _ -> return . Right . filterErrors . unionsFC . rights $ res

genMeasureExs :: LiquidReadyState -> [GhcInfo] -> G2.Config -> FuncConstraints -> IO MeasureExs
genMeasureExs lrs ghci g2config fcs =
    let
        es = concatMap (\fc ->
                    let
                        cons = constraint fc
                        ex_poly = concat . concatMap extractValues . concatMap extractExprPolyBound $ returns cons:arguments cons
                    in
                    returns cons:arguments cons ++ ex_poly
                ) (allFC fcs)
    in
    evalMeasures lrs ghci g2config es

synthesize :: InferenceConfig -> [GhcInfo] -> LiquidReadyState -> MeasureExs -> FuncConstraints -> GeneratedSpecs -> Name -> IO GeneratedSpecs
synthesize infconfig ghci lrs meas_ex fc gs n@(Name n' _ _ _) = do
    let eenv = expr_env . state $ lr_state lrs
        tc = type_classes . state $ lr_state lrs

        fc_of_n = lookupFC n fc
        ghci' = insertMissingAssertSpec n ghci
        fspec = case genSpec ghci n of
                Just spec' -> spec'
                _ -> error $ "synthesize: No spec found for " ++ show n
        e = case E.occLookup (nameOcc n) (nameModule n) eenv of
                Just e' -> e'
                Nothing -> error $ "synthesize: No expr found"

        meas = lrsMeasures ghci lrs

    print $ "Synthesize spec for " ++ show n
    let tcemb = foldr (<>) mempty $ map (gsTcEmbeds . spec) ghci
    spec_qual <- refSynth infconfig fspec e tc meas meas_ex fc_of_n (measureSymbols ghci) tcemb

    case spec_qual of
        Just (new_spec, new_qual) -> do
            putStrLn $ "fspec = " ++ show fspec
            putStrLn $ "new_spec = " ++ show new_spec

            -- We ASSUME postconditions, and ASSERT preconditions.  This ensures
            -- that our precondition is satisified by the caller, and the postcondition
            -- is strong enough to allow verifying the caller
            let gs' = insertAssertGS n (pre new_spec) $ insertAssumeGS n (post new_spec) gs

            return $ foldr insertQualifier gs' new_qual
        Nothing -> return gs
    where
        pre xs = init xs ++ [PolyBound PTrue []]
        post xs = replicate (length $ init xs) (PolyBound PTrue []) ++ [last xs]

-- | Converts counterexamples into constraints that the refinements must allow for, or rule out.
cexsToFuncConstraints :: LiquidReadyState -> [GhcInfo] -> InferenceConfig -> G2.Config -> CounterExample -> IO (Either CounterExample FuncConstraints)
cexsToFuncConstraints _ _ infconfig _ (DirectCounter dfc fcs@(_:_))
    | not . null $ fcs' =
        return . Right . insertsFC $ map (FC Pos Post . real) fcs ++ map (FC Neg Post . abstract) fcs'
    | otherwise = return . Right $ error "cexsToFuncConstraints: unhandled 1"
    where
        fcs' = filter (\fc -> abstractedMod fc `S.member` modules infconfig) fcs
cexsToFuncConstraints _ _ infconfig _ (CallsCounter dfc _ fcs@(_:_))
    | not . null $ fcs' =
        return . Right . insertsFC $ map (FC Pos Post . real) fcs ++ map (FC Neg Post . abstract) fcs'
    | otherwise = return . Right $ error "cexsToFuncConstraints: unhandled 2"
    where
        fcs' = filter (\fc -> abstractedMod fc `S.member` modules infconfig) fcs
cexsToFuncConstraints lrs ghci _ g2config cex@(DirectCounter fc []) = do
    v_cex <- checkCounterexample lrs ghci g2config fc
    case v_cex of
        True -> return . Right . insertsFC $ [FC Pos Post fc]
        False -> return . Left $ cex
cexsToFuncConstraints lrs ghci _ g2config cex@(CallsCounter callee_fc called_fc []) = do
    v_cex <- checkCounterexample lrs ghci g2config called_fc
    case v_cex of
        True -> return . Right . insertsFC $ [FC Pos Pre called_fc]
        False -> case funcName callee_fc `elem` exported_funcs (lr_binding lrs) of
                    True -> return . Left $ cex
                    False -> return . Right . insertsFC $ [FC Neg Pre callee_fc]

insertsFC :: [FuncConstraint] -> FuncConstraints
insertsFC = foldr insertFC emptyFC

abstractedMod :: Abstracted -> Maybe T.Text
abstractedMod = nameModule . funcName . abstract

filterErrors :: FuncConstraints -> FuncConstraints
filterErrors = filterFC filterErrors'

filterErrors' :: FuncConstraint -> Bool
filterErrors' fc =
    let
        c = constraint fc

        as = not . any isError $ arguments c
        r = not . isError . returns $ c
    in
    as && (r || FC.violated fc == Pre)
    where
        isError (Prim Error _) = True
        isError _ = False

