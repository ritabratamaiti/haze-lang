/-
Copyright (c) 2026 Ritabrata Maiti. All rights reserved.
Released under the Functional Source License 1.1 (FSL-1.1-ALv2) as described in the file LICENSE.md.
Authors: Ritabrata Maiti
-/
import Haze.Kernel.Solve

/-!
# Reachability with Ambiguous Transitions

When a continuous fuzzy parameter holds an interval, a step can have *ambiguous* transitions: with
a known probability, the system moves to one state from a set, but which one isn't known. This
file bounds the probability of reaching a goal over every way of resolving the ambiguities. The
smallest such probability is a lower bound on the probability for every value of the parameter in
the interval, and the largest is an upper bound. This is the parameter lifting of Quatmann et al.:
each state resolves its ambiguity on its own, which allows more behaviors than any single value of
the parameter does.

The values are the least solution of `x = b + A x + Σ m · opt x[S]`, where `opt` is the minimum
or the maximum over the set `S`. They are computed by policy iteration: fix one element of each
set, solve the resulting linear system with `Haze.Kernel.Solve.solve`, and switch each choice to
the best element until no choice changes. The answer is then *certified* against the operator
itself, in exact arithmetic:

* An upper bound `u` on the largest values must satisfy `F u ≤ u`. By the Knaster–Tarski theorem,
  such a `u` lies above the least fixed point.
* A lower bound `l` on the smallest values must satisfy `l ≤ F l`. The states from which the
  ambiguities can avoid the goal forever have value 0, and are found by graph search. On the other
  states the fixed point is unique, so `l ≤ F l` implies that `l` lies below it.

If a check fails, the trivial bound is returned instead, so the result is never wrong.

## Main Definitions

* `Haze.Kernel.Robust.SetSystem`: a linear system with ambiguous transitions.
* `Haze.Kernel.Robust.solve`: certified bounds on its smallest or largest solution.

## References

* Tim Quatmann, Christian Dehnert, Nils Jansen, Sebastian Junges and Joost-Pieter Katoen,
  *Parameter Synthesis for Markov Models: Faster Than Ever* (ATVA 2016).
* Christel Baier and Joost-Pieter Katoen, *Principles of Model Checking* (2008), section 10.6.
-/

namespace Haze.Kernel.Robust
open Solve

/--
A linear system `x = b + A x` in which some transitions are ambiguous. `sets[s]` lists them for
state `s`: with probability `m`, the next state is one of the states in the set.
-/
structure SetSystem where
  b : Array Rat
  rows : Array (Array (Nat × Rat))
  sets : Array (Array (Array Nat × Rat))
  deriving Inhabited

/-- The best element of a set for the values `x`, keeping `cur` on ties. -/
def pick (x : Array Rat) (minimize : Bool) (ts : Array Nat) (cur : Nat) : Nat :=
  ts.foldl (init := cur) fun best t =>
    if (minimize && x[t]! < x[best]!) || (!minimize && x[best]! < x[t]!) then t else best

/-- Computes `b + A x` exactly, resolving each ambiguous transition by the best element. -/
def apply (sys : SetSystem) (minimize : Bool) (x : Array Rat) : Array Rat :=
  (Array.range sys.b.size).map fun s =>
    let v := sys.rows[s]!.foldl (fun acc (t, a) => acc + a * x[t]!) sys.b[s]!
    sys.sets[s]!.foldl (init := v) fun acc (ts, m) =>
      acc + m * x[pick x minimize ts ts[0]!]!

/--
The states from which the ambiguities can be resolved so that no positive entry of `b` is ever
reached. This is the largest set of states with `b = 0` from which every certain transition, and
some element of every ambiguous one, stays in the set.
-/
def zeroMin (sys : SetSystem) : Array Bool := Id.run do
  let n := sys.b.size
  let mut pred : Array (Array Nat) := Array.replicate n #[]
  for s in [0:n] do
    for (t, _) in sys.rows[s]! do pred := pred.modify t (·.push s)
    for (ts, _) in sys.sets[s]! do
      for t in ts do pred := pred.modify t (·.push s)
  let mut z := sys.b.map (· == 0)
  let mut work := (Array.range n).filter (!z[·]!)
  while !work.isEmpty do
    let t := work.back!
    work := work.pop
    for s in pred[t]! do
      if !z[s]! then continue
      let stays := sys.rows[s]!.all (fun (u, a) => a == 0 || z[u]!) &&
        sys.sets[s]!.all fun (ts, m) => m == 0 || ts.any (z[·]!)
      if !stays then
        z := z.set! s false
        work := work.push s
  return z

/--
The linear system in which each ambiguous transition goes to its chosen element. States in
`zero` have value 0.
-/
def withChoice (sys : SetSystem) (choice : Array (Array Nat)) (zero : Array Bool) : System :=
  { b := (Array.range sys.b.size).map fun s => if zero[s]! then 0 else sys.b[s]!
    rows := (Array.range sys.b.size).map fun s =>
      if zero[s]! then #[] else
      sys.rows[s]! ++ (sys.sets[s]!.zip choice[s]!).map fun ((_, m), t) => (t, m) }

/--
Bounds on the smallest (`minimize`) or the largest solution of a system, over every way of
resolving its ambiguous transitions. For the smallest, the first component of each pair is a
lower bound; for the largest, the second is an upper bound, where `cap` is a known upper bound.
The other component is the trivial bound. The second result is `true` when the bound is exact.
-/
def solve (sys : SetSystem) (minimize : Bool) (cap : Upper) : Array (Rat × Upper) × Bool := Id.run do
  let n := sys.b.size
  let alive := Array.replicate n true
  if sys.sets.all (·.isEmpty) then return Solve.solve ⟨sys.b, sys.rows⟩ alive cap
  let zero := if minimize then zeroMin sys else Array.replicate n false
  let mut choice := sys.sets.map (·.map fun (ts, _) => ts[0]!)
  let mut x : Array Rat := Array.replicate n 0
  let mut exact := false
  let mut finite := true
  for _ in [0:100] do
    let (sol, ex) := Solve.solve (withChoice sys choice zero) alive cap
    finite := sol.all fun (_, h) => h.isSome
    x := sol.map fun (l, h) => if minimize then l else h.getD l
    exact := ex
    let next := (Array.range n).map fun s =>
      (sys.sets[s]!.zip choice[s]!).map fun ((ts, _), c) => pick x minimize ts c
    if next == choice then break
    choice := next
  if minimize then
    let l := (Array.range n).map fun s => if zero[s]! then 0 else x[s]!
    let fl := apply sys true l
    if (Array.range n).all fun s => l[s]! ≤ fl[s]! then
      return (l.map (·, cap), exact)
    return (Array.replicate n (0, cap), false)
  else
    let fx := apply sys false x
    if finite && (Array.range n).all fun s => fx[s]! ≤ x[s]! then
      return (x.map fun v => (0, some (match cap with | some c => qmin c v | none => v)), exact)
    return (Array.replicate n (0, cap), false)

end Haze.Kernel.Robust
