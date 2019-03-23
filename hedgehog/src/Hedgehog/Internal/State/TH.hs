{-# OPTIONS_HADDOCK not-home #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
module Hedgehog.Internal.State.TH (
    Availability(..)
  , command
  ) where

import           Control.Monad (when, replicateM)
import           Control.Monad.IO.Class (MonadIO(..))
import qualified Data.Char as Char
import           Hedgehog
import           Hedgehog.Internal.Show (showPretty)
import           Language.Haskell.TH
import           Language.Haskell.TH.Syntax (Name(..), NameFlavour(..))
import           Language.Haskell.TH.Syntax (OccName(..), ModName(..))
import           Language.Haskell.TH.Lift (deriveLift)
import qualified Data.Generics.Uniplate.Data as Uniplate

import Debug.Trace

rename :: (String -> String) -> Name -> Name
rename f =
  mkName . f . nameBase

upcase :: String -> String
upcase = \case
  [] ->
    []
  x : xs ->
    Char.toUpper x : xs

upcaseName :: Name -> Name
upcaseName =
  rename upcase

data Function =
  Function {
      functionContext :: [Type]
    , functionArguments :: [Type]
    , functionMonad :: Type
    , functionResult :: Type
    } deriving (Eq, Ord, Show)

reifyVarType :: Name -> Q Type
reifyVarType name = do
  x0 <- reify name
  case x0 of
    VarI _ x _ ->
      return x
    _ ->
      fail $ show name ++ " is not a variable / function"

takeFunction :: Type -> Maybe Function
takeFunction x0 =
  case x0 of
    ForallT _ ctx x -> do
      Function _ xs m r <- takeFunction x
      pure $ Function ctx xs m r

    ArrowT `AppT` x `AppT` y -> do
      Function ctx xs m r <- takeFunction y
      pure $ Function ctx (x : xs) m r

    AppT m x ->
      pure $ Function [] [] m x

    _ ->
      Nothing

lazyBang :: Bang
lazyBang =
  Bang NoSourceUnpackedness NoSourceStrictness

lazy :: Type -> (Bang, Type)
lazy x =
  (lazyBang, x)

nameVar :: String -> Q Type
nameVar name =
  pure (VarT (mkName name))

modelVar :: Q Type -> Q Type
modelVar x = do
  [t| Var $(x) $(nameVar "v") |]

-- ((<*>) ((<$>) Register (pure name)) (htraverse f pid))

applyHTraverse :: Q Exp -> Name -> Availability -> Q Exp
applyHTraverse f name = \case
  G ->
    [e| pure $(varE name) |]
  V ->
    [e| htraverse $(f) $(varE name) |]

constructHTraverseTail :: Q Exp -> [(Name, Availability)] -> Q Exp -> Q Exp
constructHTraverseTail f xs0 expr =
  case xs0 of
    [] ->
      expr
    (name, x) : xs ->
      constructHTraverseTail f xs [e| $(expr) <*> $(applyHTraverse f name x) |]

constructHTraverse :: Q Exp -> [(Name, Availability)] -> Q Exp -> Q Exp
constructHTraverse f xs0 expr =
  case xs0 of
    [] ->
      expr
    (name, x) : xs ->
      constructHTraverseTail f xs [e| $(expr) <$> $(applyHTraverse f name x) |]

instanceHTraversable :: Name -> [Availability] -> Q [Dec]
instanceHTraversable name aargs = do
  names <- replicateM (length aargs) (newName "x")

  [d| instance HTraversable $(conT name) where
        htraverse _f x =
          case x of
            $(conP name (fmap varP names)) ->
              $(constructHTraverse [e| _f |] (zip names aargs) (conE name))
   |]

unwrap :: Type -> Q Exp -> Q Exp
unwrap ty0 x = do
  var <- [t| Var |]
  case ty0 of
    ty `AppT` _ `AppT` _ ->
      if ty == var then
        [e| concrete $(x) |]
      else
        x
    _ ->
      x

makeExecuteFunction :: Name -> [Type] -> Q Exp
makeExecuteFunction functionName args = do
  names <- replicateM (length args) (newName "x")

  let
    dataName =
      rename upcase functionName

    pats =
      fmap varP names

    exps =
      zipWith ($) (fmap unwrap args) (fmap varE names)

  -- lam <- lamE [conP dataName pats] (foldl appE (varE functionName) exps)
  -- liftIO . putStrLn . pprint $ lam

  lamE [conP dataName pats] (foldl appE (varE functionName) exps)

contextForall :: [Type] -> Q Type -> Q Type
contextForall xs qtyp = do
  typ <- qtyp
  pure $
    ForallT [PlainTV name | VarT name <- Uniplate.universeBi xs] xs typ

makeCommandFunction :: Name -> [Type] -> [Type] -> Q Type -> Q Type -> Q [Dec]
makeCommandFunction functionName ctx args monad resultType = do
  let
    dataName =
      rename upcase functionName

    name =
      rename (\x -> "make" ++ x) dataName

  sig <-
    sigD name $ contextForall ctx [t|
      forall g s.
      MonadGen g =>
      (s Symbolic -> Maybe (g ($(conT dataName) Symbolic))) ->
      [Callback $(conT dataName) $(resultType) s] ->
      Command g $(monad) s
    |]

  let
    gen =
      mkName "gen"

    callbacks =
      mkName "callbacks"

    body =
      normalB [e|
        let
          execute =
            $(makeExecuteFunction functionName args)
        in
          Command $(varE gen) execute $(varE callbacks)
      |]

  fun <-
    funD name [clause [varP gen, varP callbacks] body []]

  pure [sig, fun]

data Availability =
    G -- | Generated values, always available.
  | V -- | Variables, results of commands, only available during execution.
    deriving (Eq, Ord, Show)

command :: Name -> [Availability] -> Q [Dec]
command name aargs = do
  vtype <- reifyVarType name

  Function ctx gargs monad result <-
    maybe (fail $ show name ++ " was not monadic.") pure (takeFunction vtype)

  let
    gargsLength =
      length gargs

    targsLength =
      length aargs

  when (gargsLength /= targsLength) $
    fail $
      show name ++ " has " ++ show gargsLength ++
      " arguments, but " ++ show targsLength ++ " availabilities" ++
      " were provided."

  vargs <- traverse (modelVar . pure) gargs

  eqT <- [t| Eq |]
  ordT <- [t| Ord |]
  showT <- [t| Show |]

  let
    deal t g v =
      case t of
        G ->
          g
        V ->
          v

    args =
      zipWith3 deal aargs gargs vargs

    dataName =
      upcaseName name

    con =
      NormalC dataName (fmap lazy args)

    dat_v =
      [KindedTV (mkName "v") (ArrowT `AppT` StarT `AppT` StarT)]

    dat =
      DataD [] dataName dat_v Nothing [con] [DerivClause Nothing [
        eqT, ordT, showT
      ]]

    htraversable =
      instanceHTraversable dataName aargs

    makeCommand =
      makeCommandFunction name ctx args (pure monad) (pure result)

  --liftIO . putStrLn $ showPretty vtype
  liftIO $ putStrLn "\n== Extracted Function =="
  liftIO . putStrLn $ showPretty (takeFunction vtype)
  liftIO $ putStrLn "\n== Data Type =="
  liftIO . putStrLn $ pprint dat
  liftIO $ putStrLn "\n== HTraversable Instance =="
  ht <- htraversable
  liftIO . putStrLn $ pprint ht
  liftIO $ putStrLn "\n== Command Builder =="
  mc <- makeCommand
  liftIO . putStrLn $ pprint mc

  return $ [dat] ++ ht ++ mc

------------------------------------------------------------------------
-- FIXME Replace with DeriveLift when we drop 7.10 support.

$(deriveLift ''Availability)
