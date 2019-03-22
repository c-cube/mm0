module SpecCheck(insertSort, insertDecl, insertSpec) where

import Control.Monad.Except
import Debug.Trace
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import qualified Data.Sequence as Q
import AST
import Environment
import Util

insertSort :: Ident -> SortData -> Environment -> Either String Environment
insertSort v sd e = do
  s' <- insertNew ("sort " ++ v ++ " already declared") v sd (eSorts e)
  return (e {eSorts = s', eSpec = eSpec e Q.|> SSort v sd})

insertDecl :: Ident -> Decl -> Environment -> Either String Environment
insertDecl v d e = do
  trace ("insertDecl " ++ v ++ ": " ++ show d) (return ())
  d' <- insertNew ("decl " ++ v ++ " already declared") v d (eDecls e)
  return (e {eDecls = d', eSpec = eSpec e Q.|> SDecl v d})

insertSpec :: Spec -> Environment -> Either String Environment
insertSpec (SSort v sd) e = insertSort v sd e
insertSpec (SDecl v d) e = insertDecl v d e
insertSpec s e = return (e {eSpec = eSpec e Q.|> s})

checkSpec :: Environment -> Spec -> Either String ()
checkSpec e (SSort _ _) = return ()
checkSpec e (SDecl _ (DTerm bis ret)) = checkDef e bis ret Nothing
checkSpec e (SDecl _ (DAxiom bis hs ret)) = do
  ctx <- checkBinders e bis
  mapM_ (provableSExpr e ctx) hs
  provableSExpr e ctx ret
checkSpec e (SDecl _ (DDef bis ret defn)) = checkDef e bis ret defn
checkSpec e (SThm _ bis hs ret) = do
  ctx <- checkBinders e bis
  mapM_ (provableSExpr e ctx) hs
  provableSExpr e ctx ret

checkDef :: Environment -> [PBinder] -> DepType ->
  Maybe (M.Map Ident Ident, SExpr) -> Either String ()
checkDef env bis ret defn = do
  ctx <- checkBinders env bis
  checkType ctx ret
  sd <- fromJustError "sort not found" (eSorts env M.!? dSort ret)
  guardError ("cannot declare term for pure sort '" ++ dSort ret ++ "'") (not (sPure sd))
  case defn of
    Nothing -> return ()
    Just (dummy, e) -> do
      ctx2 <- traverse (\t -> do
          sd <- fromJustError "sort not found" (eSorts env M.!? t)
          guardError ("sort '" ++ dSort ret ++ "' is not nonempty, cannot declare dummy") (not (sNonempty sd))
          return (True, DepType t [])) dummy
      checkSExpr env (ctx <> ctx2) e ret

checkBinders :: Environment -> [PBinder] -> Either String (M.Map Ident (Bool, DepType))
checkBinders e = go M.empty where
  go :: M.Map Ident (Bool, DepType) -> [PBinder] -> Either String (M.Map Ident (Bool, DepType))
  go ctx (PBound x t : bis) = do
    sd <- fromJustError "sort not found" (eSorts e M.!? t)
    guardError ("cannot bind variable; sort '" ++ t ++ "' is strict") (not (sStrict sd))
    go (M.insert x (True, DepType t []) ctx) bis
  go ctx (PReg x ty : bis) = do
    fromJustError "sort not found" (eSorts e M.!? dSort ty)
    checkType ctx ty >> go (M.insert x (False, ty) ctx) bis
  go ctx [] = return ctx

checkType :: M.Map Ident (Bool, DepType) -> DepType -> Either String ()
checkType ctx (DepType t ts) = mapM_ ok ts where
  ok v = do
    (bd, _) <- fromJustError "variable not found" (ctx M.!? v)
    guardError "variable depends on regular variable" bd

provableSExpr :: Environment -> M.Map Ident (Bool, DepType) -> SExpr -> Either String ()
provableSExpr env ctx e = do
  t <- inferSExpr env ctx e
  sd <- fromJustError "sort not found" (eSorts env M.!? t)
  guardError "expression must be a provable sort" (sProvable sd)

checkSExpr :: Environment -> M.Map Ident (Bool, DepType) -> SExpr -> DepType -> Either String ()
checkSExpr env ctx e ty = do
  t <- inferSExpr env ctx e
  guardError "type error" (t == dSort ty)

inferSExpr :: Environment -> M.Map Ident (Bool, DepType) -> SExpr -> Either String Ident
inferSExpr _ ctx (SVar v) = do
  (_, DepType t _) <- fromJustError "variable not found" (ctx M.!? v)
  return t
inferSExpr env ctx (App f es) = do
  (ts, DepType t _) <- fromJustError "term not found" (getTerm env f)
  matchTypes env ctx es ts
  return t

matchTypes :: Environment -> M.Map Ident (Bool, DepType) -> [SExpr] -> [PBinder] -> Either String ()
matchTypes _ _ [] [] = return ()
matchTypes env ctx (e:es) (bi:bis) = do
  t <- checkSExpr env ctx e (binderType bi)
  matchTypes env ctx es bis
matchTypes _ _ _ _ = throwError "incorrect number of arguments"