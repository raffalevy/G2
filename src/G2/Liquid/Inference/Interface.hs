module G2.Liquid.Inference.Interface (inference) where

import G2.Config.Config as G2
import G2.Execution.Memory
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
import G2.Liquid.Helpers
import G2.Liquid.Inference.RefSynth
import G2.Liquid.Inference.GeneratedSpecs
import G2.Liquid.Inference.Verify
import G2.Liquid.Inference.WorkingUp
import G2.Liquid.Interface
import G2.Liquid.Types
import G2.Translation

import Language.Haskell.Liquid.Types as LH
import Language.Fixpoint.Types hiding (Safe, Unsafe, Crash)

import Control.Monad
import Data.Either
import qualified Data.HashSet as S
import Data.List
import Data.Maybe
import Data.Monoid
import qualified Data.Text as T

import Language.Haskell.Liquid.Types
import Language.Haskell.Liquid.Types.RefType
import qualified Language.Fixpoint.Types.Config as FP

import Var (Var, varName, varType)

import Debug.Trace

inference :: InferenceConfig -> G2.Config -> [FilePath] -> [FilePath] -> [FilePath] -> IO (Either [CounterExample] GeneratedSpecs)
inference infconfig config proj fp lhlibs = do
    -- Initialize LiquidHaskell
    lhconfig <- lhConfig proj lhlibs
    let lhconfig' = lhconfig { pruneUnsorted = True
                             -- Block qualifiers being auto-generated by LH (for fair comparison)
                             , maxParams = 0
                             , eliminate = if keep_quals infconfig then eliminate lhconfig else FP.All
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
        (g2config', infconfig') = adjustConfig main_mod simp_s g2config infconfig ghci

        lrs = createStateForInference simp_s g2config' ghci

        cg = getCallGraph . expr_env . state . lr_state $ lrs

    inf <- inference' infconfig' g2config' lhconfig' ghci (fst exg2) lrs cg workingUp emptyGS emptyFC emptyFC []
    case inf of
        CEx cex -> return $ Left cex
        GS gs -> return $ Right gs
        FCs _ _ -> error "inference: Unhandled Func Constraints"

data InferenceRes = CEx [CounterExample]
                  | FCs FuncConstraints WorkingUp
                  | GS GeneratedSpecs
                  deriving (Show)

-- When we try to synthesize a specification for a function that we have already found a specification for,
-- we have to return to when we originally synthesized that specification.  We pass the newly aquired
-- FuncConstraints as RisignFuncConstraints
type RisingFuncConstraints = FuncConstraints

inference' :: InferenceConfig -> G2.Config -> LH.Config -> [GhcInfo] -> Maybe T.Text -> LiquidReadyState
           -> CallGraph -> WorkingUp -> GeneratedSpecs -> FuncConstraints -> RisingFuncConstraints -> [Name] -> IO InferenceRes
inference' infconfig g2config lhconfig ghci m_modname lrs cg wu gs fc rising_fc try_to_synth = do
    putStrLn "inference'"
    
    synth_gs <- synthesize infconfig g2config ghci lrs gs (unionFC fc rising_fc) try_to_synth

    print synth_gs


    res <- tryHardToVerify infconfig lhconfig ghci synth_gs

    case res of
        Right new_gs
            | nullAssumeGS synth_gs -> return $ GS new_gs
            | otherwise ->
                let new_gs' = switchAssumesToAsserts new_gs
                    ghci' = addSpecsToGhcInfos ghci new_gs'
                in
                inference' infconfig g2config lhconfig ghci' m_modname lrs cg wu new_gs' fc rising_fc []
        Left bad -> do
            let wu' = wu -- adjustWorkingUp infconfig cg bad wu
            ref <- refineUnsafe infconfig g2config lhconfig ghci m_modname lrs cg wu' synth_gs fc rising_fc bad
            case ref of
                FCs new_fc new_wu ->
                    conflictingFCs infconfig g2config lhconfig ghci m_modname lrs cg new_wu synth_gs fc new_fc
                _ -> return ref

refineUnsafe :: InferenceConfig -> G2.Config -> LH.Config -> [GhcInfo] -> Maybe T.Text -> LiquidReadyState
             -> CallGraph -> WorkingUp -> GeneratedSpecs -> FuncConstraints -> RisingFuncConstraints -> [Name] -> IO InferenceRes
refineUnsafe infconfig g2config lhconfig ghci m_modname lrs cg wu gs fc rising_fc bad = do
    putStrLn $ "refineUnsafe " ++ show bad
    print wu
    let merged_se_ghci = addSpecsToGhcInfos ghci (switchAssumesToAsserts gs)

    let bad' = nub $ map nameOcc bad

    res <- mapM (genNewConstraints merged_se_ghci m_modname lrs infconfig g2config) bad'

    putStrLn $ "res"
    printCE $ concat res
    let res' = concat res

    -- Either converts counterexamples to FuncConstraints, or returns them as errors to
    -- show to the user.
    new_fc <- checkNewConstraints ghci lrs infconfig g2config wu res'

    case new_fc of
        Left cex -> return $ CEx cex
        Right new_fc' -> do
            -- Check if we already have specs for any of the functions
            let pre_solved = alreadySpecified ghci new_fc'
                wu' = adjustWorkingUp infconfig res' wu

            case nullFC pre_solved of
                False -> do
                    putStrLn $ "already solved " ++ show (map (funcName . constraint) $ toListFC new_fc')
                    return $ FCs (unionFC pre_solved rising_fc) wu'
                True -> do
                    -- Only consider functions in the modules that we have access to.
                    let rel_funcs = relFuncs infconfig new_fc'
                        fc' = adjustOldFC fc new_fc'
                        merged_fc = unionFC (unionFC fc' new_fc') rising_fc
                    
                    inference' infconfig g2config lhconfig ghci m_modname lrs cg wu' gs merged_fc emptyFC rel_funcs
                    
conflictingFCs :: InferenceConfig -> G2.Config -> LH.Config -> [GhcInfo] -> Maybe T.Text -> LiquidReadyState
               -> CallGraph -> WorkingUp -> GeneratedSpecs -> FuncConstraints -> RisingFuncConstraints -> IO InferenceRes
conflictingFCs infconfig g2config lhconfig ghci m_modname lrs cg wu gs fc rising_fc = do
    putStrLn "conflictingFCs"
    let as_f_rising_fc = alreadySpecified ghci rising_fc
    case nullFC as_f_rising_fc of
        False -> return $ FCs rising_fc wu
        True ->
            let
                constrained = map (funcName . constraint) $ toListFC rising_fc
                fc' = adjustOldFC fc rising_fc

                merged_fc = unionFC fc' rising_fc

                all_f_rising_fc = map (funcName . constraint) $ toListFC rising_fc
            in
            inference' infconfig g2config lhconfig ghci m_modname lrs cg wu gs fc' rising_fc all_f_rising_fc

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
    putStrLn $ "Generating constraints for " ++ T.unpack n
    ((exec_res, _), i) <- runLHInferenceCore n m lrs ghci infconfig g2config
    return $ map (lhStateToCE i) exec_res

checkNewConstraints :: [GhcInfo] -> LiquidReadyState -> InferenceConfig ->  G2.Config -> WorkingUp -> [CounterExample] -> IO (Either [CounterExample] FuncConstraints)
checkNewConstraints ghci lrs infconfig g2config wd cexs = do
    let res = map (cexsToFuncConstraints lrs ghci infconfig g2config wd) cexs
    case lefts res of
        res'@(_:_) -> return . Left $ res'
        _ -> return . Right . filterErrors . unionsFC . rights $ res

alreadySpecified :: [GhcInfo] -> FuncConstraints -> FuncConstraints
alreadySpecified ghci = filterFC (flip isPreRefined ghci . funcName . constraint)

genMeasureExs :: LiquidReadyState -> [GhcInfo] -> G2.Config -> FuncConstraints -> IO MeasureExs
genMeasureExs lrs ghci g2config fcs =
    let
        es = concatMap (\fc ->
                    let
                        cons = constraint fc
                        ex_poly = concat . concatMap extractValues . concatMap extractExprPolyBound $ returns cons:arguments cons
                    in
                    returns cons:arguments cons ++ ex_poly
                ) (toListFC fcs)
    in
    evalMeasures lrs ghci g2config es


synthesize :: InferenceConfig -> G2.Config -> [GhcInfo] -> LiquidReadyState
            -> GeneratedSpecs -> FuncConstraints -> [Name] -> IO GeneratedSpecs
synthesize infconfig g2config ghci lrs gs fc for_funcs = do
    -- Only consider functions in the modules that we have access to.
    putStrLn "Before genMeasureExs"
    meas_ex <- genMeasureExs lrs ghci g2config fc
    putStrLn "After genMeasureExs"
    foldM (synthesize' infconfig ghci lrs meas_ex fc) gs $ nub for_funcs

synthesize' :: InferenceConfig -> [GhcInfo] -> LiquidReadyState -> MeasureExs -> FuncConstraints -> GeneratedSpecs -> Name -> IO GeneratedSpecs
synthesize' infconfig ghci lrs meas_ex fc gs n = do
    spec_qual <- refSynth infconfig ghci lrs meas_ex fc n

    case spec_qual of
        Just (new_spec, new_qual) -> do
            putStrLn $ "new_qual = " ++ show new_qual

            -- We ASSUME postconditions, and ASSERT preconditions.  This ensures
            -- that our precondition is satisified by the caller, and the postcondition
            -- is strong enough to allow verifying the caller
            let gs' = insertNewSpec n new_spec gs

            return $ foldr insertQualifier gs' new_qual
        Nothing -> return gs

synthesizePre :: InferenceConfig -> [GhcInfo] -> LiquidReadyState -> MeasureExs -> FuncConstraints -> GeneratedSpecs -> Name -> IO GeneratedSpecs
synthesizePre infconfig ghci lrs meas_ex fc gs n = do
    spec_qual <- refSynth infconfig ghci lrs meas_ex fc n

    case spec_qual of
        Just (new_spec, new_qual) -> do
            putStrLn $ "new_qual = " ++ show new_qual

            -- When we are trying to find a precondition to prevent some bad call,
            -- we want to avoid asserting the precondition, as this will cause us
            -- to move on before we are ready
            let gs' = insertAssumeGS n new_spec gs

            return $ foldr insertQualifier gs' new_qual
        Nothing -> return gs

-- | Converts counterexamples into constraints that the refinements must allow for, or rule out.
cexsToFuncConstraints :: LiquidReadyState -> [GhcInfo] -> InferenceConfig -> G2.Config -> WorkingUp -> CounterExample -> Either CounterExample FuncConstraints
cexsToFuncConstraints _ _ infconfig _ _ (DirectCounter dfc fcs@(_:_))
    | not . null $ fcs' =
        let
            mkFC pol md fc = FC { polarity = if notRetError fc then pol else Neg
                                , violated = Post
                                , modification = md
                                , bool_rel = if notRetError fc then BRAnd else BRImplies
                                , constraint = fc}
        in
        Right . insertsFC $ map (mkFC Pos imp . real) fcs' ++ map (mkFC Neg del . abstract) fcs'
    | otherwise = Right $ error "cexsToFuncConstraints: unhandled 1"
    where
        fcs' = filter (\fc -> abstractedMod fc `S.member` modules infconfig) fcs

        imp = SwitchImplies [funcName dfc]
        del = Delete [funcName dfc]
cexsToFuncConstraints _ _ infconfig _ _ (CallsCounter dfc cfc fcs@(_:_))
    | not . null $ fcs' =
        let
            mkFC pol md fc = FC { polarity = if notRetError fc then pol else Neg
                                , violated = Post
                                , modification = md
                                , bool_rel = if notRetError fc then BRAnd else BRImplies
                                , constraint = fc}
        in
        Right . insertsFC $ map (mkFC Pos imp . real) fcs' ++ map (mkFC Neg del . abstract) fcs'
    | otherwise = Right $ error "cexsToFuncConstraints: Should be unreachable! Non-refinable function abstracted!"
    where
        fcs' = filter (\fc -> abstractedMod fc `S.member` modules infconfig) fcs

        imp = SwitchImplies [funcName dfc, funcName cfc]
        del = Delete [funcName dfc, funcName cfc]
cexsToFuncConstraints lrs ghci infconfig _ _ cex@(DirectCounter fc []) = do
    let Name n m _ _ = funcName fc
    case (n, m) `S.member` pre_refined infconfig of
        False ->
            Right . insertsFC $ [FC { polarity = if notRetError fc then Pos else Neg
                                    , violated = Post
                                    , modification = SwitchImplies [funcName fc]
                                    , bool_rel = BRImplies
                                    , constraint = fc} ]
        True -> Left $ cex
cexsToFuncConstraints lrs ghci infconfig _ wu cex@(CallsCounter caller_fc called_fc []) = do
    let caller_pr = hasUserSpec (funcName caller_fc) infconfig
        called_pr = hasUserSpec (funcName called_fc) infconfig

    case (caller_pr, called_pr) of
        (True, True) -> Left $ cex
        (False, True) ->  Right . insertsFC $ [FC { polarity = Neg
                                                  , violated = Pre
                                                  , modification = None -- [funcName called_fc]
                                                  , bool_rel = BRImplies 
                                                  , constraint = caller_fc } ]
        (True, False) -> Right . insertsFC $ [FC { polarity = if notRetError called_fc then Pos else Neg
                                                 , violated = Pre
                                                 , modification = None -- [funcName caller_fc]
                                                 , bool_rel = if notRetError called_fc then BRAnd else BRImplies
                                                 , constraint = called_fc } ]
        (False, False)
            | funcName called_fc `memberWU` wu -> 
                           Right . insertsFC $ [FC { polarity = Neg
                                                   , violated = Pre
                                                   , modification = Delete [funcName caller_fc]
                                                   , bool_rel = BRImplies
                                                   , constraint = caller_fc } ]
            | otherwise -> Right . insertsFC $ [FC { polarity = if notRetError called_fc then Pos else Neg
                                                   , violated = Pre
                                                   , modification = SwitchImplies [funcName caller_fc]
                                                   , bool_rel = if notRetError called_fc then BRAnd else BRImplies
                                                   , constraint = called_fc } ]

isPreRefined :: Name -> [GhcInfo] -> Bool
isPreRefined (Name n m _ _) ghci =
    let
        pre_r = map (varToName . fst) . concatMap (gsTySigs . spec) $ ghci
    in
    any (\(Name n' m' _ _) -> n == n' && m == m' ) pre_r

hasUserSpec :: Name -> InferenceConfig -> Bool
hasUserSpec (Name n m _ _) infconfig = (n, m) `S.member` pre_refined infconfig

adjustWorkingUp ::  InferenceConfig -> [CounterExample] -> WorkingUp -> WorkingUp
adjustWorkingUp infconfig cexs wu =
    let
        wu' = foldr (addWorkingUp infconfig) wu cexs

        call_in_wu = filter (\x -> case getDirectCalled x of
                                        Just n -> memberWU n wu'
                                        Nothing -> False) cexs
        callers = mapMaybe getDirectCaller call_in_wu
        called = mapMaybe getDirectCalled call_in_wu
    in
    foldr deleteWU (foldr insertWU wu' callers) called

addWorkingUp ::  InferenceConfig -> CounterExample -> WorkingUp -> WorkingUp
addWorkingUp infconfig (CallsCounter caller_fc called_fc []) wu =
    let 
        caller_pr = hasUserSpec (funcName caller_fc) infconfig
        called_pr = hasUserSpec (funcName called_fc) infconfig
    in
    case (caller_pr, called_pr) of
        (False, True) -> insertWU (funcName caller_fc) wu
        _ -> wu
addWorkingUp _ ce wu = wu

getDirectCaller :: CounterExample -> Maybe Name
getDirectCaller (CallsCounter f _ []) = Just $ funcName f
getDirectCaller _ = Nothing

getDirectCalled :: CounterExample -> Maybe Name
getDirectCalled (CallsCounter _ f []) = Just $ funcName f
getDirectCalled _ = Nothing

-- If g is in WorkingUp, but not in the list of names, remove g from WorkingUp,
-- but add all functions that call g that are in the list of names.
-- adjustWorkingUp :: InferenceConfig -> CallGraph -> [Name] -> WorkingUp -> WorkingUp
-- adjustWorkingUp infconfig cg ns wu =
--     let
--         ns' = map zeroOut ns

--         diff = S.toList (allMembers wu) \\ ns'

--         cb = concatMap (flip calledBy cg) diff
--     in
--     trace ("diff = " ++ show ) 
--     foldr insertWU (foldr deleteWU wu diff) cb
--     where
--         zeroOut (Name n m _ l) = Name n m 0 l

-- adjustWorkingUp ::  InferenceConfig -> CounterExample -> WorkingUp -> WorkingUp
-- adjustWorkingUp infconfig (CallsCounter caller_fc called_fc []) wd =
--     let 
--         caller_pr = hasUserSpec (funcName caller_fc) infconfig
--         called_pr = hasUserSpec (funcName called_fc) infconfig
--     in
--     case (caller_pr, called_pr) of
--         (True, False) -> wd
--         (False, False)
--             | (funcName called_fc) `memberWorkUp` wd ->
--                     insertQueueWorkUp (funcName called_fc) wd
--             | otherwise -> insertQueueWorkUp (funcName called_fc) wd
--         _ -> wd 
-- adjustWorkingUp _ _ wd = wd

-- adjustWorkingUp :: InferenceConfig -> CounterExample -> WorkingUp -> WorkingUp
-- adjustWorkingUp infconfig (CallsCounter caller_fc called_fc []) wu =
--     let 
--         caller_pr = isPreRefined (funcName caller_fc) infconfig
--         called_pr = isPreRefined (funcName called_fc) infconfig
--     in
--     case (caller_pr, called_pr) of
--         (True, False) -> S.empty -- wu -- TODO
--         (False, False)
--             | nameOcc (funcName called_fc) `S.member` wu ->
--                     S.insert (nameOcc $ funcName called_fc) wu
--             | otherwise -> S.insert (nameOcc $ funcName called_fc) wu
--         _ -> wu 
-- adjustWorkingUp _ _ wu = wu

-- isPreRefined :: Name -> InferenceConfig -> Bool
-- isPreRefined (Name n m _ _) infconfig = (n, m) `S.member` pre_refined infconfig

getBoolRel :: FuncCall -> FuncCall -> BoolRel
getBoolRel fc1 fc2 =
    if notSameFunc fc1 fc2 && notRetError fc2 then BRAnd else BRImplies

notSameFunc :: FuncCall -> FuncCall -> Bool
notSameFunc fc1 fc2 = nameOcc (funcName fc1) /= nameOcc (funcName fc2)

notRetError :: FuncCall -> Bool
notRetError (FuncCall { returns = Prim Error _ }) = False
notRetError _ = True

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


relFuncs :: InferenceConfig -> FuncConstraints -> [Name]
relFuncs infconfig = filter (\(Name _ m _ _) -> m `S.member` (modules infconfig))
                   . nubBy (\n1 n2 -> nameOcc n1 == nameOcc n2)
                   . map (funcName . constraint)
                   . toListFC

-- -- | Checks if we found an incorrect specification higher in the tree,
-- -- and if so indicates which function(s) were incorrectly guessed
-- madeWrongGuesses :: [CounterExample] -> [Name]
-- madeWrongGuesses = mapMaybe madeWrongGuess

-- madeWrongGuess :: CounterExample -> Maybe Name
-- madeWrongGuess (DirectCounter f []) = Just $ funcName f
-- madeWrongGuess (CallsCounter caller_f _ []) = Just $ funcName caller_f
-- madeWrongGuess _ = Nothing

-- -- Go back and try to reverify all functions that call the passed function
-- correctWrongGuessesInFC :: [Name] -> FuncConstraints -> FuncConstraints
-- correctWrongGuessesInFC ns =
--     mapFC (\fc -> if funcName (constraint fc) `elem` ns
--                     then fc { bool_rel = BRImplies}
--                     else fc)


-- correctWrongGuessesInGS :: [Name] -> CallGraph -> GeneratedSpecs -> GeneratedSpecs
-- correctWrongGuessesInGS ns cg gs =
--     foldr (\n -> correctWrongGuessInGS n cg) gs $ nub ns

-- correctWrongGuessInGS :: Name -> CallGraph -> GeneratedSpecs -> GeneratedSpecs
-- correctWrongGuessInGS n g gs =
--     trace ("wrong guess = " ++ show n)
--     deleteAssert n . deleteAssume n
--         $ foldr (\n -> moveAssertToSpec) gs $ calledBy n g
--     where
--         moveAssertToSpec
--             | Just s <- lookupAssertGS n gs = insertNewSpec n s
--             | otherwise = id


-------

getGoodCalls :: InferenceConfig -> G2.Config -> LH.Config -> [GhcInfo] -> Maybe T.Text -> LiquidReadyState -> IO [FuncCall]
getGoodCalls infconfig config lhconfig ghci m_mod lrs = do
    let es = map (\(Name n m _ _) -> (n, m)) . E.keys . expr_env . state $ lr_state lrs
        
        cs = map (mkName . varName) $ concatMap (map fst . gsTySigs . spec) ghci
        cs' = filter (\(Name n m _ _) -> (n, m) `elem` es && m == m_mod) cs

        cs'' = map nameOcc cs'

    putStrLn $ "cs'' = " ++ show cs''
    return . concat
        =<< mapM (\c -> gatherAllowedCalls c m_mod lrs ghci infconfig config) cs''

