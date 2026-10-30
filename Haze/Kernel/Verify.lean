/-
Kernel semantics of programs: worlds, fuzzy branches, bounded model checking and
the α-cut integration that turns per-parameter results into `[belief, plausibility]`.

Semantics (see docs/DESIGN.md):
* A fuzzy parameter `p ≈ {v₁: m₁, …}` is a possibility distribution. Drawing `α ~ U(0,1]`
  gives the α-cut `{v | m(v) ≥ α}`, a set of admissible values (consonant random set).
* For each joint parameter assignment `y` (possibility `π(y) = min mᵢ`) the program is an
  exact finite Markov chain; a property gets an exact degree interval `[lo_y, hi_y]`
  (`hi_y - lo_y` is the mass on which evaluation ran out of fuel = formally unknown).
* `Bel = ∫₀¹ min_{π(y) ≥ α} lo_y dα`, `Pl = ∫₀¹ max_{π(y) ≥ α} hi_y dα`.
  With only probabilistic inputs this is the exact probability; with only fuzzy inputs it
  is the necessity/possibility pair of possibility theory.
-/
import Haze.Kernel.Eval

namespace Haze.Kernel
open Std

abbrev World := Array (Res Value)

structure Branch where
  assign : List (String × Value) := []
  poss : Rat := 1
  worlds : List (World × Rat) := [(#[], 1)]
  deriving Inhabited

structure Config where
  world : World
  st : SState
  deriving DecidableEq, Hashable, Inhabited

def liftM (m : M α) : Except String (List (Res α × Rat)) := m.run

/-! ## Building worlds -/

def addParam (name : String) (support : List (Value × Rat)) (bs : Array Branch) : Array Branch :=
  bs.flatMap fun b => (support.filter (·.2 > 0)).toArray.map fun (v, m) =>
    { assign := b.assign ++ [(name, v)], poss := qmin b.poss m,
      worlds := b.worlds.map fun (w, p) => (w.push (.ok v), p) }

def addNode (env : Env) (fuel : Nat) (val : Expr) (bs : Array Branch) :
    Except String (Array Branch) :=
  bs.mapM fun b => do
    let mut out : Array (World × Rat) := #[]
    for (w, p) in b.worlds do
      for (r, q) in ← liftM (eval { env, world := w, fuel } val) do
        out := out.push (w.push r, p * q)
    pure { b with worlds := M.compactList out.toList }

structure ObserveResult where
  branches : Array Branch
  evidence : List (List (String × Value) × Rat)
  dropped : Nat

/-- Bayesian conditioning on a Boolean observation, per parameter assignment. -/
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

/-- `rows` are `(π(y), lo_y, hi_y)`. Returns `[Bel, Pl]` by integrating over α-cuts.
If conditioning removed the core (max π < 1), possibilities are renormalised by the max. -/
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

/-- Same α-cut integration for unbounded numeric expectations (lower/upper Choquet). -/
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

/-! ## Relevance: marginalising worlds onto the globals a property depends on -/

/-- Globals (by world index) that `spec` can read, transitively through node definitions,
called functions and the system's init/step. Projecting worlds onto this set and merging
equal projections is sound (the property cannot observe the other coordinates) and
shrinks the state space. -/
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

def Branch.project (b : Branch) (relevant : Array Bool) : Branch :=
  { b with worlds := M.compactList (b.worlds.map fun (w, p) =>
      (w.mapIdx fun i r => if relevant[i]?.getD true then r else .stuck, p)) }

/-! ## Bounded model checking -/

def maxFrontier : Nat := 2000000

structure Witness where
  step : Nat
  assign : List (String × Value)
  config : Config
  degree : Rat
  mass : Rat
  deriving Inhabited

structure BranchResult where
  assign : List (String × Value)
  poss : Rat
  lo : Rat
  hi : Rat
  maxStates : Nat
  deriving Inhabited

structure Checker where
  env : Env
  fuel : Nat
  sys : Option SysInfo
  body : Expr
  relevant : Array Bool := #[]

namespace Checker

def ctx (ck : Checker) (cfg : Config) : ECtx :=
  { env := ck.env, world := cfg.world, vars := cfg.st.vars, crashed := cfg.st.crashed, fuel := ck.fuel }

def toDeg : Value → Except String Rat
  | .bool b => pure (if b then 1 else 0)
  | .deg q => pure q
  | .num q => pure q
  | v => throw s!"kernel: property evaluated to non-truth value {repr v}"

def degrees (ck : Checker) (cfg : Config) : Except String (List (Res Rat × Rat)) := do
  let xs ← liftM (eval (ck.ctx cfg) ck.body)
  xs.mapM fun (r, q) => match r with
    | .ok v => return (.ok (← toDeg v), q)
    | .stuck => pure (.stuck, q)

def values (ck : Checker) (cfg : Config) : Except String (List (Res Value × Rat)) :=
  liftM (eval (ck.ctx cfg) ck.body)

def step (ck : Checker) (cfg : Config) : Except String (List (Res Config × Rat)) := do
  let some si := ck.sys | return [(.ok cfg, 1)]
  let xs ← liftM (exec (ck.ctx cfg) [] cfg.st si.step)
  return xs.map fun (r, q) => match r with
    | .ok st => (.ok { cfg with st }, q)
    | .stuck => (.stuck, q)

/-- Initial configurations; the second component is mass whose initialisation diverged. -/
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

def guard (n : Nat) : Except String Unit :=
  if n > maxFrontier then throw s!"kernel: state space exceeded {maxFrontier} configurations"
  else pure ()

/-- Distribution over configurations after `k` steps, plus diverged mass. -/
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

/-- Evaluate the property on one fuzzy branch: exact `[lo, hi]` and an optional witness of
(partial) failure. -/
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
    -- frontier: (configuration, running min (always) / max (eventually) degree) ↦ mass
    let mut frontier : List ((Config × Rat) × Rat) := []
    for t in [0:k+1] do
      -- arrivals: (successor or divergence, mass, accumulator of the incoming path)
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
          -- the rest of the path is unknown: worst case for `lo`, best case for `hi`
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

/-- For a failed property, search its leading `forall` / `and` structure for concrete
bindings that falsify it (diagnostics only; not part of the trusted result). -/
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
