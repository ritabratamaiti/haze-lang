/-
Copyright (c) 2026 Ritabrata Maiti. All rights reserved.
Released under the PolyForm Noncommercial License 1.0.0 as described in the file LICENSE.md.
Authors: Ritabrata Maiti
-/
import Haze.Elab
import Haze.Json
import Haze.Kernel.Verify

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

/-- Command-line options. `fuel` bounds the depth of nested function calls. -/
structure Options where
  fuel : Nat := 1000
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
      | .stuck => .null), ("probability", Json.rat q)])

def indent (lines : List String) : String :=
  String.intercalate "" (lines.map ("\n  " ++ ·))

def padRight (s : String) (n : Nat) : String :=
  s ++ String.ofList (List.replicate (n - s.length) ' ')

/-! ## Rendering -/

def fmtAssign (env : Env) (a : List (String × Value)) : String :=
  ", ".intercalate (a.map fun (n, v) => s!"{n} = {fmtValue env v}")

def fmtRes (env : Env) : Res Value → String
  | .ok v => fmtValue env v
  | .stuck => "⊥"

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
def checkerFor (env : Env) (fuel : Nat) (spec : PropSpec) : Checker :=
  let sys := spec.sys.bind (env.systems[·]?)
  Checker.forSpec env fuel sys spec.body spec.args

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
def runConditional (env : Env) (fuel : Nat) (bs : Array Branch) (spec : PropSpec) (cond : Expr) :
    Except String (List BranchResult × Option Witness) := do
  let φ := asDegree env spec
  let zero : Expr := .lit (.deg 0)
  let base := { spec with given := none }
  let num := checkerFor env fuel { base with body := .ite cond φ zero }
  let cmp := checkerFor env fuel { base with body := .ite cond (.prim .tnot [φ]) zero }
  -- a counterexample is a configuration where the condition holds and the property fails
  let wit := checkerFor env fuel { base with body := .ite cond φ (.lit (.deg 1)) }
  let mut rows := #[]
  let mut witness := none
  for b in bs do
    let (n, _) ← num.runBranch spec.mode b
    let (c, _) ← cmp.runBranch spec.mode b
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
def runSpec (env : Env) (fuel : Nat) (bs : Array Branch) (spec : PropSpec) :
    Except String (List BranchResult × Option Witness) := do
  if let some cond := spec.given then
    return ← runConditional env fuel bs spec cond
  let ck := checkerFor env fuel spec
  let mut rows := #[]
  let mut wit := none
  for b in bs do
    let (r, w) ← ck.runBranch spec.mode b
    rows := rows.push r
    if wit.isNone then wit := w
  return (rows.toList, wit)

/-- The largest number of parameter assignments shown as a full table. -/
def maxTableRows : Nat := 6

/--
Formats per-assignment results, given as (assignment, possibility, value, text). Small tables are
shown in full. For larger ones, the summary shows the lowest, highest and most plausible results,
and then how much the result moves when each parameter is varied alone while the others keep
their most plausible values, which shows which uncertain quantity matters most.
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
      s!"  most plausible  {line w core}",
      "what moves the result most (each parameter varied alone, the others at their most plausible values):"]
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
  match runSpec env s.opts.fuel bs spec with
  | .error e => emit d.pos "error" e
  | .ok (rows, wit) =>
    let iv := integrate (rows.map fun r => (r.poss, r.lo, r.hi))
    let maxN := rows.foldl (fun m r => max m r.maxStates) 0
    let sys := spec.sys.bind (env.systems[·]?)
    let ck0 := checkerFor env s.opts.fuel spec
    -- show the inputs that the condition after `given` reads as well
    let rel := relevantGlobals env ck0.sys spec.body (spec.args ++ spec.given.toList)
    -- Take the example from a parameter assignment that breaks the bound.
    let failing : Array Branch := match isThm, bound with
      | false, .ge q => (bs.zip rows.toArray).filterMap fun (b, r) => if r.lo < q then some b else none
      | false, .le q => (bs.zip rows.toArray).filterMap fun (b, r) => if q < r.hi then some b else none
      | _, _ => bs
    -- When an upper bound fails, the useful example is a run where the property does happen.
    -- It is found as a counterexample to the negated property.
    let (wit, happens) : Option Witness × Bool := match isThm, bound with
      | false, .ge q =>
        if q ≤ iv.bel then (none, false) else
        match runSpec env s.opts.fuel failing spec with
        | .ok (_, w) => (w, false)
        | .error _ => (wit, false)
      | false, .le q =>
        if iv.pl ≤ q then (none, true) else
        let negMode : Option Temporal := match spec.mode with
          | .after k => some (.after k)
          | .eventually k => some (.always k)
          | .always _ => none
        match negMode with
        | some m =>
          let neg := { spec with body := .prim .tnot [asDegree env spec], mode := m }
          match runSpec env s.opts.fuel failing neg with
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
          | .eventually _ => "never reached on this path"
          | _ => s!"degree {fmtQ w.degree}"
        let binds := match spec.mode with
          | .eventually _ => []
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
    let lines := [s!"{fmtInterval iv} — {status g iv}",
        s!"grade {g} · {rows.length} parameter assignment(s) · ≤{maxN} states/step"]
      ++ (if verdict.isEmpty then [] else [verdict])
      ++ branchTable env rows
      ++ (if ok then [] else witLines)
    let kind := if isThm then "theorem" else "claim"
    let cex : Json := match wit with
      | some w =>
        let st : List (String × Json) := match sys with
          | some si => (si.vars.toList.zip w.config.st.vars.toList).map fun ((n, _), v) => (n, Json.value env v)
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
def evalDist (env : Env) (fuel : Nat) (b : Branch) (spec : PropSpec) :
    Except String (List (Res Value × Rat)) := do
  let ck := checkerFor env fuel spec
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
    for b in branches do
      match evalDist env fuel b spec with
      | .error e => emit d.pos "error" e; return
      | .ok xs =>
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
    match runSpec env fuel branches spec with
    | .error e => emit d.pos "error" e
    | .ok (rows, _) =>
      let iv := integrate (rows.map fun r => (r.poss, r.lo, r.hi))
      emit d.pos "info" s!"{d.text}{indent ([fmtInterval iv] ++ branchTable env rows)}"
        ([("kind", .str "prob"), ("query", .str d.text)] ++ jsonInterval iv ++
          [("branches", jsonBranches env rows)])
  | .expect =>
    let mut rows := #[]
    for b in branches do
      match evalDist env fuel b spec with
      | .error e => emit d.pos "error" e; return
      | .ok xs =>
        let mut e : Rat := 0
        for (r, q) in xs do
          match r with
          | .ok (.num v) | .ok (.deg v) => e := e + q * v
          | .ok (.bool v) => e := e + q * (if v then 1 else 0)
          | .ok _ => emit d.pos "error" "#expect needs a numeric expression"; return
          | .stuck => emit d.pos "error" s!"expectation undefined: mass {fmtQ q} ran out of fuel"; return
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
    let kind := match g.kind with | .param _ => "param" | .node _ true => "input" | .node _ false => "def"
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
