/-
Copyright (c) 2026 Ritabrata Maiti. All rights reserved.
Released under the PolyForm Noncommercial License 1.0.0 as described in the file LICENSE.md.
Authors: Ritabrata Maiti
-/
import Std.Data.HashMap

/-!
# Core Language

This file defines the data that the elaborator produces and the kernel checks: kernel terms,
types, values, grades, declarations and the environment. They play the roles that `Lean.Expr`,
`Lean.Declaration` and `Lean.Environment` play in Lean.

Compared with Lean's core language, there are a few differences:

* The typing judgement is graded. In `Γ ⊢ e : T @ g`, the grade `g` records which kinds of
  uncertainty `e` can carry: randomness, fuzziness and possible non-termination.
* Stochastic conditionals (`Expr.choose`), random primitives (`Expr.rand`, `Expr.cat`) and the
  state of a transition system (`Expr.svar`, `Expr.crashed`) are part of the term language.
* Theorems are graded too. Instead of a proof, a `ClaimInfo` stores the belief–plausibility
  interval that the kernel computed for its property.

## Main Definitions

* `Haze.Grade`: uncertainty grades and their order.
* `Haze.Expr`, `Haze.Stmt`: kernel terms and statements.
* `Haze.Decl`: elaborated declarations, which the kernel takes as input.
* `Haze.Env`: the environment of checked declarations.

## Tags

graded types, probabilistic programming, fuzzy logic
-/

namespace Haze

/--
The kinds of uncertainty that a term can carry: randomness, fuzziness and possible
non-termination. Each kind is a flag, and grades are ordered flag by flag.
-/
structure Grade where
  prob : Bool := false
  fuzzy : Bool := false
  diverge : Bool := false
  deriving DecidableEq, Hashable, Repr, Inhabited

namespace Grade
/-- The grade of terms without uncertainty: deterministic, crisp and terminating. -/
def crisp : Grade := {}
/-- The grade of terms that can depend on random choices. -/
def probG : Grade := { prob := true }
/-- The grade of terms that can depend on fuzzy parameters. -/
def fuzzyG : Grade := { fuzzy := true }
/-- The grade of terms that might not terminate within the fuel bound. -/
def divergeG : Grade := { diverge := true }

/--
The least upper bound of two grades. A term built from subterms of grades `a` and `b` can carry
the uncertainty of both, so its grade is at least `a.join b`.
-/
def join (a b : Grade) : Grade :=
  { prob := a.prob || b.prob, fuzzy := a.fuzzy || b.fuzzy, diverge := a.diverge || b.diverge }

/--
The grade order. `a.le b` is `true` when every kind of uncertainty allowed by `a` is also allowed by
`b`.
-/
def le (a b : Grade) : Bool :=
  (!a.prob || b.prob) && (!a.fuzzy || b.fuzzy) && (!a.diverge || b.diverge)

/-- The least upper bound of a list of grades. The empty list gives `crisp`. -/
def joinAll (gs : List Grade) : Grade := gs.foldl join crisp

protected def toString (g : Grade) : String :=
  let parts := (if g.prob then ["prob"] else []) ++ (if g.fuzzy then ["fuzzy"] else [])
    ++ (if g.diverge then ["partial"] else [])
  if parts.isEmpty then "crisp" else "+".intercalate parts

instance : ToString Grade := ⟨Grade.toString⟩
end Grade

/--
The types of Haze terms.

`Num` values are exact rational numbers, and `Deg` values are fuzzy truth degrees between 0 and 1.
An enumeration type is referred to by its name.
-/
inductive Ty where
  | bool
  | num
  /-- Fuzzy truth degrees, which lie between 0 and 1. -/
  | deg
  | enum (name : String)
  deriving DecidableEq, Hashable, Repr, Inhabited

instance : ToString Ty := ⟨fun
  | .bool => "Bool" | .num => "Num" | .deg => "Deg" | .enum n => n⟩

/--
Runtime values. Numbers and degrees are exact rational numbers, and an enumeration value is the
index of its constructor.
-/
inductive Value where
  | bool (b : Bool)
  | num (q : Rat)
  | deg (q : Rat)
  | tag (ty : String) (idx : Nat)
  deriving DecidableEq, Hashable, Repr, Inhabited

/--
The result of an evaluation: a value, or `stuck` if evaluation ran out of fuel. Since nothing is
known about a stuck outcome, it widens the belief–plausibility interval of any property that
depends on it.
-/
inductive Res (α : Type) where
  | ok (a : α)
  | stuck
  deriving DecidableEq, Hashable, Repr, Inhabited

/-- The fuzzy logics. The active logic determines what `and` and `or` mean on degrees. -/
inductive Logic where
  | godel | product | lukasiewicz
  deriving DecidableEq, Hashable, Repr, Inhabited

instance : ToString Logic := ⟨fun
  | .godel => "godel" | .product => "product" | .lukasiewicz => "lukasiewicz"⟩

/--
Deterministic primitive operations.

Arithmetic, comparisons and the Boolean connectives are crisp. `tand` and `tor` are the fuzzy
conjunction and disjunction of a `Logic`, `tnot` is the fuzzy negation `1 - x`, and `very` squares
a degree. `degOfBool`, `numOfDeg` and `degOfNum` are the coercions that the elaborator inserts,
and `tri`, `trap`, `rampUp` and `rampDown` are membership functions.
-/
inductive Prim where
  | add | sub | mul | div | neg | abs | min | max | floor
  | eq | ne | lt | le
  | band | bor | bnot
  | tand (l : Logic) | tor (l : Logic) | tnot | very
  | degOfBool | numOfDeg | degOfNum
  | tri | trap | rampUp | rampDown
  deriving DecidableEq, Repr, Inhabited

/--
Random primitives: `bernoulli p` (written `flip(p)` in source), `uniform a b`, which picks an
integer from `a` to `b`, and `binomial n p`.
-/
inductive RandPrim where
  | bernoulli | uniform | binomial
  deriving DecidableEq, Repr, Inhabited

/-- Kernel terms. Local variables are de Bruijn indices, as in Lean's `Lean.Expr.bvar`. -/
inductive Expr where
  | lit (v : Value)
  | bvar (i : Nat)
  /-- A global variable: a random node or a fuzzy parameter. -/
  | gvar (n : String)
  /-- A state variable of the enclosing transition system. -/
  | svar (i : Nat)
  /-- Whether an `assert` has failed in the enclosing system. -/
  | crashed
  | prim (op : Prim) (args : List Expr)
  | call (f : String) (args : List Expr)
  | ite (c t e : Expr)
  /-- A stochastic conditional: evaluates `t` with probability `p`, and `e` otherwise. -/
  | choose (p t e : Expr)
  | rand (r : RandPrim) (args : List Expr)
  /-- A categorical choice with exact weights. The kernel checks that the weights sum to 1. -/
  | cat (alts : List (Expr × Rat))
  /--
  A categorical choice whose weights are computed, for example from fuzzy parameters. The weights
  are checked when they are evaluated: they must be non-negative and sum to 1.
  -/
  | catW (alts : List (Expr × Expr))
  | letE (v b : Expr)
  /--
  A bounded quantifier over the integers from `lo` to `hi`, which binds `bvar 0` in `body`.

  `binder` is the name of the bound variable and is used only in messages. `isDeg` is `true` when
  the body is a `Deg` rather than a `Bool`. Degrees are then combined by minimum for `forall` and
  by maximum for `exists`.
  -/
  | quant (all isDeg : Bool) (binder : String) (lo hi body : Expr)
  | matchE (s : Expr) (arms : List (Nat × Expr)) (dflt : Option Expr)
  deriving Repr, Inhabited

/--
Statements in the step of a transition system. State variables are referred to by index, and
local variables introduced by `letS` by de Bruijn index.
-/
inductive Stmt where
  | skip
  | assign (i : Nat) (e : Expr)
  | seq (a b : Stmt)
  | ite (c : Expr) (t e : Stmt)
  | choose (p : Expr) (t e : Stmt)
  | matchS (s : Expr) (arms : List (Nat × Stmt)) (dflt : Stmt)
  /-- Binds `bvar 0` in `body`. -/
  | letS (v : Expr) (body : Stmt)
  | assert (c : Expr)
  deriving Repr, Inhabited

/--
Bounded temporal modalities. `after k` looks at step `k` only, `always k` requires the property at
every step from 0 to `k`, and `eventually k` requires it at some step from 0 to `k`.
-/
inductive Temporal where
  | after (k : Nat)
  | always (k : Nat)
  | eventually (k : Nat)
  deriving DecidableEq, Repr, Inhabited

instance : ToString Temporal := ⟨fun
  | .after k => s!"after[{k}]" | .always k => s!"always[{k}]" | .eventually k => s!"eventually[{k}]"⟩

/--
A property: a truth-valued term, optionally evaluated on the states of a transition system under a
temporal modality.
-/
structure PropSpec where
  sys : Option String
  mode : Temporal
  body : Expr
  /-- The values of the system's parameters, if it has any. -/
  args : List Expr := []
  /-- A condition, for the conditional probability of `body` given that the condition holds. -/
  given : Option Expr := none
  deriving Repr, Inhabited

/--
An optional probability bound on a claim. `ge q` requires a belief of at least `q`, and `le q`
requires a plausibility of at most `q`.
-/
inductive Bound where
  | none
  | ge (q : Rat)
  | le (q : Rat)
  deriving DecidableEq, Repr, Inhabited

/--
A belief–plausibility interval. `bel` is the degree to which the evidence guarantees a property,
and `pl` is the degree to which the evidence allows it, so `bel ≤ pl`.
-/
structure Interval where
  bel : Rat
  pl : Rat
  deriving DecidableEq, Repr, Inhabited

/-- How a global variable gets its value. -/
inductive GlobalKind where
  /--
  A fuzzy parameter, given by the membership degree of each value in its finite support. The
  membership function is normal, meaning that at least one value has membership 1.
  -/
  | param (support : List (Value × Rat))
  /--
  A random node, which has one value in each world. `isInput` marks nodes declared with `input`.
  -/
  | node (val : Expr) (isInput : Bool)
  deriving Repr, Inhabited

/-- A global variable in the environment, with its type and grade. -/
structure GlobalInfo where
  name : String
  ty : Ty
  grade : Grade
  kind : GlobalKind
  deriving Repr, Inhabited

/--
A function in the environment. `latent` is the grade that a call adds to the grades of its
arguments, and `recursive` records whether the body calls the function itself.
-/
structure FunInfo where
  name : String
  params : List (String × Ty)
  ret : Ty
  body : Expr
  latent : Grade := .crisp
  recursive : Bool := false
  deriving Repr, Inhabited

/--
A transition system: named state variables with initial values, and the statement that runs at
each step. `grade` is computed by the kernel.
-/
structure SysInfo where
  name : String
  vars : Array (String × Ty)
  init : Array Expr
  step : Stmt
  grade : Grade := .crisp
  /--
  The number of parameters. The first `params` state variables are the parameters: each property
  about the system supplies their values, and the step may not assign to them.
  -/
  params : Nat := 0
  deriving Repr, Inhabited

/--
A checked claim or theorem. Where Lean would store a proof term, it stores the exact
belief–plausibility interval that the kernel's model checker computed for the property. A theorem
is accepted only if its belief is 1.
-/
structure ClaimInfo where
  name : String
  isTheorem : Bool
  spec : PropSpec
  bound : Bound
  grade : Grade
  result : Interval
  deriving Repr, Inhabited

/-- The query commands `#check`, `#eval`, `#prob`, `#expect` and `#outcomes`. -/
inductive QueryKind where
  | check | eval | prob | expect | outcomes
  deriving DecidableEq, Repr, Inhabited

/-- Elaborated declarations, which the kernel takes as input. -/
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
/--
The environment of checked declarations. Only declarations accepted by `Haze.Kernel.addDecl` are
added to it.
-/
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
/-- Checks whether any declaration in `env` already uses the name `n`. -/
def contains (env : Env) (n : String) : Bool :=
  env.enums.contains n || env.ctors.contains n || env.globalIx.contains n ||
  env.funs.contains n || env.systems.contains n || env.claims.contains n

/-- Looks up a global variable by name. -/
def global? (env : Env) (n : String) : Option GlobalInfo :=
  env.globalIx[n]? >>= (env.globals[·]?)

/--
Adds a global variable. Its index in `globals` is also the position of its value in every world.
-/
def addGlobal (env : Env) (g : GlobalInfo) : Env :=
  { env with globals := env.globals.push g, globalIx := env.globalIx.insert g.name env.globals.size }

/--
The name of constructor `i` of the enumeration type `ty`, or `ty#i` if the environment doesn't
define it.
-/
def ctorName (env : Env) (ty : String) (i : Nat) : String :=
  match env.enums[ty]? >>= (·[i]?) with
  | some n => n
  | none => s!"{ty}#{i}"
end Env

/-! Helpers for exact rational numbers and their formatting -/

/-- The minimum of two rational numbers. -/
def qmin (a b : Rat) : Rat := if a ≤ b then a else b
/-- The maximum of two rational numbers. -/
def qmax (a b : Rat) : Rat := if a ≤ b then b else a

/-- Checks whether a rational number is an integer. -/
def isInt (q : Rat) : Bool := q.den == 1

/--
Renders a rational number in decimal notation, rounded to `digits` places, without trailing zeros.
-/
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

/--
Renders a nonzero rational number in scientific notation with six significant digits, such as
`1.37019e-8`.
-/
def fmtSci (q : Rat) : String := Id.run do
  let mut x := if q < 0 then -q else q
  let mut e : Int := 0
  for _ in [0:100000] do
    if x ≥ 1 then break
    x := x * 10
    e := e - 1
  for _ in [0:100000] do
    if x < 10 then break
    x := x / 10
    e := e + 1
  let mut m := fmtDec x 5
  if m.startsWith "10" then
    m := fmtDec (x / 10) 5
    e := e + 1
  return (if q < 0 then "-" else "") ++ m ++ "e" ++ toString e

/--
Renders a rational number for messages. Integers and numbers with at most six decimal places are
shown exactly. Other numbers are rounded, in scientific notation if their absolute value is below
0.001 and in decimal notation otherwise, and are followed by the exact fraction when its
denominator is small enough.
-/
def fmtQ (q : Rat) : String :=
  if q.den == 1 then toString q.num
  else
    let exactDec := ((q * (1000000 : Rat)).den == 1)
    let a := if q < 0 then -q else q
    if exactDec then fmtDec q
    else if a < 1/1000 then
      if q.den ≤ 1000000000000 then s!"≈{fmtSci q} (={q.num}/{q.den})" else s!"≈{fmtSci q}"
    else if q.den ≤ 100000 then s!"{fmtDec q} (={q.num}/{q.den})"
    else s!"≈{fmtDec q}"

/-- Renders a value for messages, using constructor names for enumeration values. -/
def fmtValue (env : Env) : Value → String
  | .bool b => toString b
  | .num q => fmtQ q
  | .deg q => s!"deg {fmtQ q}"
  | .tag ty i => env.ctorName ty i

end Haze
