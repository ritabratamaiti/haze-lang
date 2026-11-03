/-
Copyright (c) 2026 Ritabrata Maiti. All rights reserved.
Released under the PolyForm Noncommercial License 1.0.0 as described in the file LICENSE.md.
Authors: Ritabrata Maiti
-/
import Haze.Core

/-!
# Exact and Certified Linear Solving

Unbounded properties of a Markov chain, such as the probability of eventually reaching a set of
states or the expected number of steps until it is reached, are solutions of linear systems
`x = b + A x`, where `b` and `A` are nonnegative and the system has a unique solution. This file
solves such systems.

The states are split into strongly connected components, which are solved one at a time, from
the components that can't reach any other to the ones that can. A small component is solved
exactly by Gauss–Jordan elimination over the rationals. A large one would make exact elimination
far too slow, so it is solved in floating point and the answer is then *certified*: Haze checks,
in exact arithmetic, that a vector `l` satisfies `F l ≥ l` and that a vector `u` satisfies
`F u ≤ u`, where `F x = b + A x`. Because `F` is monotone and its iterates converge to the unique
solution `x*`, these checks prove `l ≤ x* ≤ u`. Floating-point rounding can make the bounds
looser, but never wrong.

The result for each state is therefore an interval, which is a single point whenever every
component on the way was solved exactly.

## Main Definitions

* `Haze.Kernel.Solve.sccs`: strongly connected components, in reverse topological order.
* `Haze.Kernel.Solve.solve`: bounds on the solution of a linear system.

## References

* Robert Tarjan, *Depth-First Search and Linear Graph Algorithms* (1972).
* Arnd Hartmanns and Benjamin Lucien Kaminski, *Optimistic Value Iteration* (CAV 2020).
-/

namespace Haze.Kernel.Solve

/-- An upper bound, where `none` stands for +∞. -/
abbrev Upper := Option Rat

/--
A linear system `x = b + A x` over states `0, …, n - 1`. `rows[s]` lists the nonzero entries
`(t, A s t)` of row `s`. All entries of `b` and `A` are nonnegative.
-/
structure System where
  b : Array Rat
  rows : Array (Array (Nat × Rat))
  deriving Inhabited

/--
The strongly connected components of the graph with successors `succ`, restricted to the states
that `alive` marks, in reverse topological order: every component comes after all components that
it can reach. This is Tarjan's algorithm, written with an explicit stack so that deep graphs don't
overflow the call stack.
-/
def sccs (succ : Array (Array Nat)) (alive : Array Bool) : Array (Array Nat) := Id.run do
  let n := succ.size
  let mut index : Array Nat := Array.replicate n 0     -- 0 means not visited yet
  let mut low : Array Nat := Array.replicate n 0
  let mut onStack : Array Bool := Array.replicate n false
  let mut stack : Array Nat := #[]
  let mut out : Array (Array Nat) := #[]
  let mut counter := 1
  for root in [0:n] do
    if !alive[root]! || index[root]! != 0 then continue
    index := index.set! root counter; low := low.set! root counter; counter := counter + 1
    stack := stack.push root; onStack := onStack.set! root true
    let mut call : Array (Nat × Nat) := #[(root, 0)]
    while !call.isEmpty do
      let (v, i) := call.back!
      let es := succ[v]!
      if i < es.size then
        call := call.set! (call.size - 1) (v, i + 1)
        let w := es[i]!
        if !alive[w]! then continue
        if index[w]! == 0 then
          index := index.set! w counter; low := low.set! w counter; counter := counter + 1
          stack := stack.push w; onStack := onStack.set! w true
          call := call.push (w, 0)
        else if onStack[w]! then
          low := low.set! v (min low[v]! index[w]!)
      else
        call := call.pop
        if let some (u, _) := call.back? then low := low.set! u (min low[u]! low[v]!)
        if low[v]! == index[v]! then
          let mut comp := #[]
          let mut more := true
          while more do
            let w := stack.back!
            stack := stack.pop; onStack := onStack.set! w false
            comp := comp.push w
            more := w != v
          out := out.push comp
  return out

/--
Marks the states that can reach a state in `targets`, following the edges in `succ` backwards.
-/
def canReach (succ : Array (Array Nat)) (targets : Array Bool) : Array Bool := Id.run do
  let n := succ.size
  let mut pred : Array (Array Nat) := Array.replicate n #[]
  for s in [0:n] do
    for t in succ[s]! do pred := pred.modify t (·.push s)
  let mut seen := targets
  let mut work := (Array.range n).filter (targets[·]!)
  while !work.isEmpty do
    let t := work.back!
    work := work.pop
    for s in pred[t]! do
      if !seen[s]! then seen := seen.set! s true; work := work.push s
  return seen

/-! ## Exact elimination -/

/-- The largest component solved exactly. Larger ones are solved numerically and certified. -/
def exactLimit : Nat := 120

/--
Solves `M X = R` exactly by Gauss–Jordan elimination, where each row of `rows` is a row of `M`
followed by the corresponding row of `R`, and `m` is the size of `M`. Returns the rows of `X`, or
`none` if `M` is singular.
-/
def gaussJordan (m : Nat) (rows : Array (Array Rat)) : Option (Array (Array Rat)) := Id.run do
  let mut a := rows
  for col in [0:m] do
    let some p := (List.range' col (m - col)).find? (fun r => a[r]![col]! != 0) | return none
    if p != col then
      let rp := a[p]!
      a := (a.set! p a[col]!).set! col rp
    let piv := a[col]![col]!
    let prow := a[col]!.map (· / piv)
    a := a.set! col prow
    for r in [0:m] do
      if r == col then continue
      let f := a[r]![col]!
      if f == 0 then continue
      a := a.modify r fun row => row.zipWith (fun x y => x - f * y) prow
  return some (a.map (·.extract m (a[0]!.size)))

/-! ## Certified numerical solving -/

/-- Converts a finite floating-point number to the rational number it represents exactly. -/
def floatToRat (x : Float) : Rat :=
  if !x.isFinite then 0 else
  let (m, e) := x.abs.frExp
  let mi : Nat := (m * 9007199254740992.0).toUInt64.toNat
  let q : Rat := if e ≥ 53 then ((mi * 2 ^ (e - 53).toNat : Nat) : Rat) else mkRat mi (2 ^ (53 - e).toNat)
  if x < 0 then -q else q

/-- Approximates a rational number in floating point, even when its parts don't fit in a `Float`. -/
def ratToFloat (q : Rat) : Float :=
  let scaled := fun (n : Nat) =>
    let k := n.log2 - 62
    ((n >>> k).toUInt64.toFloat, (k : Int))
  let (mn, en) := scaled q.num.natAbs
  let (md, ed) := scaled q.den
  let f := (mn / md).scaleB (en - ed)
  if q.num < 0 then -f else f

/-- Bounds are rounded to multiples of `2^-precisionBits`, which keeps their size small. -/
def precisionBits : Nat := 64

/-- Rounds down to a multiple of `2^-precisionBits`. -/
def roundDown (q : Rat) : Rat := mkRat (q * (2 ^ precisionBits : Nat)).floor (2 ^ precisionBits)

/-- Rounds up to a multiple of `2^-precisionBits`. -/
def roundUp (q : Rat) : Rat := mkRat (q * (2 ^ precisionBits : Nat)).ceil (2 ^ precisionBits)

/--
Gauss–Seidel iteration for `x = r + A x` in floating point, stopping when an update changes no
entry by more than a relative `1e-15`, or after `maxSweeps` sweeps.
-/
def gaussSeidel (rows : Array (Array (Nat × Float))) (r : Array Float) (maxSweeps : Nat) :
    Array Float := Id.run do
  let mut x := r
  for _ in [0:maxSweeps] do
    let mut delta : Float := 0
    let mut size : Float := 0
    for s in [0:rows.size] do
      let mut v := r[s]!
      for (t, a) in rows[s]! do v := v + a * x[t]!
      delta := max delta (v - x[s]!).abs
      size := max size v.abs
      x := x.set! s v
    if delta ≤ 1e-14 * (1 + size) then break
  return x

/-- The largest amount of work, in multiply-adds, spent on one banded factorization. -/
def bandBudget : Nat := 400000000

/--
Solves `(I - A) x = r` in floating point for each right-hand side `r`, by LU factorization of the
band of `I - A`. No pivoting is needed: `I - A` is a nonsingular M-matrix, whose LU factors exist
and keep the band. States are numbered in breadth-first order, which tends to keep the band
narrow. Returns `none` if the band is too wide for `bandBudget`.
-/
def bandedSolve (rows : Array (Array (Nat × Float))) (rhss : Array (Array Float)) :
    Option (Array (Array Float)) := Id.run do
  let n := rows.size
  let mut bl := 0
  let mut bu := 0
  for i in [0:n] do
    for (j, _) in rows[i]! do
      if j < i then bl := max bl (i - j) else bu := max bu (j - i)
  if n * (bl + 1) * (bu + 1) > bandBudget then return none
  let w := bl + bu + 1
  -- entry (i, j) of the band is stored at i * w + (j + bl - i)
  let mut a : FloatArray := ⟨Array.replicate (n * w) 0⟩
  for i in [0:n] do
    a := a.set! (i * w + bl) 1
    for (j, v) in rows[i]! do
      let ix := i * w + (j + bl - i)
      a := a.set! ix (a[ix]! - v)
  let mut bs : Array FloatArray := rhss.map (⟨·⟩)
  for k in [0:n] do
    let piv := a[k * w + bl]!
    if piv == 0 then return none
    for i in [k + 1 : min n (k + bl + 1)] do
      let f := a[i * w + (k + bl - i)]! / piv
      if f == 0 then continue
      for j in [k : min n (k + bu + 1)] do
        let ix := i * w + (j + bl - i)
        a := a.set! ix (a[ix]! - f * a[k * w + (j + bl - k)]!)
      bs := bs.map fun b => b.set! i (b[i]! - f * b[k]!)
  let mut out : Array (Array Float) := #[]
  for b in bs do
    let mut x : FloatArray := ⟨Array.replicate n 0⟩
    for kk in [0:n] do
      let k := n - 1 - kk
      let mut v := b[k]!
      for j in [k + 1 : min n (k + bu + 1)] do v := v - a[k * w + (j + bl - k)]! * x[j]!
      x := x.set! k (v / a[k * w + bl]!)
    out := out.push x.data
  return some out

/-- Computes `r + A x` exactly. -/
def applyF (rows : Array (Array (Nat × Rat))) (r x : Array Rat) : Array Rat :=
  (Array.range rows.size).map fun s => rows[s]!.foldl (fun acc (t, a) => acc + a * x[t]!) r[s]!

/--
Bounds on the solution of `x = r + A x` for one component, found numerically and certified
exactly. `cap` is a known upper bound, such as 1 for probabilities. Returns `0` as the lower bound
and `cap` (or +∞) as the upper bound for any side that couldn't be certified.
-/
def certified (rows : Array (Array (Nat × Rat))) (r : Array Rat) (cap : Upper) :
    Array (Rat × Upper) := Id.run do
  let m := rows.size
  let rowsF := rows.map (·.map fun (t, a) => (t, ratToFloat a))
  let rF := r.map ratToFloat
  -- `vt` solves (I - A) v = 1, so moving along it lowers every residual by about the same amount
  let (xt, vt) := match bandedSolve rowsF #[rF, Array.replicate m 1] with
    | some #[x, v] => (x, v)
    | _ => (gaussSeidel rowsF rF 20000, gaussSeidel rowsF (Array.replicate m 1) 20000)
  let resid := (Array.range m).foldl (fun acc s =>
    let v := rowsF[s]!.foldl (fun acc (t, a) => acc + a * xt[t]!) rF[s]!
    max acc (v - xt[s]!).abs) 0
  let scale := xt.foldl (fun acc v => max acc v.abs) 0
  let mut delta := max (4 * resid) (1e-13 * (1 + scale))
  let mut lo : Option (Array Rat) := none
  let mut hi : Option (Array Rat) := none
  for _ in [0:8] do
    if lo.isNone then
      let l := (Array.range m).map fun s => qmax 0 (roundDown (floatToRat (xt[s]! - delta * vt[s]!)))
      let fl := applyF rows r l
      if (Array.range m).all fun s => l[s]! ≤ fl[s]! then lo := some l
    if hi.isNone then
      let u := (Array.range m).map fun s =>
        let q := roundUp (floatToRat (xt[s]! + delta * vt[s]!))
        match cap with | some c => qmin c q | none => q
      let fu := applyF rows r u
      if (Array.range m).all fun s => fu[s]! ≤ u[s]! then hi := some u
    if lo.isSome && hi.isSome then break
    delta := delta * 16
  let l := lo.getD (Array.replicate m 0)
  return (Array.range m).map fun s => (l[s]!, match hi with | some u => some u[s]! | none => cap)

/-! ## Solving a system -/

/--
Bounds on the unique solution of `x = b + A x`, for the states that `alive` marks; the others get
`0`. Transitions from alive states must stay among alive states. The second result is `true` when
every component was solved exactly, so that the bounds coincide.

The system must have a unique solution among the states that can reach a state with `b > 0`,
which holds when every such state eventually leaves the system with positive probability. The
other states have solution 0.
-/
def solve (sys : System) (alive : Array Bool) (cap : Upper) : Array (Rat × Upper) × Bool := Id.run do
  let n := sys.b.size
  let succ := sys.rows.map (·.map (·.1))
  -- states that can't reach a positive entry of `b` have solution 0
  let positive := (Array.range n).map fun s => alive[s]! && sys.b[s]! > 0
  let reach := canReach succ positive
  let live := (Array.range n).map fun s => alive[s]! && reach[s]!
  let mut lo : Array Rat := Array.replicate n 0
  let mut hi : Array Upper := Array.replicate n (some 0)
  let mut exact := true
  -- sorting each component keeps the breadth-first numbering, which keeps bands narrow
  let comps := (sccs succ live).map (·.qsort (· < ·))
  -- the index of each state within its component, and the number of its component
  let mut posIn : Array Nat := Array.replicate n 0
  let mut compOf : Array Nat := Array.replicate n 0
  for ci in [0:comps.size] do
    let comp := comps[ci]!
    for i in [0:comp.size] do
      posIn := posIn.set! comp[i]! i
      compOf := compOf.set! comp[i]! ci
  for ci in [0:comps.size] do
    let comp := comps[ci]!
    let m := comp.size
    let inComp := fun t => live[t]! && compOf[t]! == ci
    -- the right-hand sides, with the values of components already solved filled in
    let mut rLo : Array Rat := #[]
    let mut rHi : Array Upper := #[]
    let mut inner : Array (Array (Nat × Rat)) := #[]
    for s in comp do
      let mut l := sys.b[s]!
      let mut h : Upper := some sys.b[s]!
      let mut row := #[]
      for (t, a) in sys.rows[s]! do
        if a == 0 then continue
        if m > 1 && inComp t || t == s then row := row.push (posIn[t]!, a)
        else if live[t]! then
          l := l + a * lo[t]!
          h := match h, hi[t]! with | some x, some y => some (x + a * y) | _, _ => none
      rLo := rLo.push l; rHi := rHi.push h; inner := inner.push row
    let hiAll : Option (Array Rat) := rHi.mapM id
    if m == 1 then
      -- a single state, possibly with a self-loop: x = r + a x
      let a : Rat := inner[0]!.foldl (fun (acc : Rat) (p : Nat × Rat) => acc + p.2) 0
      let s := comp[0]!
      if a < 1 then
        lo := lo.set! s (rLo[0]! / (1 - a))
        hi := hi.set! s ((rHi[0]!).map (· / (1 - a)))
      else
        -- a state that never leaves; its value grows without bound unless `r` is 0
        exact := false
        lo := lo.set! s rLo[0]!
        hi := hi.set! s none
    else if m ≤ exactLimit then
      let cols : Nat := if hiAll.isSome then 2 else 1
      let rows := (Array.range m).map fun i =>
        let coeffs := (Array.range m).map fun j =>
          (if i == j then (1 : Rat) else 0) - inner[i]!.foldl (fun (acc : Rat) (p : Nat × Rat) => if p.1 == j then acc + p.2 else acc) 0
        coeffs.push rLo[i]! ++ (match hiAll with | some h => #[h[i]!] | none => #[])
      match gaussJordan m rows with
      | some xs =>
        for i in [0:m] do
          lo := lo.set! comp[i]! xs[i]![0]!
          hi := hi.set! comp[i]! (if cols == 2 then some xs[i]![1]! else none)
      | none =>
        -- can't happen for a system with a unique solution; fall back to the trivial bounds
        exact := false
        for s in comp do lo := lo.set! s 0; hi := hi.set! s cap
    else
      exact := false
      let bl := certified inner rLo cap
      for i in [0:m] do lo := lo.set! comp[i]! bl[i]!.1
      match hiAll with
      | some h =>
        let bh := certified inner h cap
        for i in [0:m] do hi := hi.set! comp[i]! bh[i]!.2
      | none => for s in comp do hi := hi.set! s none
  return ((Array.range n).map fun s => (lo[s]!, hi[s]!), exact)

end Haze.Kernel.Solve
