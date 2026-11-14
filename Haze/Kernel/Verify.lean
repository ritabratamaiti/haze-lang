/-
Copyright (c) 2026 Ritabrata Maiti. All rights reserved.
Released under the Functional Source License 1.1 (FSL-1.1-ALv2) as described in the file LICENSE.md.
Authors: Ritabrata Maiti
-/
import Haze.Kernel.Eval
import Haze.Kernel.Solve

/-!
# Worlds, Fuzzy Parameters and Model Checking

This file checks properties of whole programs. It builds the distribution over worlds, conditions
it on observations, model-checks bounded temporal properties of transition systems, and combines
the results for the different fuzzy parameter assignments into a belief–plausibility interval.

A fuzzy parameter is described by a possibility distribution `π` over a finite set of values. For
a level `α` between 0 and 1, the α-cut `{v | π v ≥ α}` is the set of values that are admissible
at that level, and drawing `α` uniformly from the interval `(0, 1]` gives a random set of
values. For each joint parameter assignment `y` the program is a finite Markov chain, and the
model checker computes an exact interval `[lo y, hi y]` for the property. The two ends differ
only because of outcomes that ran out of fuel, and the gap is at most their probability.
Combining the assignments gives the final interval:

* belief, the integral over `α` of the minimum of `lo y` over the α-cut, and
* plausibility, the integral over `α` of the maximum of `hi y` over the α-cut.

Without fuzzy parameters, belief and plausibility both equal the exact probability. Without
randomness, they are the necessity and possibility of possibility theory.

## Main Definitions

* `Haze.Kernel.addParam`, `Haze.Kernel.addNode`, `Haze.Kernel.observe`: build the worlds and
  condition them on evidence.
* `Haze.Kernel.Checker.runBranch`: model-checks a property for one parameter assignment.
* `Haze.Kernel.integrate`: combines the results for all assignments.

## References

* Didier Dubois and Henri Prade, *Possibility Theory* (1988).
* Glenn Shafer, *A Mathematical Theory of Evidence* (1976).
-/

namespace Haze.Kernel
open Std

/-! ## Parallel evaluation -/

/-- Below this many items, work is done on the current thread. -/
def parThreshold : Nat := 64

/--
Applies `f` to every element of `xs` and returns the results in order. Large arrays are split into
chunks that run as parallel tasks, but the result is the same as a sequential map: only the
scheduling differs, and the first error in order is the one reported.
-/
def parMapM (xs : Array α) (f : α → Except String β) : Except String (Array β) := do
  if xs.size < parThreshold then return ← xs.mapM f
  let nChunks := min 64 (xs.size / (parThreshold / 2))
  let size := (xs.size + nChunks - 1) / nChunks
  let tasks := (Array.range nChunks).map fun c =>
    Task.spawn fun _ => (xs.extract (c * size) ((c + 1) * size)).mapM f
  let mut out := Array.mkEmpty xs.size
  for t in tasks do out := out ++ (← t.get)
  return out

/--
Applies `f` to every element of `xs`, running each one as its own parallel task, and returns the
results in order. Suited to a few expensive items, such as the parameter assignments of a query.
-/
def parMapM' (xs : Array α) (f : α → Except String β) : Except String (Array β) := do
  if xs.size ≤ 1 then return ← xs.mapM f
  let tasks := xs.map fun x => Task.spawn fun _ => f x
  tasks.mapM (·.get)

/--
Like `parMapM`, but every element gives an array of results, and they are concatenated in order.
-/
def parFlatMapM (xs : Array α) (f : α → Except String (Array β)) : Except String (Array β) := do
  let parts ← parMapM xs f
  return parts.foldl (· ++ ·) #[]

/--
A world assigns an outcome to every global variable, at the index of the variable in `Env.globals`.
-/
abbrev World := Array (Res Value)

/--
One joint assignment of the fuzzy parameters, with its possibility and the distribution of worlds
under that assignment. The front end keeps one branch per assignment.
-/
structure Branch where
  assign : List (String × Value) := []
  poss : Rat := 1
  worlds : List (World × Rat) := [(#[], 1)]
  deriving Inhabited

/--
A configuration of a transition system: the world together with the state that steps can change.
-/
structure Config where
  world : World
  st : SState
  deriving DecidableEq, Hashable, Inhabited

/-- Runs a computation and returns its weighted outcomes as a list, or its runtime error. -/
def liftM (m : M α) : Except String (List (Res α × Rat)) := m.run

/-! ## Building worlds -/

/--
Splits every branch by the values of a new fuzzy parameter, skipping values of membership 0. The
possibility of a branch is the minimum of the memberships of the values it assigns.
-/
def addParam (name : String) (support : List (Value × Rat)) (bs : Array Branch) : Array Branch :=
  bs.flatMap fun b => (support.filter (·.2 > 0)).toArray.map fun (v, m) =>
    { assign := b.assign ++ [(name, v)], poss := qmin b.poss m,
      worlds := b.worlds.map fun (w, p) => (w.push (.ok v), p) }

/-- Extends every world with the outcome of a new random node. -/
def addNode (env : Env) (fuel : Nat) (val : Expr) (bs : Array Branch) :
    Except String (Array Branch) :=
  parMapM' bs fun b => do
    let mut out : Array (World × Rat) := #[]
    for (w, p) in b.worlds do
      for (r, q) in ← liftM (eval { env, world := w, fuel } val) do
        out := out.push (w.push r, p * q)
    pure { b with worlds := M.compactList out.toList }

/--
The result of conditioning: the remaining branches, the probability of the evidence in each
branch, and the number of branches that were dropped because they contradict the evidence.
-/
structure ObserveResult where
  branches : Array Branch
  evidence : List (List (String × Value) × Rat)
  dropped : Nat

/--
Conditions the worlds of every branch on a Boolean observation, using Bayes' rule. A branch in
which the observation has probability 0 is dropped, and it is an error if every branch is dropped
or if the observation can't be decided within the fuel bound.
-/
def observe (env : Env) (fuel : Nat) (cond : Expr) (bs : Array Branch) :
    Except String ObserveResult := do
  let mut out : Array Branch := #[]
  let mut evidence := []
  let mut dropped := 0
  for b in bs do
    let mut kept : Array (World × Rat) := #[]
    let mut z : Rat := 0
    for (w, p) in b.worlds do
      for (r, q) in ← liftM (eval { env, world := w, fuel } cond) do
        match r with
        | .ok (.bool true) => kept := kept.push (w, p * q); z := z + p * q
        | .ok _ => pure ()
        | .stuck => throw "kernel: observation could not be decided within the fuel bound"
    evidence := evidence ++ [(b.assign, z)]
    if z == 0 then dropped := dropped + 1
    else out := out.push { b with worlds := M.compactList (kept.toList.map fun (w, p) => (w, p / z)) }
  if out.isEmpty then throw "kernel: observation is impossible under every parameter assignment"
  pure { branches := out, evidence, dropped }

/--
A declaration that shapes the distribution over worlds. Every `param` and `node` adds one global
variable, in the order of `Env.globals`.
-/
inductive WorldOp where
  | param (name : String) (support : List (Value × Rat))
  | node (val : Expr)
  | observe (cond : Expr)
  deriving Inhabited

/--
Builds the branches for a query by replaying the declarations in order. Only the parameters and
nodes that `keep` marks are included; the others get the outcome `Res.stuck`. This is exact for
any query whose property, and every observation, reads only marked variables:

* the joint distribution of the marked nodes doesn't depend on the unmarked ones, and
* a parameter that nothing reads doesn't change any branch's result. Its membership function is
  normal, so every α-cut of it is non-empty, and the minimum and maximum over an α-cut are the
  same with or without it.

It avoids building the joint distribution of every random input in the program, which grows
exponentially with the number of inputs, and splitting on parameters that don't matter.

Also returns the result of the last observation, if there is one.
-/
def buildBranches (env : Env) (fuel : Nat) (ops : Array WorldOp) (keep : Array Bool) :
    Except String (Array Branch × Option ObserveResult) := do
  let mut bs : Array Branch := #[{}]
  let mut last := none
  let mut gi := 0
  for op in ops do
    match op with
    | .param n sup =>
      if keep[gi]?.getD true then bs := addParam n sup bs
      else bs := bs.map fun b => { b with worlds := b.worlds.map fun (w, p) => (w.push .stuck, p) }
      gi := gi + 1
    | .node v =>
      if keep[gi]?.getD true then bs ← addNode env fuel v bs
      else bs := bs.map fun b => { b with worlds := b.worlds.map fun (w, p) => (w.push .stuck, p) }
      gi := gi + 1
    | .observe c =>
      let r ← observe env fuel c bs
      bs := r.branches
      last := some r
  return (bs, last)

/-! ## Fuzzy integration -/

/--
Combines the results for the different parameter assignments into a belief–plausibility interval
by integrating over α-cuts. Each row is `(π y, lo y, hi y)`. If conditioning removed every
assignment of possibility 1, the possibilities are rescaled by their maximum.
-/
def integrate (rows : List (Rat × Rat × Rat)) : Interval := Id.run do
  let rows := rows.filter (·.1 > 0)
  let levels := (rows.map (·.1)).eraseDups.mergeSort (fun a b => b ≤ a)
  let some top := levels.head? | return { bel := 0, pl := 1 }
  let mut bel : Rat := 0
  let mut pl : Rat := 0
  let nexts := levels.drop 1 ++ [0]
  for (l, n) in levels.zip nexts do
    let cut := rows.filter (·.1 ≥ l)
    let lo := cut.foldl (fun acc r => qmin acc r.2.1) 1
    let hi := cut.foldl (fun acc r => qmax acc r.2.2) 0
    bel := bel + (l - n) * lo
    pl := pl + (l - n) * hi
  return { bel := bel / top, pl := pl / top }

/--
Combines the expectations for the different parameter assignments into lower and upper
expectations by integrating over α-cuts. These are the lower and upper Choquet integrals. Each
row is `(π y, expectation for y)`.
-/
def integrateNum (rows : List (Rat × Rat)) : Interval := Id.run do
  let rows := rows.filter (·.1 > 0)
  let levels := (rows.map (·.1)).eraseDups.mergeSort (fun a b => b ≤ a)
  let some top := levels.head? | return { bel := 0, pl := 0 }
  let mut lo : Rat := 0
  let mut hi : Rat := 0
  let nexts := levels.drop 1 ++ [0]
  for (l, n) in levels.zip nexts do
    let cut := (rows.filter (·.1 ≥ l)).map (·.2)
    let some c0 := cut.head? | continue
    lo := lo + (l - n) * cut.foldl qmin c0
    hi := hi + (l - n) * cut.foldl qmax c0
  return { bel := lo / top, pl := hi / top }

/-! ## Relevance: Projecting Worlds onto the Variables a Property Reads -/

/--
Marks, by world index, the global variables that `body` can read, either directly or through
node definitions, called functions, and the initialization and step of `sys`.

Projecting worlds onto these variables and merging worlds that become equal doesn't change the
result, because the property can't observe the other variables. It does make the state space
smaller.
-/
partial def relevantGlobals (env : Env) (sys : Option SysInfo) (body : Expr) (args : List Expr := []) :
    Array Bool := Id.run do
  let mut seen : Array Bool := Array.replicate env.globals.size false
  let mut seenFns : List String := []
  let mut work : List Expr := body :: args ++ (match sys with
    | some si => si.init.toList ++ stmtExprs si.step
    | none => [])
  for _ in [0:100000] do
    match work with
    | [] => break
    | e :: rest =>
      work := rest
      match e with
      | .gvar n =>
        if let some i := env.globalIx[n]? then
          if !seen[i]! then
            seen := seen.set! i true
            if let some g := env.globals[i]? then
              if let .node v _ := g.kind then work := v :: work
      | .call f args =>
        work := args ++ work
        if !seenFns.contains f then
          seenFns := f :: seenFns
          if let some fi := env.funs[f]? then work := fi.body :: work
      | .prim _ args | .rand _ args => work := args ++ work
      | .ite a b c | .choose a b c => work := a :: b :: c :: work
      | .cat alts => work := alts.map (·.1) ++ work
      | .catW alts => work := alts.map (·.1) ++ alts.map (·.2) ++ work
      | .letE a b => work := a :: b :: work
      | .quant _ _ _ a b c => work := a :: b :: c :: work
      | .matchE s arms d => work := s :: arms.map (·.2) ++ d.toList ++ work
      | _ => pure ()
  return seen
where
  stmtExprs : Stmt → List Expr
    | .skip => []
    | .assign _ e | .assert e => [e]
    | .seq a b => stmtExprs a ++ stmtExprs b
    | .ite c a b | .choose c a b => c :: stmtExprs a ++ stmtExprs b
    | .matchS s arms d => s :: (arms.flatMap fun (_, b) => stmtExprs b) ++ stmtExprs d
    | .letS v b _ => v :: stmtExprs b

/--
The state variables that `e` reads, directly or through local variables. `locals` gives, for each
local variable in scope, the state variables its value was computed from. Function bodies and
nodes can't read state variables, so a call depends only on its arguments.
-/
partial def exprVars (locals : List (List Nat)) : Expr → List Nat
  | .svar i => [i]
  | .bvar i => locals[i]?.getD []
  | .prim _ args | .rand _ args | .call _ args => args.flatMap (exprVars locals)
  | .ite a b c | .choose a b c => [a, b, c].flatMap (exprVars locals)
  | .cat alts => alts.flatMap fun (e, _) => exprVars locals e
  | .catW alts => alts.flatMap fun (e, w) => exprVars locals e ++ exprVars locals w
  | .letE v b => let d := exprVars locals v; d ++ exprVars (d :: locals) b
  | .quant _ _ _ lo hi b =>
    let d := exprVars locals lo ++ exprVars locals hi
    d ++ exprVars (d :: locals) b
  | .matchE s arms d =>
    exprVars locals s ++ arms.flatMap (fun (_, b) => exprVars locals b) ++
      (d.map (exprVars locals)).getD []
  | _ => []

/-- Whether `e` calls a function, and so might run out of fuel. -/
partial def hasCall : Expr → Bool
  | .call _ _ => true
  | .prim _ args | .rand _ args => args.any hasCall
  | .ite a b c | .choose a b c => hasCall a || hasCall b || hasCall c
  | .cat alts => alts.any (hasCall ·.1)
  | .catW alts => alts.any fun (e, w) => hasCall e || hasCall w
  | .letE v b => hasCall v || hasCall b
  | .quant _ _ _ lo hi b => hasCall lo || hasCall hi || hasCall b
  | .matchE s arms d => hasCall s || arms.any (hasCall ·.2) || d.any hasCall
  | _ => false

/--
The dependencies of a step. For each state variable, the result lists the state variables its new
value can depend on, through the assigned expression, the local variables it uses, or the
conditions that decide whether the assignment runs. It also returns the roots: state variables that
must always be kept, because assertions read them or because an assignment that might run out of
fuel depends on them.
-/
partial def stepDeps (n : Nat) (step : Stmt) : Array (List Nat) × List Nat :=
  go step [] [] (Array.replicate n [], [])
where
  go (st : Stmt) (locals : List (List Nat)) (ctl : List Nat) (acc : Array (List Nat) × List Nat) :
      Array (List Nat) × List Nat :=
    let (deps, roots) := acc
    match st with
    | .skip => acc
    | .assign i e =>
      let d := exprVars locals e ++ ctl
      let deps := deps.modify i (d ++ ·)
      if hasCall e then (deps, i :: d ++ roots) else (deps, roots)
    | .assert c => (deps, exprVars locals c ++ ctl ++ roots)
    | .seq a b => go b locals ctl (go a locals ctl acc)
    | .ite c a b | .choose c a b =>
      let ctl := exprVars locals c ++ ctl
      go b locals ctl (go a locals ctl acc)
    | .matchS sc arms d =>
      let ctl := exprVars locals sc ++ ctl
      go d locals ctl (arms.foldl (fun acc (_, b) => go b locals ctl acc) acc)
    | .letS v b _ =>
      let acc := if hasCall v then (deps, exprVars locals v ++ ctl ++ roots) else acc
      go b (exprVars locals v :: locals) ctl acc

/--
Marks the state variables of `si` that can influence `body`, its cone of influence. The other
variables can't affect the property: nothing that the property reads is computed from them, and no
assertion or possibly stuck computation reads them.
-/
def coneOfInfluence (si : SysInfo) (body : Expr) : Array Bool := Id.run do
  let n := si.vars.size
  let (deps, roots) := stepDeps n si.step
  let deps := deps.map (·.eraseDups)
  let mut seen : Array Bool := Array.replicate n false
  let mut work := exprVars [] body ++ roots
  -- each entry of `work` and of every dependency list is taken from the work list at most once
  for _ in [0:work.length + deps.foldl (· + ·.length) 0 + 1] do
    match work with
    | [] => break
    | i :: rest =>
      work := rest
      if i < n && !seen[i]! then
        seen := seen.set! i true
        work := deps[i]! ++ work
  return seen

/--
Removes assignments to the state variables that `relevant` doesn't mark. Those variables then keep
their initial values, which nothing reads.
-/
partial def sliceStep (relevant : Array Bool) : Stmt → Stmt
  | .assign i e => if relevant[i]?.getD true then .assign i e else .skip
  | .seq a b => .seq (sliceStep relevant a) (sliceStep relevant b)
  | .ite c a b => .ite c (sliceStep relevant a) (sliceStep relevant b)
  | .choose c a b => .choose c (sliceStep relevant a) (sliceStep relevant b)
  | .matchS sc arms d =>
    .matchS sc (arms.map fun (k, b) => (k, sliceStep relevant b)) (sliceStep relevant d)
  | .letS v b n => .letS v (sliceStep relevant b) n
  | st => st

/--
Replaces the value of every irrelevant global variable in each world by `Res.stuck`, and merges
worlds that become equal.
-/
def Branch.project (b : Branch) (relevant : Array Bool) : Branch :=
  { b with worlds := M.compactList (b.worlds.map fun (w, p) =>
      (w.mapIdx fun i r => if relevant[i]?.getD true then r else .stuck, p)) }

/-! ## Bounded model checking -/

/-- The largest number of configurations kept for one step. Larger state spaces are rejected. -/
def maxFrontier : Nat := 2000000

/--
A configuration that violates a property, with the step at which it occurs, the parameter
assignment, the probability mass of the path, and the degree of the property there.
-/
structure Witness where
  step : Nat
  assign : List (String × Value)
  config : Config
  degree : Rat
  mass : Rat
  deriving Inhabited

/--
The degree interval `[lo, hi]` of a property on one branch, with the assignment and possibility
of the branch and the largest number of configurations reached at any step.
-/
structure BranchResult where
  assign : List (String × Value)
  poss : Rat
  lo : Rat
  hi : Rat
  maxStates : Nat
  /-- An unbounded property explored only part of the state space. -/
  truncated : Bool := false
  /-- Every number was computed exactly, rather than bounded numerically. -/
  exact : Bool := true
  deriving Inhabited

/--
A bounded model checker for one property. `relevant` marks the global variables that the property
can read.
-/
structure Checker where
  env : Env
  fuel : Nat
  sys : Option SysInfo
  body : Expr
  relevant : Array Bool := #[]
  /-- The values of the system's parameters. -/
  args : List Expr := []
  /--
  Marks the state variables in the property's cone of influence. The others are never assigned and
  hold the placeholder `false`, so configurations that differ only in them are merged.
  -/
  relevantVars : Array Bool := #[]
  /--
  Whether a step may split its own work into parallel tasks when the frontier is small. Callers
  that already run many parameter assignments in parallel turn this off.
  -/
  splitSteps : Bool := true
  /-- The number of states explored for an unbounded property. -/
  maxStates : Nat := 100000
  /-- Whether steps record their random decisions, for `#tests`. -/
  trace : Bool := false
  /-- The names of the state variables, for labeling recorded decisions. -/
  varNames : Array String := #[]

namespace Checker

/--
The checker for a property. It reads only the global variables and state variables that can
influence the property, and runs a step without the assignments to the other state variables.
-/
def forSpec (env : Env) (fuel : Nat) (sys : Option SysInfo) (body : Expr) (args : List Expr) :
    Checker :=
  let relVars := (sys.map (coneOfInfluence · body)).getD #[]
  let sys := sys.map fun si => { si with step := sliceStep relVars si.step }
  { env, fuel, sys, body, args, relevant := relevantGlobals env sys body args, relevantVars := relVars }

/-- The evaluation context for a configuration. -/
def ctx (ck : Checker) (cfg : Config) : ECtx :=
  { env := ck.env, world := cfg.world, vars := cfg.st.vars, crashed := cfg.st.crashed, fuel := ck.fuel,
    trace := ck.trace, varNames := ck.varNames }

/--
Reads the value of a property as a degree. `true` is 1, `false` is 0, and degrees and numbers are
taken as they are.
-/
def toDeg : Value → Except String Rat
  | .bool b => pure (if b then 1 else 0)
  | .deg q => pure q
  | .num q => pure q
  | v => throw s!"kernel: property evaluated to non-truth value {repr v}"

/-- The distribution of the degree of the property in a configuration. -/
def degrees (ck : Checker) (cfg : Config) : Except String (List (Res Rat × Rat)) := do
  let xs ← liftM (eval (ck.ctx cfg) ck.body)
  xs.mapM fun (r, q) => match r with
    | .ok v => return (.ok (← toDeg v), q)
    | .stuck => pure (.stuck, q)

/-- The distribution of the value of the property in a configuration. -/
def values (ck : Checker) (cfg : Config) : Except String (List (Res Value × Rat)) :=
  liftM (eval (ck.ctx cfg) ck.body)

/--
The distribution of successor configurations after one step of the system. Without a system, a
configuration is its own successor.
-/
def step (ck : Checker) (cfg : Config) (par := false) : Except String (List (Res Config × Rat)) := do
  let some si := ck.sys | return [(.ok cfg, 1)]
  let xs ← liftM (exec { ck.ctx cfg with par } [] cfg.st si.step)
  return xs.map fun (r, q) => match r with
    | .ok st => (.ok { cfg with st }, q)
    | .stuck => (.stuck, q)

/--
The initial configurations of a branch, after projecting its worlds onto the relevant variables,
and the probability mass whose initialization ran out of fuel.
-/
def initial (ck : Checker) (b : Branch) : Except String (List (Config × Rat) × Rat) := do
  let b := b.project ck.relevant
  let mut out : Array (Config × Rat) := #[]
  let mut unk : Rat := 0
  for (w, p) in b.worlds do
    match ck.sys with
    | none => out := out.push ({ world := w, st := { vars := #[] } }, p)
    | some si =>
      let ctx : ECtx := { env := ck.env, world := w, fuel := ck.fuel }
      -- the parameters take the property's arguments; later initial values may refer to them
      let inits := ck.args.toArray ++ si.init.extract ck.args.length si.init.size
      let m : M (Array Value) := inits.foldlM (init := #[]) fun arr e => do
        let v ← eval { ctx with vars := arr } e
        pure (arr.push v)
      for (r, q) in ← liftM m do
        match r with
        | .ok vars =>
          let vars := vars.mapIdx fun i v => if ck.relevantVars[i]?.getD true then v else .bool false
          out := out.push ({ world := w, st := { vars } }, p * q)
        | .stuck => unk := unk + p * q
  return (M.compactList out.toList, unk)

/-- Fails when the number of configurations exceeds `maxFrontier`. -/
def guard (n : Nat) : Except String Unit :=
  if n > maxFrontier then throw s!"kernel: state space exceeded {maxFrontier} configurations"
  else pure ()

/--
The distribution of configurations after `k` steps, the probability mass that ran out of fuel,
and the largest number of configurations at any step.
-/
def after (ck : Checker) (b : Branch) (k : Nat) : Except String (List (Config × Rat) × Rat × Nat) := do
  let (cfgs, unk0) ← ck.initial b
  let mut frontier := cfgs
  let mut unk := unk0
  let mut maxN := frontier.length
  for _ in [0:k] do
    -- a small frontier leaves cores idle, so each step splits its own work instead
    let par := ck.splitSteps && frontier.length < parThreshold
    let succ ← parFlatMapM frontier.toArray fun (cfg, w) => do
      return (← ck.step cfg par).toArray.map fun (r, q) => (r, w * q)
    let mut next : Array (Config × Rat) := #[]
    for (r, m) in succ do
      match r with
      | .ok c' => next := next.push (c', m)
      | .stuck => unk := unk + m
    frontier := M.compactList next.toList
    maxN := max maxN frontier.length
    guard maxN
  return (frontier, unk, maxN)

/-! ## Unbounded properties -/

/-- The default number of states explored for an unbounded property. -/
def defaultMaxStates : Nat := 100000

/--
The reachable part of a system's state space, explored breadth first. `succ` gives each expanded
state's successors and `stuck` the probability that its step runs out of fuel. `depth` gives the
step at which a state was first found, and `parent` the state it was found from, with the
probability of that transition (or, for an initial state, its initial probability).
-/
structure StateSpace where
  configs : Array Config
  succ : Array (Array (Nat × Rat))
  stuck : Array Rat
  expanded : Array Bool
  depth : Array Nat
  parent : Array (Option Nat × Rat)
  init : Array (Nat × Rat)
  initUnk : Rat
  /-- Exploration stopped at `Checker.maxStates`, leaving some states unexpanded. -/
  truncated : Bool

/--
The probability of the path along which a state was first found. It is computed only when needed,
because along deep paths the exact product has a very large numerator and denominator.
-/
def StateSpace.pathMass (sp : StateSpace) (s : Nat) : Rat := Id.run do
  let mut m : Rat := 1
  let mut cur := s
  for _ in [0:sp.configs.size] do
    let (p, q) := sp.parent[cur]!
    m := m * q
    match p with
    | some p' => cur := p'
    | none => break
  return m

/--
Explores the states reachable from the initial configurations of a branch. Each level of the
search is expanded in parallel. Once `maxStates` states are known, the search stops, and the
states found but not expanded are left as they are: what happens after them counts as unknown,
which keeps the result sound for systems with infinitely many states.
-/
def explore (ck : Checker) (b : Branch) : Except String StateSpace := do
  let (cfgs, unk0) ← ck.initial b
  let mut ix : HashMap Config Nat := {}
  let mut configs : Array Config := #[]
  let mut depth : Array Nat := #[]
  let mut parent : Array (Option Nat × Rat) := #[]
  let mut init : Array (Nat × Rat) := #[]
  for (c, w) in cfgs do
    match ix[c]? with
    | some i => init := init.push (i, w)
    | none =>
      ix := ix.insert c configs.size
      init := init.push (configs.size, w)
      configs := configs.push c; depth := depth.push 0; parent := parent.push (none, w)
  let mut succ : Array (Array (Nat × Rat)) := Array.replicate configs.size #[]
  let mut stuck : Array Rat := Array.replicate configs.size 0
  let mut expanded : Array Bool := Array.replicate configs.size false
  let mut level : Array Nat := Array.range configs.size
  let mut d := 0
  let mut truncated := false
  while !level.isEmpty do
    if configs.size ≥ ck.maxStates then
      truncated := true
      break
    let par := ck.splitSteps && level.size < parThreshold
    -- copy out this level's configurations, so that no task holds on to `configs` while it grows
    let current := level.map (configs[·]!)
    let results ← parMapM current fun c => ck.step c par
    let mut next : Array Nat := #[]
    for (i, xs) in level.zip results do
      let mut out : Array (Nat × Rat) := #[]
      let mut st : Rat := 0
      for (r, q) in xs do
        match r with
        | .stuck => st := st + q
        | .ok c' =>
          match ix[c']? with
          | some j => out := out.push (j, q)
          | none =>
            let j := configs.size
            ix := ix.insert c' j
            configs := configs.push c'; depth := depth.push (d + 1); parent := parent.push (some i, q)
            succ := succ.push #[]; stuck := stuck.push 0; expanded := expanded.push false
            next := next.push j
            out := out.push (j, q)
      succ := succ.set! i (M.compactList out.toList).toArray
      stuck := stuck.set! i st
      expanded := expanded.set! i true
    guard configs.size
    level := next
    d := d + 1
  return { configs, succ, stuck, expanded, depth, parent, init, initUnk := unk0, truncated }

/--
Splits the distribution of a property's degree in each state into the probability of a "hit"
(a degree for which `hit` holds), of an unknown degree, and of the rest.
-/
def splitDegrees (degs : Array (List (Res Rat × Rat))) (hit : Rat → Bool) : Array (Rat × Rat × Rat) :=
  degs.map fun ds => ds.foldl (init := (0, 0, 0)) fun (h, u, c) (r, q) => match r with
    | .ok d => if hit d then (h + q, u, c) else (h, u, c + q)
    | .stuck => (h, u + q, c)

/--
The linear system for the probability of eventually hitting, given the split of each state.
The lower system counts unknown outcomes as never hitting, and the upper one as hitting.
-/
def reachSystem (sp : StateSpace) (split : Array (Rat × Rat × Rat)) (upper : Bool) : Solve.System :=
  { b := (Array.range sp.configs.size).map fun s =>
      let (h, u, c) := split[s]!
      if upper then h + u + c * (if sp.expanded[s]! then sp.stuck[s]! else 1) else h
    rows := (Array.range sp.configs.size).map fun s =>
      let (_, _, c) := split[s]!
      if sp.expanded[s]! && c != 0 then sp.succ[s]!.map fun (t, p) => (t, c * p) else #[] }

/--
Checks `always φ` or `eventually φ` over the infinite run, on one branch.

For a Boolean property, `eventually φ` is the probability of reaching a state where `φ` holds,
and `always φ` is one minus the probability of reaching a state where it fails. For a degree,
`eventually` takes the expected highest degree along the run, and `always` the expected lowest.
The layer-cake formula `E[X] = Σⱼ (θⱼ - θⱼ₋₁) P(X ≥ θⱼ)` reduces both to probabilities of
reaching a state where the degree is at least, or below, each value `θⱼ` that it takes.
-/
def runUnbounded (ck : Checker) (isAlways : Bool) (b : Branch) :
    Except String (BranchResult × Option Witness) := do
  let sp ← ck.explore b
  let degs ← parMapM sp.configs ck.degrees
  let n := sp.configs.size
  let mut seen : HashSet Rat := {}
  let mut ths : Array Rat := #[1]
  seen := seen.insert 1
  for ds in degs do
    for (r, q) in ds do
      if let .ok d := r then
        if d > 0 && q > 0 && !seen.contains d then seen := seen.insert d; ths := ths.push d
  let thresholds := ths.qsort (· < ·)
  let all := Array.replicate n true
  let sols ← parMapM' thresholds fun θ => do
    let split := splitDegrees degs (if isAlways then (· < θ) else (θ ≤ ·))
    pure (Solve.solve (reachSystem sp split false) all (some 1),
          Solve.solve (reachSystem sp split true) all (some 1))
  let known := sp.init.foldl (fun acc (_, w) => acc + w) 0
  let mut lo : Rat := 0
  let mut hi : Rat := 0
  let mut exact := true
  let mut prev : Rat := 0
  for (θ, ((sl, el), (sh, eh))) in thresholds.zip sols do
    exact := exact && el && eh
    let pLo := sp.init.foldl (fun acc (s, w) => acc + w * sl[s]!.1) 0
    let pHi := sp.init.foldl (fun acc (s, w) => acc + w * qmin 1 ((sh[s]!.2).getD 1)) 0
    if isAlways then
      lo := lo + (θ - prev) * (known - pHi)
      hi := hi + (θ - prev) * (known - pLo)
    else
      lo := lo + (θ - prev) * pLo
      hi := hi + (θ - prev) * pHi
    prev := θ
  hi := hi + sp.initUnk
  -- a counterexample: for `always`, the first state found where the property fails; for
  -- `eventually`, the first state from which it can never fully hold
  let mut wit : Option Witness := none
  if isAlways then
    for s in [0:n] do
      if let some (d, q) := degs[s]!.findSome? fun (r, q) => match r with
          | .ok d => if d < 1 && q > 0 then some (d, q) else none
          | .stuck => none then
        wit := some { step := sp.depth[s]!, assign := b.assign, config := sp.configs[s]!,
                      degree := d, mass := sp.pathMass s * q }
        break
  else if let some (_, (sh, _)) := sols.back? then
    for s in [0:n] do
      if (sh[s]!.2) == some 0 then
        wit := some { step := sp.depth[s]!, assign := b.assign, config := sp.configs[s]!,
                      degree := 0, mass := sp.pathMass s }
        break
  return ({ assign := b.assign, poss := b.poss, lo, hi, maxStates := n,
            truncated := sp.truncated, exact }, wit)

/--
The expected number of steps until a Boolean property first holds, on one branch, as a lower and
an upper bound, where `none` is +∞. Also returns the number of states, whether exploration was
truncated, and whether the bounds are exact.

The expectation is infinite from a state where, with positive probability, the property never
holds and nothing unknown happens; graph search finds these states exactly. From the other
states, the expectation solves `y = c + c·P y`, where `c` is the probability that the property
doesn't hold. Unknown outcomes count as taking no more steps for the lower bound, and as taking
infinitely many for the upper bound.
-/
def expectedSteps (ck : Checker) (b : Branch) :
    Except String (Option Rat × Option Rat × Nat × Bool × Bool) := do
  let sp ← ck.explore b
  let degs ← parMapM sp.configs ck.degrees
  let n := sp.configs.size
  let split := splitDegrees degs (1 ≤ ·)
  let cont : Nat → Rat := fun s => (split[s]!).2.2
  let toUnk : Array Bool := (Array.range n).map fun s =>
    (split[s]!).2.1 > (0 : Rat) || (cont s > 0 && (!sp.expanded[s]! || sp.stuck[s]! > 0))
  let toTarget : Array Bool := (Array.range n).map fun s => (split[s]!).1 > (0 : Rat) || toUnk[s]!
  let succ := (Array.range n).map fun s =>
    if sp.expanded[s]! && cont s > 0 then sp.succ[s]!.map (·.1) else #[]
  let never := (Solve.canReach succ toTarget).map (!·)
  -- `alive`: the property, or something unknown, happens with probability 1
  let alive := (Solve.canReach succ never).map (!·)
  let reachUnk := Solve.canReach succ toUnk
  let sys : Solve.System :=
    { b := (Array.range n).map fun s => if alive[s]! then cont s else 0
      rows := (Array.range n).map fun s =>
        if alive[s]! && sp.expanded[s]! then sp.succ[s]!.map fun (t, p) => (t, cont s * p) else #[] }
  let (sol, exact) := Solve.solve sys alive none
  let mut lo : Option Rat := some 0
  let mut hi : Option Rat := some 0
  for (s, w) in sp.init do
    if !alive[s]! then
      lo := none; hi := none
    else
      lo := lo.map (· + w * sol[s]!.1)
      hi := if reachUnk[s]! then none else match hi, sol[s]!.2 with
        | some x, some y => some (x + w * y)
        | _, _ => none
  if sp.initUnk > 0 then hi := none
  return (lo, hi, n, sp.truncated, exact)

/-! ## Probability-weighted test generation -/

/--
A run found by `Checker.weightedRuns`: its probability, the property's degree on it (`none` if an
outcome on it ran out of fuel), and the configuration after each step, starting with the initial
one. The trace of the last configuration lists the run's random decisions.
-/
structure Run where
  prob : Rat
  degree : Option Rat
  configs : Array Config
  /-- Whether the run is among the `n` most likely runs, rather than an extra failing run. -/
  inSuite : Bool
  deriving Inhabited

/-- The result of `Checker.weightedRuns`. -/
structure RunSearch where
  runs : Array Run
  /-- The total probability of the runs in the suite. -/
  covered : Rat
  /-- The total probability of the failing runs found. -/
  failingFound : Rat
  /-- Every run was found. -/
  complete : Bool
  /-- The search stopped at its budget before finding everything it looked for. -/
  budgetHit : Bool

/-- A partial run in the search, ordered by probability and then by when it was found. -/
structure RunNode where
  prob : Rat
  seq : Nat
  configs : Array Config
  /-- The lowest (for `always`) or highest (for `eventually`) degree so far. -/
  acc : Option Rat
  /-- The degree, once the run is complete. -/
  final : Option (Option Rat) := none
  deriving Inhabited

/-- Whether `a` comes before `b`: a more likely run first, and among equals the one found first. -/
def RunNode.before (a b : RunNode) : Bool := a.prob > b.prob || (a.prob == b.prob && a.seq < b.seq)

/-- Adds a node to a binary heap whose first element comes `before` all others. -/
def heapPush (h : Array RunNode) (x : RunNode) : Array RunNode := Id.run do
  let mut h := h.push x
  let mut i := h.size - 1
  while i > 0 do
    let p := (i - 1) / 2
    if h[i]!.before h[p]! then h := h.swapIfInBounds i p; i := p else break
  return h

/-- Removes the first node of a binary heap. -/
def heapPop (h : Array RunNode) : Option (RunNode × Array RunNode) := Id.run do
  let some top := h[0]? | return none
  let last := h.back!
  let mut h := h.pop
  if h.isEmpty then return some (top, h)
  h := h.set! 0 last
  let mut i := 0
  while true do
    let l := 2 * i + 1
    let r := l + 1
    let mut m := i
    if l < h.size && h[l]!.before h[m]! then m := l
    if r < h.size && h[r]!.before h[m]! then m := r
    if m == i then break
    h := h.swapIfInBounds i m
    i := m
  return some (top, h)

/--
The expected degree of the property in a configuration, or `none` if it can run out of fuel.
-/
def expectedDegree (ck : Checker) (cfg : Config) : Except String (Option Rat) := do
  let mut e : Rat := 0
  for (r, q) in ← ck.degrees cfg do
    match r with
    | .ok d => e := e + q * d
    | .stuck => return none
  return some e

/--
Lists the runs of a system up to the property's horizon in order of decreasing probability, which
is exact: a run is only reported once every more likely run has been. A run is a sequence of
configurations together with the random decisions that produced it, so runs that reach the same
states by different decisions are kept apart. A run ends early when the property's result is
settled (an `always` property has failed, or an `eventually` property has held) or when the system
stops changing.

The first `maxRuns` runs form the suite. If the property can fail (`failProb > 0`), the search goes
on until it has listed `maxFailing` failing runs or failing runs with the whole failure probability,
or until it has expanded `budget` partial runs.
-/
def weightedRuns (ck : Checker) (mode : Temporal) (b : Branch) (maxRuns : Nat) (failProb : Rat)
    (maxFailing : Nat := 3) (budget : Nat := 200000) : Except String RunSearch := do
  let k := match mode with | .after k | .always k | .eventually k => k | _ => 0
  let isAlways := mode matches .always _
  let isEventually := mode matches .eventually _
  let combine : Option Rat → Option Rat → Option Rat := fun a d => match a, d with
    | some x, some y => some (if isAlways then qmin x y else if isEventually then qmax x y else y)
    | _, _ => none
  let (cfgs, _) ← ck.initial b
  let mut heap : Array RunNode := #[]
  let mut seq := 0
  for (c, w) in cfgs do
    heap := heapPush heap { prob := w, seq, configs := #[c], acc := ← ck.expectedDegree c }
    seq := seq + 1
  let mut runs : Array Run := #[]
  let mut covered : Rat := 0
  let mut failingFound : Rat := 0
  let mut failingCount := 0
  let mut expanded := 0
  let mut budgetHit := false
  let mut found := 0
  while true do
    let suiteDone := found ≥ maxRuns
    let failDone := failProb == 0 || failingCount ≥ maxFailing || failingFound ≥ failProb
    if suiteDone && failDone then break
    if expanded ≥ budget then budgetHit := true; break
    let some (node, rest) := heapPop heap | break
    heap := rest
    let cfg := node.configs.back!
    let t := node.configs.size - 1
    -- is the run complete?
    let mut final := node.final
    if final.isNone then
      if (isAlways && node.acc == some 0) || (isEventually && node.acc == some 1) then
        final := some node.acc
      else if t == k then
        let here ← ck.expectedDegree cfg
        final := some (if isAlways || isEventually then node.acc else here)
    if let some degree := final then
      found := found + 1
      let fails := degree != some 1
      let inSuite := found ≤ maxRuns
      if inSuite then covered := covered + node.prob
      if fails then
        failingFound := failingFound + node.prob
        failingCount := failingCount + 1
      if inSuite || (fails && failingCount ≤ maxFailing) then
        runs := runs.push { prob := node.prob, degree, configs := node.configs, inSuite }
      continue
    expanded := expanded + 1
    let succ ← ck.step cfg
    -- a system that has stopped changing would repeat this configuration forever
    if let [(.ok c', q)] := succ then
      if q == 1 && c'.st.vars == cfg.st.vars && c'.st.crashed == cfg.st.crashed &&
          c'.st.trace.size == cfg.st.trace.size then
        let here ← ck.expectedDegree cfg
        let degree := if isAlways || isEventually then node.acc else here
        heap := heapPush heap { node with seq, final := some degree }
        seq := seq + 1
        continue
    for (r, q) in succ do
      if q == 0 then continue
      match r with
      | .stuck =>
        heap := heapPush heap { node with prob := node.prob * q, seq, final := some none }
      | .ok c' =>
        -- stamp the decisions made in this step with its number
        let n := cfg.st.trace.size
        let tr := c'.st.trace.mapIdx fun i e => if i < n then e else { e with step := t + 1 }
        let c' := { c' with st := { c'.st with trace := tr } }
        let d ← ck.expectedDegree c'
        heap := heapPush heap { prob := node.prob * q, seq, configs := node.configs.push c',
                                acc := combine node.acc d }
      seq := seq + 1
  return { runs, covered, failingFound, complete := heap.isEmpty && !budgetHit, budgetHit }

/--
Checks a property on one branch. Returns the exact degree interval, together with the first
configuration found that violates the property, if there is one.
-/
def runBranch (ck : Checker) (mode : Temporal) (b : Branch) :
    Except String (BranchResult × Option Witness) := do
  let mut lo : Rat := 0
  let mut hi : Rat := 0
  let mut wit : Option Witness := none
  let mut maxN := 0
  match mode with
  | .alwaysInf => return ← ck.runUnbounded true b
  | .eventuallyInf => return ← ck.runUnbounded false b
  | .stepsUntil => throw "kernel: `steps until` can only be used with #expect"
  | .after k =>
    let (frontier, unk, n) ← ck.after b k
    maxN := n
    hi := hi + unk
    for (cfg, w) in frontier do
      for (r, q) in ← ck.degrees cfg do
        match r with
        | .ok d =>
          lo := lo + w * q * d; hi := hi + w * q * d
          if d < 1 && wit.isNone then
            wit := some { step := k, assign := b.assign, config := cfg, degree := d, mass := w * q }
        | .stuck => hi := hi + w * q
  | .always k | .eventually k =>
    let isAlways := match mode with | .always _ => true | _ => false
    let unit : Rat := if isAlways then 1 else 0
    let (cfgs, unk0) ← ck.initial b
    hi := hi + unk0
    -- The frontier maps a configuration, paired with the running degree of the path that reached
    -- it (the minimum so far for `always`, the maximum for `eventually`), to its probability mass.
    let mut frontier : List ((Config × Rat) × Rat) := []
    for t in [0:k+1] do
      -- Each arrival is a successor configuration (or `stuck` if the step ran out of fuel), its
      -- mass, and the running degree of the path that led to it.
      let arrivals : Array ((Res Config × Rat) × Rat) ←
        if t == 0 then pure (cfgs.toArray.map fun (c, w) => ((.ok c, unit), w))
        else
          let par := ck.splitSteps && frontier.length < parThreshold
          parFlatMapM frontier.toArray fun ((cfg, acc), w) => do
            return (← ck.step cfg par).toArray.map fun (r, q) => ((r, acc), w * q)
      -- Merge equal arrivals, so the property is evaluated once per distinct configuration.
      let arrivals := (M.compactList arrivals.toList).toArray
      let degs ← parMapM arrivals fun ((r, _), _) => match r with
        | .ok c' => ck.degrees c'
        | .stuck => pure []
      let mut next : Array ((Config × Rat) × Rat) := #[]
      for (((r, acc), w), ds) in arrivals.zip degs do
        match r with
        | .stuck =>
          -- The rest of the path is unknown, so `lo` assumes the worst case and `hi` the best.
          if isAlways then
            hi := hi + w * acc
          else
            lo := lo + w * acc
            hi := hi + w
        | .ok c' =>
          for (rd, qd) in ds do
            let m := w * qd
            match rd with
            | .stuck =>
              if isAlways then
                hi := hi + m * acc
              else
                lo := lo + m * acc
                hi := hi + m
            | .ok d =>
              if isAlways then
                if d < 1 && wit.isNone then
                  wit := some { step := t, assign := b.assign, config := c', degree := d, mass := m }
                let a := qmin acc d
                if a > 0 then next := next.push ((c', a), m)
              else
                let a := qmax acc d
                if a == 1 then
                  lo := lo + m
                  hi := hi + m
                else
                  next := next.push ((c', a), m)
      frontier := M.compactList next.toList
      maxN := max maxN frontier.length
      guard maxN
    for ((cfg, acc), w) in frontier do
      lo := lo + w * acc
      hi := hi + w * acc
      if !isAlways && wit.isNone then
        wit := some { step := k, assign := b.assign, config := cfg, degree := acc, mass := w }
  return ({ assign := b.assign, poss := b.poss, lo, hi, maxStates := maxN }, wit)

/--
Finds values for the leading `forall` quantifiers and conjunctions of a failed property that
falsify it. The result only makes messages more helpful and isn't part of the checked result.
-/
partial def counterexample (ck : Checker) (c : ECtx) (e : Expr) : List (String × Value) :=
  let certain (c : ECtx) (e : Expr) : Bool := match liftM (eval c e) with
    | .ok xs => xs.all fun (r, _) => r == .ok (.bool true) || r == .ok (.deg 1)
    | .error _ => false
  match e with
  | .quant true _ n lo hi body =>
    match liftM (eval c lo), liftM (eval c hi) with
    | .ok [(.ok (.num a), _)], .ok [(.ok (.num b), _)] =>
      if !(isInt a && isInt b) || b < a then [] else
      let count := (b.num - a.num + 1).toNat
      let xs := (List.range count).map fun (i : Nat) => Value.num (a + (i : Rat))
      match xs.find? (fun x => !certain { c with locals := x :: c.locals } body) with
      | some x => (n, x) :: ck.counterexample { c with locals := x :: c.locals } body
      | none => []
    | _, _ => []
  | .prim .band [a, b] | .prim (.tand _) [a, b] =>
    if certain c a then ck.counterexample c b else ck.counterexample c a
  | _ => []

end Checker

end Haze.Kernel
