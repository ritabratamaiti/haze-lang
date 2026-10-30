# Haze design

## 1. How Lean 4 is built (what Haze starts from)

References are to the sources shipped with the pinned toolchain
(`~/.elan/toolchains/leanprover--lean4---v4.35.0/src/lean`).

| Stage | Lean | Role |
|---|---|---|
| Concrete syntax | `Syntax` (`Init/Prelude.lean:5119`), `Lean/Parser/*` | Extensible parser producing untyped trees (`node`, `atom`, `ident`, `missing`). Syntax categories and `macro_rules` rewrite trees before elaboration. |
| Elaboration | `Lean/Elab/*`; `elabTermAux` (`Lean/Elab/Term/TermElabM.lean:1851`) | Turns `Syntax` into typed `Expr`, resolving names, inserting coercions and implicit arguments, solving metavariables and running tactics. Elaborators are looked up in the `termElabAttribute` table (`TermElabM.lean:637-654`), which built-in (`builtin_term_elab`) and user (`term_elab`) elaborators share. The elaborator is **not trusted**. |
| Core terms | `Expr` (`Lean/Expr.lean:298`) | `bvar` (de Bruijn index), `fvar`, `mvar`, `sort`, `const`, `app`, `lam`, `forallE`, `letE`, `lit`, `mdata`, `proj`: the dependent type theory with universes and inductive types. Binder names are kept only for printing. |
| Declarations | `Declaration` (`Lean/Declaration.lean:185`), `ConstantInfo` (`:430`) | Axioms, definitions, theorems, opaque constants, inductive types. A theorem is a constant whose value is a proof term. |
| Kernel | `addDecl` (`Lean/AddDecl.lean:229`) → `@[extern "lean_add_decl"]` (`Lean/Environment.lean:296`) | A small C++ type checker (not shipped in the toolchain; reached through FFI) re-checks each declaration before it enters the `Environment`. This is the de Bruijn criterion: only the kernel has to be trusted. |
| Driver | `processCommand` / `processCommands` (`Lean/Elab/Frontend.lean:64,79`) | Parses and elaborates one command at a time, threading the environment and collecting messages. |

### Why Haze is a new kernel and not a patch to Lean's

Lean's kernel decides one judgement: a term has a type (a proposition is either proved or
not). Software with variable outcomes needs a different judgement: *with what degree of
belief does this property hold, given random events and vague parameters?* Patching the
C++ kernel to return degrees would make every existing Lean proof's meaning ambiguous and
require maintaining a fork of the bootstrapped compiler. Haze keeps Lean's architecture
(untrusted elaborator, small trusted kernel, environment of checked declarations) and
replaces the calculus and the judgement. Haze is written in Lean, so its kernel can be read,
executed and partly proved correct in the same system (`Haze/Theory.lean`).

### Correspondence

| Lean | Haze | Change |
|---|---|---|
| `Syntax`, `Lean.Parser` | `Haze.Syntax` | dedicated grammar for systems, claims and fuzzy literals |
| `Lean.Elab` | `Haze.Elab` | type-directed: `if` on `Deg` elaborates to the stochastic `choose` |
| `Expr` | `Haze.Expr`, `Haze.Stmt` | adds `choose`, `rand`, `cat`, `svar`, `crashed`, bounded `quant`; drops universes and dependent types |
| `Declaration` / `ConstantInfo` | `Haze.Decl`, `GlobalInfo`, `SysInfo`, `ClaimInfo` | new kinds: fuzzy `param`, random `node`, `system`, **graded theorem** carrying `[bel, pl]` |
| kernel `type_checker` | `Haze.Kernel.Check` | graded judgement `Γ ⊢ e : T @ g` |
| kernel `whnf`/defeq | `Haze.Kernel.Eval`, `Verify` | exact semantics: distribution monad, model checking, α-cut integration |
| `Environment.addDecl` | `Kernel.addDecl` + `Frontend.processDecl` | a declaration is committed only after both the checker and its semantic action succeed |

## 2. Grades: which uncertainty a term can carry

`Grade = {prob, fuzzy, partial} ⊆ Bool³`, ordered pointwise. `⊔` is pointwise `or`.

```
 Γ ⊢ lit v : T @ crisp            Γ ⊢ gvar x : T @ grade(x)       param ⇒ fuzzy
 Γ ⊢ rand r args : T @ ⊔args ⊔ prob     Γ ⊢ cat alts : T @ ⊔alts ⊔ prob   (Σ weights = 1, all ≥ 0)
 Γ ⊢ c : Deg @ g₀   Γ ⊢ a : T @ g₁   Γ ⊢ b : T @ g₂
 ─────────────────────────────────────────────── (stochastic conditional)
 Γ ⊢ choose c a b : T @ g₀ ⊔ g₁ ⊔ g₂ ⊔ prob
 Γ ⊢ call f args : ret(f) @ ⊔args ⊔ latent(f)
```

Function latent grades are the least fixed point of `g ↦ g ⊔ infer(body | f : g)`,
starting from `partial` for recursive functions. `Haze/Theory.lean` proves that `⊔`
is a semilattice whose order is `le` (`Grade.le_iff_join`) with a top element
(`Grade.le_top`). Iteration therefore converges in at most 4 steps. A declaration
annotated `@g` is rejected when its inferred grade is not `≤ g`.
For example, `def noisy : Num @crisp := uniform(1,3)` is a kernel error.

## 3. Semantics

**Values and exactness.** Numbers are exact rationals (`Rat` from Lean core). All
probabilities are exact, and the output prints `0.666667 (=2/3)`.

**Expressions** denote finite sub-distributions over `Value ⊎ {⊥}`
(`Kernel.M α = Except String (List (Res α × Rat))`). `⊥` (`Res.stuck`) means the
recursion fuel ran out: the outcome is formally *unknown*. Runtime faults such as division
by zero or a degree outside [0,1] are errors, not outcomes.

**Worlds.** Declarations are processed in order. Random nodes extend every world with a
sampled value (so `def actual := …` is one random variable shared by all later uses).
`observe` filters worlds and renormalises (exact Bayes).

**Fuzzy parameters as random sets.** A normal possibility distribution `π` is read as a
consonant random set: draw `α ~ U(0,1]` and take the α-cut `{v | π(v) ≥ α}`. Haze
enumerates joint parameter assignments `y` with `π(y) = minᵢ πᵢ(yᵢ)`. For each `y`
the program is an exact finite Markov chain, and a property gets
`[lo_y, hi_y]` (`hi_y − lo_y` is the unknown mass). Then

```
Bel = (1/π*) Σⱼ (αⱼ − αⱼ₊₁) · min_{π(y) ≥ αⱼ} lo_y
Pl  = (1/π*) Σⱼ (αⱼ − αⱼ₊₁) · max_{π(y) ≥ αⱼ} hi_y
```

over the distinct levels `1 = α₁ > … > αₙ > αₙ₊₁ = 0` (`π*` = max possibility, which is
1 unless an observation eliminated the core). Special cases:

* no fuzzy parameters: `Bel = Pl = Pr` exactly;
* a crisp property of fuzzy parameters only: `Bel = N` (necessity) and `Pl = Π`
  (possibility). In `tests/basics.hz`, `load ≈ {50: .5, 70: 1, 90: .4}` gives
  `Π(load > 80) = 0.4` and `N(load ≤ 80) = 0.6`.

**Fuzzy truth.** A `Deg`-valued property contributes its degree rather than 0/1, so the
interval bounds the expected truth degree. Connectives follow the selected t-norm family.
The Lean proofs cover commutativity, units, `tand ≤ min`, and De Morgan for Gödel and
Łukasiewicz.

**Systems and temporal properties.** A configuration is `(world, state vars, crashed)`.
A step executes the statement block (a failed `assert` sets `crashed`, which is
absorbing). The kernel propagates exact distributions over configurations, merging equal
ones:

* `after[k] φ`: expected degree of φ at step k;
* `always[k] φ`: per path, the running `min` of φ over steps 0..k (paths that reach 0
  are dropped);
* `eventually[k] φ`: per path, the running `max` (paths that reach 1 are absorbed).

Divergence on a path contributes the worst case to `lo` and the best case to `hi`.

**Relevance projection.** Before checking, worlds are projected onto the globals the
property can read, transitively through node definitions, called functions and the
system's init and step (`relevantGlobals`). Equal projections are merged. This is sound
because the property cannot observe the dropped coordinates, and it keeps state spaces
small.

**Claims and theorems.**

* `claim c : φ` is always accepted and stores its `[Bel, Pl]`.
* `claim … with prob >= q` is accepted iff `q ≤ Bel`; `with prob <= q` iff `Pl ≤ q`.
* `theorem t : φ` is accepted iff `Bel = 1`: true on every path of positive probability,
  for every parameter assignment of positive possibility, with no unknown mass.

Rejected theorems report a counterexample configuration. For leading
`forall`/`and` structure they also report the falsifying bindings.

## 4. Trust and testing

* Trusted: `Haze/Kernel/*` (≈ 900 lines of Lean). The elaborator's output is re-checked by
  `Kernel.addDecl`, which repeats every type and grade judgement.
* Proved in Lean (`Haze/Theory.lean`, standard axioms only): the grade-lattice laws behind
  latent-grade inference, and the algebraic laws of the fuzzy connectives the evaluator
  executes.
* Tested: golden files for every program in `tests/` and `examples/` (`lake test`).
  They include hand-checked exact answers: Monty Hall 2/3; a Bayesian test posterior of
  19/118; binomial coin counts; a possibility/necessity pair; a Łukasiewicz implication;
  a retry give-up probability of 0.19³; a stale-read risk of 0.128; and a triage
  posterior of 567/955.
