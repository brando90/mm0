use std::sync::Arc;
use std::fmt::{self, Display};
use num::BigUint;
use crate::lined_string::LinedString;
use crate::util::{Span, ArcString};
use crate::elab::lisp::print::{EnvDisplay, FormatEnv};
use super::ParseError;

bitflags! {
  pub struct Modifiers: u8 {
    const PURE = 1;
    const STRICT = 2;
    const PROVABLE = 4;
    const FREE = 8;

    const PUB = 16;
    const ABSTRACT = 32;
    const LOCAL = 64;
  }
}

impl Modifiers {
  pub const NONE: Modifiers = Self::empty();
  pub fn sort_data() -> Modifiers {
    Modifiers::PURE | Modifiers::STRICT | Modifiers::PROVABLE | Modifiers::FREE
  }
  pub fn allowed_visibility(self, k: DeclKind) -> bool {
    match k {
      DeclKind::Term => self.is_empty(),
      DeclKind::Axiom => self.is_empty(),
      DeclKind::Def => self == Modifiers::ABSTRACT || self == Modifiers::LOCAL || self.is_empty(),
      DeclKind::Thm => self == Modifiers::PUB || self.is_empty(),
    }
  }
  pub fn from_name(s: &str) -> Option<Modifiers> {
    match s {
      "pure" => Some(Modifiers::PURE),
      "strict" => Some(Modifiers::STRICT),
      "provable" => Some(Modifiers::PROVABLE),
      "free" => Some(Modifiers::FREE),
      "pub" => Some(Modifiers::PUB),
      "abstract" => Some(Modifiers::ABSTRACT),
      "local" => Some(Modifiers::LOCAL),
      _ => None
    }
  }
}

impl Display for Modifiers {
  fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
    if self.contains(Modifiers::PURE) {write!(f, "pure ")?}
    if self.contains(Modifiers::STRICT) {write!(f, "strict ")?}
    if self.contains(Modifiers::PROVABLE) {write!(f, "provable ")?}
    if self.contains(Modifiers::FREE) {write!(f, "free ")?}
    if self.contains(Modifiers::PUB) {write!(f, "pub ")?}
    if self.contains(Modifiers::ABSTRACT) {write!(f, "abstract ")?}
    if self.contains(Modifiers::LOCAL) {write!(f, "local ")?}
    Ok(())
  }
}

#[derive(Clone)]
pub enum Delimiter {
  Both(Box<[u8]>),
  LeftRight(Box<[u8]>, Box<[u8]>),
}

#[derive(Copy, Clone, Debug)]
pub struct Formula(pub Span);
impl Formula {
  pub fn inner(&self) -> Span { (self.0.start + 1 .. self.0.end - 1).into() }
}

#[derive(Clone)]
pub struct Const {
  pub fmla: Formula,
  pub trim: Span
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum DeclKind { Term, Axiom, Thm, Def }

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum LocalKind { Bound, Reg, Dummy, Anon }

impl LocalKind {
  pub fn is_bound(self) -> bool {
    match self {
      LocalKind::Bound | LocalKind::Dummy => true,
      LocalKind::Reg | LocalKind::Anon => false,
    }
  }
}

#[derive(Clone, Debug)]
pub struct DepType {
  pub sort: Span,
  pub deps: Vec<Span>,
}

impl DepType {
  pub fn span(&self) -> Span {
    (self.sort.start..self.deps.last().unwrap_or(&self.sort).end).into()
  }
}

#[derive(Clone, Debug)]
pub enum Type {
  DepType(DepType),
  Formula(Formula)
}

impl Type {
  pub fn span(&self) -> Span {
    match self {
      Type::DepType(d) => d.span(),
      Type::Formula(f) => f.0
    }
  }
}

#[derive(Clone, Debug)]
pub struct Binder {
  pub span: Span,
  pub local: Option<Span>,
  pub kind: LocalKind,
  pub ty: Option<Type>,
}

#[derive(Clone, Debug)]
pub struct SExpr {
  pub span: Span,
  pub k: SExprKind,
}
#[derive(Copy, Clone, Debug)]
pub enum Atom { Ident, Quote, Unquote, Nfx }
#[derive(Clone, Debug)]
pub enum SExprKind {
  Atom(Atom),
  List(Vec<SExpr>),
  DottedList(Vec<SExpr>, Box<SExpr>),
  Number(BigUint),
  String(ArcString),
  Bool(bool),
  Formula(Formula),
}

// separated from curly_list for testing
pub fn curly_transform<T>(es: &mut Vec<T>, no_dot: bool, eq: impl Fn(&T, &T) -> bool, nfx: impl FnOnce() -> T) {
  let n = es.len();
  if n > 2 {
    let valid_curly = no_dot && n % 2 != 0 && {
      let e = &es[1];
      (3..n).step_by(2).all(|i| eq(&es[i], e))
    };
    if valid_curly {
      es.swap(0, 1);
      let mut from = 4;
      let mut to = 3;
      while from < n {
        es.swap(from, to);
        to += 1;
        from += 2;
      }
      es.truncate(to);
    } else {
      es.insert(0, nfx());
    }
  }
}

impl SExpr {
  pub fn atom(span: impl Into<Span>, a: Atom) -> SExpr {
    SExpr {span: span.into(), k: SExprKind::Atom(a)}
  }
  pub fn list(span: impl Into<Span>, es: Vec<SExpr>) -> SExpr {
    SExpr {span: span.into(), k: SExprKind::List(es)}
  }
  pub fn dotted_list(span: impl Into<Span>, mut es: Vec<SExpr>, dot: Option<SExpr>) -> SExpr {
    match dot {
      None => SExpr {span: span.into(), k: SExprKind::List(es)},
      Some(e) => match e.k {
        SExprKind::DottedList(es2, e2) => {
          es.extend(es2);
          SExpr {span: span.into(), k: SExprKind::DottedList(es, e2)}
        }
        SExprKind::List(es2) => {
          es.extend(es2);
          SExpr::list(span, es)
        }
        _ => SExpr {span: span.into(), k: SExprKind::DottedList(es, Box::new(e))}
      }
    }
  }

  pub fn curly_list(span: Span, curly: bool, mut es: Vec<SExpr>, dot: Option<SExpr>, eq: impl Fn(&SExpr, &SExpr) -> bool) -> SExpr {
    if curly {
      curly_transform(&mut es, dot.is_none(), eq,
        || SExpr::atom(span.start..span.start+1, Atom::Nfx))
    }
    Self::dotted_list(span, es, dot)
  }
}

impl EnvDisplay for SExpr {
  fn fmt(&self, fe: FormatEnv, f: &mut fmt::Formatter) -> fmt::Result {
    match &self.k {
      &SExprKind::Atom(a) => fe.source.span_atom(self.span, a).fmt(f),
      SExprKind::List(es) => {
        let mut it = es.iter();
        match it.next() {
          None => "()".fmt(f),
          Some(e) => {
            write!(f, "({}", fe.to(e))?;
            for e in it {write!(f, " {}", fe.to(e))?}
            ")".fmt(f)
          }
        }
      }
      SExprKind::DottedList(es, r) => {
        "(".fmt(f)?;
        for e in es {write!(f, "{} ", fe.to(e))?}
        write!(f, ". {})", fe.to(r))
      }
      SExprKind::Number(n) => n.fmt(f),
      SExprKind::String(s) => write!(f, "{:?}", s),
      SExprKind::Bool(true) => "#t".fmt(f),
      SExprKind::Bool(false) => "#f".fmt(f),
      SExprKind::Formula(s) => fe.source[s.0].fmt(f),
    }
  }
}

#[derive(Clone)]
pub struct Decl {
  pub mods: Modifiers,
  pub k: DeclKind,
  pub id: Span,
  pub bis: Vec<Binder>,
  pub ty: Option<Type>,
  pub val: Option<SExpr>,
}

#[derive(Copy, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub enum Prec { Prec(u32), Max }

impl fmt::Display for Prec {
  fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
    match self {
      &Prec::Prec(p) => p.fmt(f),
      &Prec::Max => "max".fmt(f)
    }
  }
}
impl fmt::Debug for Prec {
  fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result { fmt::Display::fmt(self, f) }
}

#[derive(Clone)]
pub enum SimpleNotaKind { Prefix, Infix {right: bool} }
#[derive(Clone)]
pub struct SimpleNota {
  pub k: SimpleNotaKind,
  pub id: Span,
  pub c: Const,
  pub prec: Prec,
}

#[derive(Clone)]
pub enum Literal {
  Const(Const, Prec),
  Var(Span),
}

#[derive(Clone)]
pub struct GenNota {
  pub id: Span,
  pub bis: Vec<Binder>,
  pub ty: Option<Type>,
  pub lits: Vec<Literal>,
  pub prec: Option<(Prec, bool)>
}

#[derive(Clone)]
pub enum StmtKind {
  Sort(Span, Modifiers),
  Decl(Decl),
  Delimiter(Delimiter),
  SimpleNota(SimpleNota),
  Coercion { id: Span, from: Span, to: Span },
  Notation(GenNota),
  Inout { out: bool, k: Span, hs: Vec<SExpr> },
  Annot(SExpr, Box<Stmt>),
  Do(Vec<SExpr>),
  Import(Span, String),
}

#[derive(Clone)]
pub struct Stmt {
  pub span: Span,
  pub k: StmtKind,
}

pub struct AST {
  pub source: Arc<LinedString>,
  pub imports: Vec<(Span, String)>,
  pub stmts: Vec<Stmt>,
  pub errors: Vec<ParseError>,
}

impl LinedString {
  pub fn span_atom(&self, sp: Span, a: Atom) -> &str {
    match a {
      Atom::Ident => &self[sp],
      Atom::Quote => "quote",
      Atom::Unquote => "unquote",
      Atom::Nfx => ":nfx",
    }
  }
}

impl AST {
  pub fn span(&self, s: Span) -> &str { &self.source[s] }
  pub fn span_atom(&self, sp: Span, a: Atom) -> &str { self.source.span_atom(sp, a) }
  pub fn last_checkpoint(&self, pos: usize) -> (usize, usize) {
    match self.stmts.binary_search_by_key(&pos, |stmt| stmt.span.end) {
      Ok(i) => (i+1, pos),
      Err(0) => (0, 0),
      Err(i) => (i, self.stmts[i-1].span.end)
    }
  }
}