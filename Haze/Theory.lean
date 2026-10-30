/-
Machine-checked facts about the Haze kernel, proved in Lean against the very definitions
the kernel executes (not against a separate model).
-/
import Haze.Kernel.Eval

namespace Haze

/-! ## The grade lattice

`Kernel.checkFun` computes latent grades of recursive functions by iterating
`g ↦ g ⊔ infer(g)` from `⊥`. Termination and correctness rest on `join` being a
semilattice operation whose order is `le`, on a lattice of height 3. -/

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

/-- `le` is exactly the order induced by `join`. -/
theorem le_iff_join (a b : Grade) : a.le b = true ↔ a.join b = b := by
  rcases a with ⟨p, f, d⟩; rcases b with ⟨p', f', d'⟩
  cases p <;> cases f <;> cases d <;> cases p' <;> cases f' <;> cases d' <;> simp [le, join]

/-- Every grade lies below `prob+fuzzy+partial`, so ascending chains have length ≤ 4. -/
theorem le_top (a : Grade) : a.le { prob := true, fuzzy := true, diverge := true } = true := by
  cases a; simp [le]

end Grade

/-! ## Fuzzy connectives -/

namespace Kernel

theorem tand_comm (l : Logic) (a b : Rat) : tand l a b = tand l b a := by
  cases l <;> simp only [tand, qmin, qmax] <;> (try split) <;> (try split) <;> grind

theorem tor_comm (l : Logic) (a b : Rat) : tor l a b = tor l b a := by
  cases l <;> simp only [tor, qmin, qmax] <;> (try split) <;> (try split) <;> grind

/-- `1` is the unit of every t-norm on `[0,1]`. -/
theorem tand_one (l : Logic) (a : Rat) (h0 : 0 ≤ a) (h1 : a ≤ 1) : tand l a 1 = a := by
  cases l <;> simp only [tand, qmin, qmax] <;> (try split) <;> grind

/-- `0` is the unit of every t-conorm on `[0,1]`. -/
theorem tor_zero (l : Logic) (a : Rat) (h0 : 0 ≤ a) (h1 : a ≤ 1) : tor l a 0 = a := by
  cases l <;> simp only [tor, qmin, qmax] <;> (try split) <;> grind

/-- t-norms are bounded by Gödel's `min`: Gödel logic is the most permissive conjunction. -/
theorem tand_le_min (l : Logic) (a b : Rat) (ha : 0 ≤ a) (ha' : a ≤ 1) (hb : 0 ≤ b) (hb' : b ≤ 1) :
    tand l a b ≤ qmin a b := by
  -- the product case is nonlinear: `a·b ≤ a·1` and `a·b ≤ 1·b`
  have h1 : a * b ≤ a * 1 := Rat.mul_le_mul_of_nonneg_left hb' ha
  have h2 : a * b ≤ 1 * b := Rat.mul_le_mul_of_nonneg_right ha' hb
  cases l <;> simp only [tand, qmin, qmax] <;> (try split) <;> (try split) <;> grind

/-- De Morgan duality with the standard negation `1 - x` (Gödel and Łukasiewicz). -/
theorem demorgan_godel (a b : Rat) : 1 - tand .godel a b = tor .godel (1 - a) (1 - b) := by
  simp only [tand, tor, qmin, qmax]; split <;> (try split) <;> grind

theorem demorgan_lukasiewicz (a b : Rat) :
    1 - tand .lukasiewicz a b = tor .lukasiewicz (1 - a) (1 - b) := by
  simp only [tand, tor, qmin, qmax]; split <;> (try split) <;> grind

/-- Membership functions are clamped into `[0,1]` by the evaluator. -/
theorem clamp01_mem (q : Rat) : 0 ≤ clamp01 q ∧ clamp01 q ≤ 1 := by
  simp only [clamp01, qmin, qmax]; split <;> (try split) <;> grind

end Kernel
end Haze
