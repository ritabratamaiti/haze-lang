/-
Copyright (c) 2026 Ritabrata Maiti. All rights reserved.
Released under the Functional Source License 1.1 (FSL-1.1-ALv2) as described in the file LICENSE.md.
Authors: Ritabrata Maiti
-/
import Haze.Kernel.Verify

/-!
# Continuous Fuzzy Parameters

A continuous fuzzy parameter has a possibility distribution over an interval of numbers, such as
a triangle around a most likely value, or the likelihood of a failure rate after observed
failures. Its α-cut, the set of values whose possibility is at least `α`, is an interval, and the
belief in a property is the integral over `α` of the smallest probability over the α-cut. This
file computes certified bounds on the belief and the plausibility.

**Levels.** The integral over `α` is split at a finite set of levels: `j / N` for `j = 1, …, N`,
the possibilities of the discrete parameters, and for a likelihood a few small levels near 0. On
the band between two consecutive levels `n < l`, the α-cut is at most the cut at `n`, so the
smallest probability over the cut at `n` is at most the smallest over any cut in the band. Using
it gives a belief that is at most the true belief, and likewise a plausibility that is at least
the true plausibility. Using the cut at `l` instead bounds the true values from the other side,
which shows how close the levels are.

**Search.** The smallest probability over a cut is bounded by branch and bound. Checking the
model with the parameter's value an interval (see `Haze.Kernel.Robust`) gives a lower bound over
the whole interval, and checking it at a single value gives an upper bound. The interval with the
lowest lower bound is split in two until its lower bound is within a small tolerance of the best
value found, or the budget of checks runs out. The result is the lowest lower bound over all the
pieces, so it is certified whether or not the search finishes. For a probability that moves the
same way with every use of the parameter, the bound over an interval is reached at one of its
ends, and the search finishes at once.

## Main Definitions

* `Haze.Shape.cut`: the α-cut of a possibility distribution, rounded outward.
* `Haze.Kernel.Continuous.run`: certified belief and plausibility.

## References

* Didier Dubois, Serafín Moral and Henri Prade, *A Semantics for Possibility Theory Based on
  Likelihoods* (1997).
* Lotfi Zadeh, *Fuzzy Sets as a Basis for a Theory of Possibility* (1978).
-/

namespace Haze

/-- Checks whether `p^k (1 - p)^(n - k)` is at most `α` times its largest value, at `p = k / n`. -/
def likelihoodAtMost (k n : Nat) (p α : Rat) : Bool :=
  let ph : Rat := (k : Rat) / n
  p ^ k * (1 - p) ^ (n - k) ≤ α * (ph ^ k * (1 - ph) ^ (n - k))

/-- The binomial log-likelihood `k log p + (n - k) log (1 - p)`, in floating point. -/
def logLik (k n : Nat) (p : Float) : Float :=
  (if k == 0 then 0 else k.toFloat * Float.log p) +
  (if k == n then 0 else (n - k).toFloat * Float.log (1 - p))

/-- Values are rounded to multiples of `2^-40`, which keeps exact powers of them manageable. -/
def cutGrid : Nat := 2 ^ 40

/--
One end of the α-cut of a binomial likelihood: the lower end if `lower`, else the upper one. It
is found in floating point and then moved outward until exact arithmetic confirms that the
possibility there is at most `α`; since the likelihood is unimodal, every value beyond it has
possibility below `α` too.
-/
def likelihoodEnd (k n : Nat) (α : Rat) (lower : Bool) : Rat := Id.run do
  let ph : Float := k.toFloat / n.toFloat
  let target := logLik k n ph + Float.log (Kernel.Solve.ratToFloat α)
  let mut a : Float := if lower then 0 else ph
  let mut b : Float := if lower then ph else 1
  for _ in [0:80] do
    let m := (a + b) / 2
    -- on the lower side the log-likelihood rises towards `ph`; on the upper side it falls
    if (logLik k n m < target) == lower then a := m else b := m
  let g : Rat := (cutGrid : Rat)
  let mut e : Rat := if lower then mkRat (Kernel.Solve.floatToRat a * g).floor cutGrid
    else mkRat (Kernel.Solve.floatToRat b * g).ceil cutGrid
  let mut step : Rat := 1 / g
  for _ in [0:64] do
    if lower && e ≤ 0 then return 0
    if !lower && 1 ≤ e then return 1
    if likelihoodAtMost k n e α then return e
    e := if lower then e - step else e + step
    step := step * 2
  return if lower then 0 else 1

/--
The α-cut of a continuous possibility distribution: an interval that contains every value of
possibility at least `α`. At `α = 0` it is the whole support. The ends of a likelihood's cut are
rounded outward, so the interval may be slightly wider than the exact cut.
-/
def Shape.cut (sh : Shape) (α : Rat) : Rat × Rat :=
  match sh with
  | .trap a b c d => if α == 0 then (a, d) else (a + α * (b - a), d - α * (d - c))
  | .likelihood k n =>
    if α == 0 then (0, 1) else
    if α == 1 then ((k : Rat) / n, (k : Rat) / n) else
    (if k == 0 then 0 else likelihoodEnd k n α true, if k == n then 1 else likelihoodEnd k n α false)

/-- Whether a distribution's support is the whole unit interval, as a likelihood's is. -/
def Shape.unbounded : Shape → Bool
  | .likelihood _ _ => true
  | _ => false

namespace Kernel.Continuous

/-- One range of values for each continuous parameter. -/
abbrev Box := Array Bnd

/-- A continuous fuzzy parameter. -/
structure CParam where
  name : String
  shape : Shape
  deriving Inhabited

/-- The closed range from `l` to `h`. -/
def range (l h : Rat) : Bnd := { lo := l, hi := h }

/-- Whether a box is a single point. -/
def Box.isPoint (b : Box) : Bool := b.all fun r => r.lo == r.hi

/-- The center of a box. -/
def Box.center (b : Box) : Box := b.map fun r => range ((r.lo + r.hi) / 2) ((r.lo + r.hi) / 2)

/-- The corners of a box, ends included. -/
def Box.corners (b : Box) : List Box :=
  b.foldl (init := [#[]]) fun acc r =>
    acc.flatMap fun c => if r.lo == r.hi then [c.push r] else [c.push (range r.lo r.lo), c.push (range r.hi r.hi)]

/-- Whether box `a` lies inside box `b`. -/
def Box.within (a b : Box) : Bool :=
  (a.zip b).all fun (x, y) =>
    (y.lo < x.lo || (y.lo == x.lo && (!y.openLo || x.openLo))) &&
    (x.hi < y.hi || (x.hi == y.hi && (!y.openHi || x.openHi)))

/--
Splits a box into pieces that cover it. A constant from `cuts` that the model compares against is
split off first: at a closed end of a range, as a single point and the rest of the range without
it; inside a range, as the single point with the parts below and above it. A comparison with the
constant is then decided on every piece. Without such a constant, the widest side, measured
relative to `widths`, is halved.
-/
def Box.split (b : Box) (widths : Array Rat) (cuts : Array Rat) : List Box := Id.run do
  for i in [0:b.size] do
    let r := b[i]!
    if r.lo == r.hi then continue
    if !r.openLo && cuts.contains r.lo then
      return [b.set! i (range r.lo r.lo), b.set! i { r with openLo := true }]
    if !r.openHi && cuts.contains r.hi then
      return [b.set! i (range r.hi r.hi), b.set! i { r with openHi := true }]
    if let some c := cuts.find? fun c => r.lo < c && c < r.hi then
      return [b.set! i { r with hi := c, openHi := true }, b.set! i (range c c),
              b.set! i { r with lo := c, openLo := true }]
  let mut best := 0
  let mut bestW : Rat := -1
  for i in [0:b.size] do
    let r := b[i]!
    let w := if widths[i]! == 0 then 0 else (r.hi - r.lo) / widths[i]!
    if w > bestW then best := i; bestW := w
  let r := b[best]!
  let m := (r.lo + r.hi) / 2
  return [b.set! best { r with hi := m, openHi := false }, b.set! best { r with lo := m, openLo := false }]

/-- The values the parameters take for a box: intervals, or numbers where the box is a point. -/
def Box.values (b : Box) (ps : Array CParam) : List (String × Value) :=
  (ps.zip b).toList.map fun (p, r) => (p.name, mkIvalB r false)

/-- The result of checking a property at a point or over a box. -/
structure Check where
  lo : Rat
  hi : Rat
  maxStates : Nat
  truncated : Bool
  exact : Bool
  deriving Inhabited

/-- How far the bound may stay from the best value found before the search stops. -/
def tolerance (v : Rat) : Rat :=
  let a := if v < 0 then -v else v
  qmax (1 / 1000000000000) (qmin a (1 - a) / 1000000)

/--
The outcome of a branch-and-bound search for the smallest value: a certified lower bound, the
best value found, and every point checked with its result.
-/
structure Search where
  bound : Rat
  best : Rat
  points : Array (Box × Check)
  maxStates : Nat
  truncated : Bool
  /-- Every point was checked in exact arithmetic. -/
  exact : Bool
  /-- The bound met the best value found, within the tolerance. -/
  closed : Bool

/--
Bounds the smallest lower value (`minimize`) or the largest upper value of a property over a box,
where `check` checks the property at a point or over a box. A box check gives a certified bound;
a point check gives the value at that point, which the true extreme can't be worse than. Each
step splits the piece with the weakest bound, and the search stops once that bound is within
`tolerance` of the best value or `budget` box checks are spent.
-/
def search (check : Box → Except String Check) (box : Box) (widths cuts : Array Rat) (minimize : Bool)
    (budget : Nat) (extra : List Box) : Except String Search := do
  -- maximizing is minimizing the negated values
  let sign : Rat := if minimize then 1 else -1
  let bnd := fun (c : Check) => sign * (if minimize then c.lo else c.hi)
  let inc := fun (c : Check) => sign * (if minimize then c.hi else c.lo)
  let mut points : Array (Box × Check) := #[]
  let mut best : Option Rat := none
  let mut maxStates := 0
  let mut truncated := false
  let mut exact := true
  let pts := Box.center box :: (if box.size ≤ 3 then Box.corners box else []) ++ extra.filter (Box.within · box)
  for p in pts.eraseDups do
    let c ← check p
    points := points.push (p, c)
    best := some (match best with | some b => qmin b (inc c) | none => inc c)
    maxStates := max maxStates c.maxStates
    truncated := truncated || c.truncated
    exact := exact && c.exact
  let c0 ← check box
  maxStates := max maxStates c0.maxStates
  truncated := truncated || c0.truncated
  let mut leaves : Array (Box × Rat) := #[(box, bnd c0)]
  let mut used := 1
  while used < budget do
    let some b := best | break
    let mut li := 0
    for i in [0:leaves.size] do
      if leaves[i]!.2 < leaves[li]!.2 then li := i
    let (lb, v) := leaves[li]!
    if b - tolerance (sign * b) ≤ v || Box.isPoint lb then break
    let pieces := Box.split lb widths cuts
    let mut kids : Array (Box × Rat) := #[]
    for k in pieces do
      let ck ← check k
      maxStates := max maxStates ck.maxStates
      truncated := truncated || ck.truncated
      let cp ← check (Box.center k)
      points := points.push (Box.center k, cp)
      best := some (match best with | some b' => qmin b' (inc cp) | none => inc cp)
      kids := kids.push (k, bnd ck)
    leaves := (leaves.eraseIdx! li) ++ kids
    used := used + pieces.length
  let low := leaves.foldl (fun m (_, v) => qmin m v) (leaves[0]!.2)
  let b := best.getD low
  return { bound := sign * low, best := sign * b, points, maxStates, truncated, exact,
           closed := b - tolerance (sign * b) ≤ low }

/-- The result of checking a property with continuous fuzzy parameters. -/
structure Result where
  /-- One row per level and discrete assignment: the bounds over the cut at the level below. -/
  rows : List BranchResult
  /-- For each row, the level of the cut it was computed over. -/
  bottoms : List Rat
  /-- The result at the most possible values, for each discrete assignment. -/
  core : List (List (String × Value) × Rat × Check)
  /-- Certified belief and plausibility, at most and at least the true ones. -/
  outer : Interval
  /-- Belief and plausibility from the cuts at the levels above, which bound the true ones from
  the other side, up to the points checked. -/
  inner : Interval
  /-- The point with the lowest value found, with its discrete assignment's index. -/
  worst : List (String × Value) × Nat
  /-- The point with the highest value found. -/
  bestPt : List (String × Value) × Nat
  /-- The number of levels and the number of model checks. -/
  levels : Nat
  checks : Nat
  /-- Every bound met the best value found, so the levels are the only approximation. -/
  closed : Bool

/--
Checks a property with continuous fuzzy parameters `ps` and `nLevels` levels. `build` gives the
branches (one per assignment of the discrete parameters) with the continuous parameters set to
the given values, and `check` checks a property on one branch, ambiguously if `robust`.
-/
def run (ps : Array CParam) (nLevels : Nat) (budget : Nat) (cuts : Array Rat)
    (build : List (String × Value) → Except String (Array Branch))
    (check : Branch → Bool → Except String BranchResult) : Except String Result := do
  let core : Box := ps.map fun p => range p.shape.core p.shape.core
  let bs0 ← build (Box.values core ps)
  if bs0.isEmpty then throw "no parameter assignment is left"
  let top := bs0.foldl (fun m b => qmax m b.poss) 0
  let small : List Rat := if ps.any (·.shape.unbounded) then [1/1000000, 1/10000, 1/1000, 1/100] else []
  let levels := ((List.range nLevels).map (fun j => ((j + 1 : Nat) : Rat) / nLevels) ++ small
      ++ bs0.toList.map (·.poss)).filter (fun l => 0 < l && l ≤ top)
    |>.eraseDups |>.mergeSort (· ≤ ·)
  let levels := if levels.contains top then levels else levels ++ [top]
  let bands := levels.zip (0 :: levels)   -- (l, n): the band from n up to l
  let widths := ps.map fun p => let (l, h) := p.shape.cut 0; h - l
  let boxAt := fun (α : Rat) => ps.map fun p => let (l, h) := p.shape.cut α; range l h
  -- one task per band and discrete assignment in it
  let tasks : Array ((Rat × Rat) × Nat) := (bands.toArray.flatMap fun (l, n) =>
    (Array.range bs0.size).filterMap fun d => if bs0[d]!.poss ≥ l then some ((l, n), d) else none)
  let checkAt := fun (d : Nat) (b : Box) => do
    let bs ← build (Box.values b ps)
    let some br := bs[d]? | throw "kernel: parameter assignments changed between checks"
    let r ← check br (!Box.isPoint b)
    pure ({ lo := r.lo, hi := r.hi, maxStates := r.maxStates, truncated := r.truncated,
            exact := r.exact } : Check)
  let results ← parMapM' tasks fun ((_, n), d) => do
    let box := boxAt n
    let lo ← search (checkAt d) box widths cuts true budget [core]
    let hi ← search (checkAt d) box widths cuts false budget [core]
    pure (lo, hi)
  let mut rows : Array BranchResult := #[]
  let mut bottoms : Array Rat := #[]
  let mut points : Array (Nat × Box × Check) := #[]
  let mut closed := true
  let mut checks := 0
  for (((l, n), d), (lo, hi)) in tasks.zip results do
    let b := bs0[d]!
    let discrete := b.assign.filter fun (x, _) => !ps.any (·.name == x)
    let row : BranchResult :=
      { assign := discrete ++ Box.values (boxAt n) ps, poss := l, lo := lo.bound, hi := hi.bound,
        maxStates := max lo.maxStates hi.maxStates, truncated := lo.truncated || hi.truncated,
        exact := lo.exact && hi.exact }
    rows := rows.push row
    bottoms := bottoms.push n
    closed := closed && lo.closed && hi.closed
    checks := checks + lo.points.size + hi.points.size
    points := points ++ (lo.points ++ hi.points).map fun (p, c) => (d, p, c)
  let outer := integrate (rows.toList.map fun r => (r.poss, r.lo, r.hi))
  -- the other side: the best points inside the cut at the top of each band
  let mut bel : Rat := 0
  let mut pl : Rat := 0
  for (l, n) in bands do
    let inCut := points.filter fun (d, p, _) => bs0[d]!.poss ≥ l && Box.within p (boxAt l)
    let some (_, _, c0) := inCut[0]? | continue
    bel := bel + (l - n) * inCut.foldl (fun m (_, _, c) => qmin m c.hi) c0.hi
    pl := pl + (l - n) * inCut.foldl (fun m (_, _, c) => qmax m c.lo) c0.lo
  if points.isEmpty then throw "kernel: no point was checked"
  let pick := fun (lower : Bool) => points.foldl (init := points[0]!) fun acc x =>
    if (lower && x.2.2.lo < acc.2.2.lo) || (!lower && x.2.2.hi > acc.2.2.hi) then x else acc
  let (dw, pw, _) := pick true
  let (db, pb, _) := pick false
  let coreRes := (Array.range bs0.size).toList.filterMap fun d =>
    (points.find? fun (d', p, _) => d' == d && p == core).map fun (_, _, c) =>
      ((bs0[d]!.assign.filter fun (x, _) => !ps.any (·.name == x)) ++ Box.values core ps, bs0[d]!.poss, c)
  return { rows := rows.toList, bottoms := bottoms.toList, core := coreRes, outer, inner := { bel := bel / top, pl := pl / top },
           worst := (Box.values pw ps, dw), bestPt := (Box.values pb ps, db),
           levels := levels.length, checks, closed }

end Kernel.Continuous
end Haze
