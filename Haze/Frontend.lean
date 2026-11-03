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
The state of the front end: the environment, the current branches (one per joint assignment of the
fuzzy parameters) and the messages produced so far.
-/
structure FState where
  file : String
  opts : Options
  env : Env := {}
  branches : Array Branch := #[{}]
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
    (assign : List (String × Value)) (c : Config) : List String :=
  let ps := if assign.isEmpty then [] else [s!"parameters: {fmtAssign env assign}"]
  let ins := inputsOf env relevant c.world
  let ins := if ins.isEmpty then [] else [s!"inputs: {", ".intercalate (ins.map fun (n, v) => s!"{n} = {v}")}"]
  let st := match sys with
    | none => []
    | some si =>
      let vs := (si.vars.toList.zip c.st.vars.toList).map fun ((n, _), v) => s!"{n} = {fmtValue env v}"
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
  { env, fuel, sys, body := spec.body, relevant := relevantGlobals env sys spec.body }

/--
Checks a property on every branch. Returns the result for each branch, and the counterexample
from the first branch that has one.
-/
def runSpec (env : Env) (fuel : Nat) (bs : Array Branch) (spec : PropSpec) :
    Except String (List BranchResult × Option Witness) := do
  let ck := checkerFor env fuel spec
  let mut rows := #[]
  let mut wit := none
  for b in bs do
    let (r, w) ← ck.runBranch spec.mode b
    rows := rows.push r
    if wit.isNone then wit := w
  return (rows.toList, wit)

/--
Formats the results for each fuzzy parameter assignment as a table. The table is omitted when every
assignment gives the same result.
-/
def branchTable (env : Env) (rows : List BranchResult) : List String :=
  let same := match rows with
    | r :: rs => rs.all fun x => x.lo == r.lo && x.hi == r.hi
    | [] => true
  if same then [] else
  let label (r : BranchResult) := fmtAssign env r.assign
  let w := rows.foldl (fun m r => max m (label r).length) 0
  "by fuzzy parameter (π = possibility):" :: rows.map fun r =>
    let v := if r.lo == r.hi then fmtQ r.lo else s!"[{fmtQ r.lo}, {fmtQ r.hi}]"
    s!"  {padRight (label r) w}  π {padRight (fmtQ r.poss) 6}  {v}"

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
Checks a claim or theorem and reports the result. If it is rejected, the report includes a
counterexample when the model checker found one. An accepted claim is added to the environment.
-/
def doClaim (d : DeclStx) (name : String) (isThm : Bool) (spec : PropSpec) (bound : Bound) : FM Unit := do
  let s ← get
  let env := s.env
  let g := match checkSpec env spec false with | .ok (_, g) => g | .error _ => .crisp
  match runSpec env s.opts.fuel s.branches spec with
  | .error e => emit d.pos "error" e
  | .ok (rows, wit) =>
    let iv := integrate (rows.map fun r => (r.poss, r.lo, r.hi))
    let maxN := rows.foldl (fun m r => max m r.maxStates) 0
    let sys := spec.sys.bind (env.systems[·]?)
    let ck0 := checkerFor env s.opts.fuel spec
    let rel := ck0.relevant
    let witLines := match wit with
      | some w =>
        let what := match spec.mode with
          | .eventually _ => "never reached on this path"
          | _ => s!"degree {fmtQ w.degree}"
        let binds := match spec.mode with
          | .eventually _ => []
          | _ => ck0.counterexample (ck0.ctx w.config) spec.body
        let bindLine := if binds.isEmpty then [] else
          [s!"falsified by {", ".intercalate (binds.map fun (n, v) => s!"{n} = {fmtValue env v}")}"]
        s!"counterexample at step {w.step} (path mass {fmtQ w.mass}, {what}):" ::
          ((fmtConfig env rel sys w.assign w.config) ++ bindLine).map ("  " ++ ·)
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
    for b in s.branches do
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
    match runSpec env fuel s.branches spec with
    | .error e => emit d.pos "error" e
    | .ok (rows, _) =>
      let iv := integrate (rows.map fun r => (r.poss, r.lo, r.hi))
      emit d.pos "info" s!"{d.text}{indent ([fmtInterval iv] ++ branchTable env rows)}"
        ([("kind", .str "prob"), ("query", .str d.text)] ++ jsonInterval iv ++
          [("branches", jsonBranches env rows)])
  | .expect =>
    let mut rows := #[]
    for b in s.branches do
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
    let w := rows.foldl (fun m (b, _) => max m (fmtAssign env b.assign).length) 0
    let same := rows.all fun (_, e) => some e == (rows[0]?.map (·.2))
    let tbl := if same then [] else
      "by fuzzy parameter (π = possibility):" :: rows.toList.map fun (b, e) =>
        s!"  {padRight (fmtAssign env b.assign) w}  π {padRight (fmtQ b.poss) 6}  E {fmtQ e}"
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
    for b in s.branches do
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
    let vs := ", ".intercalate (si.vars.toList.map fun (x, t) => s!"{x} : {t}")
    emit d.pos "info" s!"system {n} \{ {vs} } @{si.grade}"
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
        modify fun s => { s with branches := addParam n sup s.branches }
      | .node _ _ val _ _ =>
        match addNode env' fuel val s.branches with
        | .ok bs => commit; modify fun s => { s with branches := bs }
        | .error e => emit d.pos "error" e
      | .observe c =>
        match Kernel.observe env' fuel c s.branches with
        | .error e => emit d.pos "error" e
        | .ok r =>
          modify fun s => { s with branches := r.branches }
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
