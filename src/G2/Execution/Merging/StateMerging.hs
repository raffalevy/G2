{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE OverloadedStrings #-}

module G2.Execution.Merging.StateMerging
  ( mergeState
  , createCaseExpr
  , concretizeSym
  , bindExprToNum
  , implies
  , restrictSymVal
  ) where

import G2.Language
import G2.Execution.NormalForms
import G2.Solver.Simplifier
import qualified G2.Language.ExprEnv as E 
import qualified G2.Language.PathConds as PC

import Control.Exception
import Control.Monad
import qualified Control.Monad.State.Lazy as S
import Data.Maybe
import qualified Data.List as L
import qualified Data.HashSet as HS
import qualified Data.HashMap.Strict as HM
import qualified Data.Map as M

import Debug.Trace


type MergeId = Id
type MergedIds = HM.HashMap (Name, Name) Id

-------------------------------------------------------
-- Merging Monad
-------------------------------------------------------
-- Defines a Monad to use during merging.

-- | Values that are passed around and updated while merging individual fields in 2 States
data Context t = Context { state1_ :: State t
                         , state2_ :: State t
                         , mergedIds_ :: MergedIds
                         , newMergedIds_ :: MergedIds
                         , newExprEnv_ :: ExprEnv
                         , ng_ :: NameGen
                         , newId_ :: MergeId -- `newId` is set to 1 or 2 in an AssumePC/ Case Expr when merging values from `state1_` or `state2_` respectively
                         , newPCs_ :: [PathCond]
                         , newSyms_ :: SymbolicIds
                         }

type MergeM t a = S.State (Context t) a

runMergeM :: MergeId -> MergedIds -> NameGen -> [PathCond] -> SymbolicIds -> State t -> State t -> MergeM t a -> (a, Context t)
runMergeM m_id m_ns ng pc syms s1 s2 f =
    let
        ctxt = Context { state1_ = s1
                       , state2_ = s2
                       , mergedIds_ = m_ns
                       , ng_ = ng
                       , newId_ = m_id
                       , newPCs_ = pc
                       , newSyms_ = syms }
    in
    runMergeMContext f ctxt

runMergeMContext :: MergeM t a -> Context t -> (a, Context t)
runMergeMContext = S.runState

state1 :: MergeM t (State t)
state1 = S.gets state1_

state2 :: MergeM t (State t)
state2 = S.gets state2_

splitId :: MergeM t Id
splitId = S.gets newId_

modifyNewMergedIds :: (MergedIds -> MergedIds) -> MergeM t ()
modifyNewMergedIds f = S.modify (\c -> c { newMergedIds_ = f (newMergedIds_ c) })

insertNewMergedIds :: Name -> Name -> Id -> MergeM t ()
insertNewMergedIds n1 n2 i = modifyNewMergedIds (HM.insert (n1, n2) i)

lookupMergedIds :: Name -> Name -> MergeM t (Maybe Id)
lookupMergedIds n1 n2 = do
    m_is <- S.gets mergedIds_
    new_m_is <- S.gets newMergedIds_
    return $ HM.lookup (n1, n2) (HM.union m_is new_m_is)

modifyState1 :: (State t -> State t) -> MergeM t ()
modifyState1 f = S.modify (\c -> c { state1_ = f (state1_ c) })

modifyState2 :: (State t -> State t) -> MergeM t ()
modifyState2 f = S.modify (\c -> c { state2_ = f (state2_ c) })

modifySymbolicIds1 :: (SymbolicIds -> SymbolicIds) -> MergeM t ()
modifySymbolicIds1 f = modifyState1 (\s -> s { symbolic_ids = f (symbolic_ids s) })

modifySymbolicIds2 :: (SymbolicIds -> SymbolicIds) -> MergeM t ()
modifySymbolicIds2 f = modifyState2 (\s -> s { symbolic_ids = f (symbolic_ids s) })

exprEnv1 :: MergeM t ExprEnv
exprEnv1 = S.gets (expr_env . state1_)

modifyExprEnv1 :: (ExprEnv -> ExprEnv) -> MergeM t ()
modifyExprEnv1 f = modifyState1 (\s -> s { expr_env = f (expr_env s) })

insertExprEnv1 :: Name -> Expr -> MergeM t ()
insertExprEnv1 n e = modifyExprEnv1 (E.insert n e)

insertSymbolicExprEnv1 :: Name -> Id -> MergeM t ()
insertSymbolicExprEnv1 n i = modifyExprEnv1 (E.insertSymbolic n i)

lookupExprEnv1 :: Name -> MergeM t (Maybe Expr)
lookupExprEnv1 n = return . E.lookup n =<< return . expr_env =<< state1

lookupEnvObjExprEnv1 :: Name -> MergeM t (Maybe E.EnvObj)
lookupEnvObjExprEnv1 n = return . E.lookupEnvObj n =<< return . expr_env =<< state1

exprEnv2 :: MergeM t ExprEnv
exprEnv2 = S.gets (expr_env . state2_)

modifyExprEnv2 :: (ExprEnv -> ExprEnv) -> MergeM t ()
modifyExprEnv2 f = modifyState2 (\s -> s { expr_env = f (expr_env s) })

insertExprEnv2 :: Name -> Expr -> MergeM t ()
insertExprEnv2 n e = modifyExprEnv2 (E.insert n e)

lookupExprEnv2 :: Name -> MergeM t (Maybe Expr)
lookupExprEnv2 n = return . E.lookup n =<< return . expr_env =<< state2

lookupEnvObjExprEnv2 :: Name -> MergeM t (Maybe E.EnvObj)
lookupEnvObjExprEnv2 n = return . E.lookupEnvObj n =<< return . expr_env =<< state2

newExprEnv :: MergeM t ExprEnv
newExprEnv = S.gets (newExprEnv_)

modifyNewExprEnv :: (ExprEnv -> ExprEnv) -> MergeM t ()
modifyNewExprEnv f = S.modify (\c -> c { newExprEnv_ = f (newExprEnv_ c) })

insertNewExprEnv:: Name -> Expr -> MergeM t ()
insertNewExprEnv n e = modifyNewExprEnv (E.insert n e)

lookupNewExprEnv :: Name -> MergeM t (Maybe Expr)
lookupNewExprEnv n = return . E.lookup n =<< newExprEnv

insertSymbolic1 :: Id -> MergeM t ()
insertSymbolic1 i = do
    modifyExprEnv1 (E.insertSymbolic (idName i) i)
    modifySymbolicIds1 (HS.insert i)

deleteSymbolic1 :: Id -> MergeM t ()
deleteSymbolic1 i = modifySymbolicIds1 (HS.delete i)

insertSymbolic2 :: Id -> MergeM t ()
insertSymbolic2 i = do
    modifyExprEnv2 (E.insertSymbolic (idName i) i)
    modifySymbolicIds2 (HS.insert i)

deleteSymbolic2 :: Id -> MergeM t ()
deleteSymbolic2 i = modifySymbolicIds2 (HS.delete i)

insertNewSymbolic :: Id -> MergeM t ()
insertNewSymbolic i = do
    S.modify (\c -> c { newSyms_ = HS.insert i (newSyms_ c) })

addPC :: [PathCond] -> MergeM t ()
addPC pc = S.modify (\c -> c { newPCs_ = pc ++ newPCs_ c})

freshNameM :: MergeM t Name
freshNameM = do
    ng <- S.gets ng_
    let (n, ng') = freshName ng
    S.modify (\c -> c { ng_ = ng' } )
    return n

freshIdM :: Type -> MergeM t Id
freshIdM t = do
    n <- freshNameM
    return (Id n t)

freshIdsM :: [Type] -> MergeM t [Id]
freshIdsM = mapM freshIdM

lookupTypeM :: Name -> MergeM t (Maybe AlgDataTy)
lookupTypeM n = do
    s <- state1
    return (M.lookup n (type_env s))

-- TODO: Get rid of this!
exprContextToTuple :: Expr -> Context t -> (Expr, MergedIds, ExprEnv, [PathCond], HS.HashSet Id, NameGen)
exprContextToTuple e c =
    (e, newMergedIds_ c, newExprEnv_ c, newPCs_ c, symbolic_ids (state1_ c) `HS.union` symbolic_ids (state2_ c) `HS.union` (newSyms_ c), ng_ c)

-------------------------------------------------------

isMergeable :: Eq t => State t -> State t -> Bool
isMergeable s1 s2 = 
    (exec_stack s1 == exec_stack s2)
    && (isMergeableCurrExpr (expr_env s1) (expr_env s2) (curr_expr s1) (curr_expr s2))
    && (type_env s1 == type_env s2)
    && (known_values s1 == known_values s2)
    && (non_red_path_conds s1 == non_red_path_conds s2)
    && (true_assert s1 == true_assert s2)
    && (assert_ids s1 == assert_ids s2)
    && (tags s1 == tags s2)
    && (track s1 == track s2)
    && (type_classes s1 == type_classes s2)
    -- && (cases s1) == (cases s2)
    && (isEmpty $ model s1)
    && (isEmpty $ model s2)

isMergeableCurrExpr :: E.ExprEnv -> E.ExprEnv -> CurrExpr -> CurrExpr -> Bool
isMergeableCurrExpr eenv1 eenv2 (CurrExpr Evaluate ce1) (CurrExpr Evaluate ce2) = isMergeableExpr eenv1 eenv2 ce1 ce2
isMergeableCurrExpr eenv1 eenv2 (CurrExpr Return ce1) (CurrExpr Return ce2) = isMergeableExpr eenv1 eenv2 ce1 ce2
isMergeableCurrExpr _ _ _ _ = False

isMergeableExpr :: E.ExprEnv -> E.ExprEnv -> Expr -> Expr -> Bool
isMergeableExpr eenv1 eenv2 (App e1 _) (App e1' _) = isMergeableExpr eenv1 eenv2 e1 e1'
isMergeableExpr _ _ (Data dc1) (Data dc2) = dc1 == dc2
isMergeableExpr _ _ _ _ = True



emptyContext :: State t -> State t -> NameGen -> Id -> Context t
emptyContext s1 s2 ng newId = Context { state1_ = s1
                                      , state2_ = s2
                                      , ng_ = ng
                                      , mergedIds_ = HM.empty
                                      , newMergedIds_ = HM.empty
                                      , newId_ = newId
                                      , newPCs_ = []
                                      , newSyms_ = HS.empty }

mergeState :: (Eq t, Named t, Simplifier simplifier) => Bindings -> simplifier -> State t -> State t -> Maybe (Bindings, State t)
mergeState b@(Bindings { name_gen = ng }) simplifier s1 s2 =
    if isMergeable s1 s2
        then 
            let (newId, ng') = freshMergeId TyLitInt ng
                ctxt = emptyContext s1 s2 ng' newId
                (curr_expr', m_ns, ctxt') = newMergeCurrExprCxt ctxt

                (eenv', ctxt'') = newMergeExprEnvCxt ctxt' m_ns

                (ctxt''', path_conds') = mergePathConds simplifier ctxt''

                syms' = mergeSymbolicIds ctxt'''

                s1' = state1_ ctxt'''
                ng'' = ng_ ctxt'''

                m_b = b { name_gen = ng'' }
                m_s = State { expr_env = eenv'
                            , type_env = type_env s1'
                            , curr_expr = curr_expr'
                            , path_conds = path_conds'
                            , non_red_path_conds = non_red_path_conds s1'
                            , true_assert = true_assert s1'
                            , assert_ids = assert_ids s1'
                            , type_classes = type_classes s1'
                            , symbolic_ids = syms'
                            , exec_stack = exec_stack s1'
                            , model = model s1'
                            , known_values = known_values s1'
                            , rules = rules s1'
                            , num_steps = max (num_steps s1) (num_steps s2)
                            , track = track s1'
                            , tags = tags s1' }
            in
            Just (m_b, m_s)
        else Nothing

newMergeCurrExprCxt :: Context t -> (CurrExpr, MergedIds, Context t)
newMergeCurrExprCxt cxt@(Context { state1_ = s1, state2_ = s2, newPCs_ = pc, ng_ = ng, newId_ = m_id }) =
    let
        (ce', m_ns, eenv1, eenv2, a_eenv, pc', f_symbs1, f_symbs2, ng') =
            newMergeCurrExpr (expr_env s1) (expr_env s2) (type_env s1)
                             (known_values s1)
                             ng
                             (symbolic_ids s1) (symbolic_ids s2)
                              m_id (curr_expr s1) (curr_expr s2)

        eenv1' = foldr (\i -> E.insertSymbolic (idName i) i) eenv1 f_symbs1
        eenv2' = foldr (\i -> E.insertSymbolic (idName i) i) eenv2 f_symbs2
    in
    (ce', m_ns, cxt { state1_ = s1 { expr_env = eenv1'
                               , symbolic_ids = f_symbs1 `HS.union` symbolic_ids s1 }
                    , state2_ = s2 { expr_env = eenv2'
                               , symbolic_ids = f_symbs2 `HS.union` symbolic_ids s2}
                    , newExprEnv_ = a_eenv
                    , newPCs_ = pc ++ pc'
                    , ng_ = ng' } )

newMergeCurrExpr :: ExprEnv
                 -> ExprEnv
                 -> TypeEnv
                 -> KnownValues
                 -> NameGen
                 -> SymbolicIds
                 -> SymbolicIds
                 -> MergeId
                 -> CurrExpr
                 -> CurrExpr
                 -> (CurrExpr, MergedIds, ExprEnv, ExprEnv, ExprEnv, [PathCond], SymbolicIds, SymbolicIds, NameGen)
newMergeCurrExpr eenv1 eenv2 tenv kv ng symbs1 symbs2 m_id (CurrExpr er1 e1) (CurrExpr er2 e2)
    | er1 == er2 =
        let
            (m_e, m_ns', eenv1', eenv2', a_eenv, pc', symb1', symb2', ng') = newMergeCurrExpr' eenv1 eenv2 tenv kv ng symbs1 symbs2 m_id e1 e2
        in
        (CurrExpr er1 m_e, m_ns', eenv1', eenv2', a_eenv, pc', symb1', symb2', ng')
    | otherwise = error "The curr_expr(s) have an invalid form and cannot be merged."

newMergeCurrExpr' :: ExprEnv
                  -> ExprEnv
                  -> TypeEnv
                  -> KnownValues
                  -> NameGen
                  -> SymbolicIds
                  -> SymbolicIds
                  -> MergeId
                  -> Expr
                  -> Expr
                  -> (Expr, MergedIds, ExprEnv, ExprEnv, ExprEnv, [PathCond], SymbolicIds, SymbolicIds, NameGen)
newMergeCurrExpr' eenv1 eenv2 tenv kv ng symbs1 symbs2 m_id e1 e2
    | isPrimType (typeOf e1) =
        let
            (m_e, m_ns, a_eenv, pc, symbs, ng') = newMergeExpr kv ng m_id HM.empty eenv1 eenv2 tenv e1 e2
        in
        (m_e, m_ns, eenv1, eenv2, a_eenv, pc, symbs1 `HS.union` symbs, symbs2 `HS.union` symbs, ng')
newMergeCurrExpr' eenv1 eenv2 tenv kv ng symbs1 symbs2 m_id (Var (Id n1 t)) (Var (Id n2 _)) =
    let
        (e1, f_pc1, f_symbs1, ng') = arbDCCase tenv ng t
        (e2, f_pc2, f_symbs2, ng'') = arbDCCase tenv ng' t

        eenv1' = E.insert n1 e1 eenv1
        eenv2' = E.insert n2 e2 eenv2

        (m_e, m_ns, a_eenv, pc, symbs, ng''') = newMergeExpr kv ng'' m_id HM.empty eenv1' eenv2' tenv e1 e2
    in
    assert (E.isSymbolic n1 eenv1 && E.isSymbolic n2 eenv2)
           ( m_e
           , m_ns
           , eenv1'
           , eenv2'
           , a_eenv
           , f_pc1 ++ f_pc2 ++ pc
           , f_symbs1 `HS.union` symbs
           , f_symbs2 `HS.union` symbs
           , ng''')
newMergeCurrExpr' eenv1 eenv2 tenv kv ng symbs1 symbs2 m_id (Var (Id n1 t)) e2 =
    let
        (e1, f_pc1, f_symbs1, ng') = arbDCCase tenv ng t

        eenv1' = E.insert n1 e1 eenv1

        (m_e, m_ns, a_eenv, pc, symbs, ng'') = newMergeExpr kv ng' m_id HM.empty eenv1' eenv2 tenv e1 e2
    in
    assert (E.isSymbolic n1 eenv1)
           ( m_e
           , m_ns
           , eenv1'
           , eenv2
           , a_eenv
           , f_pc1 ++ pc
           , f_symbs1 `HS.union` symbs
           , symbs
           , ng'')
newMergeCurrExpr' eenv1 eenv2 tenv kv ng symbs1 symbs2 m_id e1 (Var (Id n2 t)) =
    let
        (e2, f_pc2, f_symbs2, ng') = arbDCCase tenv ng t

        eenv2' = E.insert n2 e2 eenv2

        (m_e, m_ns, a_eenv, pc, symbs, ng'') = newMergeExpr kv ng' m_id HM.empty eenv1 eenv2' tenv e1 e2
    in
    assert (E.isSymbolic n2 eenv2)
           ( m_e
           , m_ns
           , eenv1
           , eenv2'
           , a_eenv
           , f_pc2 ++ pc
           , symbs
           , f_symbs2 `HS.union` symbs
           , ng'')
newMergeCurrExpr' eenv1 eenv2 tenv kv ng symbs1 symbs2 m_id e1 e2 =
    let
        (m_e, m_ns, a_eenv, pc, symbs, ng') = newMergeExpr kv ng m_id HM.empty eenv1 eenv2 tenv e1 e2
    in
    (m_e, m_ns, eenv1, eenv2, a_eenv, pc, symbs1 `HS.union` symbs, symbs2 `HS.union` symbs, ng')

------------------------------------------------
-- Merging expressions

type NewSymbolicIds = SymbolicIds

newMergeExprEnvCxt :: Context t -> MergedIds -> (ExprEnv, Context t)
newMergeExprEnvCxt cxt@(Context { state1_ = s1, state2_ = s2, newExprEnv_ = m_eenv, newPCs_ = pc, ng_ = ng, newId_ = m_id }) m_ns =
    let
        (eenv', pc', symbs', ng') =
            newMergeExprEnv (known_values s1) ng m_id m_ns (symbolic_ids s1) (symbolic_ids s2) (type_env s1) (expr_env s1) (expr_env s2) m_eenv
    in
    (eenv', cxt { state1_ = s1 { symbolic_ids = symbs'}
                , state2_ = s2 { symbolic_ids = symbs' }
                , newPCs_ = pc ++ pc'
                , ng_ = ng' } )

newMergeExprEnv :: KnownValues
                -> NameGen
                -> MergeId
                -> MergedIds
                -> SymbolicIds
                -> SymbolicIds
                -> TypeEnv
                -> ExprEnv
                -> ExprEnv
                -> ExprEnv
                -> (ExprEnv, [PathCond], SymbolicIds, NameGen)
newMergeExprEnv kv ng m_id m_ns symb1 symb2 tenv eenv1 eenv2 m_eenv =
    let 
        s1 = State { expr_env = eenv1, type_env = tenv, symbolic_ids = symb1, rules = [], num_steps = 0 }
        s2 = State { expr_env = eenv2, type_env = tenv, symbolic_ids = symb2, rules = [], num_steps = 0 }

        ctxt = Context { state1_ = s1
                       , state2_ = s2
                       , mergedIds_ = m_ns
                       , newMergedIds_ = HM.empty
                       , newExprEnv_ = m_eenv
                       , ng_ = ng
                       , newId_ = m_id
                       , newPCs_ = []
                       , newSyms_ = HS.empty
                       }

        (n_eenv, ctxt') = 
            runMergeMContext (E.mergeAEnvObj
                              E.preserveMissing
                              E.preserveMissing
                              (E.zipWithAMatched (newMergeEnvObj kv)) 
                              eenv1 
                              eenv2)
                            ctxt

        n_eenv' = foldr (\i -> E.insertSymbolic (idName i) i) n_eenv (newSyms_ ctxt')

        ctxt_eenv = newExprEnv_ ctxt'
        ctxt_eenv1 = expr_env (state1_ ctxt') 
        ctxt_eenv2 = expr_env (state2_ ctxt') 
        m_ns' = newMergedIds_ ctxt'
        symbs = symbolic_ids (state1_ ctxt') `HS.union` symbolic_ids (state2_ ctxt')
        ng' = ng_ ctxt'
        n_pc = newPCs_ ctxt'

        (n_eenv'', n_pc', symbs', ng'') = (n_eenv', [], symbs, ng') -- resolveNewVariables tenv kv ng' m_id (HM.union m_ns m_ns') symbs ctxt_eenv1 ctxt_eenv2 n_eenv'

        n_eenv''' = foldr (\i -> E.insertSymbolic (idName i) i) n_eenv'' symbs'

    in
    (E.union ctxt_eenv n_eenv''', n_pc ++ n_pc', symbs', ng'')

newMergeEnvObj :: KnownValues -> Name -> E.EnvObj -> E.EnvObj
               -> MergeM t E.EnvObj
newMergeEnvObj kv n eObj1 eObj2
    | E.EqFast eObj1 == E.EqFast eObj2 = return eObj1
    | E.ExprObj _ e1 <- eObj1
    , E.ExprObj _ e2 <- eObj2 = do
        m_e <- newMergeExpr' kv e1 e2
        return $ E.ExprObj Nothing m_e
    | (E.SymbObj i) <- eObj1
    , (E.ExprObj _ e2) <- eObj2 = do
        -- We check to make sure that we have not already overwritten the SymbObj in some other mergeExpr call
        obj <- lookupEnvObjExprEnv1 (idName i)
        case obj of
            Just (E.SymbObj _) -> do
                e_s <- arbDCCase1 (typeOf i)
                insertExprEnv1 (idName i) e_s
                e <- newMergeExpr' kv e_s e2
                deleteSymbolic1 i
                return $ E.ExprObj Nothing e
            Just obj' -> return obj'
            Nothing -> error "mergeEnvObj: bad input"
    | (E.ExprObj _ e1) <- eObj1
    , (E.SymbObj i) <- eObj2 = do
        -- We check to make sure that we have not already overwritten the SymbObj in some other mergeExpr call
        obj <- lookupEnvObjExprEnv2 (idName i)
        case obj of
            Just (E.SymbObj _) -> do
                e_s <- arbDCCase2 (typeOf i)
                insertExprEnv2 (idName i) e_s
                e <- newMergeExpr' kv e1 e_s
                deleteSymbolic2 i
                return $ E.ExprObj Nothing e
            Just obj' -> return obj'
            Nothing -> error "mergeEnvObj: bad input"
    | (E.RedirObj n) <- eObj1
    , (E.ExprObj _ e2) <- eObj2 = do
        i1 <- nameToId1 n
        e <- newMergeExpr' kv (Var i1) e2
        return $ E.ExprObj Nothing e
    | (E.ExprObj _ e1) <- eObj1
    , (E.RedirObj n) <- eObj2 = do
        i2 <- nameToId2 n
        e <- newMergeExpr' kv e1 (Var i2)
        return $ E.ExprObj Nothing e
    | (E.RedirObj n1) <- eObj1
    , (E.RedirObj n2) <- eObj2 = do
        i1 <- nameToId1 n
        i2 <- nameToId2 n
        e <- newMergeExpr' kv  (Var i1) (Var i2)
        return $ E.ExprObj Nothing e
    | (E.SymbObj i1) <- eObj1
    , (E.SymbObj i2) <- eObj2
    , i1 == i2 = return eObj1
    | otherwise = error $ "Unequal SymbObjs or RedirObjs present in the expr_envs of both states." ++ (show eObj1) ++ " " ++ (show eObj2)

-- | Build a case expression with one alt for each data constructor of the given type
-- and symbolic arguments.  Thus, the case expression could evaluate to any value of the
-- given type.
arbDCCase :: TypeEnv
          -> NameGen
          -> Type
          -> (Expr, [PathCond], HS.HashSet Id, NameGen)
arbDCCase tenv ng t
    | TyCon tn _:ts <- unTyApp t
    , Just adt <- M.lookup tn tenv =
        let
            dcs = dataCon adt
            (bindee_id, ng') = freshId TyLitInt ng

            bound = boundIds adt
            bound_ts = zip bound ts

            ty_apped_dcs = map (\dc -> mkApp $ Data dc:map Type ts) dcs
            ((ng'', symbs), apped_dcs) =
                        L.mapAccumL
                            (\(ng_, symbs_) dc ->
                                let
                                    anon_ts = anonArgumentTypes dc
                                    re_anon = foldr (\(i, t) -> retype i t) anon_ts bound_ts
                                    (ars, ng_') = freshIds re_anon ng_
                                    symbs_' = foldr HS.insert symbs_ ars
                                in
                                ((ng_', symbs_'), mkApp $ dc:map Var ars)
                            )
                            (ng', HS.empty)
                            ty_apped_dcs

            bindee = Var bindee_id

            pc = mkBounds bindee 1 (toInteger $ length dcs)

            e = createCaseExpr bindee_id apped_dcs
        in
        (e, pc, HS.insert bindee_id symbs, ng'')
    | otherwise = error $ "arbDCCase: type not found\n" ++ show t

arbDCCase1 :: Type -> MergeM t Expr
arbDCCase1 = arbDCCase' insertSymbolic1

arbDCCase2 :: Type -> MergeM t Expr
arbDCCase2 = arbDCCase' insertSymbolic2

arbDCCase' :: (Id -> MergeM t ()) -> Type -> MergeM t Expr
arbDCCase' insertSym t 
    | TyCon tn _:ts <- unTyApp t = do
        m_adt <- lookupTypeM tn
        case m_adt of
            Just adt -> do
                let dcs = dataCon adt
                bindee_id <- freshIdM TyLitInt

                let bound = boundIds adt
                    bound_ts = zip bound ts

                    ty_apped_dcs = map (\dc -> mkApp $ Data dc:map Type ts) dcs
                
                apped_dcs <- mapM (\dc -> do
                                        let anon_ts = anonArgumentTypes dc
                                            re_anon = foldr (\(i, t) -> retype i t) anon_ts bound_ts

                                        ars <- freshIdsM re_anon
                                        mapM insertSym ars

                                        return (mkApp $ dc:map Var ars)) ty_apped_dcs

                let bindee = Var bindee_id

                let pc = mkBounds bindee 1 (toInteger $ length dcs)
                    e = createCaseExpr bindee_id apped_dcs

                insertSym bindee_id
                addPC pc
                
                return e
            Nothing -> error $ "arbDCCase: type not found"
arbDCCase' _ _ = error $ "arbDCCase: type not found"

nameToId1 :: Name -> MergeM t Id
nameToId1 n = do
    m_e <- lookupExprEnv1 n
    case m_e of
        Just e -> return $ Id n (typeOf e)
        Nothing -> error "nameToId1: name not found"

nameToId2 :: Name -> MergeM t Id
nameToId2 n = do
    m_e <- lookupExprEnv2 n
    case m_e of
        Just e -> return $ Id n (typeOf e)
        Nothing -> error "nameToId2: name not found"

-- Takes two expressions to merge.  In addition, takes a map from pairs of
-- variables names to a single name, which can be substituted in place of
-- the variables.
-- Returns the results of merging the expressions, as well as a HashMap of
-- new name pairs which must be merged.
newMergeExpr :: KnownValues
             -> NameGen
             -> MergeId
             -> MergedIds
             -> ExprEnv
             -> ExprEnv
             -> TypeEnv
             -> Expr
             -> Expr
             -> (Expr, MergedIds, ExprEnv, [PathCond], HS.HashSet Id, NameGen)
newMergeExpr kv ng m_id m_ns eenv1 eenv2 tenv e1 e2 =
    let s1 = State { expr_env = eenv1, type_env = tenv, symbolic_ids = HS.empty, rules = [], num_steps = 0 }
        s2 = State { expr_env = eenv2, type_env = tenv, symbolic_ids = HS.empty, rules = [], num_steps = 0 }

        ctxt = Context { state1_ = s1
                       , state2_ = s2
                       , mergedIds_ = m_ns
                       , newMergedIds_ = HM.empty
                       , newExprEnv_ = E.empty
                       , ng_ = ng
                       , newId_ = m_id
                       , newPCs_ = []
                       , newSyms_ = HS.empty
                       }
        (e, ctxt') = runMergeMContext (newMergeExpr' kv e1 e2) ctxt
    in
    exprContextToTuple e ctxt'

newMergeExpr' :: KnownValues -> Expr -> Expr -> MergeM t Expr
newMergeExpr' kv e1 e2 = do
    eenv1 <- exprEnv1
    eenv2 <- exprEnv2

    let e1' = if  | Var (Id n _) <- e1
                  , Just e_ <- E.deepLookup n eenv1 -> e_
                  | otherwise -> e1
    let e2' = if  | Var (Id n _) <- e2
                  , Just e_ <- E.deepLookup n eenv2 -> e_
                  | otherwise -> e2

    newMergeExpr'' kv e1 e2

newMergeExpr'' :: KnownValues -> Expr -> Expr -> MergeM t Expr
newMergeExpr'' kv v1@(Var i1@(Id n1 t)) v2@(Var i2@(Id n2 _)) = do
    m_i <- lookupMergedIds n1 n2

    eenv1 <- exprEnv1
    eenv2 <- exprEnv2

    if  | n1 == n2 -> return v1
        | Just i <- m_i -> return (Var i)
        | isPrimType t -> do
            m_id <- splitId
            i <- freshIdM t
            insertNewSymbolic i
            let pc = [ PC.mkAssumePC m_id 1 $ ExtCond (mkEqPrimExpr t kv (Var i) v1) True
                     , PC.mkAssumePC m_id 2 $ ExtCond (mkEqPrimExpr t kv (Var i) v2) True ]
            addPC pc
            return (Var i)
        | E.isSymbolic n1 eenv1
        , E.isSymbolic n2 eenv2
        , n1 `E.member` eenv1
        , not (n1 `E.member` eenv2) -> do
            insertNewExprEnv n2 v1
            insertExprEnv2 n2 v1
            deleteSymbolic2 i2
            return v1
        | E.isSymbolic n1 eenv1
        , E.isSymbolic n2 eenv2
        , n2 `E.member` eenv2
        , not (n2 `E.member` eenv1) -> do
            insertNewExprEnv n1 v2
            insertExprEnv1 n1 v2
            deleteSymbolic1 i1
            return v2
        | Just e1 <- E.deepLookup n1 eenv1
        , Just e2 <- E.deepLookup n2 eenv2
        , Var _ <- e1
        , Var _ <- e2 -> newMergeExpr' kv e1 e2
        | Just e1 <- E.deepLookup n1 eenv1
        , Just e2 <- E.deepLookup n2 eenv2
        , isSMNF eenv2 e2
        , Var (Id n1 t) <- e1 -> do
            new_e1 <- arbDCCase1 t
            insertNewExprEnv n1 new_e1
            insertExprEnv1 n1 new_e1
            newMergeExpr' kv new_e1 e2
        | Just e1 <- E.deepLookup n1 eenv1
        , Just e2 <- E.deepLookup n2 eenv2
        , isSMNF eenv1 e1
        , Var (Id n2 t) <- e2 -> do
            new_e2 <- arbDCCase2 t
            insertNewExprEnv n2 new_e2
            insertExprEnv2 n2 new_e2
            newMergeExpr' kv e1 new_e2
        | Just e1 <- E.deepLookup n1 eenv1
        , Just e2 <- E.deepLookup n2 eenv2
        , isSMNF eenv1 e1
        , isSMNF eenv2 e2 -> do
            i <- freshIdM t
            insertNewMergedIds n1 n2 i
            e <- newMergeExpr' kv e1 e2
            insertNewExprEnv (idName i) e
            insertExprEnv1 (idName i) e
            insertExprEnv2 (idName i) e
            return (Var i)
        | otherwise -> do
            i <- freshIdM t
            insertNewMergedIds n1 n2 i
            e <- newCaseExpr' v1 v2
            insertNewExprEnv (idName i) e
            insertExprEnv1 (idName i) e
            insertExprEnv2 (idName i) e
            return (Var i)

newMergeExpr'' kv v1@(Var (Id _ t)) l@(Lit _) = do
    m_id <- splitId
    i <- freshIdM t
    insertNewSymbolic i
    let pc = [ PC.mkAssumePC m_id 1 $ ExtCond (mkEqPrimExpr t kv (Var i) v1) True
             , PC.mkAssumePC m_id 2 $ ExtCond (mkEqPrimExpr t kv (Var i) l) True ]
    addPC pc
    return (Var i)
newMergeExpr'' kv l@(Lit _) v2@(Var (Id _ t)) = do
    m_id <- splitId
    i <- freshIdM t
    insertNewSymbolic i
    let pc = [ PC.mkAssumePC m_id 1 $ ExtCond (mkEqPrimExpr t kv (Var i) l) True
             , PC.mkAssumePC m_id 2 $ ExtCond (mkEqPrimExpr t kv (Var i) v2) True ]
    addPC pc
    return (Var i)
newMergeExpr'' kv l1@(Lit _) l2@(Lit _) = do
    m_id <- splitId
    let t = typeOf l1
    i <- freshIdM t
    insertNewSymbolic i
    let pc = [ PC.mkAssumePC m_id 1 $ ExtCond (mkEqPrimExpr t kv (Var i) l1) True
             , PC.mkAssumePC m_id 2 $ ExtCond (mkEqPrimExpr t kv (Var i) l2) True ]
    addPC pc
    return (Var i)

newMergeExpr'' kv e1 e2
    | d@(Data (DataCon n1 _)):es1 <- unApp e1
    , Data (DataCon n2 _):es2 <- unApp e2 
    , n1 == n2 = do
        es <- mapM (uncurry (newMergeExpr' kv)) $ zip es1 es2
        return $ mkApp (d:es)

newMergeExpr'' kv e1 e2@(Case (Var i2) b2 as2)
    | Data dc1:_ <- unApp e1
    , isSMNFCase e2 = newMergeDataConCase kv dc1 e1 i2 as2
newMergeExpr'' kv e1@(Case (Var i1) b1 as1) e2
    | Data dc2:_ <- unApp e2
    , isSMNFCase e1 = newMergeCaseDataCon kv i1 as1 dc2 e2
newMergeExpr'' kv e1@(Case (Var i1) b1 as1) e2@(Case (Var i2) b2 as2) 
    | isSMNFCase e1
    , isSMNFCase e2 = newMergeCaseExprs kv i1 as1 i2 as2
newMergeExpr'' _ ty@(Type t) (Type t') = assert (t == t') return ty
newMergeExpr'' _ e1 e2 = newCaseExpr' e1 e2

isVar :: Expr -> Bool
isVar (Var _) = True
isVar _ = False

newMergeExprs' :: KnownValues -> [Expr] -> MergeM t Expr
newMergeExprs' kv (e:es) = foldM (newMergeExpr' kv) e es
newMergeExprs' _ _ = error  "newMergeExprs: empty list"

newCaseExpr :: NameGen -> MergeId -> Expr -> Expr -> (Expr, [PathCond], Id, NameGen)
newCaseExpr ng m_id e1 e2 =
    let
        (binder, ng') = freshId TyLitInt ng
    in
    (Case (Var m_id) binder [ Alt (LitAlt $ LitInt 1) e1
                            , Alt (LitAlt $ LitInt 2) e2 ]
    , mkBounds (Var m_id) 1 2
    , binder
    , ng')

newCaseExpr' :: Expr -> Expr -> MergeM t Expr
newCaseExpr' e1 e2 = do
    m_id <- splitId
    let pc = mkBounds (Var m_id) 1 2
    addPC pc

    binder <- freshIdM TyLitInt
    let as = [ Alt (LitAlt $ LitInt 1) e1
             , Alt (LitAlt $ LitInt 2) e2 ]
    return $ Case (Var m_id) binder as

mkBounds :: Expr -> Integer -> Integer -> [PathCond]
mkBounds e l u =
    let
        t = TyFun TyLitInt $ TyFun TyLitInt TyLitInt
    in
    [ ExtCond (App (App (Prim Le t) (Lit (LitInt l))) e) True
    , ExtCond (App (App (Prim Le t) e) (Lit (LitInt u))) True]

newMergeDataConCase :: KnownValues
                    -> DataCon
                    -> Expr
                    -> Id -- ^ Case bindee variable id
                    -> [Alt] -- ^ Case Alts (with constructors in SMNF)
                    -> MergeM t Expr
newMergeDataConCase kv dc e bind2 as2 = do
    m_id <- splitId
    let as_info1 = (dc, m_id, 1, e)
        as_info2 = map (smnfAltInfo bind2) as2
    newMergeIntoCase' kv $ as_info1:as_info2

newMergeCaseDataCon :: KnownValues
                    -> Id -- ^ Case bindee variable id
                    -> [Alt] -- ^ Case Alts (with constructors in SMNF)
                    -> DataCon
                    -> Expr
                    -> MergeM t Expr
newMergeCaseDataCon kv bind1 as1 dc e = do
    m_id <- splitId
    let as_info1 = map (smnfAltInfo bind1) as1
        as_info2 = (dc, m_id, 2, e)
    newMergeIntoCase' kv $ as_info1 ++ [as_info2]


newMergeCaseExprs :: KnownValues
                  -> Id -- ^ Case 1 bindee variable id
                  -> [Alt] -- ^ Case 1 Alts (with constructors in SMNF)
                  -> Id -- ^ Case 2 bindee variable id
                  -> [Alt] -- ^ Case 2 Alts (with constructors in SMNF)
                  -> MergeM t Expr
newMergeCaseExprs kv bind1 as1 bind2 as2 =
    let
        as_info1 = map (smnfAltInfo bind1) as1
        as_info2 = map (smnfAltInfo bind2) as2
    in
    newMergeIntoCase' kv $ as_info1 ++ as_info2

newMergeIntoCase' :: KnownValues
                  -> [(DataCon, Id, Integer, Expr)]
                  -> MergeM t Expr
newMergeIntoCase' kv b_as = do
    let -- Group up by common data constructors
        as_hm = foldr (\(DataCon n _, i, l, e) -> HM.insertWith (++) n [(i, l, e)]) HM.empty $ b_as
        as_grouped = HM.toList as_hm :: [(Name, [(Id, Integer, Expr)])]

        -- Form the new case
        num_grouped = zip [1..] (map snd as_grouped) :: [(Integer, [(Id, Integer, Expr)])]

    new_alts <- mapM (\(i, es) -> do
                            me <- newMergeExprs' kv (map thd3 es)
                            return (Alt (LitAlt $ LitInt i) me)) num_grouped

    new_bndee <- freshIdM TyLitInt
    new_bnd <- freshIdM TyLitInt

    insertNewSymbolic new_bndee

    let bndee_pc = mkBounds (Var new_bndee) 1 (toInteger $ length num_grouped)
        link_pc = map (\(i, j_es) -> mkMergeCasePC kv new_bndee i
                                   $ map (\(bnd_, lit_, _) -> (bnd_, lit_)) j_es)
                      num_grouped

    addPC (bndee_pc ++ link_pc)

    return $ Case (Var new_bndee) new_bnd new_alts
    where
      fst3 (x, _, _) = x
      snd3 (_, x, _) = x
      thd3 (_, _, x) = x

smnfAltInfo :: Id -> Alt -> (DataCon, Id, Integer, Expr)
smnfAltInfo i (Alt (LitAlt (LitInt l)) e)
    | Data dc:_ <- unApp e = (dc, i, l, e)
smnfAltInfo _ a = error $ "smnfAltInfo: invalid Alt structure" ++ show a

mkMergeCasePC :: KnownValues -> Id -> Integer -> [(Id, Integer)] -> PathCond
mkMergeCasePC kv bind1 l bls =
      flip ExtCond True
    . mkEqExpr kv (mkEqExpr kv (Var bind1) (Lit $ LitInt l)) 
    $ foldr (mkOrExpr kv)
            (mkFalse kv)
            (map (\(b2, jl) -> mkEqExpr kv (Var b2) (Lit (LitInt jl))) bls)

resolveNewVariables :: TypeEnv
                    -> KnownValues
                    -> NameGen
                    -> MergeId
                    -> MergedIds
                    -> SymbolicIds
                    -> ExprEnv
                    -> ExprEnv
                    -> ExprEnv
                    -> (ExprEnv, [PathCond], SymbolicIds, NameGen)
resolveNewVariables tenv kv ng m_id m_ns = resolveNewVariables' m_ns [] tenv kv ng m_id m_ns

resolveNewVariables' :: MergedIds
                     -> [PathCond]
                     -> TypeEnv
                     -> KnownValues
                     -> NameGen
                     -> MergeId
                     -> MergedIds
                     -> SymbolicIds
                     -> ExprEnv
                     -> ExprEnv
                     -> ExprEnv
                     -> (ExprEnv, [PathCond], SymbolicIds, NameGen)
resolveNewVariables' r_m_ns pc tenv kv ng m_id m_ns symbs eenv1 eenv2 n_eenv
    | HM.null r_m_ns = (n_eenv, pc, symbs, ng)
    | otherwise =
        let
            (n_eenv', m_ns', r_m_ns', pc', symbs', ng') =
                foldr (\((m_n1, m_n2), i) (n_eenv_, m_ns_, r_m_ns_, pc_, symbs_, ng_) ->
                          let
                              (n1, eenv_e1) = case E.deepLookupName m_n1 n_eenv_ of
                                                Just ne -> ne
                                                Nothing -> error $ "resolveNewVariables': expression for 1 not found\n" ++ show m_n1
                              (n2, eenv_e2) = case E.deepLookupName m_n2 n_eenv_ of
                                                Just ne -> ne
                                                Nothing -> error $ "resolveNewVariables': expression for 2 not found\n" ++ show m_n2

                              t = typeOf i
                              i1 = Id n1 t
                              i2 = Id n2 t
                              v1 = Var i1
                              v2 = Var i2

                              (n_eenv_', r_m_ns_', pc_', symbs_', ng_') =
                                      if | E.isSymbolic n1 eenv1
                                         , E.isSymbolic n2 eenv2
                                         , isPrimType t ->
                                              let
                                                  pc__ = [ PC.mkAssumePC m_id 1 $ ExtCond (mkEqPrimExpr t kv (Var i) v1) True
                                                         , PC.mkAssumePC m_id 2 $ ExtCond (mkEqPrimExpr t kv (Var i) v2) True ]
                                              in
                                              ( E.insertSymbolic (idName i) i n_eenv_
                                              , HM.empty
                                              , pc__
                                              , HS.insert i symbs_
                                              , ng_)
                                          | E.isSymbolic n1 n_eenv_
                                          , E.isSymbolic n2 n_eenv_
                                          , n1 `E.member` eenv1
                                          , not (n1 `E.member` eenv2) ->
                                                ( n_eenv_ -- E.insert n2 v1 $ E.insert (idName i) v1 n_eenv_
                                                , HM.empty
                                                , []
                                                , symbs_
                                                , ng_)
                                          | E.isSymbolic n1 n_eenv_
                                          , E.isSymbolic n2 n_eenv_
                                          , n2 `E.member` eenv2
                                          , not (n2 `E.member` eenv1) ->
                                                ( n_eenv_ -- E.insert n1 v2 $ E.insert (idName i) v2 n_eenv_
                                                , HM.empty
                                                , []
                                                , symbs_
                                                , ng_)
                                          | e1 <- eenv_e1
                                          , e2 <- eenv_e2
                                          , isSMNF n_eenv_ e1
                                          , isSMNF n_eenv_ e2
                                          , not (isVar e1)
                                          , not (isVar e2) ->
                                                let
                                                    (e_m, f_m_ns, a_eenv, f_pc, f_symbs, f_ng) =
                                                        newMergeExpr kv ng_ m_id (HM.union m_ns_ r_m_ns_) eenv1 eenv2 tenv e1 e2
                                                in
                                                ( E.insert (idName i) e_m (E.union a_eenv n_eenv_)
                                                , f_m_ns
                                                , f_pc
                                                , HS.union f_symbs symbs_
                                                , f_ng)
                                          | (Var (Id n1 _)) <- eenv_e1
                                          , e2 <- eenv_e2
                                          , isSMNF n_eenv_ e2
                                          , E.isSymbolic n1 n_eenv_
                                          , not (isVar e2) ->
                                                let
                                                    (e1, f_pc1, f_symbs1, ng_') = arbDCCase tenv ng_ t
                                                    (m_e, m_ns, a_eenv, pc, symbs, ng_'') = newMergeExpr kv ng_' m_id HM.empty eenv1 eenv2 tenv e1 e2
                                                in
                                                ( E.insert n1 e1 $ E.insert (idName i) m_e (E.union a_eenv n_eenv_)
                                                , m_ns
                                                , f_pc1 ++ pc
                                                , f_symbs1 `HS.union` symbs `HS.union` symbs_ 
                                                , ng_'')
                                          | e1 <- eenv_e1
                                          , (Var (Id n2 _)) <- eenv_e2
                                          , isSMNF n_eenv_ e1
                                          , not (isVar e1)
                                          , E.isSymbolic n2 n_eenv_ ->
                                                let
                                                    (e2, f_pc2, f_symbs2, ng_') = arbDCCase tenv ng_ t
                                                    (m_e, m_ns, a_eenv, pc, symbs, ng_'') = newMergeExpr kv ng_' m_id HM.empty eenv1 eenv2 tenv e1 e2
                                                in
                                                ( E.insert n2 e2 $ E.insert (idName i) m_e (E.union a_eenv n_eenv_)
                                                , m_ns
                                                , f_pc2 ++ pc
                                                , f_symbs2 `HS.union` symbs `HS.union` symbs_ 
                                                , ng_'')
                                          | otherwise ->
                                                  let
                                                      (e_, pc__, _, ng__) = newCaseExpr ng_ m_id v1 v2
                                                  in
                                                  (E.insert (idName i) e_ n_eenv_, HM.empty, pc__, symbs_, ng__)

                          in
                          ( foldr (\i -> E.insertSymbolic (idName i) i) n_eenv_' symbs_'
                          , HM.union m_ns_ r_m_ns_'
                          , HM.union r_m_ns_ r_m_ns_'
                          , pc_ ++ pc_'
                          , symbs_'
                          , ng_'))
                      (n_eenv, m_ns, HM.empty, [], symbs, ng)
                      (HM.toList r_m_ns)
        in
        resolveNewVariables' r_m_ns' (pc ++ pc') tenv kv ng' m_id m_ns' symbs' eenv1 eenv2 n_eenv'
    where
        isVar (Var _) = True
        isVar _ = False
------------------------------------------------


-- | Creates and applies new symbolic variables for arguments of Data Constructor
concretizeSym :: [(Id, Type)] -> Maybe Coercion -> (State t, NameGen) -> DataCon -> ((State t, NameGen), Expr)
concretizeSym bi maybeC (s, ng) dc@(DataCon n ts) =
    let dc' = Data dc
        ts' = anonArgumentTypes $ PresType ts
        ts'' = foldr (\(i, t) e -> retype i t e) ts' bi
        (ns, ng') = freshNames (length ts'') ng
        newParams = map (\(n', t) -> Id n' t) (zip ns ts'')
        ts2 = map snd bi
        dc'' = mkApp $ dc' : (map Type ts2) ++ (map Var newParams)
        dc''' = case maybeC of
            (Just (t1 :~ t2)) -> Cast dc'' (t2 :~ t1)
            Nothing -> dc''
        eenv = foldr (uncurry E.insertSymbolic) (expr_env s) $ zip (map idName newParams) newParams
        syms = foldr HS.insert (symbolic_ids s) newParams
    in ((s {expr_env = eenv, symbolic_ids = syms} , ng'), dc''')

-- Given an Expr `e`, and an `Id`, `Int` pair, returns `ExtCond ((NOT (Id == Int)) OR e) True`
implies :: KnownValues -> Id -> Integer -> Expr -> Bool -> PathCond
implies kv newId num e b = implies' kv (mkEqExpr kv (Var newId) (Lit $ LitInt num)) e b

implies' :: KnownValues -> Expr -> Expr -> Bool -> PathCond
implies' kv clause e b =
    let e' = mkImpliesExpr kv clause e
    in ExtCond e' b

createCaseExpr :: Id -> [Expr] -> Expr
createCaseExpr _ [e] = e
createCaseExpr newId es@(_:_) =
    let
        -- We assume that PathCond restricting newId's range is added elsewhere
        (_, alts) = bindExprToNum (\num e -> Alt (LitAlt (LitInt num)) e) es
    in Case (Var newId) newId alts
createCaseExpr _ [] = error "No exprs"

bindExprToNum :: (Integer -> a -> b) -> [a] -> (Integer, [b])
bindExprToNum f es = L.mapAccumL (\num e -> (num + 1, f num e)) 1 es


mergeSymbolicIds :: Context t -> SymbolicIds
mergeSymbolicIds (Context { state1_ = (State {symbolic_ids = syms1}), state2_ = (State {symbolic_ids = syms2})
                          , newId_ = newId}) =
    let
        syms' = syms1 `HS.union` syms2
        syms'' = HS.insert newId syms'
    in syms''

mergePathConds :: Simplifier simplifier => simplifier -> Context t -> (Context t, PathConds)
mergePathConds simplifier ctxt@(Context { state1_ = s1@(State { path_conds = pc1, known_values = kv })
                                         , state2_ = (State { path_conds = pc2 })
                                         , newId_ = newId
                                         , newPCs_ = newPCs}) =
    let        
        res_newId = ExtCond (mkOrExpr kv
                                (mkEqExpr kv (Var newId) (Lit $ LitInt 1))
                                (mkEqExpr kv (Var newId) (Lit $ LitInt 2))) True

        merged = PC.mergeWithAssumePCs newId pc1 pc2

        (s1', new') = L.mapAccumL (simplifyPC simplifier) s1 (res_newId:newPCs)
        new'' = concat new'

        merged' = foldr PC.insert merged new''

        merged'' = foldr (simplifyPCs simplifier s1') merged' new''
    in
    (ctxt { state1_ = s1' }, merged'')

-- | Return PathCond restricting value of `newId` to [lower, upper]
restrictSymVal :: KnownValues -> Integer -> Integer -> Id -> PathCond
restrictSymVal kv lower upper newId = ExtCond (mkAndExpr kv (mkGeIntExpr kv (Var newId) lower) (mkLeIntExpr kv (Var newId) upper)) True

freshMergeId :: Type -> NameGen -> (Id, NameGen)
freshMergeId = freshSeededId (Name "m" Nothing 0 Nothing)