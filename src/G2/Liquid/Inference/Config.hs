module G2.Liquid.Inference.Config ( InferenceConfig (..)
                                  , mkInferenceConfig
                                  , adjustConfig) where

import G2.Config.Config
import G2.Initialization.Types
import G2.Language (ExprEnv
                   , Name (..)
                   , Type (..)
                   , returnType)
import qualified G2.Language.ExprEnv as E

import qualified Data.HashSet as S
import qualified Data.Map as M
import qualified Data.Text as T

data InferenceConfig = InferenceConfig { max_ce :: Int }

mkInferenceConfig :: [String] -> InferenceConfig
mkInferenceConfig as = InferenceConfig { max_ce = strArg "max-ce" as M.empty read 20 }

adjustConfig :: Maybe T.Text -> SimpleState -> Config -> Config
adjustConfig main_mod (SimpleState { expr_env = eenv }) config =
    let
        ns = filter (\(Name _ m _ _) -> m == main_mod) $ E.keys eenv
        ns' = filter (not . retTyVar eenv) ns
        ns'' = map (\(Name n m _ _) -> (n, m)) ns'
    in
    config { counterfactual = Counterfactual . CFOnly $ S.fromList ns'' }

retTyVar :: ExprEnv -> Name -> Bool
retTyVar eenv n
    | Just e <- E.lookup n eenv
    , TyVar _ <- returnType e = True
    | otherwise = False