/-
Copyright (c) 2026 Ritabrata Maiti. All rights reserved.
Released under the PolyForm Noncommercial License 1.0.0 as described in the file LICENSE.md.
Authors: Ritabrata Maiti
-/
import Haze.Kernel.Eval

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
  bs.mapM fun b => do
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
partial def relevantGlobals (env : Env) (sys : Option SysInfo) (body : Expr) : Array Bool := Id.run do
  let mut seen : Array Bool := Array.replicate env.globals.size false
  let mut seenFns : List String := []
  let mut work : List Expr := body :: (match sys with
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
    | .letS v b => v :: stmtExprs b

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

namespace Checker

/-- The evaluation context for a configuration. -/
def ctx (ck : Checker) (cfg : Config) : ECtx :=
  { env := ck.env, world := cfg.world, vars := cfg.st.vars, crashed := cfg.st.crashed, fuel := ck.fuel }

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
def step (ck : Checker) (cfg : Config) : Except String (List (Res Config × Rat)) := do
  let some si := ck.sys | return [(.ok cfg, 1)]
  let xs ← liftM (exec (ck.ctx cfg) [] cfg.st si.step)
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
      let m : M (Array Value) := si.init.foldlM (init := #[]) fun arr e => do
        let v ← eval ctx e
        pure (arr.push v)
      for (r, q) in ← liftM m do
        match r with
        | .ok vars => out := out.push ({ world := w, st := { vars } }, p * q)
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
    let mut next : Array (Config × Rat) := #[]
    for (cfg, w) in frontier do
      for (r, q) in ← ck.step cfg do
        match r with
        | .ok c' => next := next.push (c', w * q)
        | .stuck => unk := unk + w * q
    frontier := M.compactList next.toList
    maxN := max maxN frontier.length
    guard maxN
  return (frontier, unk, maxN)

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
      let mut arrivals : Array (Res Config × Rat × Rat) := #[]
      if t == 0 then
        arrivals := cfgs.toArray.map fun (c, w) => (.ok c, w, unit)
      else
        for ((cfg, acc), w) in frontier do
          for (r, q) in ← ck.step cfg do
            arrivals := arrivals.push (r, w * q, acc)
      let mut next : Array ((Config × Rat) × Rat) := #[]
      for (r, w, acc) in arrivals do
        match r with
        | .stuck =>
          -- The rest of the path is unknown, so `lo` assumes the worst case and `hi` the best.
          if isAlways then
            hi := hi + w * acc
          else
            lo := lo + w * acc
            hi := hi + w
        | .ok c' =>
          for (rd, qd) in ← ck.degrees c' do
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
