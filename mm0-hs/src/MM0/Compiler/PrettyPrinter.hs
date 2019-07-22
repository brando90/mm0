module MM0.Compiler.PrettyPrinter (PP, doc, dlift, ppExpr, render, render',
  ppExpr', (<+>), unifyErr, getStat, ppMVar, ppExprCyc, ppStmt, ppBinder,
  ppDecl) where

import Control.Applicative
import Control.Concurrent.STM
import Control.Monad.State
import Data.Void
import Data.List (elemIndex)
import Data.Maybe
import Data.Functor
import Data.Foldable
import Data.Text.Prettyprint.Doc hiding (lparen, rparen)
import Data.Text.Prettyprint.Doc.Render.Text
import qualified Data.HashMap.Strict as H
import qualified Data.Vector as V
import qualified Data.Vector.Mutable.Dynamic as VD
import qualified Data.Text as T
import System.IO.Unsafe
import MM0.Compiler.AST
import MM0.Compiler.Env
import MM0.FrontEnd.MathParser (appPrec)

data PP = PP {
  _lTerminate :: Bool,
  _rTerminate :: Bool,
  small :: Bool,
  doc :: Doc Void }

dlift :: Doc Void -> PP
dlift = PP False False False

word :: T.Text -> PP
word = PP False False True . pretty

dmap :: (Doc Void -> Doc Void) -> PP -> PP
dmap f (PP l r s e) = PP l r s (f e)

surround' :: Doc Void -> PP -> PP -> PP
surround' x (PP l _ _ dl) (PP _ r _ dr) = PP l r False (dl <> x <> dr)

(<<>>) :: PP -> PP -> PP
(<<>>) (PP l lr _ dl) (PP rl r _ dr) = PP l r False $
  dl <> (if lr || rl then softline' else softline) <> dr

-- (<<|>>) :: PP -> PP -> PP
-- (<<|>>) (PP l lr _ dl) (PP rl r _ dr) = PP l r False $
--   dl <> (if lr || rl then line' else line) <> dr

render' :: Doc Void -> T.Text
render' = renderStrict . layoutPretty defaultLayoutOptions

render :: PP -> T.Text
render = render' . doc

ppExpr' :: LispVal -> ElabM T.Text
ppExpr' = fmap render . ppExpr

unifyErr :: LispVal -> LispVal -> ElabM PP
unifyErr e1 e2 = liftA2
  (\p1 p2 -> dlift $ sep ["failed to unify:", doc p1, flatAlt "  =?=" "=?=", doc p2])
  (ppExpr e1) (ppExpr e2)

ppExpr :: LispVal -> ElabM PP
ppExpr v = do env <- get; liftIO $ ppExpr1 False env v

ppExprCyc :: LispVal -> ElabM PP
ppExprCyc v = do env <- get; liftIO $ ppExpr1 True env v

ppExpr1 :: Bool -> Env -> LispVal -> IO PP
ppExpr1 cyc env = \v ->
  ppExpr2 (if cyc then Just [] else Nothing) (Prec 0) v where

  delims = pDelims (ePE env)

  token :: Token -> PP
  token tk =
    let l = delimVal delims (T.head tk)
        r = delimVal delims (T.last tk) in
    PP (isRightDelim l) (isLeftDelim r) True $ pretty tk

  lparen = token "("
  rparen = token ")"

  ppExpr2 :: Maybe [TVar LispVal] -> Prec -> LispVal -> IO PP
  ppExpr2 ctx tgt (Ref g) = case ctx of
    Nothing -> readTVarIO g >>= ppExpr2 Nothing tgt
    Just l -> case elemIndex g l of
      Nothing -> dmap (enclose "<" ">") <$> (readTVarIO g >>= ppExpr2 (Just (g : l)) tgt)
      Just n -> return $ dlift $ "#" <> pretty n
  ppExpr2 _ _ (MVar n _ _ _) = return $ word $ "?" <> alphanumber n
  ppExpr2 _ _ (Atom _ x) = return $ word x
  ppExpr2 ctx tgt (List (Atom _ t : es)) = case lookupTerm t env of
    Nothing -> ppApp tgt ("?" <> t <> "?") <$> mapM (ppExpr2 ctx PrecMax) es
    Just (_, _, _, _, Nothing) -> ppApp tgt t <$> mapM (ppExpr2 ctx PrecMax) es
    Just (_, _, _, _, Just (NCoe _ _)) -> case es of
      [e] -> ppExpr2 ctx tgt e
      _ -> ppApp tgt ("?" <> t <> "?") <$> mapM (ppExpr2 ctx PrecMax) es
    Just (_, _, _, _, Just (NPrefix tk)) -> do
      let PrefixInfo _ _ lits = pPrefixes (ePE env) H.! tk
      let (_, p) = pPrec (ePE env) H.! tk
      parenBelow p tgt <$> ppPfx ctx tk lits es
    Just (_, _, _, _, Just (NInfix tk)) -> case es of
      [e1, e2] -> do
        let InfixInfo _ _ r = pInfixes (ePE env) H.! tk
        let (_, p) = pPrec (ePE env) H.! tk
        parenBelow p tgt <$> ppInfix r ctx p t (token tk) e1 e2
      _ -> ppApp tgt ("?" <> t <> "?") <$> mapM (ppExpr2 ctx PrecMax) es
  ppExpr2 _ _ _ = return $ word "???"

  parenBelow :: Prec -> Prec -> PP -> PP
  parenBelow p tgt e | tgt <= p = e
  parenBelow _ _ e = lparen <<>> e <<>> rparen

  ppApp :: Prec -> T.Text -> [PP] -> PP
  ppApp _ t [] = word t
  ppApp p t es = dmap group $ parenBelow (Prec appPrec) p $
    dmap (nest 2) $ soft (word t) es where

    soft :: PP -> [PP] -> PP
    soft e [] = e
    soft e1 (e2 : es') =
      if small e1 then
        surround' softline e1 (soft e2 es')
      else hard e1 (e2 : es')

    hard :: PP -> [PP] -> PP
    hard e [] = e
    hard e1 (e2 : es') = surround' line e1 (hard e2 es')

  ppPfx :: Maybe [TVar LispVal] -> Token -> [PLiteral] -> [LispVal] -> IO PP
  ppPfx ctx tk lits es = go (token tk) lits where
    vec = V.fromList es
    go :: PP -> [PLiteral] -> IO PP
    go e [] = return e
    go e (PConst c : lits') = go (e <<>> token c) lits'
    go e (PVar n p : lits') = do
      e' <- ppExpr2 ctx p (vec V.! n)
      go (e <<>> e') lits'

  ppInfix :: Bool -> Maybe [TVar LispVal] -> Prec -> TermName ->
    PP -> LispVal -> LispVal -> IO PP
  ppInfix _ _ PrecMax _ _ = error "impossible"
  ppInfix r ctx (Prec p) t tk = \e1 e2 ->
    dmap (group . nest 2) <$> (if r then ppInfixr else ppInfixl) e1 e2
    where

    ppInfixl :: LispVal -> LispVal -> IO PP
    ppInfixl e1 e2 = do
      pp1 <- case e1 of
        List [Atom _ t', e11, e12] | t == t' -> ppInfixl e11 e12
        _ -> dmap group <$> ppExpr2 ctx (Prec p) e1
      pp2 <- dmap group <$> ppExpr2 ctx (Prec (p+1)) e2
      return $ surround' softline pp1 $ surround' line tk pp2

    ppInfixr :: LispVal -> LispVal -> IO PP
    ppInfixr e1 e2 = do
      pp1 <- dmap group <$> ppExpr2 ctx (Prec (p+1)) e1
      pp2 <- case e2 of
        List [Atom _ t', e21, e22] | t == t' -> ppInfixr e21 e22
        _ -> dmap group <$> ppExpr2 ctx (Prec p) e2
      return $ surround' softline pp1 $ surround' line tk pp2

ppMVar :: Int -> Sort -> Bool -> PP
ppMVar n s bd =
  let t = "?" <> alphanumber n <> ": " <> (if s == "" then "?" else s)
  in word $ if bd then "{" <> t <> "}" else t

getStat :: ElabM PP
getStat = do
  tc <- getTC
  vec <- VD.freeze (tcProofList tc)
  hs <- foldlM (\d (h, e, _) -> ppExpr e <&>
    \t -> d <> pretty h <> ": " <> doc t <> hardline) mempty vec
  let gs = tcGoals tc
  gs' <- foldlM (\d g ->
    getRef g >>= \case
      Goal _ ty -> ppExpr ty <&> \t -> d <> "|- " <> doc t <> hardline
      _ -> return d) hs gs
  mvs <- V.toList <$> VD.freeze (tcMVars tc) >>= mapM (\g ->
    getRef g <&> \case
      MVar n _ s bd -> Just $ doc $ ppMVar n s bd
      _ -> Nothing)
  return $ dlift $ gs' <> fillSep (catMaybes mvs)

_ppAtStmt :: AtPos Stmt -> Doc Void
_ppAtStmt = ppStmt . unPos

ppStmt :: Stmt -> Doc Void
ppStmt (Sort _ x (SortData p s pr f)) =
  flag "pure" p <> flag "strict" s <> flag "provable" pr <> flag "free" f <>
  "sort" <+> pretty x <> ";"
  where flag t b = if b then t <> space else mempty
ppStmt _ = error "ppStmt unimplemented"

ppLocal :: Local -> Doc Void
ppLocal l = pretty $ fromMaybe "_" (localName l)

ppDepType :: DepType -> Doc Void
ppDepType (DepType t vs) = fillSep $ pretty <$> (t : vs)

ppType :: Type -> Doc Void
ppType (TType ty) = ppDepType $ unDepType ty
ppType (TFormula (Formula _ f)) = "$" <> pretty f <> "$"

ppBinder :: Binder -> Doc Void
ppBinder (Binder _ x ty) = ppBinderGroup False [x] ty

ppBinderGroup :: Bool -> [Local] -> Maybe Type -> Doc Void
ppBinderGroup _ [] _ = undefined
ppBinderGroup b ls@(l : _) ty =
  (if isLCurly l then braces else if b then parens else id) $
  fillSep (ppLocal <$> ls) <> case ty of
    Nothing -> mempty
    Just t -> ":" <+> ppType t

_ppGroupedBinders :: [Binder] -> Doc Void
_ppGroupedBinders bis = layout False (join' bis Nothing) where
  layout :: Bool -> [([Local], Maybe Type)] -> Doc Void
  layout _ [] = mempty
  layout _ ((gr, ty@(Just (TFormula _))) : grs) =
    line <> ppBinderGroup True gr ty <> layout True grs
  layout b ((gr, ty) : grs) =
    (if b then line else softline) <> ppBinderGroup True gr ty <> layout b grs

  join' :: [Binder] -> Maybe ([Local], Bool, Maybe Type) -> [([Local], Maybe Type)]
  join' [] o = flush o []
  join' (Binder _ x ty : bis') (Just (xs, b, ty')) | isLCurly x == b && eqType ty ty' =
    join' bis' (Just (x : xs, b, ty'))
  join' (Binder _ x ty : bis') o = flush o (join' bis' (Just ([x], isLCurly x, ty)))

  flush :: Maybe ([Local], Bool, Maybe Type) -> [([Local], Maybe Type)] -> [([Local], Maybe Type)]
  flush Nothing l = l
  flush (Just (xs, _, ty)) l = (reverse xs, ty) : l

  eqType :: Maybe Type -> Maybe Type -> Bool
  eqType (Just (TType t1)) (Just (TType t2)) = unDepType t1 == unDepType t2
  eqType Nothing Nothing = True
  eqType _ _ = False

_ppPBinder :: PBinder -> Doc Void
_ppPBinder bi = ppPBinderGroup False [bi]

ppPBinderGroup :: Bool -> [PBinder] -> Doc Void
ppPBinderGroup _ [] = undefined
ppPBinderGroup b bis@(bi : _) =
  (if binderBound bi then braces else if b then parens else id) $
  fillSep (pretty . binderName <$> bis) <> ":" <+> ppDepType (binderType bi)

ppGroupedPBinders :: [PBinder] -> Doc Void
ppGroupedPBinders bis = mconcat $
  (\bis' -> space <> ppPBinderGroup True bis') <$> join' bis Nothing where

  join' :: [PBinder] -> Maybe ([PBinder], Bool, DepType) -> [[PBinder]]
  join' [] o = flush o []
  join' (bi : bis') (Just (xs, b, ty)) | binderBound bi == b && binderType bi == ty =
    join' bis' (Just (bi : xs, b, ty))
  join' (bi : bis') o = flush o (join' bis' (Just ([bi], binderBound bi, binderType bi)))

  flush :: Maybe ([PBinder], Bool, DepType) -> [[PBinder]] -> [[PBinder]]
  flush Nothing l = l
  flush (Just (xs, _, _)) l = reverse xs : l

ppSExpr :: Env -> SExpr -> Doc Void
ppSExpr env e = "$" <+> align p <+> "$" where
  p = doc $ unsafePerformIO $ ppExpr1 False env $ sExprToLisp 0 e

ppArrowSExpr :: Env -> [SExpr] -> SExpr -> Doc Void
ppArrowSExpr env es e =
  mconcat (es <&> \e' -> ppSExpr env e' <+> ">" <> softline) <>
  ppSExpr env e

ppVis :: Visibility -> Doc Void
ppVis Public = "pub "
ppVis Abstract = "abstract "
ppVis Local = "local "
ppVis VisDefault = mempty

ppDecl :: Env -> Ident -> Decl -> Doc Void
ppDecl _ x (DTerm bis ty) = group $ "term" <+> pretty x <>
  nest 2 (ppGroupedPBinders bis <> ":" <+> ppDepType ty <> ";")
ppDecl env x (DAxiom bis hyps ret) = group $ "axiom" <+> pretty x <>
  nest 2 (ppGroupedPBinders bis <> ":" <> line <> ppArrowSExpr env hyps ret <> ";")
ppDecl env x (DDef vis bis ty _ val) = group $ ppVis vis <> "def" <+> pretty x <>
  nest 2 (ppGroupedPBinders bis <> ":" <+> ppDepType ty <+> "=") <> softline <> ppSExpr env val
ppDecl env x (DTheorem vis bis hyps ret _) = group $ ppVis vis <> "theorem" <+> pretty x <>
  nest 2 (ppGroupedPBinders bis <> ":" <> line <> ppArrowSExpr env hyps ret <> ";")