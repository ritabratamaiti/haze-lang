/-
Haze core language: the analogue of Lean's `Lean.Expr`, `ConstantInfo` and `Environment`.

Differences from Lean's core calculus (see docs/DESIGN.md):
* the judgement is graded: `Γ ⊢ e : T @ g` where `g : Grade` records which kinds of
  uncertainty (probabilistic, fuzzy, possibly-divergent) a term can carry;
* there are kernel-level constructors for stochastic conditionals (`choose`),
  random primitives (`rand`, `cat`) and system state (`svar`, `crashed`);
* declarations include fuzzy parameters, random nodes, transition systems and
  *graded* theorems whose result is a `[belief, plausibility]` interval.
-/
import Std.Data.HashMap

namespace Haze

/-- Which kinds of uncertainty a term may carry. The lattice is `Bool × Bool × Bool`. -/
structure Grade where
  prob : Bool := false
  fuzzy : Bool := false
  diverge : Bool := false
  deriving DecidableEq, Hashable, Repr, Inhabited

namespace Grade
def crisp : Grade := {}
def probG : Grade := { prob := true }
def fuzzyG : Grade := { fuzzy := true }
def divergeG : Grade := { diverge := true }

def join (a b : Grade) : Grade :=
  { prob := a.prob || b.prob, fuzzy := a.fuzzy || b.fuzzy, diverge := a.diverge || b.diverge }

def le (a b : Grade) : Bool :=
  (!a.prob || b.prob) && (!a.fuzzy || b.fuzzy) && (!a.diverge || b.diverge)

def joinAll (gs : List Grade) : Grade := gs.foldl join crisp

protected def toString (g : Grade) : String :=
  let parts := (if g.prob then ["prob"] else []) ++ (if g.fuzzy then ["fuzzy"] else [])
    ++ (if g.diverge then ["partial"] else [])
  if parts.isEmpty then "crisp" else "+".intercalate parts

instance : ToString Grade := ⟨Grade.toString⟩
end Grade

inductive Ty where
  | bool
  | num
  /-- fuzzy truth degree in `[0,1]` -/
  | deg
  | enum (name : String)
  deriving DecidableEq, Hashable, Repr, Inhabited

instance : ToString Ty := ⟨fun
  | .bool => "Bool" | .num => "Num" | .deg => "Deg" | .enum n => n⟩

/-- Runtime values. All numbers are exact rationals. -/
inductive Value where
  | bool (b : Bool)
  | num (q : Rat)
  | deg (q : Rat)
  | tag (ty : String) (idx : Nat)
  deriving DecidableEq, Hashable, Repr, Inhabited

/-- Result of evaluation: a value, or `stuck` when the fuel bound was exhausted
(the outcome is formally *unknown*, which widens `[belief, plausibility]`). -/
inductive Res (α : Type) where
  | ok (a : α)
  | stuck
  deriving DecidableEq, Hashable, Repr, Inhabited

/-- Fuzzy logics (t-norm families) for `and` / `or` on degrees. -/
inductive Logic where
  | godel | product | lukasiewicz
  deriving DecidableEq, Hashable, Repr, Inhabited

instance : ToString Logic := ⟨fun
  | .godel => "godel" | .product => "product" | .lukasiewicz => "lukasiewicz"⟩

inductive Prim where
  | add | sub | mul | div | neg | abs | min | max | floor
  | eq | ne | lt | le
  | band | bor | bnot
  | tand (l : Logic) | tor (l : Logic) | tnot | very
  | degOfBool | numOfDeg | degOfNum
  | tri | trap | rampUp | rampDown
  deriving DecidableEq, Repr, Inhabited

inductive RandPrim where
  | bernoulli | uniform | binomial
  deriving DecidableEq, Repr, Inhabited

/-- Kernel terms. Local variables use de Bruijn indices like Lean's `Expr.bvar`. -/
inductive Expr where
  | lit (v : Value)
  | bvar (i : Nat)
  /-- global random node or fuzzy parameter -/
  | gvar (n : String)
  /-- state variable of the enclosing transition system -/
  | svar (i : Nat)
  /-- `true` once an `assert` failed in the enclosing system -/
  | crashed
  | prim (op : Prim) (args : List Expr)
  | call (f : String) (args : List Expr)
  | ite (c t e : Expr)
  /-- stochastic conditional: take `t` with probability `p : Deg`, else `e` -/
  | choose (p t e : Expr)
  | rand (r : RandPrim) (args : List Expr)
  /-- categorical choice with exact weights (checked by the kernel to sum to 1) -/
  | cat (alts : List (Expr × Rat))
  | letE (v b : Expr)
  /-- bounded quantifier over the integers `lo..hi`; binds `bvar 0` in `body`.
  `binder` is kept for diagnostics only (like Lean's `binderName`);
  `isDeg` records whether the body is fuzzy (`Deg`, aggregated by inf/sup) or `Bool`. -/
  | quant (all isDeg : Bool) (binder : String) (lo hi body : Expr)
  | matchE (s : Expr) (arms : List (Nat × Expr)) (dflt : Option Expr)
  deriving Repr, Inhabited

inductive Stmt where
  | skip
  | assign (i : Nat) (e : Expr)
  | seq (a b : Stmt)
  | ite (c : Expr) (t e : Stmt)
  | choose (p : Expr) (t e : Stmt)
  | matchS (s : Expr) (arms : List (Nat × Stmt)) (dflt : Stmt)
  /-- binds `bvar 0` in `body` -/
  | letS (v : Expr) (body : Stmt)
  | assert (c : Expr)
  deriving Repr, Inhabited

inductive Temporal where
  | after (k : Nat)
  | always (k : Nat)
  | eventually (k : Nat)
  deriving DecidableEq, Repr, Inhabited

instance : ToString Temporal := ⟨fun
  | .after k => s!"after[{k}]" | .always k => s!"always[{k}]" | .eventually k => s!"eventually[{k}]"⟩

structure PropSpec where
  sys : Option String
  mode : Temporal
  body : Expr
  deriving Repr, Inhabited

inductive Bound where
  | none
  | ge (q : Rat)
  | le (q : Rat)
  deriving DecidableEq, Repr, Inhabited

structure Interval where
  bel : Rat
  pl : Rat
  deriving DecidableEq, Repr, Inhabited

inductive GlobalKind where
  /-- fuzzy parameter with a normal membership function over a finite support -/
  | param (support : List (Value × Rat))
  /-- random node, evaluated once per world -/
  | node (val : Expr) (isInput : Bool)
  deriving Repr, Inhabited

structure GlobalInfo where
  name : String
  ty : Ty
  grade : Grade
  kind : GlobalKind
  deriving Repr, Inhabited

structure FunInfo where
  name : String
  params : List (String × Ty)
  ret : Ty
  body : Expr
  latent : Grade := .crisp
  recursive : Bool := false
  deriving Repr, Inhabited

structure SysInfo where
  name : String
  vars : Array (String × Ty)
  init : Array Expr
  step : Stmt
  grade : Grade := .crisp
  deriving Repr, Inhabited

/-- A graded theorem: the analogue of Lean's `TheoremVal`, but its "proof" is an exact
certificate interval computed by the kernel's model checker. -/
structure ClaimInfo where
  name : String
  isTheorem : Bool
  spec : PropSpec
  bound : Bound
  grade : Grade
  result : Interval
  deriving Repr, Inhabited

inductive QueryKind where
  | check | eval | prob | expect | outcomes
  deriving DecidableEq, Repr, Inhabited

/-- Elaborated declarations, the input of the kernel (`Lean.Declaration` analogue). -/
inductive Decl where
  | logic (l : Logic)
  | enumD (name : String) (ctors : Array String)
  | param (name : String) (ty : Ty) (support : List (Value × Rat))
  | node (name : String) (ty : Ty) (val : Expr) (isInput : Bool) (declared : Option Grade)
  | fn (f : FunInfo) (declared : Option Grade)
  | observe (cond : Expr)
  | system (s : SysInfo)
  | claim (name : String) (isTheorem : Bool) (spec : PropSpec) (bound : Bound)
  | query (k : QueryKind) (spec : PropSpec)
  | print (name : String)
  deriving Repr, Inhabited

open Std in
structure Env where
  logic : Logic := .godel
  enums : HashMap String (Array String) := {}
  ctors : HashMap String (String × Nat) := {}
  globals : Array GlobalInfo := #[]
  globalIx : HashMap String Nat := {}
  funs : HashMap String FunInfo := {}
  systems : HashMap String SysInfo := {}
  claims : HashMap String ClaimInfo := {}
  deriving Inhabited

namespace Env
def contains (env : Env) (n : String) : Bool :=
  env.enums.contains n || env.ctors.contains n || env.globalIx.contains n ||
  env.funs.contains n || env.systems.contains n || env.claims.contains n

def global? (env : Env) (n : String) : Option GlobalInfo :=
  env.globalIx[n]? >>= (env.globals[·]?)

def addGlobal (env : Env) (g : GlobalInfo) : Env :=
  { env with globals := env.globals.push g, globalIx := env.globalIx.insert g.name env.globals.size }

def ctorName (env : Env) (ty : String) (i : Nat) : String :=
  match env.enums[ty]? >>= (·[i]?) with
  | some n => n
  | none => s!"{ty}#{i}"
end Env

/-! Exact rational helpers and formatting -/

def qmin (a b : Rat) : Rat := if a ≤ b then a else b
def qmax (a b : Rat) : Rat := if a ≤ b then b else a

def isInt (q : Rat) : Bool := q.den == 1

/-- Decimal rendering of an exact rational, rounded to `digits` places. -/
def fmtDec (q : Rat) (digits : Nat := 6) : String := Id.run do
  let neg := q < 0
  let a := if neg then -q else q
  let scale : Nat := 10 ^ digits
  let scaled := (a * (scale : Rat) + 1/2).floor.toNat
  let ip := scaled / scale
  let fp := toString (scaled % scale)
  let fp := String.ofList (List.replicate (digits - fp.length) '0') ++ fp
  let fp := String.ofList (fp.toList.reverse.dropWhile (· == '0')).reverse
  let sign := if neg && scaled != 0 then "-" else ""
  return sign ++ toString ip ++ (if fp.isEmpty then "" else "." ++ fp)

/-- Exact when short, otherwise decimal plus the exact fraction. -/
def fmtQ (q : Rat) : String :=
  if q.den == 1 then toString q.num
  else
    let exactDec := ((q * (1000000 : Rat)).den == 1)
    let d := fmtDec q
    if exactDec then d
    else if q.den ≤ 100000 then s!"{d} (={q.num}/{q.den})"
    else s!"≈{d}"

def fmtValue (env : Env) : Value → String
  | .bool b => toString b
  | .num q => fmtQ q
  | .deg q => s!"deg {fmtQ q}"
  | .tag ty i => env.ctorName ty i

end Haze
