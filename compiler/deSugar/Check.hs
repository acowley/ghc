
{-
  Author: George Karachalias <george.karachalias@cs.kuleuven.be>
-}

{-# OPTIONS_GHC -Wwarn #-}   -- unused variables

{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds, GADTs, KindSignatures #-}

module Check ( toTcTypeBag, pprUncovered, checkSingle, checkMatches, PmResult ) where

#include "HsVersions.h"

import TmOracle

import HsSyn
import TcHsSyn
import Id
import ConLike
import DataCon
import Name
import TysWiredIn
import TyCon
import SrcLoc
import Util
import BasicTypes
import Outputable
import FastString

-- For the new checker (We need to remove and reorder things)
import DsMonad ( DsM, initTcDsForSolver, getDictsDs)
import TcSimplify( tcCheckSatisfiability )
import TcType ( toTcType, toTcTypeBag )
import Bag
import ErrUtils
import Data.List (find)
import Data.Maybe (isJust)
import MonadUtils -- MonadIO
import Var (EvVar)
import Type
import UniqSupply
import Control.Monad (liftM, liftM3, forM)
import Data.Maybe (isNothing, fromJust)
import DsGRHSs (isTrueLHsExpr)

{-
This module checks pattern matches for:
\begin{enumerate}
  \item Equations that are redundant
  \item Equations with inaccessible right-hand-side
  \item Exhaustiveness
\end{enumerate}

The algorithm used is described in the paper "GADTs meet their match"

    http://people.cs.kuleuven.be/~george.karachalias/papers/gadtpm_ext.pdf

%************************************************************************
%*                                                                      *
\subsection{Pattern Match Check Types}
%*                                                                      *
%************************************************************************
-}

type PmM a = DsM a

data PmConstraint = TmConstraint Id PmExpr -- Term equalities: x ~ e
                  | TyConstraint [EvVar]   -- Type equalities
                  | BtConstraint Id        -- Strictness constraints: x ~ _|_

data Abstraction = P | V   -- Used to parameterise PmPat

type ValAbs  = PmPat 'V -- Value Abstraction
type Pattern = PmPat 'P -- Pattern

{-
data PatVec = PVNil
            | GuardCons Guard          PatVec
            | PatCons   (PmPat PatVec) PatVec

data ValueVec = VNil
              | VCons (PmPat ValueVec) ValueVec

data PmPat rec_pats
  = ConAbs { ...
           , cabs_args :: rec_pats }
  | VarAbs Id
-}

type PatVec    = [Pattern] -- Just a type synonym for pattern vectors ps
type ValVecAbs = [ValAbs]  -- Just a type synonym for value   vectors as

-- The difference between patterns (PmPat 'P)
-- and value abstractios (PmPat 'V)
-- is that the patterns can contain guards (GBindAbs)
-- and value abstractions cannot.  Enforced with a GADT.

-- The *arity* of a PatVec [p1,..,pn] is
-- the number of p1..pn that are not Guards

{-  ???
data PmPat p = ConAbs { cabs_args :: [p] }
             | VarAbs

data PmGPat = Guard PatVec Expr
            | NonGuard (PmPat PmGPat)   -- Patterns

newtype ValAbs = VA (PmPat ValAbs)
-}


data PmPat :: Abstraction -> * where
  -- Guard: P <- e (strict by default) Instead of a single P use a list [AsPat]
  GBindAbs :: { gabs_pats :: PatVec   -- Of arity 1
              , gabs_expr :: PmExpr } -> PmPat 'P

  -- Constructor: K ps
  -- The patterns ps are the ones visible in the source language
  ConAbs :: { cabs_con     :: DataCon
            , cabs_arg_tys :: [Type]          -- The univeral arg types, 1-1 with the universal
                                              -- tyvars of the constructor/pattern synonym
                                              --   Use (conLikeResTy pat_con pat_arg_tys) to get
                                              --   the type of the pattern

            , cabs_tvs     :: [TyVar]         -- Existentially bound type variables (tyvars only)
            , cabs_dicts   :: [EvVar]         -- Ditto *coercion variables* and *dictionaries*
            , cabs_args    :: [PmPat abs] } -> PmPat abs

  -- Variable: x
  VarAbs :: { vabs_id :: Id } -> PmPat abs

  LitAbs :: { labs_lit :: PmLit } -> PmPat abs

-- data T a where
--     MkT :: forall p q. (Eq p, Ord q) => p -> q -> T [p]
-- or  MkT :: forall p q r. (Eq p, Ord q, [p] ~ r) => p -> q -> T r

{- pats ::= pat1 .. patn
   pat ::= K ex_tvs ev_vars pats arg_tys     -- K is from data type T
                                             -- Pattern has type T ty1 .. tyn
         | var
         | pats <- expr       -- Arity(pats) = 1

   arg_tys ::= ty1 .. tyn
-}

-- Drop the guards
coercePmPats :: PatVec -> [ValAbs]
coercePmPats pv = map coercePmPat [ p | p <- pv, isActualPat p]
  where
    isActualPat :: Pattern -> Bool
    isActualPat = (==1) . patternArity

coercePmPat :: Pattern -> ValAbs
coercePmPat (GBindAbs {}) = panic "coercePmPat: Pattern guard"
coercePmPat (VarAbs {vabs_id  = x}) = VarAbs x
coercePmPat (LitAbs {labs_lit = l}) = LitAbs l
coercePmPat (ConAbs { cabs_con = con, cabs_arg_tys = arg_tys
                    , cabs_tvs = tvs, cabs_dicts = dicts, cabs_args = args })
  = ConAbs { cabs_con = con, cabs_arg_tys = arg_tys
           , cabs_tvs = tvs, cabs_dicts = dicts, cabs_args = args' } -- Gadts do not support record updates :(
  where
    args' = coercePmPats args

data ValSetAbs   -- Reprsents a set of value vector abstractions
                 -- Notionally each value vector abstraction is a triple (Gamma |- us |> Delta)
                 -- where 'us'    is a ValueVec
                 --       'Delta' is a constraint
  -- INVARIANT VsaInvariant: an empty ValSetAbs is always represented by Empty
  -- INVARIANT VsaArity: the number of Cons's in any path to a leaf is the same
  -- The *arity* of a ValSetAbs is the number of Cons's in any path to a leaf
  = Empty                               -- {}
  | Union ValSetAbs ValSetAbs           -- S1 u S2
  | Singleton                           -- { |- empty |> empty }
  | Constraint [PmConstraint] ValSetAbs -- Extend Delta
  | Cons ValAbs ValSetAbs               -- map (ucon u) vs

type PmResult = ( [[LPat Id]] -- redundant (do not show the guards)
                , [[LPat Id]] -- inaccessible rhs (do not show the guards)
                , [([ValAbs],[PmConstraint])] ) -- missing (to be improved)

{-
%************************************************************************
%*                                                                      *
\subsection{Entry points to the checker: checkSingle and checkMatches}
%*                                                                      *
%************************************************************************
-}

-- Check a single pattern binding (let)
checkSingle :: Type -> Pat Id -> DsM PmResult
checkSingle ty p = do
  let lp = [noLoc p]
  vec <- liftUs (translatePat p)
  vsa <- initial_uncovered [ty]
  (c,d,us'') <- patVectProc (vec,[]) vsa -- no guards
  us <- pruneValSetAbs us''
  let us' = valSetAbsToList us
  return $ case (c,d) of
    (True,  _)     -> ([],   [],   us')
    (False, True)  -> ([],   [lp], us')
    (False, False) -> ([lp], [],   us')

-- Check a matchgroup (case, etc)
checkMatches :: [Type] -> [LMatch Id (LHsExpr Id)] -> DsM PmResult
checkMatches tys matches
  | null matches = return ([],[],[])
  | otherwise    = do
      missing    <- initial_uncovered tys
      (rs,is,us) <- go matches missing
      return (map hsLMatchPats rs, map hsLMatchPats is, valSetAbsToList us) -- Turn them into a list so we can take as many as we want
  where
    go [] missing = do
      missing' <- pruneValSetAbs missing
      return ([], [], missing')

    go (m:ms) missing = do
      clause        <- liftUs (translateMatch m)
      (c,  d,  us ) <- patVectProc clause missing
      (rs, is, us') <- go ms us
      return $ case (c,d) of
        (True,  _)     -> (  rs,   is, us')
        (False, True)  -> (  rs, m:is, us')
        (False, False) -> (m:rs,   is, us')

initial_uncovered :: [Type] -> DsM ValSetAbs
initial_uncovered tys = do
  us <- getUniqueSupplyM
  cs <- ((:[]) . TyConstraint . bagToList) <$> getDictsDs
  let vsa = zipWith mkPmVar (listSplitUniqSupply us) tys
  return $ mkConstraint cs (foldr Cons Singleton vsa)

{-
%************************************************************************
%*                                                                      *
\subsection{Transform source syntax to *our* syntax}
%*                                                                      *
%************************************************************************
-}

-- -----------------------------------------------------------------------
-- | Utilities

nullaryPmConPat :: DataCon -> PmPat abs
-- Nullary data constructor and nullary type constructor
nullaryPmConPat con = ConAbs { cabs_con = con, cabs_arg_tys = []
                             , cabs_tvs = [], cabs_dicts = [], cabs_args = [] }
truePmPat :: PmPat abs
truePmPat = nullaryPmConPat trueDataCon

-- falsePmPat :: PmPat abs
-- falsePmPat = nullaryPmConPat falseDataCon

nilPmPat :: Type -> PmPat abs
nilPmPat ty = ConAbs { cabs_con = nilDataCon, cabs_arg_tys = [ty]
                     , cabs_tvs = [], cabs_dicts = [], cabs_args = [] }

mkListPmPat :: Type -> [PmPat abs] -> [PmPat abs] -> [PmPat abs]
mkListPmPat ty xs ys = [ConAbs { cabs_con = consDataCon, cabs_arg_tys = [ty]
                               , cabs_tvs = [], cabs_dicts = []
                               , cabs_args = xs++ys }]

mkLitPmPat :: HsLit -> PmPat abs
mkLitPmPat lit = LitAbs { labs_lit = PmLit lit }

mkPosLitPmPat :: HsOverLit Id -> PmPat abs
mkPosLitPmPat lit = LitAbs { labs_lit = PmOLit False lit }

mkNegLitPmPat :: HsOverLit Id -> PmPat abs
mkNegLitPmPat lit = LitAbs { labs_lit = PmOLit True lit }

-- -----------------------------------------------------------------------
-- | Transform a Pat Id into a list of (PmPat Id) -- Note [Translation to PmPat]

translatePat :: Pat Id -> UniqSM PatVec
translatePat pat = case pat of
  WildPat ty         -> (:[]) <$> mkPmVarSM ty
  VarPat  id         -> return [VarAbs id]
  ParPat p           -> translatePat (unLoc p)
  LazyPat p          -> translatePat (unLoc p) -- COMEHERE: We ignore laziness   for now

  BangPat p          -> translatePat (unLoc p) -- COMEHERE: We ignore strictness for now
                                               -- This might affect the divergence checks?
  AsPat lid p -> do
    ps <- translatePat (unLoc p)
    let [va] = coercePmPats ps -- has to be singleton
        g    = GBindAbs [VarAbs (unLoc lid)] (valAbsToPmExpr va)
    return (ps ++ [g])

  SigPatOut p _ty -> translatePat (unLoc p) -- TODO: Use the signature?

  CoPat wrapper p ty -> do
    ps      <- translatePat p
    (xp,xe) <- mkPmId2FormsSM ty {- IS THIS TYPE CORRECT OR IS IT THE OPPOSITE?? -}
    let g = GBindAbs ps $ hsExprToPmExpr $ HsWrap wrapper (unLoc xe)
    return [xp,g]

  -- (n + k)  ===>   x (True <- x >= k) (n <- x-k)
  NPlusKPat n k ge minus -> do
    (xp, xe) <- mkPmId2FormsSM $ idType (unLoc n)
    let ke = noLoc (HsOverLit k)         -- k as located expression
        g1 = GBindAbs [truePmPat]        $ hsExprToPmExpr $ OpApp xe (noLoc ge)    no_fixity ke -- True <- (x >= k)
        g2 = GBindAbs [VarAbs (unLoc n)] $ hsExprToPmExpr $ OpApp xe (noLoc minus) no_fixity ke -- n    <- (x -  k)
    return [xp, g1, g2]

  -- (fun -> pat)   ===>   x (pat <- fun x)
  ViewPat lexpr lpat arg_ty -> do
    (xp,xe) <- mkPmId2FormsSM arg_ty
    ps      <- translatePat (unLoc lpat) -- p translated recursively
    let g  = GBindAbs ps $ hsExprToPmExpr $ HsApp lexpr xe -- p <- f x
    return [xp,g]

  ListPat ps ty Nothing -> do
    foldr (mkListPmPat ty) [nilPmPat ty] <$> translatePatVec (map unLoc ps)

  ListPat lpats elem_ty (Just (pat_ty, to_list)) -> do
    (xp, xe) <- mkPmId2FormsSM pat_ty
    ps       <- translatePatVec (map unLoc lpats) -- list as value abstraction
    let pats = foldr (mkListPmPat elem_ty) [nilPmPat elem_ty] ps
        g  = GBindAbs pats $ hsExprToPmExpr $ HsApp (noLoc to_list) xe -- [...] <- toList x
    return [xp,g]

  ConPatOut { pat_con = L _ (PatSynCon _) } ->
    -- Pattern synonyms have a "matcher" (see Note [Pattern synonym representation] in PatSyn.hs
    -- We should be able to transform (P x y)
    -- to   v (Just (x, y) <- matchP v (\x y -> Just (x,y)) Nothing
    -- That is, a combination of a variable pattern and a guard
    -- But there are complications with GADTs etc, and this isn't done yet
    (:[]) <$> mkPmVarSM (hsPatType pat)

  ConPatOut { pat_con     = L _ (RealDataCon con)
            , pat_arg_tys = arg_tys
            , pat_tvs     = ex_tvs
            , pat_dicts   = dicts
            , pat_args    = ps } -> do
    args <- translateConPatVec arg_tys ex_tvs con ps
    return [ConAbs { cabs_con     = con
                   , cabs_arg_tys = arg_tys
                   , cabs_tvs     = ex_tvs
                   , cabs_dicts   = dicts
                   , cabs_args    = args }]

  NPat lit mb_neg _eq
    | Just _  <- mb_neg -> return [mkNegLitPmPat lit] -- negated literal
    | Nothing <- mb_neg -> return [mkPosLitPmPat lit] -- non-negated literal

  LitPat lit
      -- If it is a string then convert it to a list of characters
    | HsString src s <- lit ->
        foldr (mkListPmPat charTy) [nilPmPat charTy] <$>
          translatePatVec (map (LitPat . HsChar src) (unpackFS s))
    | otherwise -> return [mkLitPmPat lit]

  PArrPat ps ty -> do
    tidy_ps <-translatePatVec (map unLoc ps)
    let fake_con = parrFakeCon (length ps)
    return [ConAbs { cabs_con     = fake_con
                   , cabs_arg_tys = [ty]
                   , cabs_tvs     = []
                   , cabs_dicts   = []
                   , cabs_args    = concat tidy_ps }]

  TuplePat ps boxity tys -> do
    tidy_ps   <- translatePatVec (map unLoc ps)
    let tuple_con = tupleCon (boxityNormalTupleSort boxity) (length ps)
    return [ConAbs { cabs_con     = tuple_con
                   , cabs_arg_tys = tys
                   , cabs_tvs     = []
                   , cabs_dicts   = []
                   , cabs_args    = concat tidy_ps }]

  -- --------------------------------------------------------------------------
  -- Not supposed to happen
  ConPatIn {}      -> panic "Check.translatePat: ConPatIn"
  SplicePat {}     -> panic "Check.translatePat: SplicePat"
  QuasiQuotePat {} -> panic "Check.translatePat: QuasiQuotePat"
  SigPatIn {}      -> panic "Check.translatePat: SigPatIn"

translatePatVec :: [Pat Id] -> UniqSM [PatVec] -- Do not concatenate them (sometimes we need them separately)
translatePatVec pats = mapM translatePat pats

translateConPatVec :: [Type] -> [TyVar] -> DataCon -> HsConPatDetails Id -> UniqSM PatVec
translateConPatVec _univ_tys _ex_tvs _ (PrefixCon ps)   = concat <$> translatePatVec (map unLoc ps)
translateConPatVec _univ_tys _ex_tvs _ (InfixCon p1 p2) = concat <$> translatePatVec (map unLoc [p1,p2])
translateConPatVec  univ_tys  ex_tvs c (RecCon (HsRecFields fs _))
    -- Nothing matched. Make up some fresh term variables
  | null fs        = mkPmVarsSM arg_tys
    -- The data constructor was not defined using record syntax. For the
    -- pattern to be in record syntax it should be empty (e.g. Just {}).
    -- So just like the previous case.
  | null orig_lbls = ASSERT (null matched_lbls) mkPmVarsSM arg_tys
    -- Some of the fields appear, in the original order (there may be holes).
    -- Generate a simple constructor pattern and make up fresh variables for
    -- the rest of the fields
  | matched_lbls `subsetOf` orig_lbls = ASSERT (length orig_lbls == length arg_tys)
      let translateOne (lbl, ty) = case lookup lbl matched_pats of
            Just p  -> translatePat p
            Nothing -> mkPmVarsSM [ty]
      in  concatMapM translateOne (zip orig_lbls arg_tys)
    -- The fields that appear are not in the correct order. Make up fresh
    -- variables for all fields and add guards after matching, to force the
    -- evaluation in the correct order.
  | otherwise = do
      arg_var_pats    <- mkPmVarsSM arg_tys
      translated_pats <- forM matched_pats $ \(x,pat) -> do
        pvec <- translatePat pat
        return (x, pvec)

      let zipped = zip orig_lbls [ x | VarAbs x <- arg_var_pats ] -- [(Name, Id)]
          guards = map (\(name,pvec) -> case lookup name zipped of
                            Just x  -> GBindAbs pvec (PmExprVar x)
                            Nothing -> panic "translateConPatVec: lookup")
                       translated_pats

      return (arg_var_pats ++ guards)
  where
    -- The actual argument types (instantiated)
    arg_tys = dataConInstOrigArgTys c (univ_tys ++ mkTyVarTys ex_tvs)

    -- Some label information
    orig_lbls    = dataConFieldLabels c
    matched_lbls = [ idName id       | L _ (HsRecField (L _ id) _         _) <- fs]
    matched_pats = [(idName id,pat)  | L _ (HsRecField (L _ id) (L _ pat) _) <- fs]

    subsetOf :: Eq a => [a] -> [a] -> Bool
    subsetOf []     _  = True
    subsetOf (_:_)  [] = False
    subsetOf (x:xs) (y:ys)
      | x == y    = subsetOf    xs  ys
      | otherwise = subsetOf (x:xs) ys

translateMatch :: LMatch Id (LHsExpr Id) -> UniqSM (PatVec,[PatVec])
translateMatch (L _ (Match lpats _ grhss)) = do
  pats'   <- concat <$> translatePatVec pats
  guards' <- mapM translateGuards guards
  return (pats', guards')
  where
    extractGuards :: LGRHS Id (LHsExpr Id) -> [GuardStmt Id]
    extractGuards (L _ (GRHS gs _)) = map unLoc gs

    pats   = map unLoc lpats
    guards = map extractGuards (grhssGRHSs grhss)

-- -----------------------------------------------------------------------
-- | Transform source guards (GuardStmt Id) to PmPats (Pattern)

-- A. What to do with lets?
-- B. write a function hsExprToPmExpr for better results? (it's a yes)

translateGuards :: [GuardStmt Id] -> UniqSM PatVec
translateGuards guards = do
  all_guards <- concat <$> mapM translateGuard guards

  let any_unhandled = or [ not (solvable pv expr)
                         | GBindAbs pv expr <- all_guards ]
  if any_unhandled
    then do
      let fake_pats = GBindAbs [truePmPat] (PmExprOther EWildPat)
      return $ (fake_pats : [ p | p@(GBindAbs pv e) <- all_guards, solvable pv e ]) -- all must be GBindAbs
    else return all_guards

  where
    solvable :: PatVec -> PmExpr -> Bool
    solvable pv expr
      | [p] <- pv, VarAbs {} <- p = True  -- Binds to variable? We don't branch (Y)
      | isNotPmExprOther expr     = True  -- The expression is "normal"? We branch but we want that
      | otherwise                 = False -- Otherwise it branches without being useful
-- | Should have been (but is too expressive):
-- translateGuards guards = concat <$> mapM translateGuard guards

translateGuard :: GuardStmt Id -> UniqSM PatVec
translateGuard (BodyStmt e _ _ _) = translateBoolGuard e
translateGuard (LetStmt    binds) = translateLet binds
translateGuard (BindStmt p e _ _) = translateBind p e
translateGuard (LastStmt      {}) = panic "translateGuard LastStmt"
translateGuard (ParStmt       {}) = panic "translateGuard ParStmt"
translateGuard (TransStmt     {}) = panic "translateGuard TransStmt"
translateGuard (RecStmt       {}) = panic "translateGuard RecStmt"

translateLet :: HsLocalBinds Id -> UniqSM PatVec
translateLet _binds = return [] -- NOT CORRECT: A let cannot fail so in a way we
  -- are fine with it but it can bind things which we do not bring in scope.
  -- Hence, they are free while they shouldn't. More constraints would make it
  -- more expressive but omitting some is always safe (Is it? Make sure it is)

translateBind :: LPat Id -> LHsExpr Id -> UniqSM PatVec
translateBind (L _ p) e = do
  ps <- translatePat p
  let expr = lhsExprToPmExpr e
  return [GBindAbs ps expr]

translateBoolGuard :: LHsExpr Id -> UniqSM PatVec
translateBoolGuard e
  | Just _ <- isTrueLHsExpr e = return []
    -- The formal thing to do would be to generate (True <- True)
    -- but it is trivial to solve so instead we give back an empty
    -- PatVec for efficiency
  | otherwise = return [GBindAbs [truePmPat] (lhsExprToPmExpr e)]

{-
%************************************************************************
%*                                                                      *
\subsection{Main Pattern Matching Check}
%*                                                                      *
%************************************************************************
-}

-- ----------------------------------------------------------------------------
-- | Process a vector

process_guards :: UniqSupply -> [PatVec] -> (ValSetAbs, ValSetAbs, ValSetAbs) -- covered, uncovered, eliminated
process_guards _us [] = (Singleton, Empty, Empty) -- No guard == True guard
process_guards us  gs
  | any null gs = (Singleton, Empty, Singleton) -- Contains an empty guard? == it is exhaustive [Too conservative for divergence]
  | otherwise   = go us Singleton gs
  where
    go _usupply missing []       = (Empty, missing, Empty)
    go  usupply missing (gv:gvs) = (mkUnion cs css, uss, mkUnion ds dss)
      where
        (us1, us2, us3, us4) = splitUniqSupply4 usupply

        cs = covered   us1 Singleton gv missing
        us = uncovered us2 Empty     gv missing
        ds = divergent us3 Empty     gv missing

        (css, uss, dss) = go us4 us gvs

-- ----------------------------------------------------------------------------
-- | Getting some more uniques

-- Do not want an infinite list
splitUniqSupply3 :: UniqSupply -> (UniqSupply, UniqSupply, UniqSupply)
splitUniqSupply3 us = (us1, us2, us3)
  where
    (us1, us') = splitUniqSupply us
    (us2, us3) = splitUniqSupply us'

-- Do not want an infinite list
splitUniqSupply4 :: UniqSupply -> (UniqSupply, UniqSupply, UniqSupply, UniqSupply)
splitUniqSupply4 us = (us1, us2, us3, us4)
  where
    (us1, us2, us') = splitUniqSupply3 us
    (us3, us4)      = splitUniqSupply us'

getUniqueSupplyM3 :: MonadUnique m => m (UniqSupply, UniqSupply, UniqSupply)
getUniqueSupplyM3 = liftM3 (,,) getUniqueSupplyM getUniqueSupplyM getUniqueSupplyM

-- ----------------------------------------------------------------------------
-- | Basic utilities

-- | Get the type out of a PmPat. For guard patterns (ps <- e) we use the type
-- of the first (or the single -WHEREVER IT IS- valid to use?) pattern
pmPatType :: PmPat abs -> Type
pmPatType (GBindAbs { gabs_pats = pats })
  = ASSERT (patVecArity pats == 1) (pmPatType p)
  where Just p = find ((==1) . patternArity) pats
pmPatType (ConAbs { cabs_con = con, cabs_arg_tys = tys })
  = mkTyConApp (dataConTyCon con) tys
pmPatType (VarAbs { vabs_id  = x }) = idType x
pmPatType (LitAbs { labs_lit = l }) = pmLitType l

mkOneConFull :: Id -> UniqSupply -> DataCon -> (ValAbs, [PmConstraint])
--  *  x :: T tys, where T is an algebraic data type
--     NB: in the case of a data familiy, T is the *representation* TyCon
--     e.g.   data instance T (a,b) = T1 a b
--       leads to
--            data TPair a b = T1 a b  -- The "representation" type
--       It is TPair, not T, that is given to mkOneConFull
--
--  * 'con' K is a constructor of data type T
--
-- After instantiating the universal tyvars of K we get
--          K tys :: forall bs. Q => s1 .. sn -> T tys
--
-- Results: ValAbs:          K (y1::s1) .. (yn::sn)
--          [PmConstraint]:  Q, x ~ K y1..yn

mkOneConFull x usupply con = (con_abs, constraints)
  where

    (usupply1, usupply2, usupply3) = splitUniqSupply3 usupply

    res_ty = idType x -- res_ty == TyConApp (dataConTyCon (cabs_con cabs)) (cabs_arg_tys cabs)
    (univ_tvs, ex_tvs, eq_spec, thetas, arg_tys, _dc_res_ty) = dataConFullSig con
    data_tc = dataConTyCon con   -- The representation TyCon
    tc_args = case splitTyConApp_maybe res_ty of
                 Just (tc, tys) -> ASSERT( tc == data_tc ) tys
                 Nothing -> pprPanic "mkOneConFull: Not a type application" (ppr res_ty)

    subst1  = zipTopTvSubst univ_tvs tc_args

    -- IS THE SECOND PART OF THE TUPLE THE SET OF FRESHENED EXISTENTIALS? MUST BE
    (subst, ex_tvs') = cloneTyVarBndrs subst1 ex_tvs usupply1

    arguments  = mkConVars usupply2 (substTys subst arg_tys)      -- Constructor arguments (value abstractions)
    theta_cs   = substTheta subst (eqSpecPreds eq_spec ++ thetas) -- All the constraints bound by the constructor

    evvars = zipWith (nameType "oneCon") (listSplitUniqSupply usupply3) theta_cs
    con_abs    = ConAbs { cabs_con     = con
                        , cabs_arg_tys = tc_args
                        , cabs_tvs     = ex_tvs'
                        , cabs_dicts   = evvars
                        , cabs_args    = arguments }

    constraints = [ TmConstraint x (valAbsToPmExpr con_abs)
                  , TyConstraint evvars ] -- Both term and type constraints

mkConVars :: UniqSupply -> [Type] -> [ValAbs] -- ys, fresh with the given type
mkConVars usupply tys = map (uncurry mkPmVar) $
  zip (listSplitUniqSupply usupply) tys

tailValSetAbs :: ValSetAbs -> ValSetAbs
tailValSetAbs Empty               = Empty
tailValSetAbs Singleton           = panic "tailValSetAbs: Singleton"
tailValSetAbs (Union vsa1 vsa2)   = tailValSetAbs vsa1 `mkUnion` tailValSetAbs vsa2
tailValSetAbs (Constraint cs vsa) = cs `mkConstraint` tailValSetAbs vsa
tailValSetAbs (Cons _ vsa)        = vsa -- actual work

wrapK :: DataCon -> ValSetAbs -> ValSetAbs
wrapK con = wrapK_aux (dataConSourceArity con) emptylist
  where
    wrapK_aux :: Int -> DList ValAbs -> ValSetAbs -> ValSetAbs
    wrapK_aux _ _    Empty               = Empty
    wrapK_aux 0 args vsa                 = ConAbs { cabs_con = con, cabs_arg_tys = [] {- SHOULD THESE BE EMPTY? -}
                                                  , cabs_tvs = [], cabs_dicts = []
                                                  , cabs_args = toList args } `mkCons` vsa
    wrapK_aux _ _    Singleton           = panic "wrapK: Singleton"
    wrapK_aux n args (Cons vs vsa)       = wrapK_aux (n-1) (args `snoc` vs) vsa
    wrapK_aux n args (Constraint cs vsa) = cs `mkConstraint` wrapK_aux n args vsa
    wrapK_aux n args (Union vsa1 vsa2)   = wrapK_aux n args vsa1 `mkUnion` wrapK_aux n args vsa2

newtype DList a = DL { unDL :: [a] -> [a] }

toList :: DList a -> [a]
toList = ($[]) . unDL
{-# INLINE toList #-}

emptylist :: DList a
emptylist = DL id
{-# INLINE emptylist #-}

infixl `snoc`
snoc :: DList a -> a -> DList a
snoc xs x = DL (unDL xs . (x:))
{-# INLINE snoc #-}

-- ----------------------------------------------------------------------------
-- | Smart constructors (NB: An empty value set can only be represented as `Empty')

mkConstraint :: [PmConstraint] -> ValSetAbs -> ValSetAbs
-- The smart constructor for Constraint (maintains VsaInvariant)
mkConstraint _cs Empty                = Empty
mkConstraint cs1 (Constraint cs2 vsa) = Constraint (cs1++cs2) vsa -- careful about associativity
mkConstraint cs  other_vsa            = Constraint cs other_vsa

mkUnion :: ValSetAbs -> ValSetAbs -> ValSetAbs
-- The smart constructor for Union (maintains VsaInvariant)
mkUnion Empty vsa = vsa
mkUnion vsa Empty = vsa
mkUnion vsa1 vsa2 = Union vsa1 vsa2

mkCons :: ValAbs -> ValSetAbs -> ValSetAbs
mkCons _ Empty = Empty
mkCons va vsa  = Cons va vsa

valAbsToPmExpr :: ValAbs -> PmExpr
valAbsToPmExpr (ConAbs { cabs_con  = c
                       , cabs_args = ps }) = PmExprCon c (map valAbsToPmExpr ps)
valAbsToPmExpr (VarAbs x)                  = PmExprVar x
valAbsToPmExpr (LitAbs l)                  = PmExprLit l

no_fixity :: a -- CHECKME: Can we retrieve the fixity from the operator name?
no_fixity = panic "Check: no fixity"

-- Get all constructors in the family (including given)
allConstructors :: DataCon -> [DataCon]
allConstructors = tyConDataCons . dataConTyCon

mkPmVar :: UniqSupply -> Type -> PmPat abs
mkPmVar usupply ty = VarAbs (mkPmId usupply ty)

mkPmVarSM :: Type -> UniqSM (PmPat abs)
mkPmVarSM ty = flip mkPmVar ty <$> getUniqueSupplyM

mkPmVarsSM :: [Type] -> UniqSM [PmPat abs]
mkPmVarsSM tys = mapM mkPmVarSM tys

mkPmId :: UniqSupply -> Type -> Id
mkPmId usupply ty = mkLocalId name ty
  where
    unique  = uniqFromSupply usupply
    occname = mkVarOccFS (fsLit (show unique))
    name    = mkInternalName unique occname noSrcSpan

mkPmId2FormsSM :: Type -> UniqSM (PmPat abs, LHsExpr Id)
mkPmId2FormsSM ty = do
  us <- getUniqueSupplyM
  let x = mkPmId us ty
  return (VarAbs x, noLoc (HsVar x))

-- -----------------------------------------------------------------------
-- | Types and constraints

newEvVar :: Name -> Type -> EvVar
newEvVar name ty = mkLocalId name (toTcType ty)

nameType :: String -> UniqSupply -> Type -> EvVar
nameType name usupply ty = newEvVar idname ty
  where
    unique  = uniqFromSupply usupply
    occname = mkVarOccFS (fsLit (name++"_"++show unique))
    idname  = mkInternalName unique occname noSrcSpan

valSetAbsToList :: ValSetAbs -> [([ValAbs],[PmConstraint])]
valSetAbsToList Empty               = []
valSetAbsToList (Union vsa1 vsa2)   = valSetAbsToList vsa1 ++ valSetAbsToList vsa2
valSetAbsToList Singleton           = [([],[])]
valSetAbsToList (Constraint cs vsa) = [(vs, cs ++ cs') | (vs, cs') <- valSetAbsToList vsa]
valSetAbsToList (Cons va vsa)       = [(va:vs, cs) | (vs, cs) <- valSetAbsToList vsa]

splitConstraints :: [PmConstraint] -> ([EvVar], [(Id, PmExpr)], Maybe Id) -- Type constraints, term constraints, forced variables
splitConstraints [] = ([],[],Nothing)
splitConstraints (c : rest)
  = case c of
      TyConstraint cs  -> (cs ++ ty_cs, tm_cs, bot_cs)
      TmConstraint x e -> (ty_cs, (x,e):tm_cs, bot_cs)
      BtConstraint cs  -> ASSERT (isNothing bot_cs) (ty_cs, tm_cs, Just cs) -- NB: Only one x ~ _|_
  where
    (ty_cs, tm_cs, bot_cs) = splitConstraints rest

{-
%************************************************************************
%*                                                                      *
\subsection{The oracles}
%*                                                                      *
%************************************************************************
-}

-- Same interface to check all kinds of different constraints like in the paper
satisfiable :: [PmConstraint] -> PmM (Maybe PmVarEnv) -- Bool -- Give back the substitution for pretty-printing
satisfiable constraints = do
  let (ty_cs, tm_cs, bot_cs) = splitConstraints constraints
  sat <- tyOracle (listToBag ty_cs)
  case sat of
    True -> case tmOracle tm_cs of
      Left _eq -> return Nothing
      Right (residual, (expr_eqs, mapping)) ->
        let answer = isNothing bot_cs || -- just term eqs ==> OK (success)
                     notNull residual || -- something we cannot reason about -- gives inaccessible while it shouldn't
                     notNull expr_eqs || -- something we cannot reason about
                     notForced (fromJust bot_cs) mapping -- Was not evaluated before
        in  return $ if answer then Just mapping
                               else Nothing
    False -> return Nothing -- inconsistent type constraints

-- | For coverage & laziness
-- True  => Set may be non-empty
-- False => Set is definitely empty
-- Fact:  anySatValSetAbs s = pruneValSetAbs /= Empty
--        (but we implement it directly for efficiency)
anySatValSetAbs :: ValSetAbs -> PmM Bool
anySatValSetAbs = anySatValSetAbs' []
  where
    anySatValSetAbs' :: [PmConstraint] -> ValSetAbs -> PmM Bool
    anySatValSetAbs' _cs Empty                = return False
    anySatValSetAbs'  cs (Union vsa1 vsa2)    = anySatValSetAbs' cs vsa1 `orM` anySatValSetAbs' cs vsa2
    anySatValSetAbs'  cs Singleton            = liftM isJust (satisfiable cs)
    anySatValSetAbs'  cs (Constraint cs' vsa) = anySatValSetAbs' (cs' ++ cs) vsa -- in front for faster concatenation
    anySatValSetAbs'  cs (Cons _va vsa)       = anySatValSetAbs' cs vsa

    orM m1 m2 = m1 >>= \x ->
      if x then return True else m2

-- | For exhaustiveness check
-- Prune the set by removing unsatisfiable paths
pruneValSetAbs :: ValSetAbs -> PmM ValSetAbs
pruneValSetAbs = pruneValSetAbs' []
  where
    pruneValSetAbs' :: [PmConstraint] -> ValSetAbs -> PmM ValSetAbs
    pruneValSetAbs' _cs Empty = return Empty
    pruneValSetAbs'  cs (Union vsa1 vsa2) = do
      mb_vsa1 <- pruneValSetAbs' cs vsa1
      mb_vsa2 <- pruneValSetAbs' cs vsa2
      return $ mkUnion mb_vsa1 mb_vsa2
    pruneValSetAbs' cs Singleton = do
      sat <- liftM isJust (satisfiable cs)
      return $ if sat then mkConstraint cs Singleton -- always leave them at the end
                      else Empty
    pruneValSetAbs' cs (Constraint cs' vsa)
      = pruneValSetAbs' (cs' ++ cs) vsa -- in front for faster concatenation
    pruneValSetAbs' cs (Cons va vsa) = do
      mb_vsa <- pruneValSetAbs' cs vsa
      return $ mkCons va mb_vsa

-- It checks whether a set of type constraints is satisfiable.
tyOracle :: Bag EvVar -> PmM Bool
tyOracle evs
  = do { ((_warns, errs), res) <- initTcDsForSolver $ tcCheckSatisfiability evs
       ; case res of
            Just sat -> return sat
            Nothing  -> pprPanic "tyOracle" (vcat $ pprErrMsgBagWithLoc errs) }

{-
Note [Pattern match check give up]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
A simple example is trac #322:
\begin{verbatim}
  f :: Maybe Int -> Int
  f 1 = 1
  f Nothing = 2
  f _ = 3
\end{verbatim}
-}

{-
%************************************************************************
%*                                                                      *
\subsection{Sanity Checks}
%*                                                                      *
%************************************************************************
-}

type PmArity = Int

patVecArity :: PatVec -> PmArity
patVecArity = sum . map patternArity

patternArity :: Pattern -> PmArity
patternArity (GBindAbs {}) = 0
patternArity (ConAbs   {}) = 1
patternArity (VarAbs   {}) = 1
patternArity (LitAbs   {}) = 1

-- -- Should get a default value because an empty set has any arity
-- -- (We have no value vector abstractions to see)
-- vsaArity :: PmArity -> ValSetAbs -> PmArity
-- vsaArity  arity Empty = arity
-- vsaArity _arity vsa   = ASSERT (allTheSame arities) (head arities)
--   where arities = vsaArities vsa
-- 
-- vsaArities :: ValSetAbs -> [PmArity] -- Arity for every path. INVARIANT: All the same
-- vsaArities Empty              = []
-- vsaArities (Union vsa1 vsa2)  = vsaArities vsa1 ++ vsaArities vsa2
-- vsaArities Singleton          = [0]
-- vsaArities (Constraint _ vsa) = vsaArities vsa
-- vsaArities (Cons _ vsa)       = [1 + arity | arity <- vsaArities vsa]
-- 
-- allTheSame :: Eq a => [a] -> Bool
-- allTheSame []     = True
-- allTheSame (x:xs) = all (==x) xs
-- 
-- sameArity :: PatVec -> ValSetAbs -> Bool
-- sameArity pv vsa = vsaArity pv_a vsa == pv_a
--   where pv_a = patVecArity pv

{-
%************************************************************************
%*                                                                      *
\subsection{Heart of the algorithm: Function patVectProc}
%*                                                                      *
%************************************************************************
-}

patVectProc :: (PatVec, [PatVec]) -> ValSetAbs -> PmM (Bool, Bool, ValSetAbs) -- Covers? Forces? U(n+1)?
patVectProc (vec,gvs) vsa = do
  us <- getUniqueSupplyM
  let (c_def, u_def, d_def) = process_guards us gvs -- default (the continuation)
  (usC, usU, usD) <- getUniqueSupplyM3
  mb_c <- anySatValSetAbs (covered   usC c_def vec vsa)
  mb_d <- anySatValSetAbs (divergent usD d_def vec vsa)
  let vsa' = uncovered usU u_def vec vsa
  return (mb_c, mb_d, vsa')

-- ----------------------------------------------------------------------------
-- | Main function 1 (covered)

--THE SECOND ARGUMENT IS THE CONT, WHAT TO PLUG AT THE END (GUARDS)
covered :: UniqSupply -> ValSetAbs -> PatVec -> ValSetAbs -> ValSetAbs

-- CEmpty (New case because of representation)
covered _usupply _gvsa _vec Empty = Empty

-- CNil
covered _usupply gvsa [] Singleton = gvsa

-- Pure induction (New case because of representation)
covered usupply gvsa vec (Union vsa1 vsa2)
  = covered usupply1 gvsa vec vsa1 `mkUnion` covered usupply2 gvsa vec vsa2
  where (usupply1, usupply2) = splitUniqSupply usupply

-- Pure induction (New case because of representation)
covered usupply gvsa vec (Constraint cs vsa)
  = cs `mkConstraint` covered usupply gvsa vec vsa

-- CGuard
covered usupply gvsa (pat@(GBindAbs p e) : ps) vsa
  = cs `mkConstraint` (tailValSetAbs $ covered usupply2 gvsa (p++ps) (VarAbs y `mkCons` vsa))
  where
    (usupply1, usupply2) = splitUniqSupply usupply
    y  = mkPmId usupply1 (pmPatType pat)
    cs = [TmConstraint y e]

-- CVar
covered usupply gvsa (VarAbs x : ps) (Cons va vsa)
  = va `mkCons` (cs `mkConstraint` covered usupply gvsa ps vsa)
  where cs = [TmConstraint x (valAbsToPmExpr va)]

-- | CLitCon | --
covered usupply gvsa ((LitAbs { labs_lit = l }) : ps)
                     (Cons cabs@(ConAbs {}) vsa)
  | PmOLit {} <- l = cabs `mkCons` (cs `mkConstraint` covered usupply2 gvsa ps vsa)
  | otherwise      = panic "covered: CLitCon"
  where
    (usupply1, usupply2) = splitUniqSupply usupply
    y  = mkPmId usupply1 (pmPatType cabs)
    cs = [ TmConstraint y (PmExprLit l)
         , TmConstraint y (valAbsToPmExpr cabs) ]

-- | CConLit | --
covered usupply gvsa (cabs@(ConAbs { cabs_con = con }) : ps)
                     (Cons lit_abs@(LitAbs l) vsa)
  | PmOLit {} <- l = covered usupply3 gvsa (cabs : ps) (con_abs `mkCons` (cs `mkConstraint` vsa))
  | otherwise      = panic "covered: CConLit"
  where
    (usupply1, usupply2, usupply3) = splitUniqSupply3 usupply
    y                 = mkPmId usupply1 (pmPatType cabs)
    (con_abs, all_cs) = mkOneConFull y usupply2 con
    cs = TmConstraint y (valAbsToPmExpr lit_abs) : all_cs

-- CConCon
covered usupply gvsa (ConAbs { cabs_con = c1, cabs_args = args1 } : ps)
               (Cons (ConAbs { cabs_con = c2, cabs_args = args2 }) vsa)
  | c1 /= c2  = Empty
  | otherwise = wrapK c1 (covered usupply gvsa (args1 ++ ps) (foldr mkCons vsa args2))

-- | CLitLit | --
covered usupply gvsa    (LitAbs { labs_lit = l1 } : ps)
               (Cons va@(LitAbs { labs_lit = l2 }) vsa)
  | l1 /= l2  = Empty
  | otherwise = va `mkCons` covered usupply gvsa ps vsa

-- CConVar
covered usupply gvsa (cabs@(ConAbs { cabs_con = con }) : ps) (Cons (VarAbs x) vsa)
  = covered usupply2 gvsa (cabs : ps) (con_abs `mkCons` (all_cs `mkConstraint` vsa))
  where
    (usupply1, usupply2) = splitUniqSupply usupply
    (con_abs, all_cs)    = mkOneConFull x usupply1 con -- if cs empty do not do it

-- | CLitVar | --
covered usupply gvsa (lpat@(LitAbs { labs_lit = lit }) : ps) (Cons (VarAbs x) vsa)
  = covered usupply gvsa (lpat : ps) (lit_abs `mkCons` (cs `mkConstraint` vsa))
  where
    lit_abs = LitAbs { labs_lit = lit }
    cs      = [TmConstraint x (PmExprLit lit)]

covered _usupply _gvsa (ConAbs {} : _) Singleton  = panic "covered: length mismatch: constructor-sing"
covered _usupply _gvsa (VarAbs _  : _) Singleton  = panic "covered: length mismatch: variable-sing"
covered _usupply _gvsa (LitAbs {} : _) Singleton  = panic "covered: length mismatch: literal-sing"
covered _usupply _gvsa []              (Cons _ _) = panic "covered: length mismatch: Cons"

-- ----------------------------------------------------------------------------
-- | Main function 2 (uncovered)

uncovered :: UniqSupply -> ValSetAbs -> PatVec -> ValSetAbs -> ValSetAbs

-- UEmpty (New case because of representation)
uncovered _usupply _gvsa _vec Empty = Empty

-- UNil
uncovered _usupply gvsa [] Singleton = gvsa

-- Pure induction (New case because of representation)
uncovered usupply gvsa vec (Union vsa1 vsa2)
  = uncovered usupply1 gvsa vec vsa1 `mkUnion` uncovered usupply2 gvsa vec vsa2
  where (usupply1, usupply2) = splitUniqSupply usupply

-- Pure induction (New case because of representation)
uncovered usupply gvsa vec (Constraint cs vsa)
  = cs `mkConstraint` uncovered usupply gvsa vec vsa

-- UGuard
uncovered usupply gvsa (pat@(GBindAbs p e) : ps) vsa
  = cs `mkConstraint` (tailValSetAbs $ uncovered usupply2 gvsa (p++ps) (VarAbs y `mkCons` vsa))
  where
    (usupply1, usupply2) = splitUniqSupply usupply
    y  = mkPmId usupply1 (pmPatType pat)
    cs = [TmConstraint y e]

-- UVar
uncovered usupply gvsa (VarAbs x : ps) (Cons va vsa)
  = va `mkCons` (cs `mkConstraint` uncovered usupply gvsa ps vsa)
  where cs = [TmConstraint x (valAbsToPmExpr va)]

-- | ULitCon | --
uncovered usupply gvsa (LitAbs { labs_lit = lit } : ps)
                       (Cons cabs@(ConAbs {}) vsa)
  = uncovered usupply2 gvsa (VarAbs y : ps) (mkCons cabs (mkConstraint cs vsa))
  where
    (usupply1, usupply2) = splitUniqSupply usupply
    y  = mkPmId usupply1 (pmPatType cabs)
    cs = [TmConstraint y (PmExprLit lit)]

-- | UConLit | --
uncovered usupply gvsa (cabs@(ConAbs {}) : ps)
                       (Cons va@(LitAbs {}) vsa)
  = uncovered usupply2 gvsa (cabs : ps) (mkCons (VarAbs y) (mkConstraint cs vsa))
  where
    (usupply1, usupply2) = splitUniqSupply usupply
    y  = mkPmId usupply1 (pmPatType cabs)
    cs = [TmConstraint y (valAbsToPmExpr va)]

-- UConCon
uncovered usupply gvsa (ConAbs { cabs_con = c1, cabs_args = args1 } : ps)
            (Cons cabs@(ConAbs { cabs_con = c2, cabs_args = args2 }) vsa)
  | c1 /= c2  = cabs `mkCons` vsa
  | otherwise = wrapK c1 (uncovered usupply gvsa (args1 ++ ps) (foldr mkCons vsa args2))

-- | ULitLit | --
uncovered usupply gvsa (LitAbs { labs_lit = l1 } : ps)
                       (Cons va@(LitAbs { labs_lit = l2 }) vsa)
  | l1 /= l2  = va `mkCons` vsa
  | otherwise = va `mkCons` uncovered usupply gvsa ps vsa

-- UConVar
uncovered usupply gvsa (cabs@(ConAbs { cabs_con = con }) : ps) (Cons (VarAbs x) vsa)
  = uncovered usupply2 gvsa (cabs : ps) inst_vsa -- instantiated vsa [x \mapsto K_j ys]
  where
    -- Some more uniqSupplies
    (usupply1, usupply2) = splitUniqSupply usupply

    -- Unfold the variable to all possible constructor patterns
    uniqs_cons = listSplitUniqSupply usupply1 `zip` allConstructors con
    cons_cs    = map (uncurry (mkOneConFull x)) uniqs_cons
    add_one (va,cs) valset = valset `mkUnion` (va `mkCons` (cs `mkConstraint` vsa))
    inst_vsa   = foldr add_one Empty cons_cs

-- | ULitVar | --
uncovered usupply gvsa (labs@(LitAbs { labs_lit = lit }) : ps)
                       (Cons (VarAbs x) vsa)
  = mkUnion (uncovered usupply2 gvsa (labs : ps) (LitAbs lit `mkCons` (match_cs `mkConstraint` vsa))) -- matching case
            (non_match_cs `mkConstraint` (VarAbs x `mkCons` vsa))                       -- non-matching case
  where
    (usupply1, usupply2) = splitUniqSupply usupply

    y  = mkPmId usupply1 (pmPatType labs)

    match_cs     = [ TmConstraint x (PmExprLit lit)]
    non_match_cs = [ TmConstraint y falsePmExpr
                   , TmConstraint y (PmExprEq (PmExprVar x) (PmExprLit lit)) ]

uncovered _usupply _gvsa (ConAbs {} : _) Singleton  = panic "uncovered: length mismatch: constructor-sing"
uncovered _usupply _gvsa (VarAbs _  : _) Singleton  = panic "uncovered: length mismatch: variable-sing"
uncovered _usupply _gvsa (LitAbs {} : _) Singleton  = panic "uncovered: length mismatch: literal-sing"
uncovered _usupply _gvsa []              (Cons _ _) = panic "uncovered: length mismatch: Cons"

-- ----------------------------------------------------------------------------
-- | Main function 3 (divergent)

divergent :: UniqSupply -> ValSetAbs -> PatVec -> ValSetAbs -> ValSetAbs

-- DEmpty (New case because of representation)
divergent _usupply _gvsa _vec Empty = Empty

-- DNil
divergent _usupply gvsa [] Singleton = gvsa

-- Pure induction (New case because of representation)
divergent usupply gvsa vec (Union vsa1 vsa2) = divergent usupply1 gvsa vec vsa1 `mkUnion` divergent usupply2 gvsa vec vsa2
  where (usupply1, usupply2) = splitUniqSupply usupply

-- Pure induction (New case because of representation)
divergent usupply gvsa vec (Constraint cs vsa) = cs `mkConstraint` divergent usupply gvsa vec vsa

-- DGuard
divergent usupply gvsa (pat@(GBindAbs p e) : ps) vsa
  = cs `mkConstraint` (tailValSetAbs $ divergent usupply2 gvsa (p++ps) (VarAbs y `mkCons` vsa))
  where
    (usupply1, usupply2) = splitUniqSupply usupply
    y  = mkPmId usupply1 (pmPatType pat)
    cs = [TmConstraint y e]

-- DVar
divergent usupply gvsa (VarAbs x : ps) (Cons va vsa)
  = va `mkCons` (cs `mkConstraint` divergent usupply gvsa ps vsa)
  where cs = [TmConstraint x (valAbsToPmExpr va)]

-- | DLitCon | --
divergent usupply gvsa ((LitAbs { labs_lit = l }) : ps)
                       (Cons cabs@(ConAbs {}) vsa)
  | PmOLit {} <- l = cabs `mkCons` (cs `mkConstraint` divergent usupply2 gvsa ps vsa)
  | otherwise      = panic "divergent: DLitCon"
  where
    (usupply1, usupply2) = splitUniqSupply usupply
    y  = mkPmId usupply1 (pmPatType cabs)
    cs = [ TmConstraint y (PmExprLit l)
         , TmConstraint y (valAbsToPmExpr cabs) ]

-- | DConLit | --
-- IT WILL LOOK LIKE FORCED AT FIRST BUT I HOPE THE SOLVER FIXES THIS
divergent usupply gvsa (cabs@(ConAbs { cabs_con = con }) : ps)
                       (Cons lit_abs@(LitAbs l) vsa)
  | PmOLit {} <- l = divergent usupply3 gvsa (cabs : ps) (con_abs `mkCons` (cs `mkConstraint` vsa))
  | otherwise      = panic "divergent: DConLit"
  where
    (usupply1, usupply2, usupply3) = splitUniqSupply3 usupply
    y                 = mkPmId usupply1 (pmPatType cabs)
    (con_abs, all_cs) = mkOneConFull y usupply2 con
    cs = TmConstraint y (valAbsToPmExpr lit_abs) : all_cs

-- DConCon
divergent usupply gvsa (ConAbs { cabs_con = c1, cabs_args = args1 } : ps)
                 (Cons (ConAbs { cabs_con = c2, cabs_args = args2 }) vsa)
  | c1 /= c2  = Empty
  | otherwise = wrapK c1 (divergent usupply gvsa (args1 ++ ps) (foldr mkCons vsa args2))

-- | DLitLit | --
divergent usupply gvsa (LitAbs { labs_lit = l1 } : ps)
                       (Cons va@(LitAbs { labs_lit = l2 }) vsa)
  | l1 /= l2  = Empty
  | otherwise = va `mkCons` divergent usupply gvsa ps vsa

-- DConVar [NEEDS WORK]
divergent usupply gvsa (cabs@(ConAbs { cabs_con = con }) : ps) (Cons (VarAbs x) vsa)
  = mkUnion (VarAbs x `mkCons` mkConstraint [BtConstraint x] vsa)
            (divergent usupply2 gvsa (cabs : ps) (con_abs `mkCons` (all_cs `mkConstraint` vsa)))
  where
    (usupply1, usupply2) = splitUniqSupply usupply
    (con_abs, all_cs)    = mkOneConFull x usupply1 con -- if cs empty do not do it

-- | DLitVar | --
divergent usupply gvsa (lpat@(LitAbs { labs_lit = lit }) : ps) (Cons (VarAbs x) vsa)
  = mkUnion (VarAbs x `mkCons` mkConstraint [BtConstraint x] vsa)
            (divergent usupply gvsa (lpat : ps) (lit_abs `mkCons` (cs `mkConstraint` vsa)))
  where
    lit_abs = LitAbs { labs_lit = lit }
    cs      = [TmConstraint x (PmExprLit lit)]

divergent _usupply _gvsa (ConAbs {} : _) Singleton  = panic "divergent: length mismatch: constructor-sing"
divergent _usupply _gvsa (VarAbs _  : _) Singleton  = panic "divergent: length mismatch: variable-sing"
divergent _usupply _gvsa (LitAbs {} : _) Singleton  = panic "divergent: length mismatch: literal-sing"
divergent _usupply _gvsa []              (Cons _ _) = panic "divergent: length mismatch: Cons"

{-
%************************************************************************
%*                                                                      *
\subsection{Pretty Printing}
%*                                                                      *
%************************************************************************
-}

pprUncovered :: [([ValAbs],[PmConstraint])] -> SDoc
pprUncovered vsa = vcat (map pprOne vsa)
  where
    pprOne (vs, cs) = ppr vs <+> ptext (sLit "|>") <+> ppr cs

instance Outputable PmConstraint where
  ppr (TmConstraint x expr) = ppr x <+> equals <+> ppr expr
  ppr (TyConstraint theta)  = pprSet $ map idType theta
  ppr (BtConstraint x)      = braces (ppr x <+> ptext (sLit "~") <+> ptext (sLit "_|_"))

instance Outputable (PmPat abs) where
  ppr (GBindAbs pats expr)          = ppr pats <+> ptext (sLit "<-") <+> ppr expr
  ppr (ConAbs { cabs_con  = con
              , cabs_args = args }) = sep [ppr con, pprWithParens args]
  ppr (VarAbs x)                    = ppr x
  ppr (LitAbs l)                    = ppr l

instance Outputable ValSetAbs where
  ppr = pprValSetAbs

pprWithParens :: [PmPat abs] -> SDoc
pprWithParens pats = sep (map paren_if_needed pats)
  where paren_if_needed p | ConAbs { cabs_args = args } <- p, not (null args)  = parens (ppr p)
                          | GBindAbs ps _               <- p, not (null ps)    = parens (ppr p)
                          | LitAbs l                    <- p, isNegatedPmLit l = parens (ppr p)
                          | otherwise = ppr p

pprValSetAbs :: ValSetAbs -> SDoc
pprValSetAbs = hang (ptext (sLit "Set:")) 2 . vcat . map print_vec . valSetAbsToList
  where
    print_vec (vec, cs) =
      let (ty_cs, tm_cs, bots) = splitConstraints cs
      in  hang (ptext (sLit "vector:") <+> ppr vec <+> ptext (sLit "|>")) 2 $
            vcat [ ptext (sLit "type_cs:") <+> pprSet (map idType ty_cs)
                 , ptext (sLit "term_cs:") <+> ppr tm_cs
                 , ptext (sLit "bottoms:") <+> ppr bots ]

pprSet :: Outputable id => [id] -> SDoc
pprSet lits = braces $ sep $ punctuate comma $ map ppr lits


