/-
Copyright (c) 2026 Ritabrata Maiti. All rights reserved.
Released under the Functional Source License 1.1 (FSL-1.1-ALv2) as described in the file LICENSE.md.
Authors: Ritabrata Maiti
-/
import Haze.Kernel.Eval

/-!
# Kernel Theorems

This file proves facts about the very definitions that the kernel executes, rather than about a
separate model of them.

## Main Results

* `Haze.Grade.le_iff_join`, `Haze.Grade.le_top`: grades form a finite join-semilattice whose
  order is `Grade.le`. This is why the latent-grade inference in `Haze.Kernel.checkFun`
  terminates with the least fixed point.
* `Haze.Kernel.tand_comm`, `Haze.Kernel.tand_one`, `Haze.Kernel.tand_le_min`: every t-norm is
  commutative, has unit 1, and is bounded by the Gödel t-norm `min`.
* `Haze.Kernel.demorgan_godel`, `Haze.Kernel.demorgan_lukasiewicz`: De Morgan duality between
  conjunction and disjunction.
-/

namespace Haze

/-! ## The grade lattice

`Kernel.checkFun` computes the latent grade of a function by iterating `g ↦ g ⊔ infer(g)`, starting
from `partial` for a recursive function and from `crisp` otherwise. The iteration terminates with the least fixed point because `join`
is a semilattice operation whose order is `le`, and because the lattice has height 3. -/

namespace Grade

theorem join_comm (a b : Grade) : a.join b = b.join a := by
  cases a; cases b; simp [join, Bool.or_comm]

theorem join_assoc (a b c : Grade) : (a.join b).join c = a.join (b.join c) := by
  cases a; cases b; cases c; simp [join, Bool.or_assoc]

theorem join_idem (a : Grade) : a.join a = a := by
  cases a; simp [join]

theorem crisp_join (a : Grade) : crisp.join a = a := by
  cases a; simp [join, crisp]

theorem le_refl (a : Grade) : a.le a = true := by
  cases a; simp [le]

theorem le_join_left (a b : Grade) : a.le (a.join b) = true := by
  rcases a with ⟨p, f, d⟩; rcases b with ⟨p', f', d'⟩
  cases p <;> cases f <;> cases d <;> simp [le, join]

theorem le_join_right (a b : Grade) : b.le (a.join b) = true := by
  rw [join_comm]; exact le_join_left b a

/--
The grade order `Grade.le` is the order induced by `Grade.join`: `a ≤ b` exactly when `a ⊔ b = b`.
-/
theorem le_iff_join (a b : Grade) : a.le b = true ↔ a.join b = b := by
  rcases a with ⟨p, f, d⟩; rcases b with ⟨p', f', d'⟩
  cases p <;> cases f <;> cases d <;> cases p' <;> cases f' <;> cases d' <;> simp [le, join]

/--
Every grade lies below `prob+fuzzy+partial`, so a strictly ascending chain of grades has at most
four elements.
-/
theorem le_top (a : Grade) : a.le { prob := true, fuzzy := true, diverge := true } = true := by
  cases a; simp [le]

end Grade

/-! ## Fuzzy connectives -/

namespace Kernel

theorem tand_comm (l : Logic) (a b : Rat) : tand l a b = tand l b a := by
  cases l <;> simp only [tand, qmin, qmax] <;> (try split) <;> (try split) <;> grind

theorem tor_comm (l : Logic) (a b : Rat) : tor l a b = tor l b a := by
  cases l <;> simp only [tor, qmin, qmax] <;> (try split) <;> (try split) <;> grind

/-- The degree 1 is the unit of every t-norm on degrees. -/
theorem tand_one (l : Logic) (a : Rat) (h0 : 0 ≤ a) (h1 : a ≤ 1) : tand l a 1 = a := by
  cases l <;> simp only [tand, qmin, qmax] <;> (try split) <;> grind

/-- The degree 0 is the unit of every t-conorm on degrees. -/
theorem tor_zero (l : Logic) (a : Rat) (h0 : 0 ≤ a) (h1 : a ≤ 1) : tor l a 0 = a := by
  cases l <;> simp only [tor, qmin, qmax] <;> (try split) <;> grind

/--
Every t-norm is bounded by the Gödel t-norm `min`, so Gödel conjunction is the most permissive
conjunction.
-/
theorem tand_le_min (l : Logic) (a b : Rat) (ha : 0 ≤ a) (ha' : a ≤ 1) (hb : 0 ≤ b) (hb' : b ≤ 1) :
    tand l a b ≤ qmin a b := by
  -- The product case is nonlinear, so give `grind` the bounds `a·b ≤ a·1` and `a·b ≤ 1·b`.
  have h1 : a * b ≤ a * 1 := Rat.mul_le_mul_of_nonneg_left hb' ha
  have h2 : a * b ≤ 1 * b := Rat.mul_le_mul_of_nonneg_right ha' hb
  cases l <;> simp only [tand, qmin, qmax] <;> (try split) <;> (try split) <;> grind

/-- De Morgan duality for the Gödel connectives `min` and `max` with the negation `1 - x`. -/
theorem demorgan_godel (a b : Rat) : 1 - tand .godel a b = tor .godel (1 - a) (1 - b) := by
  simp only [tand, tor, qmin, qmax]; split <;> (try split) <;> grind

/-- De Morgan duality for the Łukasiewicz connectives with the standard negation `1 - x`. -/
theorem demorgan_lukasiewicz (a b : Rat) :
    1 - tand .lukasiewicz a b = tor .lukasiewicz (1 - a) (1 - b) := by
  simp only [tand, tor, qmin, qmax]; split <;> (try split) <;> grind

/--
`clamp01` always returns a degree between 0 and 1. The evaluator applies it to the results of
membership functions.
-/
theorem clamp01_mem (q : Rat) : 0 ≤ clamp01 q ∧ clamp01 q ≤ 1 := by
  simp only [clamp01, qmin, qmax]; split <;> (try split) <;> grind

end Kernel
end Haze
