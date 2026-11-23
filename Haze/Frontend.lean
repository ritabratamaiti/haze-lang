/-
Copyright (c) 2026 Ritabrata Maiti. All rights reserved.
Released under the Functional Source License 1.1 (FSL-1.1-ALv2) as described in the file LICENSE.md.
Authors: Ritabrata Maiti
-/
import Haze.Elab
import Haze.Json
import Haze.Kernel.Continuous

/-!
# Front End

The front end processes a source file one declaration at a time, much as `Lean.Elab.Frontend`
does for Lean. Each declaration is elaborated, checked by the kernel and then executed.

Between declarations, the front end keeps the environment and a list of branches, one for each
joint assignment of the fuzzy parameters declared so far. Each branch holds an exact distribution
over worlds, where a world assigns an outcome to every global variable. Executing a declaration
updates this state: random nodes extend the worlds, observations condition them, and claims and
queries are evaluated on them. Processing is a pure function from the source text to messages.

## Main Definitions

* `Haze.Frontend.processDecl`: processes one declaration.
* `Haze.Frontend.run`: processes a source file.
-/

namespace Haze.Frontend
open Haze.Syntax Haze.Kernel

/--
Command-line options. `fuel` bounds the depth of nested function calls, and `states` the number of
states explored for an unbounded property.
-/
structure Options where
  fuel : Nat := 1000
  states : Nat := Checker.defaultMaxStates
  /-- The number of possibility levels for continuous fuzzy parameters. -/
  levels : Nat := 10
  deriving Inhabited

/--
The state of the front end: the environment, the declarations that shape the distribution over
worlds, and the messages produced so far. Each query builds its branches (one per joint assignment
of the fuzzy parameters) from the declarations it can observe.
-/
structure FState where
  file : String
  opts : Options
  env : Env := {}
  ops : Array WorldOp := #[]
  /-- The conditions of the observations so far, which every query depends on. -/
  observed : List Expr := []
  /-- Branches already built, by the set of global variables they include. -/
  cache : List (Array Bool × Array Branch) := []
  out : Array String := #[]
  /-- One JSON record per message, for `haze --json`. -/
  records : Array String := #[]
  errors : Nat := 0

/-- The front-end monad, a state monad over `FState`. -/
abbrev FM := StateM FState

/--
Records a message at a source position, together with structured `data` for the JSON output.
A message with severity `error` also increments the error count.
-/
def emit (pos : Pos) (sev : String) (msg : String) (data : List (String × Json) := []) :
    FM Unit := modify fun s =>
  let record := Json.obj ([("file", .str s.file), ("line", Json.nat pos.line),
    ("column", Json.nat pos.col), ("severity", .str sev), ("message", .str msg)] ++ data)
  { s with out := s.out.push s!"{s.file}:{pos}: {sev}: {msg}",
           records := s.records.push record.render,
           errors := if sev == "error" then s.errors + 1 else s.errors }

/-- The JSON fields for a belief–plausibility interval. -/
def jsonInterval (i : Interval) : List (String × Json) :=
  [("belief", Json.rat i.bel), ("plausibility", Json.rat i.pl)]

/-- The JSON form of the result of a property for each fuzzy parameter assignment. -/
def jsonBranches (env : Env) (rows : List BranchResult) : Json :=
  .arr (rows.map fun r => .obj [("parameters", Json.assignment env r.assign),
    ("possibility", Json.rat r.poss), ("lower", Json.rat r.lo), ("upper", Json.rat r.hi)])

/--
The JSON form of a distribution. The unknown outcome, from running out of fuel, has the value
`null`.
-/
def jsonDist (env : Env) (xs : List (Res Value × Rat)) : Json :=
  .arr (xs.map fun (r, q) => .obj [("value", match r with
      | .ok v => Json.value env v
      | .stuck | .amb _ => .null), ("probability", Json.rat q)])

def indent (lines : List String) : String :=
  String.intercalate "" (lines.map ("\n  " ++ ·))

def padRight (s : String) (n : Nat) : String :=
  s ++ String.ofList (List.replicate (n - s.length) ' ')

/-! ## Rendering -/

def fmtAssign (env : Env) (a : List (String × Value)) : String :=
  ", ".intercalate (a.map fun (n, v) => s!"{n} = {fmtValue env v}")

def fmtRes (env : Env) : Res Value → String
  | .ok v => fmtValue env v
  | .stuck | .amb _ => "⊥"

def inputsOf (env : Env) (relevant : Array Bool) (w : World) : List (String × String) := Id.run do
  let mut out := #[]
  for h : i in [0:env.globals.size] do
    let g := env.globals[i]
    if let .node _ true := g.kind then
      if relevant[i]?.getD true then
        if let some r := w[i]? then out := out.push (g.name, fmtRes env r)
  return out.toList

def fmtConfig (env : Env) (relevant : Array Bool) (sys : Option SysInfo)
    (assign : List (String × Value)) (c : Config) (relVars : Array Bool := #[]) : List String :=
  let ps := if assign.isEmpty then [] else [s!"parameters: {fmtAssign env assign}"]
  let ins := inputsOf env relevant c.world
  let ins := if ins.isEmpty then [] else [s!"inputs: {", ".intercalate (ins.map fun (n, v) => s!"{n} = {v}")}"]
  let st := match sys with
    | none => []
    | some si =>
      -- variables outside the property's cone of influence aren't tracked, so they aren't shown
      let vs := ((si.vars.toList.zip c.st.vars.toList).zipIdx.filter fun (_, i) =>
          relVars[i]?.getD true).map fun (((n, _), v), _) => s!"{n} = {fmtValue env v}"
      [s!"state: {", ".intercalate vs}{if c.st.crashed then "  [crashed]" else ""}"]
  ps ++ ins ++ st

/-- Renders an interval, or a single probability when the belief equals the plausibility. -/
def fmtInterval (i : Interval) : String :=
  if i.bel == i.pl then s!"probability {fmtQ i.bel}"
  else s!"belief {fmtQ i.bel} · plausibility {fmtQ i.pl}"

/-! ## Running properties -/

/--
Builds the model checker for a property. The checker reads only the global variables that the
property depends on.
-/
def checkerFor (env : Env) (fuel : Nat) (spec : PropSpec) (maxStates := Checker.defaultMaxStates) : Checker :=
  let sys := spec.sys.bind (env.systems[·]?)
  { Checker.forSpec env fuel sys spec.body spec.args with maxStates }

/-- The degree of truth of a property body, whether it is a `Bool` or a `Deg`. -/
def asDegree (env : Env) (spec : PropSpec) : Expr :=
  let sys := spec.sys.bind (env.systems[·]?)
  let c : TCtx := { env, sysVars := (sys.map (·.vars)).getD #[], inSystem := sys.isSome,
                    svarGrade := (sys.map (·.grade)).getD .crisp }
  match infer c spec.body with
  | .ok (.bool, _) => .prim .degOfBool [spec.body]
  | _ => spec.body

/--
Computes the conditional probability of a property given a condition, for each parameter
assignment. With `N` the probability that both hold and `C` the probability that the condition
holds but the property doesn't, the result is `N / (N + C)`. When some outcomes are unknown, the
two quantities are intervals, and the bounds take the least and most favorable combination.
-/
def runConditional (env : Env) (fuel : Nat) (bs : Array Branch) (spec : PropSpec) (cond : Expr)
    (robust := false) : Except String (List BranchResult × Option Witness) := do
  let φ := asDegree env spec
  let zero : Expr := .lit (.deg 0)
  let base := { spec with given := none }
  let num := { checkerFor env fuel { base with body := .ite cond φ zero } with splitSteps := bs.size < 4, robust }
  let cmp := { checkerFor env fuel { base with body := .ite cond (.prim .tnot [φ]) zero } with splitSteps := bs.size < 4, robust }
  -- a counterexample is a configuration where the condition holds and the property fails
  let wit := { checkerFor env fuel { base with body := .ite cond φ (.lit (.deg 1)) } with robust }
  let mut rows := #[]
  let mut witness := none
  let results ← parMapM bs fun b => do
    return (← num.runBranch spec.mode b, ← cmp.runBranch spec.mode b)
  for (b, ((n, _), (c, _))) in bs.zip results do
    if n.hi + c.hi == 0 then
      throw s!"the condition after `given` is impossible{if b.assign.isEmpty then "" else
        " when " ++ fmtAssign env b.assign}"
    let lo := if n.lo + c.hi == 0 then 0 else n.lo / (n.lo + c.hi)
    let hi := if n.hi + c.lo == 0 then 1 else n.hi / (n.hi + c.lo)
    rows := rows.push { n with lo, hi, maxStates := max n.maxStates c.maxStates }
    if witness.isNone then
      witness := (← wit.runBranch spec.mode b).2
  return (rows.toList, witness)

/--
Checks a property on every branch. Returns the result for each branch, and the counterexample
from the first branch that has one.
-/
def runSpec (env : Env) (fuel : Nat) (bs : Array Branch) (spec : PropSpec)
    (maxStates := Checker.defaultMaxStates) (robust := false) :
    Except String (List BranchResult × Option Witness) := do
  if let some cond := spec.given then
    return ← runConditional env fuel bs spec cond robust
  let ck := { checkerFor env fuel spec maxStates with splitSteps := bs.size < 4, robust }
  let mut rows := #[]
  let mut wit := none
  -- the parameter assignments are independent, so they are checked in parallel
  for (r, w) in ← parMapM' bs (ck.runBranch spec.mode) do
    rows := rows.push r
    if wit.isNone then wit := w
  return (rows.toList, wit)

/-- Notes on how an unbounded property was solved, when the result isn't simply exact. -/
def solverNotes (rows : List BranchResult) (limit : Nat) : List String :=
  (if rows.any (·.truncated) then
    [s!"exploration stopped at {limit} states; what follows the unexplored states counts as unknown (raise the limit with `explore N` or --states)"]
  else []) ++
  (if rows.all (·.exact) then [] else
    ["components with more than 120 states were solved in floating point, and their bounds checked in exact arithmetic"])

/--
Combines lower (or upper) expectations that may be infinite, written `none`, over the α-cuts of
the parameter assignments, like `integrateNum`.
-/
def integrateExt (rows : List (Rat × Option Rat)) (lower : Bool) : Option Rat := Id.run do
  let rows := rows.filter (·.1 > 0)
  let levels := (rows.map (·.1)).eraseDups.mergeSort (fun a b => b ≤ a)
  let some top := levels.head? | return some 0
  let mut acc : Option Rat := some 0
  for (l, n) in levels.zip (levels.drop 1 ++ [0]) do
    let cut := (rows.filter (·.1 ≥ l)).map (·.2)
    let finite := cut.filterMap id
    let pick : Option Rat :=
      if lower then (if finite.isEmpty then none else some (finite.foldl qmin finite.head!))
      else (if finite.length < cut.length || finite.isEmpty then none else some (finite.foldl qmax finite.head!))
    acc := match acc, pick with
      | some a, some p => some (a + (l - n) * p)
      | _, _ => none
  return acc.map (· / top)

/-- Formats a float in scientific notation with seven significant digits, for JSON. -/
def sciFloat (x : Float) : String :=
  if x == 0 || !x.isFinite then "0" else
  let e := (Float.log10 x.abs).floor
  let m := x / Float.pow 10 e
  -- rounding can carry the mantissa up to 10
  let (m, e) := if (m.abs * 1e6).round ≥ 1e7 then (m / 10, e + 1) else (m, e)
  let digits := (m.abs * 1e6).round.toUInt64.toNat
  let s := toString digits
  s!"{if x < 0 then "-" else ""}{s.take 1}.{s.drop 1}e{e.toInt64}"

/-- `P(X > c)` for `X ~ binomial(n, q)`, in floating point. -/
def binomTail (n : Nat) (q : Float) (c : Nat) : Float := Id.run do
  if q ≤ 0 then return 0
  if q ≥ 1 then return (if c < n then 1 else 0)
  let lr := Float.log (q / (1 - q))
  let mut lp := n.toFloat * Float.log (1 - q)
  let mut cdf : Float := 0
  for k in [0:min c n + 1] do
    cdf := cdf + Float.exp lp
    lp := lp + Float.log ((n - k).toFloat / (k + 1).toFloat) + lr
  return max 0 (1 - cdf)

/-- The smallest `c` with `P(X > c) ≤ α` for `X ~ binomial(n, q)`. -/
def acceptLimit (n : Nat) (q α : Float) : Nat := Id.run do
  if q ≤ 0 then return 0
  if q ≥ 1 then return n
  let lr := Float.log (q / (1 - q))
  let mut lp := n.toFloat * Float.log (1 - q)
  let mut cdf : Float := 0
  for k in [0:n + 1] do
    cdf := cdf + Float.exp lp
    if 1 - cdf ≤ α then return k
    lp := lp + Float.log ((n - k).toFloat / (k + 1).toFloat) + lr
  return n

/--
A statistical test of real code: run it `runs` times and accept up to `allowed` failures. If each
run fails independently with probability `q`, the test fails with probability `falseAlarm`; if it
fails with probability `q2`, the test catches it with probability `power`.
-/
structure FlakePlan where
  runs : Nat
  allowed : Nat
  falseAlarm : Float
  power : Float

/--
The smallest statistical test that keeps false alarms below `α` (one in a million) and catches
code that fails twice as often as `q` (or, for `q ≥ 1/2`, halfway to always failing) with
probability at least 0.99. Returns `none` if that takes more than 10 million runs.
-/
def flakePlan (q : Float) (α : Float := 1e-6) (target : Float := 0.99) : Option FlakePlan := Id.run do
  let q2 := if q < 0.5 then 2 * q else (1 + q) / 2
  let eval := fun (n : Nat) =>
    let c := acceptLimit n q α
    (c, binomTail n q c, binomTail n q2 c)
  let maxN := 10000000
  -- double until the test is strong enough, then search between the last two sizes
  let mut hi := 1
  while (eval hi).2.2 < target do
    if hi ≥ maxN then return none
    hi := min maxN (2 * hi)
  let mut lo := hi / 2 + 1
  while lo < hi do
    let mid := (lo + hi) / 2
    if (eval mid).2.2 ≥ target then hi := mid else lo := mid + 1
  let (c, fa, p) := eval hi
  return some { runs := hi, allowed := c, falseAlarm := fa, power := p }

/-- The largest number of parameter assignments shown as a full table. -/
def maxTableRows : Nat := 6

/--
Formats per-assignment results, given as (assignment, possibility, value, text). Small tables are
shown in full. For larger ones, the summary shows the lowest, highest and most possible results,
and then how much the result moves when each parameter is varied alone while the others keep
their most possible values, which shows which uncertain quantity matters most.
-/
def paramTable (env : Env) (rows : List (List (String × Value) × Rat × Rat × String)) : List String :=
  let label := fun (a : List (String × Value)) => fmtAssign env a
  let line := fun (w : Nat) (r : List (String × Value) × Rat × Rat × String) =>
    s!"{padRight (label r.1) w}  π {padRight (fmtQ r.2.1) 6}  {r.2.2.2}"
  if rows.length ≤ maxTableRows then
    let w := rows.foldl (fun m r => max m (label r.1).length) 0
    "by fuzzy parameter (π = possibility):" :: rows.map fun r => "  " ++ line w r
  else Id.run do
    let some r0 := rows.head? | return []
    let pick := fun (better : Rat → Rat → Bool) => rows.foldl (fun b r => if better r.2.2.1 b.2.2.1 then r else b) r0
    let lowest := pick (· < ·)
    let highest := pick (· > ·)
    let core := rows.foldl (fun b r => if r.2.1 > b.2.1 then r else b) r0
    let w := [lowest, highest, core].foldl (fun m r => max m (label r.1).length) 0
    let out := #[s!"by fuzzy parameter (π = possibility), {rows.length} assignments:",
      s!"  lowest          {line w lowest}", s!"  highest         {line w highest}",
      s!"  most possible   {line w core}",
      "what moves the result most (each parameter varied alone, the others at their most possible values):"]
    let names := core.1.map (·.1)
    let mut effects : Array (Rat × String) := #[]
    for n in names do
      let others := core.1.filter (·.1 != n)
      let varied := rows.filter fun r => others.all fun (m, v) => r.1.lookup m == some v
      let vals := varied.filterMap fun r => (r.1.lookup n).map fun v => (v, r.2.2.1)
      let some (_, v0) := vals.head? | continue
      let lo := vals.foldl (fun m (p : Value × Rat) => qmin m p.2) v0
      let hi := vals.foldl (fun m (p : Value × Rat) => qmax m p.2) v0
      let desc := ", ".intercalate (vals.map fun (v, x) => s!"{fmtValue env v} → {fmtQ x}")
      effects := effects.push (hi - lo, s!"{n}: {desc}  (range {fmtQ (hi - lo)})")
    let sorted := effects.toList.mergeSort fun (a b : Rat × String) => b.1 ≤ a.1
    return (out ++ (sorted.map fun (p : Rat × String) => "  " ++ p.2).toArray).toList

/--
Formats the results for each fuzzy parameter assignment. Nothing is shown when every assignment
gives the same result.
-/
def branchTable (env : Env) (rows : List BranchResult) : List String :=
  let same := match rows with
    | r :: rs => rs.all fun x => x.lo == r.lo && x.hi == r.hi
    | [] => true
  if same then [] else
  paramTable env (rows.map fun r =>
    (r.assign, r.poss, (r.lo + r.hi) / 2, if r.lo == r.hi then fmtQ r.lo else s!"[{fmtQ r.lo}, {fmtQ r.hi}]"))

/--
Describes a result in words. A belief of 1 means the property is proved, and a plausibility of 0
means it is refuted. When the grade involves randomness or fuzziness, these are reported as
holding or failing with certainty instead. Any other result is graded.
-/
def status (g : Grade) (i : Interval) : String :=
  if i.bel == 1 then (if g.prob || g.fuzzy then "holds with certainty" else "proved")
  else if i.pl == 0 then (if g.prob || g.fuzzy then "fails with certainty" else "refuted")
  else "graded"

/--
The branches for a property, built from the declarations that the property, its condition and
the observations so far can read.
-/
def branchesFor (spec : PropSpec) : FM (Except String (Array Branch)) := do
  let s ← get
  let sys := spec.sys.bind (s.env.systems[·]?)
  let keep := relevantGlobals s.env sys spec.body (spec.args ++ spec.given.toList ++ s.observed)
  if let some (_, bs) := s.cache.find? (·.1 == keep) then return .ok bs
  match buildBranches s.env s.opts.fuel s.ops keep with
  | .ok (bs, _) =>
    modify fun s => { s with cache := (keep, bs) :: s.cache.take 7 }
    return .ok bs
  | .error e => return .error e

/--
The continuous fuzzy parameters that a property, its condition and the observations so far can
read, with the global variables they can read.
-/
def continuousFor (spec : PropSpec) : FM (Array Continuous.CParam × Array Bool) := do
  let s ← get
  let sys := spec.sys.bind (s.env.systems[·]?)
  let keep := relevantGlobals s.env sys spec.body (spec.args ++ spec.given.toList ++ s.observed)
  let mut out := #[]
  for h : i in [0:s.env.globals.size] do
    let g := s.env.globals[i]
    if let .cparam sh := g.kind then
      if keep[i]?.getD true then out := out.push { name := g.name, shape := sh }
  return (out, keep)

/-- The numeric constants in a term. -/
partial def exprLits : Expr → List Rat
  | .lit (.num q) | .lit (.deg q) => [q]
  | .prim _ args | .call _ args | .rand _ args => args.flatMap exprLits
  | .ite a b c | .choose a b c => exprLits a ++ exprLits b ++ exprLits c
  | .cat alts => alts.flatMap (exprLits ·.1)
  | .catW alts => alts.flatMap fun (e, w) => exprLits e ++ exprLits w
  | .letE a b => exprLits a ++ exprLits b
  | .quant _ _ _ a b c => exprLits a ++ exprLits b ++ exprLits c
  | .matchE e arms d => exprLits e ++ arms.flatMap (exprLits ·.2) ++ (d.map exprLits).getD []
  | _ => []

/-- The numeric constants in a statement. -/
partial def stmtLits : Stmt → List Rat
  | .assign _ e | .assert e => exprLits e
  | .seq a b => stmtLits a ++ stmtLits b
  | .ite c t e | .choose c t e => exprLits c ++ stmtLits t ++ stmtLits e
  | .matchS e arms d => exprLits e ++ arms.flatMap (stmtLits ·.2) ++ stmtLits d
  | .letS v b _ => exprLits v ++ stmtLits b
  | .skip => []

/--
The constants that a model and a property contain. A continuous parameter's range is split at
them first, since comparisons with them are what an interval can leave undecided.
-/
def modelCuts (env : Env) (spec : PropSpec) : Array Rat :=
  let fromSpec := exprLits spec.body ++ (spec.given.map exprLits).getD [] ++ spec.args.flatMap exprLits
  let fromFuns := env.funs.toList.flatMap fun (_, f) => exprLits f.body
  let fromSys := env.systems.toList.flatMap fun (_, si) => si.init.toList.flatMap exprLits ++ stmtLits si.step
  let fromNodes := env.globals.toList.flatMap fun g => match g.kind with
    | .node v _ => exprLits v
    | _ => []
  ((fromSpec ++ fromFuns ++ fromSys ++ fromNodes).eraseDups.take 64).toArray

/-- The number of interval checks spent on one bound in the search over a cut. -/
def searchBudget : Nat := 40

/-- Checks a property with continuous fuzzy parameters `cps`. -/
def runContinuous (spec : PropSpec) (cps : Array Continuous.CParam) (keep : Array Bool) :
    FM (Except String Continuous.Result) := do
  let s ← get
  let build := fun box => do
    let (bs, _) ← buildBranches s.env s.opts.fuel s.ops keep box
    pure bs
  let check := fun (b : Branch) (robust : Bool) => do
    let (rs, _) ← runSpec s.env s.opts.fuel #[b] spec s.opts.states robust
    match rs with
    | r :: _ => pure r
    | [] => throw "kernel: no result"
  return Continuous.run cps s.opts.levels searchBudget (modelCuts s.env spec) build check

/-- The branch for a point found by `runContinuous`, to look for counterexamples at. -/
def branchAt (keep : Array Bool) (pt : List (String × Value) × Nat) : FM (Array Branch) := do
  let s ← get
  match buildBranches s.env s.opts.fuel s.ops keep pt.1 with
  | .ok (bs, _) => return (bs[pt.2]?).toArray
  | .error _ => return #[]

/-- Formats an assignment, with `x in [a, b]` for a range of values. -/
def fmtAssignIn (env : Env) (a : List (String × Value)) : String :=
  ", ".intercalate (a.map fun (n, v) => match v with
    | .ival .. => s!"{n} in {fmtValue env v}"
    | _ => s!"{n} = {fmtValue env v}")

/-- Formats a result range: one number, or the lowest and the highest. -/
def fmtRange (lo hi : Rat) : String := if lo == hi then fmtQ lo else s!"{fmtQ lo} to {fmtQ hi}"

/--
Notes on a result with continuous fuzzy parameters: how close the levels are, and the result at
the most possible values.
-/
def continuousNotes (env : Env) (r : Continuous.Result) : List String :=
  let bracket := if r.inner.bel == r.outer.bel && r.inner.pl == r.outer.pl then [] else
    [s!"{r.levels} possibility levels: the exact belief is at most {fmtQ (qmax r.outer.bel r.inner.bel)}, " ++
     s!"the exact plausibility at least {fmtQ (qmin r.outer.pl r.inner.pl)} (more with `levels N`)"]
  let search := if r.closed then [] else
    ["some ranges of parameter values weren't narrowed down fully, so those bounds are cautious"]
  let top := r.core.foldl (fun m (_, π, _) => qmax m π) 0
  let core := (r.core.filter (·.2.1 == top)).take 1 |>.map fun (a, _, c) =>
    s!"at the most possible values, {fmtAssignIn env a}: {fmtRange c.lo c.hi}"
  bracket ++ search ++ core

/--
The results by possibility level: over the values at least that possible, the lowest and highest
result, combined over the listed parameters' values. Shows the narrowest and widest cut and one in
the middle, and then how much the result moves when each parameter is varied alone.
-/
def continuousTable (r : Continuous.Result) (cps : Array Continuous.CParam) : List String := Id.run do
  let rows := r.bottoms.zip r.rows
  let levels := (r.bottoms.eraseDups.mergeSort fun a b => b ≤ a)
  let some hiL := levels.head? | return []
  let loL := levels.getLast!
  let mid := levels.foldl (fun b l => if (l - 1/2).abs < (b - 1/2).abs then l else b) hiL
  let shown := [hiL, mid, loL].eraseDups
  let label := fun (n : Rat) => if n == 0 then "all values" else s!"π ≥ {fmtQ n}"
  let lines := shown.filterMap fun n =>
    let here := rows.filter (·.1 == n)
    match here with
    | [] => none
    | (_, x0) :: _ =>
      let lo := here.foldl (fun m (_, x) => qmin m x.lo) x0.lo
      let hi := here.foldl (fun m (_, x) => qmax m x.hi) x0.hi
      let ranges := ", ".intercalate (cps.toList.filterMap fun c =>
        (x0.assign.lookup c.name).map fun v => s!"{c.name} {match v with | .ival .. => s!"in {fmtValue {} v}" | _ => s!"= {fmtValue {} v}"}")
      some (s!"{label n}  {ranges}", fmtRange lo hi)
  let w := lines.foldl (fun m (a, _) => max m a.length) 0
  let moving := r.effects.filter (·.2.2 != 0)
  let effects := if moving.length ≤ 1 then [] else
    "what moves the result most (each parameter varied alone, the others at their most possible values):" ::
      moving.map fun (n, desc, width) => s!"  {n}: {desc}  (range {Continuous.brief width})"
  return ("by possibility level (lowest to highest over the values at least that possible):" ::
    lines.map fun (a, b) => s!"  {padRight a w}  {b}") ++ effects

/--
Checks a claim or theorem and reports the result. If it is rejected, the report includes a
counterexample when the model checker found one. An accepted claim is added to the environment.
-/
def doClaim (d : DeclStx) (name : String) (isThm : Bool) (spec : PropSpec) (bound : Bound) : FM Unit := do
  let s ← get
  let env := s.env
  let g := match checkSpec env spec false with | .ok (_, g) => g | .error _ => .crisp
  let bs ← match ← branchesFor spec with
    | .ok bs => pure bs
    | .error e => emit d.pos "error" e; return
  let (cps, keep) ← continuousFor spec
  -- the results, the counterexample, the interval, the branches that fail the bound, notes and a
  -- table of results by parameter value
  let outcome : Except String (List BranchResult × Option Witness × Interval × Array Branch ×
      Array Branch × List String × List String × String) ← if cps.isEmpty then
      pure do
        let (rows, wit) ← runSpec env s.opts.fuel bs spec s.opts.states
        let iv := integrate (rows.map fun r => (r.poss, r.lo, r.hi))
        let low := match bound with
          | .ge q => (bs.zip rows.toArray).filterMap fun (b, r) => if r.lo < q then some b else none
          | _ => bs
        let high := match bound with
          | .le q => (bs.zip rows.toArray).filterMap fun (b, r) => if q < r.hi then some b else none
          | _ => bs
        pure (rows, wit, iv, low, high, solverNotes rows s.opts.states, branchTable env rows,
          s!"{rows.length} parameter assignment(s)")
    else
      match ← runContinuous spec cps keep with
      | .error e => pure (.error e)
      | .ok r =>
        -- show a counterexample at the most possible values that break the bound
        let low ← branchAt keep (match bound with
          | .ge q => (r.breaking true q).getD r.worst
          | _ => (r.breaking true 1).getD r.worst)
        let high ← branchAt keep (match bound with
          | .le q => (r.breaking false q).getD r.bestPt
          | _ => r.bestPt)
        let wit := match runSpec env s.opts.fuel low spec s.opts.states with
          | .ok (_, w) => w
          | .error _ => none
        pure (.ok (r.rows, wit, r.outer, low, high,
          continuousNotes env r ++ solverNotes r.rows s.opts.states, continuousTable r cps,
          s!"{r.levels} possibility levels · {r.checks} checks"))
  match outcome with
  | .error e => emit d.pos "error" e
  | .ok (rows, wit, iv, low, high, notes, table, howMany) =>
    let maxN := rows.foldl (fun m r => max m r.maxStates) 0
    let sys := spec.sys.bind (env.systems[·]?)
    let ck0 := checkerFor env s.opts.fuel spec
    -- show the inputs that the condition after `given` reads as well
    let rel := relevantGlobals env ck0.sys spec.body (spec.args ++ spec.given.toList)
    -- Take the example from a parameter assignment that breaks the bound.
    let failing : Array Branch := match isThm, bound with
      | false, .le _ => high
      | false, .ge _ => low
      | _, _ => if cps.isEmpty then bs else low
    -- When an upper bound fails, the useful example is a run where the property does happen.
    -- It is found as a counterexample to the negated property.
    let (wit, happens) : Option Witness × Bool := match isThm, bound with
      | false, .ge q =>
        if q ≤ iv.bel then (none, false) else
        match runSpec env s.opts.fuel failing spec s.opts.states with
        | .ok (_, w) => (w, false)
        | .error _ => (wit, false)
      | false, .le q =>
        if iv.pl ≤ q then (none, true) else
        let negMode : Option Temporal := match spec.mode with
          | .after k => some (.after k)
          | .eventually k => some (.always k)
          | .eventuallyInf => some .alwaysInf
          | _ => none
        match negMode with
        | some m =>
          let neg := { spec with body := .prim .tnot [asDegree env spec], mode := m }
          match runSpec env s.opts.fuel failing neg s.opts.states with
          | .ok (_, w) => (w, true)
          | .error _ => (none, true)
        | none => (none, true)
      | _, _ => (wit, false)
    let witLines := match wit with
      | some w =>
        -- a program without a system has no steps, only worlds
        let whereStr := if sys.isNone then "a world where it happens" else s!"a run where it happens, at step {w.step}"
        let massStr := if sys.isNone then s!"probability {fmtQ w.mass}" else s!"path mass {fmtQ w.mass}"
        if happens then
          s!"{whereStr} ({massStr}):" ::
            (fmtConfig env rel sys w.assign w.config ck0.relevantVars).map ("  " ++ ·)
        else
        let what := match spec.mode with
          | .eventually _ | .eventuallyInf => "never reached on this path"
          | _ => s!"degree {fmtQ w.degree}"
        let binds := match spec.mode with
          | .eventually _ | .eventuallyInf => []
          | _ => ck0.counterexample (ck0.ctx w.config) spec.body
        let bindLine := if binds.isEmpty then [] else
          [s!"falsified by {", ".intercalate (binds.map fun (n, v) => s!"{n} = {fmtValue env v}")}"]
        let atStep := if sys.isNone then "" else s!" at step {w.step}"
        s!"counterexample{atStep} ({massStr}, {what}):" ::
          ((fmtConfig env rel sys w.assign w.config ck0.relevantVars) ++ bindLine).map ("  " ++ ·)
      | none => []
    let (ok, verdict) : Bool × String := match isThm, bound with
      | true, _ => (iv.bel == 1, if iv.bel == 1 then "theorem accepted" else
          s!"theorem rejected: belief is {fmtQ iv.bel}, not 1")
      | false, .ge q => (q ≤ iv.bel, if q ≤ iv.bel then s!"bound holds: belief ≥ {fmtQ q}"
          else s!"bound fails: belief {fmtQ iv.bel} < {fmtQ q}")
      | false, .le q => (iv.pl ≤ q, if iv.pl ≤ q then s!"bound holds: plausibility ≤ {fmtQ q}"
          else s!"bound fails: plausibility {fmtQ iv.pl} > {fmtQ q}")
      | false, .none => (true, "")
    let size := if spec.mode.unbounded then s!"{maxN} reachable states" else s!"≤{maxN} states/step"
    let lines := [s!"{fmtInterval iv} · {status g iv}",
        s!"grade {g} · {howMany} · {size}"]
      ++ notes
      ++ (if verdict.isEmpty then [] else [verdict])
      ++ table
      ++ (if ok then [] else witLines)
    let kind := if isThm then "theorem" else "claim"
    let cex : Json := match wit with
      | some w =>
        let st : List (String × Json) := match sys with
          -- variables outside the property's cone of influence aren't tracked, so they're left out
          | some si => ((si.vars.toList.zip w.config.st.vars.toList).zipIdx.filter fun (_, i) =>
              ck0.relevantVars[i]?.getD true).map fun (((n, _), v), _) => (n, Json.value env v)
          | none => []
        let ins : List (String × Json) := Id.run do
          let mut out := #[]
          for h : i in [0:env.globals.size] do
            let gl := env.globals[i]
            if let .node _ true := gl.kind then
              if rel[i]?.getD true then
                if let some (.ok v) := w.config.world[i]? then out := out.push (gl.name, Json.value env v)
          return out.toList
        .obj [("step", Json.nat w.step), ("mass", Json.rat w.mass), ("degree", Json.rat w.degree),
          ("parameters", Json.assignment env w.assign), ("inputs", .obj ins), ("state", .obj st),
          ("crashed", .bool w.config.st.crashed)]
      | none => .null
    let data : List (String × Json) := [("kind", .str kind), ("name", .str name),
        ("accepted", .bool ok), ("grade", .str (toString g))] ++ jsonInterval iv ++
      [("branches", jsonBranches env rows), ("counterexample", if ok then .null else cex)]
    if ok then
      let info : ClaimInfo := { name := name, isTheorem := isThm, spec := spec, bound := bound, grade := g, result := iv }
      modify fun s => { s with env := { s.env with claims := s.env.claims.insert name info } }
      emit d.pos "info" s!"{kind} {name}{indent lines}" data
    else
      emit d.pos "error" s!"{kind} {name}{indent lines}" data

/--
Computes the exact distribution of the value of an `after[k]` property on one branch. Mass that ran
out of fuel appears as the outcome `Res.stuck`.
-/
def evalDist (env : Env) (fuel : Nat) (b : Branch) (spec : PropSpec) (splitSteps := true) :
    Except String (List (Res Value × Rat)) := do
  let ck := { checkerFor env fuel spec with splitSteps }
  let k ← match spec.mode with
    | .after k => pure k
    | _ => throw "kernel: only `after[k]` can be evaluated to a distribution"
  let (frontier, unk, _) ← ck.after b k
  let mut out : Array (Res Value × Rat) := #[]
  for (cfg, w) in frontier do
    for (r, q) in ← ck.values cfg do out := out.push (r, w * q)
  if unk != 0 then out := out.push (.stuck, unk)
  return M.compactList out.toList

def fmtDist (env : Env) (xs : List (Res Value × Rat)) : List String :=
  match xs with
  | [(r, 1)] => [fmtRes env r]
  | _ =>
  let xs := xs.mergeSort fun a b => b.2 ≤ a.2
  let shown := xs.take 12
  let w := shown.foldl (fun m (r, _) => max m (fmtRes env r).length) 0
  shown.map (fun (r, q) => s!"{padRight (fmtRes env r) w}  ↦ {fmtQ q}")
    ++ (if xs.length > 12 then [s!"… {xs.length - 12} more outcomes"] else [])

/-- Runs a query command (`#check`, `#eval`, `#prob`, `#expect` or `#outcomes`) and reports its result. -/
def doQuery (d : DeclStx) (k : QueryKind) (spec : PropSpec) : FM Unit := do
  let s ← get
  let env := s.env
  let fuel := s.opts.fuel
  let branches ← if k matches .check then pure #[] else
    match ← branchesFor spec with
    | .ok bs => pure bs
    | .error e => emit d.pos "error" e; return
  if !(k matches .check | .prob) then
    let (cps, _) ← continuousFor spec
    if !cps.isEmpty then
      let vals := ", ".intercalate (cps.toList.map fun c => s!"{c.name} = {fmtQ c.shape.core}")
      emit d.pos "info" s!"{(d.text.splitOn " ").headD d.text} uses the most possible values of continuous fuzzy parameters: {vals}"
  match k with
  | .check =>
    match checkSpec env spec true with
    | .ok (t, g) =>
      let data : List (String × Json) := [("kind", .str "check"), ("query", .str d.text),
        ("type", .str (toString t)), ("grade", .str (toString g))]
      emit d.pos "info" s!"{d.text.drop 7 |>.trimAscii} : {t} @{g}" data
    | .error e => emit d.pos "error" e
  | .eval =>
    let mut dists := #[]
    let mut js := #[]
    let all ← match parMapM' branches (evalDist env fuel · spec (branches.size < 4)) with
      | .ok r => pure r
      | .error e => emit d.pos "error" e; return
    for (b, xs) in branches.zip all do
      do
        dists := dists.push (b, fmtDist env xs)
        js := js.push (Json.obj [("parameters", Json.assignment env b.assign),
          ("possibility", Json.rat b.poss), ("distribution", jsonDist env xs)])
    let same := dists.all fun (_, l) => some l == (dists[0]?.map (·.2))
    let lines := if same then (dists[0]?.map (·.2)).getD [] else
      dists.toList.flatMap fun (b, l) =>
        s!"when {fmtAssign env b.assign} (π {fmtQ b.poss}):" :: l.map ("  " ++ ·)
    emit d.pos "info" s!"{d.text}{indent lines}"
      [("kind", .str "eval"), ("query", .str d.text), ("branches", .arr js.toList)]
  | .prob =>
    let (cps, keep) ← continuousFor spec
    if !cps.isEmpty then
      match ← runContinuous spec cps keep with
      | .error e => emit d.pos "error" e
      | .ok r =>
        emit d.pos "info" s!"{d.text}{indent ([fmtInterval r.outer] ++ continuousNotes env r ++
            solverNotes r.rows s.opts.states ++ continuousTable r cps)}"
          ([("kind", .str "prob"), ("query", .str d.text)] ++ jsonInterval r.outer ++
            [("exact_belief_at_most", Json.rat (qmax r.outer.bel r.inner.bel)),
             ("exact_plausibility_at_least", Json.rat (qmin r.outer.pl r.inner.pl)),
             ("levels", Json.nat r.levels), ("branches", jsonBranches env r.rows)])
      return
    match runSpec env fuel branches spec s.opts.states with
    | .error e => emit d.pos "error" e
    | .ok (rows, _) =>
      let iv := integrate (rows.map fun r => (r.poss, r.lo, r.hi))
      emit d.pos "info" s!"{d.text}{indent ([fmtInterval iv] ++ solverNotes rows s.opts.states ++ branchTable env rows)}"
        ([("kind", .str "prob"), ("query", .str d.text)] ++ jsonInterval iv ++
          [("branches", jsonBranches env rows)])
  | .expect =>
    if spec.mode == .stepsUntil then
      let ck := { checkerFor env fuel spec s.opts.states with splitSteps := branches.size < 4 }
      let all ← match parMapM' branches ck.expectedSteps with
        | .ok r => pure r
        | .error e => emit d.pos "error" e; return
      let fmtE : Option Rat → String := fun | some q => fmtQ q | none => "∞"
      let rows := branches.toList.zip all.toList
      let lo := integrateExt (rows.map fun (b, (l, _)) => (b.poss, l)) true
      let hi := integrateExt (rows.map fun (b, (_, h, _)) => (b.poss, h)) false
      let head := if lo == hi then s!"expected steps {fmtE lo}"
        else s!"lower expectation {fmtE lo} · upper expectation {fmtE hi}"
      let infinite := if lo.isNone then
        ["with positive probability the property never holds, so the expectation is infinite"] else []
      let results : List BranchResult := all.toList.map fun (_, _, n, tr, ex) =>
        { assign := [], poss := 1, lo := 0, hi := 0, maxStates := n, truncated := tr, exact := ex }
      let tbl := if rows.length ≤ 1 then [] else
        "by fuzzy parameter (π = possibility):" :: rows.map fun (b, (l, h, _)) =>
          s!"  {fmtAssign env b.assign}  π {fmtQ b.poss}  {if l == h then fmtE l else s!"{fmtE l} to {fmtE h}"}"
      let jsonE : Option Rat → Json := fun | some q => Json.rat q | none => .null
      emit d.pos "info" s!"{d.text}{indent (head :: infinite ++ solverNotes results s.opts.states ++ tbl)}"
        [("kind", .str "expect"), ("query", .str d.text), ("lower", jsonE lo), ("upper", jsonE hi),
         ("branches", .arr (rows.map fun (b, (l, h, _)) =>
            .obj [("parameters", Json.assignment env b.assign), ("possibility", Json.rat b.poss),
                  ("lower", jsonE l), ("upper", jsonE h)]))]
      return
    let mut rows := #[]
    let all ← match parMapM' branches (evalDist env fuel · spec (branches.size < 4)) with
      | .ok r => pure r
      | .error e => emit d.pos "error" e; return
    for (b, xs) in branches.zip all do
      do
        let mut e : Rat := 0
        for (r, q) in xs do
          match r with
          | .ok (.num v) | .ok (.deg v) => e := e + q * v
          | .ok (.bool v) => e := e + q * (if v then 1 else 0)
          | .ok _ => emit d.pos "error" "#expect needs a numeric expression"; return
          | .stuck | .amb _ => emit d.pos "error" s!"expectation undefined: mass {fmtQ q} ran out of fuel"; return
        rows := rows.push (b, e)
    let iv := integrateNum (rows.toList.map fun (b, e) => (b.poss, e))
    let head := if iv.bel == iv.pl then s!"expectation {fmtQ iv.bel}"
      else s!"lower expectation {fmtQ iv.bel} · upper expectation {fmtQ iv.pl}"
    let same := rows.all fun (_, e) => some e == (rows[0]?.map (·.2))
    let tbl := if same then [] else
      paramTable env (rows.toList.map fun (b, e) => (b.assign, b.poss, e, s!"E {fmtQ e}"))
    emit d.pos "info" s!"{d.text}{indent (head :: tbl)}"
      [("kind", .str "expect"), ("query", .str d.text), ("lower", Json.rat iv.bel),
       ("upper", Json.rat iv.pl), ("branches", .arr (rows.toList.map fun (b, e) =>
          .obj [("parameters", Json.assignment env b.assign), ("possibility", Json.rat b.poss),
                ("expectation", Json.rat e)]))]
  | .outcomes =>
    let ck := checkerFor env fuel spec
    let some kk := (match spec.mode with | .after k => some k | _ => none)
      | emit d.pos "error" "#outcomes supports `after[k]` only"; return
    let mut lines := #[]
    for b in branches do
      match ck.after b kk with
      | .error e => emit d.pos "error" e; return
      | .ok (frontier, unk, _) =>
        if !b.assign.isEmpty then lines := lines.push s!"when {fmtAssign env b.assign} (π {fmtQ b.poss}):"
        -- Group the configurations by the values of the inputs that the property can read.
        let mut groups : Array (String × Rat × List (Res Value × Rat)) := #[]
        for (cfg, w) in frontier do
          let key := ", ".intercalate ((inputsOf env ck.relevant cfg.world).map fun (n, v) => s!"{n} = {v}")
          let key := if key.isEmpty then "(all worlds)" else key
          let vals ← match ck.values cfg with
            | .ok xs => pure xs
            | .error e => do emit d.pos "error" e; return
          let vals := vals.map fun (r, q) => (r, w * q)
          match groups.findIdx? (·.1 == key) with
          | some i => groups := groups.modify i fun (k', m, vs) => (k', m + w, vs ++ vals)
          | none => groups := groups.push (key, w, vals)
        let wd := groups.foldl (fun m g => max m g.1.length) 0
        for (key, m, vs) in groups do
          let vs := (M.compactList vs).mergeSort fun a b => b.2 ≤ a.2
          let out := match vs with
            | [(r, _)] => fmtRes env r
            | _ => " | ".intercalate (vs.map fun (r, q) => s!"{fmtRes env r} {fmtQ (q / m)}")
          let pre := if b.assign.isEmpty then "" else "  "
          lines := lines.push s!"{pre}{padRight key wd}  P {padRight (fmtQ m) 8}  ⇒ {out}"
        if unk != 0 then lines := lines.push s!"diverged (out of fuel): {fmtQ unk}"
    emit d.pos "info" s!"{d.text}{indent lines.toList}"
  | .tests n =>
    let rows ← match runSpec env fuel branches spec s.opts.states with
      | .ok (rows, _) => pure rows.toArray
      | .error e => emit d.pos "error" e; return
    let some si := spec.sys.bind (env.systems[·]?) | emit d.pos "error" "#tests needs a system"; return
    -- tests are generated at the most possible parameter values
    let mut bi := 0
    for i in [0:branches.size] do
      if branches[i]!.poss > branches[bi]!.poss then bi := i
    let some b := branches[bi]? | emit d.pos "error" "no parameter assignment is left"; return
    let failProb := 1 - (rows[bi]?.map (·.lo)).getD 1
    -- every state variable matters to a test, so nothing is sliced away
    let ck : Checker := { checkerFor env fuel spec s.opts.states with
      sys := some si, relevantVars := #[], relevant := relevantGlobals env (some si) spec.body spec.args,
      trace := true, varNames := si.vars.map (·.1) }
    let res ← match ck.weightedRuns spec.mode b n failProb with
      | .ok r => pure r
      | .error e => emit d.pos "error" e; return
    let rel := ck.relevant
    let fmtDeg : Option Rat → String := fun
      | some 1 => "passes" | some 0 => "fails" | some q => s!"holds to degree {fmtQ q}"
      | none => "unknown (ran out of fuel)"
    let choicesOf (r : Checker.Run) : List String :=
      let tr := r.configs.back!.st.trace.toList
      let steps := (tr.map (·.step)).eraseDups
      if steps.isEmpty then ["no random decisions"] else
      steps.map fun t => s!"step {t}: " ++ ", ".intercalate
        ((tr.filter (·.step == t)).map fun e => s!"{e.what} = {fmtValue env e.value}")
    let mut lines : Array String := #[]
    if !b.assign.isEmpty then
      lines := lines.push s!"runs at {fmtAssign env b.assign}, the most possible parameter values"
    let suite := res.runs.filter (·.inSuite)
    lines := lines.push (if res.complete && suite.size == res.runs.size then
        (if suite.size == 1 then "this is the only run" else s!"these {suite.size} runs are all the runs there are")
      else s!"the {suite.size} most likely runs make up {fmtQ res.covered} of the probability")
    let listedFail := res.runs.foldl (fun acc r => if r.degree != some 1 then acc + r.prob else acc) 0
    if failProb == 0 then
      lines := lines.push "the property holds on every run"
    else
      let share := listedFail / failProb
      lines := lines.push s!"the property fails with probability {fmtQ failProb}; {if share == 1 then "all the failing runs are listed" else s!"the failing runs listed make up {fmtQ share} of that"}"
    if res.budgetHit then
      lines := lines.push "the search stopped after expanding 200000 partial runs"
    let mut cum : Rat := 0
    let mut idx := 0
    for r in res.runs do
      idx := idx + 1
      if r.inSuite then cum := cum + r.prob
      let head := if r.inSuite then
          s!"run {idx} · probability {fmtQ r.prob} · cumulative {fmtQ cum} · {fmtDeg r.degree}"
        else s!"failing run · probability {fmtQ r.prob} · {fmtDeg r.degree}"
      lines := lines.push head
      for l in choicesOf r ++ fmtConfig env rel (some si) [] r.configs.back! do
        lines := lines.push ("  " ++ l)
    -- a statistical test of the real code, sized for the most failure-prone possible values
    -- size it for the possible parameter values under which the property fails most often
    let mut qi := 0
    for i in [0:rows.size] do
      if rows[i]!.poss > 0 && 1 - rows[i]!.lo > 1 - rows[qi]!.lo then qi := i
    let qMax := (rows[qi]?.map (1 - ·.lo)).getD 0
    let qAssign := (rows[qi]?.map (·.assign)).getD []
    let plan := if qMax == 0 then none else flakePlan (Solve.ratToFloat qMax)
    let fmtF : Float → String := fun x => fmtQ (Solve.floatToRat x)
    let statLine := if qMax == 0 then
        "statistical test: the property holds on every run, so one run of the real code is a deterministic test"
      else match plan with
      | some p =>
        let atParams := if qAssign.isEmpty then "" else s!" at {fmtAssign env qAssign}"
        s!"statistical test{atParams}: a run of code that matches the model fails this property with probability {fmtQ qMax}. Run the real code {p.runs} times and allow up to {p.allowed} failures: code that matches the model then fails the test with probability {fmtF p.falseAlarm}, and code that fails {if qMax < 1/2 then "twice as often" else "with probability halfway between that and 1"} is caught with probability {fmtF p.power}"
      | none => "statistical test: telling correct code from code that fails twice as often would take more than 10 million runs; replaying the runs above is the practical test"
    lines := lines.push statLine
    let stateJson := fun (c : Config) => Json.obj
      ((si.vars.toList.zip c.st.vars.toList).map fun ((n, _), v) => (n, Json.value env v))
    let runJson := fun (r : Checker.Run) =>
      let tr := r.configs.back!.st.trace.toList
      Json.obj [("probability", Json.rat r.prob), ("suite", .bool r.inSuite),
        ("degree", match r.degree with | some q => Json.rat q | none => .null),
        ("passes", match r.degree with | some q => .bool (q == 1) | none => .null),
        ("inputs", .obj ((inputsOf env rel r.configs[0]!.world).map fun (n, v) => (n, .str v))),
        ("initial", stateJson r.configs[0]!),
        ("steps", .arr (((List.range r.configs.size).drop 1).map fun t =>
          .obj [("step", Json.nat t),
                ("choices", .arr ((tr.filter (·.step == t)).map fun e =>
                  .obj [("what", .str e.what), ("value", Json.value env e.value)])),
                ("state", stateJson r.configs[t]!)]))]
    let planJson : Json := match plan with
      | some p => .obj [("parameters", Json.assignment env qAssign),
          ("failure_rate", Json.rat qMax), ("runs", Json.nat p.runs),
          ("allowed_failures", Json.nat p.allowed), ("false_alarm", .num (sciFloat p.falseAlarm)),
          ("power", .num (sciFloat p.power))]
      | none => .null
    emit d.pos "info" s!"{d.text}{indent lines.toList}"
      [("kind", .str "tests"), ("query", .str d.text), ("parameters", Json.assignment env b.assign),
       ("covered", Json.rat res.covered), ("complete", .bool res.complete),
       ("failure_probability", Json.rat failProb), ("runs", .arr (res.runs.toList.map runJson)),
       ("statistical", planJson)]

/-- Reports a one-line summary of the named declaration, for `#print`. -/
def doPrint (d : DeclStx) (n : String) : FM Unit := do
  let env := (← get).env
  if let some c := env.claims[n]? then
    let kind := if c.isTheorem then "theorem" else "claim"
    emit d.pos "info" s!"{kind} {n} @{c.grade}: {fmtInterval c.result}"
  else if let some f := env.funs[n]? then
    let ps := ", ".intercalate (f.params.map fun (x, t) => s!"{x} : {t}")
    emit d.pos "info" s!"def {n}({ps}) : {f.ret}  latent grade @{f.latent}{if f.recursive then " (recursive)" else ""}"
  else if let some g := env.global? n then
    let kind := match g.kind with
      | .param _ | .cparam _ => "param" | .node _ true => "input" | .node _ false => "def"
    emit d.pos "info" s!"{kind} {n} : {g.ty} @{g.grade}"
  else if let some si := env.systems[n]? then
    let fmt := fun (vs : List (String × Ty)) => ", ".intercalate (vs.map fun (x, t) => s!"{x} : {t}")
    let ps := if si.params == 0 then "" else s!"({fmt (si.vars.toList.take si.params)})"
    emit d.pos "info" s!"system {n}{ps} \{ {fmt (si.vars.toList.drop si.params)} } @{si.grade}"
  else if let some cs := env.enums[n]? then
    emit d.pos "info" s!"enum {n} = {" | ".intercalate cs.toList}"
  else emit d.pos "error" s!"unknown declaration {n}"

/-! ## Driver -/

/--
Processes one declaration: elaborates it, checks it with the kernel and then executes it. The
environment changes only if all three steps succeed.
-/
def processDecl (d : DeclStx) : FM Unit := do
  let s ← get
  match (Elab.elabDecl d.decl).run { env := s.env, pos := d.pos } with
  | .error (p, msg) => emit p "error" msg
  | .ok decl =>
    match addDecl s.env decl with
    | .error msg => emit d.pos "error" msg
    | .ok env' =>
      let fuel := s.opts.fuel
      -- Commit the kernel-checked environment only after the declaration has executed successfully.
      let commit := modify fun s => { s with env := env' }
      match decl with
      | .param n _ sup =>
        commit
        modify fun s => { s with ops := s.ops.push (.param n sup), cache := [] }
      | .cparam n shape =>
        commit
        modify fun s => { s with ops := s.ops.push (.cparam n shape), cache := [] }
      | .levels n => commit; modify fun s => { s with opts := { s.opts with levels := n } }
      | .node _ _ val _ _ =>
        -- Evaluate the new node now, with what it depends on, so that its runtime errors are
        -- reported here even if no query reads it.
        let ops := s.ops.push (.node val)
        let keep := relevantGlobals env' none (.gvar "") (val :: s.observed)
        let keep := keep.set! (keep.size - 1) true
        match buildBranches env' fuel ops keep with
        | .ok _ => commit; modify fun s => { s with ops, cache := [] }
        | .error e => emit d.pos "error" e
      | .observe c =>
        let ops := s.ops.push (.observe c)
        let keep := relevantGlobals env' none c s.observed
        let continuous := (env'.globals.zip keep).filterMap fun (g, k) =>
          if k && g.kind matches .cparam _ then some g.name else none
        if let some n := continuous[0]? then
          emit d.pos "error" s!"an observation can't depend on the continuous fuzzy parameter {n} yet; give it a list of values, or use likelihood(failures, trials) for counts"
          return
        match buildBranches env' fuel ops keep with
        | .error e => emit d.pos "error" e
        | .ok (_, none) => emit d.pos "error" "internal: observation produced no result"
        | .ok (_, some r) =>
          modify fun s => { s with ops, observed := s.observed ++ [c], cache := [] }
          let ev := match r.evidence with
            | (_, z) :: rest =>
              if rest.all (·.2 == z) then [s!"evidence probability {fmtQ z}; worlds renormalized"]
              else "evidence probability by fuzzy parameter:" ::
                r.evidence.map fun (a, z) => s!"  {fmtAssign env' a}: {fmtQ z}"
            | [] => []
          let dr := if r.dropped == 0 then [] else
            [s!"{r.dropped} parameter assignment(s) contradict the observation and were discarded"]
          emit d.pos "info" s!"{d.text}{indent (ev ++ dr)}"
            [("kind", .str "observe"), ("query", .str d.text), ("evidence", .arr (r.evidence.map
              fun (a, z) => .obj [("parameters", Json.assignment env' a), ("probability", Json.rat z)]))]
      | .claim n isThm spec bound => doClaim d n isThm spec bound
      | .query k spec => doQuery d k spec
      | .print n => doPrint d n
      | .explore n => commit; modify fun s => { s with opts := { s.opts with states := n } }
      | _ => commit

/-- Checks a source file and returns the final front-end state. -/
def runState (file src : String) (opts : Options := {}) : FState :=
  match Syntax.program src with
  | .error (p, msg) => ((emit p "error" msg).run { file, opts }).2
  | .ok decls => ((decls.forM processDecl).run { file, opts }).2

/--
Checks a source file and returns its messages, separated by newlines, with the number of errors.
-/
def run (file src : String) (opts : Options := {}) : String × Nat :=
  let s := runState file src opts
  ("\n".intercalate s.out.toList, s.errors)

/-- Checks a source file and returns one JSON record per line, with the number of errors. -/
def runJson (file src : String) (opts : Options := {}) : String × Nat :=
  let s := runState file src opts
  ("\n".intercalate s.records.toList, s.errors)

end Haze.Frontend
