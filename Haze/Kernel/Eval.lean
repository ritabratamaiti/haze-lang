/-
Copyright (c) 2026 Ritabrata Maiti. All rights reserved.
Released under the Functional Source License 1.1 (FSL-1.1-ALv2) as described in the file LICENSE.md.
Authors: Ritabrata Maiti
-/
import Haze.Kernel.Check

/-!
# Exact Evaluation

This file gives kernel terms their exact meaning. A term denotes a finite probability distribution
over outcomes, with exact rational weights. An outcome is either a value or `Res.stuck`, which means
that evaluation ran out of fuel and the outcome is unknown. Runtime faults such as division by
zero are not outcomes: they abort evaluation with an error.

## Main Definitions

* `Haze.Kernel.M`: the exact distribution monad.
* `Haze.Kernel.eval`: evaluates a term.
* `Haze.Kernel.exec`: executes one statement of a system step.
-/

namespace Haze.Kernel
open Std

/--
Exact finite probability distributions over outcomes, which can also fail with a runtime error.

An outcome is either a value or `Res.stuck`, which means that evaluation ran out of fuel. Weights
are exact rational numbers.
-/
structure M (α : Type) where
  run : Except String (List (Res α × Rat))

namespace M
/-- The distribution with all of its mass on `a`. -/
def pure (a : α) : M α := ⟨.ok [(.ok a, 1)]⟩

/--
Combines the distributions that a computation's continuation gives for each element of an
ambiguous outcome. The result pairs up the distributions by cumulative probability: each part of
the result carries the outcomes that the distributions have at the same point of their cumulative
probability, as one ambiguous outcome. Whichever element the ambiguity stands for, its distribution
picks one outcome from each part, so the result allows everything that the original allowed. An
unknown outcome makes the whole part unknown. Elements may repeat in the result.
-/
def couple (ds : List (List (Res β × Rat))) : List (Res β × Rat) := Id.run do
  let ds := ds.toArray.map (·.toArray)
  if ds.isEmpty then return []
  let mut pos : Array Nat := Array.replicate ds.size 0
  let mut rem : Array Rat := ds.map fun d => (d[0]?.map (·.2)).getD 0
  let mut out : Array (Res β × Rat) := #[]
  for _ in [0:ds.foldl (· + ·.size) 0] do
    if (Array.range ds.size).any fun i => pos[i]! ≥ ds[i]!.size then break
    let m := rem.foldl qmin rem[0]!
    let heads := (Array.range ds.size).map fun i => ds[i]![pos[i]!]!.1
    let r : Res β :=
      if heads.any (fun | .stuck => true | _ => false) then .stuck
      else
        let xs := heads.toList.flatMap fun | .ok b => [b] | .amb bs => bs | .stuck => []
        match xs with
        | [b] => .ok b
        | _ => .amb xs
    if m > 0 then out := out.push (r, m)
    for i in [0:ds.size] do
      let left := rem[i]! - m
      if left ≤ 0 then
        pos := pos.set! i (pos[i]! + 1)
        rem := rem.set! i ((ds[i]![pos[i]!]?.map (·.2)).getD 0)
      else rem := rem.set! i left
  -- the distributions normally have the same total; any difference is left unknown
  let total := out.foldl (· + ·.2) 0
  let most := ds.foldl (fun acc d => qmax acc (d.foldl (· + ·.2) 0)) 0
  if total < most then out := out.push (.stuck, most - total)
  return out.toList

/--
Sequences two computations, multiplying their weights. Stuck mass stays stuck, and outcomes of
weight 0 are dropped. After an ambiguous outcome, the continuation runs for each of its elements,
and `couple` combines the results.
-/
def bind (m : M α) (f : α → M β) : M β := ⟨do
  let xs ← m.run
  -- Most terms are deterministic, so skip the general loop when the first part is certain.
  if let [(.ok a, 1)] := xs then return ← (f a).run
  let mut out : Array (Res β × Rat) := #[]
  for (r, w) in xs do
    match r with
    | .stuck => out := out.push (.stuck, w)
    | .ok a =>
      let ys ← (f a).run
      for (s, v) in ys do
        if w * v != 0 then out := out.push (s, w * v)
    | .amb as =>
      let ys ← as.mapM fun a => (f a).run
      for (s, v) in couple ys do
        if w * v != 0 then out := out.push (s, w * v)
  return out.toList⟩

instance : Monad M where
  pure := M.pure
  bind := M.bind

/-- Aborts with a runtime error. -/
def fail (msg : String) : M α := ⟨.error msg⟩
/-- The distribution with all of its mass on the unknown outcome. -/
def stuck : M α := ⟨.ok [(.stuck, 1)]⟩

/-- The distribution with the given outcomes and weights, dropping outcomes of weight 0. -/
def ofList (xs : List (α × Rat)) : M α :=
  ⟨.ok (xs.filterMap fun (a, w) => if w == 0 then none else some (.ok a, w))⟩

/--
Merges equal outcomes by adding their weights and drops outcomes of weight 0. Outcomes keep the
order of their first occurrence, so the output is deterministic.
-/
def compactList [BEq α] [Hashable α] (xs : List (α × Rat)) : List (α × Rat) := Id.run do
  if let [(_, w)] := xs then return if w == 0 then [] else xs
  let mut ix : HashMap α Nat := {}
  let mut out : Array (α × Rat) := #[]
  for (a, w) in xs do
    match ix[a]? with
    | some i => out := out.modify i fun (b, v) => (b, v + w)
    | none => ix := ix.insert a out.size; out := out.push (a, w)
  return (out.filter (·.2 != 0)).toList

/-- Merges equal outcomes of a computation, as `compactList` does. -/
def compact [DecidableEq α] [Hashable α] (m : M α) : M α := ⟨return compactList (← m.run)⟩

/--
Sequences two computations like `bind`. If `par` is set and the first computation has several
outcomes, the continuations for the different outcomes run as parallel tasks and are told not to
split again; otherwise `par` is passed on. The result is the same as `bind` either way.
-/
def bindSplit (par : Bool) (m : M α) (f : Bool → α → M β) : M β := ⟨do
  let xs ← m.run
  if !par || xs.length < 8 then return ← (bind m (f par)).run
  let tasks := xs.toArray.map fun (r, w) => Task.spawn fun _ =>
    match r with
    | .stuck => (Except.ok #[(Res.stuck, w)] : Except String (Array (Res β × Rat)))
    | .ok a => do
      let ys ← (f false a).run
      return ys.toArray.filterMap fun (p : Res β × Rat) =>
        if w * p.2 != 0 then some (p.1, w * p.2) else none
    | .amb as => do
      let ys ← as.mapM fun a => (f false a).run
      return (couple ys).toArray.filterMap fun (p : Res β × Rat) =>
        if w * p.2 != 0 then some (p.1, w * p.2) else none
  let mut out : Array (Res β × Rat) := #[]
  for t in tasks do out := out ++ (← t.get)
  return out.toList⟩
end M

/--
The evaluation context: the current world, the state of the enclosing system, the local variables
and the remaining fuel.
-/
structure ECtx where
  env : Env
  world : Array (Res Value) := #[]
  vars : Array Value := #[]
  crashed : Bool := false
  locals : List Value := []
  fuel : Nat
  /-- Whether a statement may split its work into parallel tasks. -/
  par : Bool := false
  /--
  Whether `exec` records the random decisions it makes, for `#tests`. Recording doesn't change
  any probability; it only keeps runs that made different decisions apart.
  -/
  trace : Bool := false
  /-- The names of the state variables, used only to label recorded decisions. -/
  varNames : Array String := #[]

/-- Reads a value as a number, failing on any other kind of value. An interval is unknown. -/
def asNum : Value → M Rat
  | .num q => pure q
  | .ival .. => M.stuck
  | v => M.fail s!"runtime: expected a number, got {repr v}"

/-- Reads a value as a degree, failing on any other kind of value. An interval is unknown. -/
def asDeg : Value → M Rat
  | .deg q => pure q
  | .ival .. => M.stuck
  | v => M.fail s!"runtime: expected a degree, got {repr v}"

/-- Reads a value as a Boolean, failing on any other kind of value. -/
def asBool : Value → M Bool
  | .bool b => pure b
  | v => M.fail s!"runtime: expected a Bool, got {repr v}"

/-- Reads a rational number as an integer, failing if it isn't one. -/
def asInt (q : Rat) : M Int :=
  if isInt q then pure q.num else M.fail s!"runtime: expected an integer, got {fmtQ q}"

/-- Clamps a rational number to the interval from 0 to 1. -/
def clamp01 (q : Rat) : Rat := qmax 0 (qmin 1 q)

/--
The t-norm of a fuzzy logic, which is how the logic interprets `and` on degrees. Gödel logic uses
`min`, product logic uses multiplication, and Łukasiewicz logic uses `max 0 (a + b - 1)`.
-/
def tand : Logic → Rat → Rat → Rat
  | .godel, a, b => qmin a b
  | .product, a, b => a * b
  | .lukasiewicz, a, b => qmax 0 (a + b - 1)

/--
The t-conorm of a fuzzy logic, which is how the logic interprets `or` on degrees. It is the dual
of `tand` under the negation `1 - x`.
-/
def tor : Logic → Rat → Rat → Rat
  | .godel, a, b => qmax a b
  | .product, a, b => a + b - a * b
  | .lukasiewicz, a, b => qmin 1 (a + b)

/--
The triangular membership function. It is 0 outside the interval from `a` to `c`, rises linearly
to 1 at `x = b`, and falls linearly after that.
-/
def tri (x a b c : Rat) : Rat :=
  if x < a then 0 else if x < b then (x - a) / (b - a)
  else if x == b then 1 else if x < c then (c - x) / (c - b) else 0

/--
The trapezoidal membership function. It rises linearly from `a` to `b`, is 1 from `b` to `c`, and
falls linearly from `c` to `d`.
-/
def trap (x a b c d : Rat) : Rat :=
  if x < a then 0 else if x < b then (x - a) / (b - a)
  else if x ≤ c then 1 else if x < d then (d - x) / (d - c) else 0

/--
The rising ramp membership function: 0 up to `a`, 1 from `b` on, and linear in between. The
falling ramp `rampDown` is computed as `1 - rampUp`.
-/
def rampUp (x a b : Rat) : Rat :=
  if x ≤ a then 0 else if b ≤ x then 1 else (x - a) / (b - a)

/-! ## Intervals

While the kernel bounds a property over a range of values of a continuous fuzzy parameter, the
parameter's value is an interval, and so are the values computed from it. Each operation on
intervals gives a result that contains its result for every choice of values from its arguments.
A comparison or a choice that an interval can't decide gives an ambiguous outcome, and anything
else it can't bound gives the unknown outcome.
-/

/--
The bounds of a number, a degree or an interval: the lower and upper end, and whether each end is
excluded. A number is an interval with both ends equal and included.
-/
structure Bnd where
  lo : Rat
  hi : Rat
  openLo : Bool := false
  openHi : Bool := false
  deriving BEq, Hashable, Inhabited

/-- The bounds of a number, a degree or an interval. -/
def bounds : Value → Option Bnd
  | .num q | .deg q => some { lo := q, hi := q }
  | .ival l h ol oh => some { lo := l, hi := h, openLo := ol, openHi := oh }
  | _ => none

/-- Checks whether a value is an interval. -/
def isIval : Value → Bool
  | .ival .. => true
  | _ => false

/-- The numbers (or degrees, if `deg`) in bounds `b`, as a single value when its ends are equal. -/
def mkIvalB (b : Bnd) (deg : Bool) : Value :=
  if b.lo == b.hi then (if deg then .deg b.lo else .num b.lo) else .ival b.lo b.hi b.openLo b.openHi

/-- The numbers (or degrees, if `deg`) from `l` to `h`, ends included. -/
def mkIval (l h : Rat) (deg : Bool) : Value := mkIvalB { lo := l, hi := h } deg

/-- The outcome `true` or `false`, without knowing which. -/
def ambBool : M Value := ⟨.ok [(.amb [.bool true, .bool false], 1)]⟩

/-- A truth value that may be undecided. -/
def decided : Option Bool → M Value
  | some b => pure (.bool b)
  | none => ambBool

/-- The smallest and largest of a list of numbers, which must not be empty. -/
def hull (xs : List Rat) : Rat × Rat :=
  let x0 := xs.headD 0
  (xs.foldl qmin x0, xs.foldl qmax x0)

/-- Whether every number in `x` is below every number in `y`. -/
def Bnd.below (x y : Bnd) : Bool := x.hi < y.lo || (x.hi == y.lo && (x.openHi || y.openLo))

/-- Whether every number in `x` is at most every number in `y`. -/
def Bnd.atMost (x y : Bnd) : Bool := x.hi ≤ y.lo

/-- Multiplies bounds by a constant, which keeps excluded ends excluded. -/
def Bnd.scale (x : Bnd) (c : Rat) : Bnd :=
  if c == 0 then { lo := 0, hi := 0 }
  else if 0 < c then { lo := x.lo * c, hi := x.hi * c, openLo := x.openLo, openHi := x.openHi }
  else { lo := x.hi * c, hi := x.lo * c, openLo := x.openHi, openHi := x.openLo }

/--
Applies a primitive to arguments of which at least one is an interval. Degrees stay between 0 and
1, so the fuzzy connectives are monotone in each argument. Excluded ends are tracked through
addition, subtraction and scaling, which is enough to decide comparisons with the constants a
parameter's range was split at; elsewhere the ends are included, which only widens the result.
-/
def evalPrimIval (op : Prim) (vs : List Value) : M Value := do
  let some bs := vs.mapM bounds | M.stuck
  let num := fun (b : Bnd) => pure (mkIvalB b false)
  let closed := fun (l h : Rat) => pure (mkIval l h false)
  let deg := fun (l h : Rat) => pure (mkIval (clamp01 l) (clamp01 h) true)
  match op, bs with
  | .add, [x, y] => num { lo := x.lo + y.lo, hi := x.hi + y.hi, openLo := x.openLo || y.openLo,
                          openHi := x.openHi || y.openHi }
  | .sub, [x, y] => num { lo := x.lo - y.hi, hi := x.hi - y.lo, openLo := x.openLo || y.openHi,
                          openHi := x.openHi || y.openLo }
  | .mul, [x, y] =>
    if y.lo == y.hi then num (x.scale y.lo) else if x.lo == x.hi then num (y.scale x.lo) else
    let (l, h) := hull [x.lo * y.lo, x.lo * y.hi, x.hi * y.lo, x.hi * y.hi]; closed l h
  | .div, [x, y] =>
    if y.lo == 0 && y.hi == 0 then M.fail "runtime: division by zero"
    else if y.lo == y.hi then num (x.scale (1 / y.lo))
    else if y.lo ≤ 0 && 0 ≤ y.hi then M.stuck
    else let (l, h) := hull [x.lo / y.lo, x.lo / y.hi, x.hi / y.lo, x.hi / y.hi]; closed l h
  | .min, [x, y] => closed (qmin x.lo y.lo) (qmin x.hi y.hi)
  | .max, [x, y] => closed (qmax x.lo y.lo) (qmax x.hi y.hi)
  | .neg, [x] => num (x.scale (-1))
  | .abs, [x] =>
    if 0 ≤ x.lo then num x else if x.hi ≤ 0 then num (x.scale (-1))
    else closed 0 (qmax (-x.lo) x.hi)
  | .floor, [x] =>
    let (l, h) := (x.lo.floor, x.hi.floor)
    if l == h then pure (.num (l : Rat))
    else if h - l ≥ 64 then M.stuck
    else ⟨.ok [(.amb ((List.range (h - l + 1).toNat).map fun (i : Nat) => .num ((l + (i : Int) : Int) : Rat)), 1)]⟩
  | .lt, [x, y] => decided (if x.below y then some true else if y.atMost x then some false else none)
  | .le, [x, y] => decided (if x.atMost y then some true else if y.below x then some false else none)
  | .eq, [x, y] => decided (if x.below y || y.below x then some false else none)
  | .ne, [x, y] => decided (if x.below y || y.below x then some true else none)
  | .tand l, [x, y] => deg (tand l x.lo y.lo) (tand l x.hi y.hi)
  | .tor l, [x, y] => deg (tor l x.lo y.lo) (tor l x.hi y.hi)
  | .tnot, [x] => deg (1 - x.hi) (1 - x.lo)
  | .very, [x] => deg (x.lo * x.lo) (x.hi * x.hi)
  | .numOfDeg, [x] => num x
  | .degOfNum, [x] =>
    if 0 ≤ x.lo && x.hi ≤ 1 then pure (mkIvalB x true)
    else if x.hi < 0 || 1 < x.lo then M.fail s!"runtime: no value from {fmtQ x.lo} to {fmtQ x.hi} is a degree in [0,1]"
    else M.stuck
  -- a membership function with a peak or plateau takes its smallest value over an interval at one
  -- end of it, and its largest at the peak if the interval contains it
  | .tri, [x, a, b, c] =>
    if a.lo != a.hi || b.lo != b.hi || c.lo != c.hi then M.stuck else
    let (fx, fy) := (clamp01 (tri x.lo a.lo b.lo c.lo), clamp01 (tri x.hi a.lo b.lo c.lo))
    deg (qmin fx fy) (if x.lo ≤ b.lo && b.lo ≤ x.hi then 1 else qmax fx fy)
  | .trap, [x, a, b, c, d] =>
    if a.lo != a.hi || b.lo != b.hi || c.lo != c.hi || d.lo != d.hi then M.stuck else
    let (fx, fy) := (clamp01 (trap x.lo a.lo b.lo c.lo d.lo), clamp01 (trap x.hi a.lo b.lo c.lo d.lo))
    deg (qmin fx fy) (if x.lo ≤ c.lo && b.lo ≤ x.hi then 1 else qmax fx fy)
  | .rampUp, [x, a, b] =>
    if a.lo != a.hi || b.lo != b.hi then M.stuck else deg (rampUp x.lo a.lo b.lo) (rampUp x.hi a.lo b.lo)
  | .rampDown, [x, a, b] =>
    if a.lo != a.hi || b.lo != b.hi then M.stuck
    else deg (1 - clamp01 (rampUp x.hi a.lo b.lo)) (1 - clamp01 (rampUp x.lo a.lo b.lo))
  | _, _ => M.stuck

/--
A choice that is `true` with probability `p`, where `p` may be an interval from `l` to `h`. Then
`true` has probability at least `l` and `false` at least `1 - h`, and the remaining `h - l` is
ambiguous.
-/
def flipVal (p : Value) : M Bool := do
  match p with
  | .ival l h _ _ =>
    let l := clamp01 l
    let h := clamp01 h
    ⟨.ok ([(Res.ok true, l), (.ok false, 1 - h), (.amb [true, false], h - l)].filter (·.2 != 0))⟩
  | _ =>
    let q ← asDeg p
    M.ofList [(true, q), (false, 1 - q)]

/--
Applies a primitive to argument values. Membership functions are clamped to the interval from 0
to 1.
-/
def evalPrim (op : Prim) (vs : List Value) : M Value := do
  if vs.any isIval then return ← evalPrimIval op vs
  match op, vs with
  | .eq, [a, b] => pure (.bool (a == b))
  | .ne, [a, b] => pure (.bool (a != b))
  | .add, [a, b] => return .num ((← asNum a) + (← asNum b))
  | .sub, [a, b] => return .num ((← asNum a) - (← asNum b))
  | .mul, [a, b] => return .num ((← asNum a) * (← asNum b))
  | .div, [a, b] =>
    let d ← asNum b
    if d == 0 then M.fail "runtime: division by zero" else return .num ((← asNum a) / d)
  | .min, [a, b] => return .num (qmin (← asNum a) (← asNum b))
  | .max, [a, b] => return .num (qmax (← asNum a) (← asNum b))
  | .neg, [a] => return .num (-(← asNum a))
  | .abs, [a] => let q ← asNum a; return .num (if q < 0 then -q else q)
  | .floor, [a] => return .num ((← asNum a).floor : Rat)
  | .lt, [a, b] => return .bool ((← asNum a) < (← asNum b))
  | .le, [a, b] => return .bool ((← asNum a) ≤ (← asNum b))
  | .band, [a, b] => return .bool ((← asBool a) && (← asBool b))
  | .bor, [a, b] => return .bool ((← asBool a) || (← asBool b))
  | .bnot, [a] => return .bool (!(← asBool a))
  | .tand l, [a, b] => return .deg (tand l (← asDeg a) (← asDeg b))
  | .tor l, [a, b] => return .deg (tor l (← asDeg a) (← asDeg b))
  | .tnot, [a] => return .deg (1 - (← asDeg a))
  | .very, [a] => let q ← asDeg a; return .deg (q * q)
  | .degOfBool, [a] => return .deg (if ← asBool a then 1 else 0)
  | .numOfDeg, [a] => return .num (← asDeg a)
  | .degOfNum, [a] =>
    let q ← asNum a
    if 0 ≤ q && q ≤ 1 then pure (.deg q) else M.fail s!"runtime: {fmtQ q} is not a degree in [0,1]"
  | .tri, [x, a, b, c] =>
    return .deg (clamp01 (tri (← asNum x) (← asNum a) (← asNum b) (← asNum c)))
  | .trap, [x, a, b, c, d] =>
    return .deg (clamp01 (trap (← asNum x) (← asNum a) (← asNum b) (← asNum c) (← asNum d)))
  | .rampUp, [x, a, b] => return .deg (clamp01 (rampUp (← asNum x) (← asNum a) (← asNum b)))
  | .rampDown, [x, a, b] => return .deg (1 - clamp01 (rampUp (← asNum x) (← asNum a) (← asNum b)))
  | _, _ => M.fail s!"runtime: bad primitive application {repr op}"

/-- The binomial coefficient `n` choose `k`. -/
def choose (n k : Nat) : Nat := Id.run do
  let mut r := 1
  for i in [0:k] do r := r * (n - i) / (i + 1)
  return r

/--
Picks an index with computed weights, some of which are intervals. Each index has at least the
lower end of its weight, and the rest of the probability is ambiguous among the indices whose
weight can be larger. Weights that can't sum to 1, or can't be non-negative, are an error.
-/
def pickIval (ws : List Value) : M Nat := do
  let some bs := ws.mapM fun w => (bounds w).map fun b => (b.lo, b.hi)
    | M.stuck
  if bs.any (·.2 < 0) then M.fail "runtime: negative weight in a distribution" else
  let lows := bs.map fun (l, _) => qmax 0 l
  let lo := lows.foldl (· + ·) 0
  let hi := bs.foldl (· + ·.2) 0
  if 1 < lo || hi < 1 then
    M.fail s!"runtime: distribution weights sum to between {fmtQ lo} and {fmtQ hi}, not 1" else
  let open_ := (List.range bs.length).filter fun i => (lows[i]?.getD 0) < ((bs[i]?.map (·.2)).getD 0)
  ⟨.ok ((lows.mapIdx fun i q => (Res.ok i, q)).filter (·.2 != 0)
    ++ (if lo == 1 then [] else [(.amb open_, 1 - lo)]))⟩

/--
The largest support accepted for `uniform`, and the largest number of values a quantifier may range
over.
-/
def maxSupport : Nat := 100000

/-- The exact distribution of a random primitive applied to argument values. -/
def evalRand (r : RandPrim) (vs : List Value) : M Value := do
  match r, vs with
  | .bernoulli, [p] => return .bool (← flipVal p)
  | .binomial, [n, .ival l h _ _] =>
    let n ← asInt (← asNum n)
    if n < 0 || n > 256 then M.stuck else
    -- each probability is unimodal in the success probability, so its smallest value over an
    -- interval is at one end; the rest of the probability is ambiguous
    let pmf := fun (q : Rat) => (List.range (n.toNat + 1)).map fun k =>
      (choose n.toNat k : Rat) * q ^ k * (1 - q) ^ (n.toNat - k)
    let low := (pmf (clamp01 l)).zipWith qmin (pmf (clamp01 h))
    let rest := 1 - low.foldl (· + ·) 0
    let ks := (List.range (n.toNat + 1)).map fun (k : Nat) => Value.num (k : Rat)
    ⟨.ok ((ks.zip low).filterMap (fun (v, q) => if q == 0 then none else some (Res.ok v, q))
      ++ (if rest == 0 then [] else [(.amb ks, rest)]))⟩
  | .uniform, [a, b] =>
    let lo ← asInt (← asNum a)
    let hi ← asInt (← asNum b)
    if hi < lo then M.fail s!"runtime: uniform({lo}, {hi}) is empty" else
    let n := (hi - lo + 1).toNat
    if n > maxSupport then M.fail s!"runtime: uniform support {n} too large" else
    M.ofList ((List.range n).map fun (i : Nat) => (.num ((lo + (i : Int) : Int) : Rat), (1 : Rat) / n))
  | .binomial, [n, p] =>
    let n ← asInt (← asNum n)
    let q ← asDeg p
    if n < 0 || n > 10000 then M.fail s!"runtime: binomial n={n} out of range" else
    let n := n.toNat
    if q == 0 || q == 1 then
      return .num (if q == 0 then 0 else (n : Rat))
    -- P(k + 1) = P(k) · (n - k) / (k + 1) · q / (1 - q), which avoids raising exact fractions to
    -- large powers for every k
    let r := q / (1 - q)
    let mut p := (1 - q) ^ n
    let mut out : Array (Value × Rat) := #[]
    for k in [0:n + 1] do
      out := out.push (.num (k : Rat), p)
      p := p * ((n - k : Nat) : Rat) / ((k + 1 : Nat) : Rat) * r
    M.ofList out.toList
  | _, _ => M.fail "runtime: bad random primitive application"

mutual
/-- Evaluates arguments from left to right. -/
partial def evalArgs (c : ECtx) : List Expr → M (List Value)
  | [] => pure []
  | e :: es => do
    let v ← eval c e
    let vs ← evalArgs c es
    pure (v :: vs)

/--
Evaluates a term to its exact distribution of outcomes.

Fuel bounds the depth of nested function calls. Each call evaluates the function body with one
unit less, and a call made with no fuel left has the outcome `Res.stuck`.
-/
partial def eval (c : ECtx) : Expr → M Value
  | .lit v => pure v
  | .bvar i => match c.locals[i]? with
    | some v => pure v
    | none => M.fail s!"runtime: loose bound variable #{i}"
  | .gvar n => match c.env.globalIx[n]? >>= (c.world[·]?) with
    | some (.ok v) => pure v
    | some .stuck => M.stuck
    | some (.amb vs) => ⟨.ok [(.amb vs, 1)]⟩
    | none => M.fail s!"runtime: global {n} has no value in this world"
  | .svar i => match c.vars[i]? with
    | some v => pure v
    | none => M.fail s!"runtime: bad state variable #{i}"
  | .crashed => pure (.bool c.crashed)
  | .prim op args => M.compact do evalPrim op (← evalArgs c args)
  | .call f args => do
    let some fi := c.env.funs[f]? | M.fail s!"runtime: unknown function {f}"
    let vs ← evalArgs c args
    if c.fuel == 0 then M.stuck else
    M.compact (eval { c with locals := vs.reverse, fuel := c.fuel - 1 } fi.body)
  | .ite cnd t e => do
    if ← asBool (← eval c cnd) then eval c t else eval c e
  | .choose p t e => do
    let b ← flipVal (← eval c p)
    if b then eval c t else eval c e
  | .rand r args => M.compact do evalRand r (← evalArgs c args)
  | .cat alts => M.compact do
    let i ← M.ofList (alts.mapIdx fun i (_, w) => (i, w))
    match alts[i]? with
    | some (e, _) => eval c e
    | none => M.fail "runtime: bad categorical index"
  | .catW alts => M.compact do
    let ws ← evalArgs c (alts.map (·.2))
    let i ← if ws.any isIval then pickIval ws else
      let qs ← ws.mapM asNum
      if qs.any (· < 0) then M.fail "runtime: negative weight in a distribution" else
      let total := qs.foldl (· + ·) 0
      if total != 1 then M.fail s!"runtime: distribution weights sum to {fmtQ total}, not 1" else
      M.ofList (qs.mapIdx fun i q => (i, q))
    match alts[i]? with
    | some (e, _) => eval c e
    | none => M.fail "runtime: bad categorical index"
  | .letE v b => do
    let x ← eval c v
    eval { c with locals := x :: c.locals } b
  | .quant all isDeg _ lo hi body => M.compact do
    let a ← asInt (← asNum (← eval c lo))
    let b ← asInt (← asNum (← eval c hi))
    let n := (b - a + 1).toNat
    if n > maxSupport then M.fail s!"runtime: quantifier range of {n} values too large" else
    -- Start from the unit of the aggregation: vacuous truth for ∀ and falsity for ∃.
    let unit : Value := if isDeg then .deg (if all then 1 else 0) else .bool all
    let mut acc : M Value := pure unit
    for i in [0:n] do
      let x : Value := .num ((a + i : Int) : Rat)
      acc := M.compact do
        let prev ← acc
        -- Once the aggregate reaches its absorbing value (false or 0 for ∀, true or 1 for ∃),
        -- further values can't change it, so skip evaluating the body.
        if prev == (if isDeg then .deg (if all then 0 else 1) else .bool (!all)) then pure prev else
        let v ← eval { c with locals := x :: c.locals } body
        match prev, v with
        | .bool p, .bool q => pure (.bool (if all then p && q else p || q))
        | .deg p, .deg q => pure (.deg (if all then qmin p q else qmax p q))
        | p, q =>
          -- a degree that depends on an interval: min or max of the bounds
          if isIval p || isIval q then evalPrimIval (if all then .tand .godel else .tor .godel) [p, q]
          else M.fail "runtime: ill-typed quantifier body"
    acc
  | .matchE s arms dflt => do
    match ← eval c s with
    | .tag _ i => match arms.find? (·.1 == i) with
      | some (_, b) => eval c b
      | none => match dflt with
        | some d => eval c d
        | none => M.fail "runtime: non-exhaustive match"
    | v => M.fail s!"runtime: match on non-enum value {repr v}"
end

/--
A random decision recorded while tracing: the step it was made in, what was decided (the name of
a local or state variable, or the condition of an `if`), and the value it took.
-/
structure TraceEntry where
  step : Nat
  what : String
  value : Value
  deriving DecidableEq, Hashable, Repr, Inhabited

/--
The part of a system configuration that a step can change: the state variables, and whether an
assertion has failed. When tracing, `trace` also lists the random decisions made so far; it is
always empty otherwise.
-/
structure SState where
  vars : Array Value
  crashed : Bool := false
  trace : Array TraceEntry := #[]
  deriving DecidableEq, Hashable, Inhabited

/-- Whether a term can make a random choice, directly or through a function it calls. -/
partial def hasRand (env : Env) : Expr → Bool
  | .rand _ _ | .choose _ _ _ | .cat _ | .catW _ => true
  | .call f args => ((env.funs[f]?).map (·.latent.prob)).getD true || args.any (hasRand env)
  | .prim _ args => args.any (hasRand env)
  | .ite a b c => hasRand env a || hasRand env b || hasRand env c
  | .letE v b => hasRand env v || hasRand env b
  | .quant _ _ _ lo hi b => hasRand env lo || hasRand env hi || hasRand env b
  | .matchE s arms d => hasRand env s || arms.any (hasRand env ·.2) || d.any (hasRand env)
  | _ => false

/--
Renders a term in roughly the syntax it was written in, to label recorded decisions. Local
variables are shown as `_`, since the core language doesn't keep their names.
-/
partial def showExpr (env : Env) (names : Array String) : Expr → String
  | .lit (.deg q) | .lit (.num q) => fmtQ q
  | .lit v => fmtValue env v
  | .bvar _ => "_"
  | .gvar n => n
  | .svar i => names[i]?.getD s!"#{i}"
  | .crashed => "crashed"
  | .prim op args =>
    let a := args.map arg
    let bin (s : String) := match a with | [x, y] => s!"{x} {s} {y}" | _ => s
    match op with
    | .add => bin "+" | .sub => bin "-" | .mul => bin "*" | .div => bin "/"
    | .eq => bin "==" | .ne => bin "!=" | .lt => bin "<" | .le => bin "<="
    | .band | .tand _ => bin "and" | .bor | .tor _ => bin "or"
    | .bnot | .tnot => s!"not {a.headD "_"}"
    | .neg => s!"-{a.headD "_"}"
    | .very => s!"very {a.headD "_"}"
    | .degOfBool | .numOfDeg | .degOfNum => (args.head?.map (showExpr env names)).getD ""
    | op => s!"{(reprStr op).drop 1 |>.toString |>.decapitalize}({", ".intercalate (args.map (showExpr env names))})"
  | .call f args => s!"{f}({", ".intercalate (args.map (showExpr env names))})"
  | .ite c t e | .choose c t e =>
    s!"if {showExpr env names c} then {showExpr env names t} else {showExpr env names e}"
  | .rand r args =>
    let a := ", ".intercalate (args.map (showExpr env names))
    match r with | .bernoulli => s!"flip({a})" | .uniform => s!"uniform({a})" | .binomial => s!"binomial({a})"
  | .cat alts => "{" ++ ", ".intercalate (alts.map fun (e, w) => s!"{showExpr env names e}: {fmtQ w}") ++ "}"
  | .catW alts =>
    "{" ++ ", ".intercalate (alts.map fun (e, w) => s!"{showExpr env names e}: {showExpr env names w}") ++ "}"
  | .letE v b => s!"let _ := {showExpr env names v} in {showExpr env names b}"
  | .quant all _ x lo hi b =>
    s!"{if all then "forall" else "exists"} {x} in {showExpr env names lo}..{showExpr env names hi}, {showExpr env names b}"
  | .matchE s _ _ => s!"match {showExpr env names s}"
where
  /-- An argument of an operator, in parentheses if it is itself an operator application. -/
  arg (e : Expr) : String :=
    let s := showExpr env names e
    match e with
    | .prim op _ =>
      if [Prim.neg, .abs, .min, .max, .floor, .degOfBool, .numOfDeg, .degOfNum, .very].contains op
      then s else s!"({s})"
    | .ite .. | .choose .. | .letE .. => s!"({s})"
    | _ => s

/--
Records a random decision in a state, if tracing is on and the term can make one. The label is
only computed when it is recorded, so tracing costs nothing when it is off.
-/
@[inline] def SState.record (s : SState) (c : ECtx) (e : Expr) (what : Unit → String) (v : Value) :
    SState :=
  if c.trace && hasRand c.env e then { s with trace := s.trace.push { step := 0, what := what (), value := v } }
  else s

/--
Executes one statement of a system step. A failed `assert` crashes the system, which skips the rest
of the step, and a crashed configuration never changes again.
-/
partial def exec (c : ECtx) (locals : List Value) (s : SState) (st : Stmt) : M SState :=
  if s.crashed then pure s else
  let ce : ECtx := { c with vars := s.vars, crashed := false, locals }
  match st with
  | .skip => pure s
  | .assign i e => do
    let v ← eval ce e
    let s := s.record c e (fun _ => c.varNames[i]?.getD s!"#{i}") v
    pure { s with vars := s.vars.set! i v }
  | .seq a b =>
    M.bindSplit c.par (M.compact (exec c locals s a)) fun par s' => exec { c with par } locals s' b
  | .ite cnd t e => do
    let b ← asBool (← eval ce cnd)
    let s := s.record c cnd (fun _ => showExpr c.env c.varNames cnd) (.bool b)
    if b then exec c locals s t else exec c locals s e
  | .choose p t e => do
    let b ← flipVal (← eval ce p)
    -- a stochastic `if` always makes a random decision
    let s := if c.trace then
        { s with trace := s.trace.push { step := 0, what := s!"if {showExpr c.env c.varNames p}", value := .bool b } }
      else s
    if b then exec c locals s t else exec c locals s e
  | .matchS scrut arms dflt => do
    let v ← eval ce scrut
    let s := s.record c scrut (fun _ => s!"match {showExpr c.env c.varNames scrut}") v
    match v with
    | .tag _ i => match arms.find? (·.1 == i) with
      | some (_, b) => exec c locals s b
      | none => exec c locals s dflt
    | v => M.fail s!"runtime: match on non-enum value {repr v}"
  | .letS v body name =>
    M.bindSplit c.par (eval ce v) fun par x =>
      exec { c with par } (x :: locals) (s.record c v (fun _ => name) x) body
  | .assert cnd => do
    let b ← asBool (← eval ce cnd)
    let s := s.record c cnd (fun _ => s!"assert {showExpr c.env c.varNames cnd}") (.bool b)
    if b then pure s else pure { s with crashed := true }

end Haze.Kernel
