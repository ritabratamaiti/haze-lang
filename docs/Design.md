# Design and Semantics

This document describes how Haze is implemented, how its implementation relates to Lean's,
and the precise meaning of the results that it reports. It assumes familiarity with typed
functional programming and with basic probability. Readers who want to learn the language
should start with the [tutorial](../examples/Tutorial/JobWorker.hz) and the
[language reference](Language-Reference.md).

## The Structure of Lean

Haze is built on the same architecture as Lean 4. The references below are to the Lean
sources that are included with the pinned toolchain, in
`~/.elan/toolchains/leanprover--lean4---v4.35.0/src/lean`.

| Stage | Lean | Role |
|---|---|---|
| Concrete syntax | `Syntax` (`Init/Prelude.lean:5119`), `Lean/Parser` | An extensible parser produces untyped syntax trees. Syntax categories and macros rewrite the trees before elaboration. |
| Elaboration | `Lean/Elab`, `elabTermAux` (`Lean/Elab/Term/TermElabM.lean:1851`) | The elaborator turns syntax into typed terms. It resolves names, inserts coercions and implicit arguments, solves metavariables and runs tactics. Elaborators for each kind of syntax are found through the `termElabAttribute` table (`TermElabM.lean:637–654`), which built-in and user-defined elaborators share. The elaborator is not trusted. |
| Core terms | `Expr` (`Lean/Expr.lean:298`) | Terms of a dependent type theory with universes and inductive types. Bound variables are de Bruijn indices (`bvar`), and binder names are kept only for printing. |
| Declarations | `Declaration` (`Lean/Declaration.lean:185`), `ConstantInfo` (`:430`) | Axioms, definitions, theorems, opaque constants and inductive types. A theorem is a constant whose value is a proof. |
| Kernel | `addDecl` (`Lean/AddDecl.lean:229`), `lean_add_decl` (`Lean/Environment.lean:296`) | A small type checker, written in C++ and called through the foreign function interface, checks each declaration again before it enters the environment. Only the kernel needs to be trusted. |
| Driver | `processCommand`, `processCommands` (`Lean/Elab/Frontend.lean:64, 79`) | Commands are parsed and elaborated one at a time, threading the environment and collecting messages. |

### Why Haze Has Its Own Kernel

Lean's kernel decides whether a term has a type, so a proposition is either proved or not.
Software with variable outcomes calls for a different question: how strongly does a property
hold, given random events and vaguely known parameters? Changing Lean's kernel to answer this
question would change the meaning of every existing Lean proof, and it would require
maintaining a separate version of Lean's compiler and runtime.

Haze keeps Lean's architecture, with an elaborator that isn't trusted, a small kernel and an
environment of checked declarations, and replaces the core language and the judgement that
the kernel decides. Because Haze is written in Lean, its kernel can be read, run and partly
proved correct in the same system (see [Trust and Testing](#trust-and-testing)).

### Correspondence

| Lean | Haze | Difference |
|---|---|---|
| `Lean.Syntax`, `Lean.Parser` | `Haze.Syntax` | A fixed grammar for systems, claims and fuzzy literals. |
| `Lean.Elab` | `Haze.Elab` | `if` on a `Deg` condition is elaborated to the stochastic conditional `Expr.choose`. |
| `Lean.Expr` | `Haze.Expr`, `Haze.Stmt` | Adds stochastic conditionals, random primitives, categorical choice, system state and bounded quantifiers. Has no universes or dependent types. |
| `Lean.Declaration` | `Haze.Decl` and the `Haze.Env` records | Adds fuzzy parameters, random nodes, transition systems and graded theorems, which store a belief–plausibility interval. |
| The kernel type checker | `Haze.Kernel.Check` | Decides the graded judgement `Γ ⊢ e : T @ g`. |
| Kernel reduction | `Haze.Kernel.Eval`, `Haze.Kernel.Verify` | Exact semantics: a distribution monad, model checking and α-cut integration. |
| `Lean.Environment.addDecl` | `Haze.Kernel.addDecl`, `Haze.Frontend.processDecl` | A declaration is added only after both the type checker and its semantic action succeed. |

## Grades

A grade is a subset of `{prob, fuzzy, partial}`, ordered by inclusion. The join `g ⊔ g'` is
the union. The grade of a term records which kinds of uncertainty it can carry. The main
rules of the graded judgement are:

```
Γ ⊢ lit v : T @ crisp
Γ ⊢ gvar x : T @ grade(x)                          (a fuzzy parameter has grade fuzzy)
Γ ⊢ rand r args : T @ ⊔ grade(args) ⊔ prob
Γ ⊢ cat alts : T @ ⊔ grade(alts) ⊔ prob             (weights are non-negative and sum to 1)
Γ ⊢ call f args : ret(f) @ ⊔ grade(args) ⊔ latent(f)

Γ ⊢ c : Deg @ g₀     Γ ⊢ a : T @ g₁     Γ ⊢ b : T @ g₂
──────────────────────────────────────────────────────
Γ ⊢ choose c a b : T @ g₀ ⊔ g₁ ⊔ g₂ ⊔ prob
```

The latent grade of a function is the least fixed point of `g ↦ g ⊔ infer(body, f : g)`,
starting from `partial` for recursive functions. The kernel computes it by iteration.
`Grade.le_iff_join` and `Grade.le_top` show that the grades form a finite join-semilattice
with a top element, so the iteration reaches the fixed point after at most four steps. A
declaration annotated `@g` is rejected if its inferred grade is not below `g`. For example,
`def noisy : Num @crisp := uniform(1, 3)` is rejected.

## Semantics

### Exact Values

Numbers are exact rational numbers, using Lean's `Rat`, so every probability is exact.
Messages show long fractions both in decimal notation and exactly, as in `0.666667 (=2/3)`.

### Expressions

An expression denotes a finite sub-distribution over outcomes. An outcome is either a value
or the unknown outcome `Res.stuck`, which arises when function calls run out of fuel.
`Haze.Kernel.M` represents such distributions as lists of outcomes with exact weights.
Runtime faults, such as division by zero or a degree outside the interval from 0 to 1, are
errors rather than outcomes.

### Worlds

Declarations are processed in order. Each random node extends every world with one value,
so every later reference to the node sees the same value. `observe` keeps the worlds in
which its condition holds and rescales their probabilities by Bayes' rule.

### Fuzzy Parameters

A fuzzy parameter is a normal possibility distribution `π` over finitely many values. Haze
interprets it as a random set: drawing `α` uniformly from `(0, 1]` gives the α-cut
`{v | π v ≥ α}` of values that are admissible at level `α`.

Haze enumerates the joint assignments `y` of the fuzzy parameters. The possibility of an
assignment is the minimum of the possibilities of its values. For each `y`, the model is a
finite Markov chain, and a property has an exact interval `[lo y, hi y]`, where
`hi y - lo y` is the probability of the outcomes that are unknown. The reported belief and
plausibility are

```
Bel = (1 / π*) · Σⱼ (αⱼ - αⱼ₊₁) · min { lo y | π y ≥ αⱼ }
Pl  = (1 / π*) · Σⱼ (αⱼ - αⱼ₊₁) · max { hi y | π y ≥ αⱼ }
```

where `α₁ > α₂ > … > αₙ` are the distinct possibilities of the assignments, `αₙ₊₁ = 0`, and
`π*` is the largest possibility. `π*` is 1 unless an observation removed every assignment of
possibility 1. Two special cases explain the meaning of these numbers:

* Without fuzzy parameters, belief and plausibility are both the exact probability of the
  property.
* For a Boolean property of fuzzy parameters alone, belief is the necessity of the property
  and plausibility is its possibility, as in possibility theory. In
  [`tests/basics.hz`](../tests/basics.hz), the parameter `load ≈ {50: 0.5, 70: 1, 90: 0.4}`
  gives `load > 80` a possibility of 0.4 and `load <= 80` a necessity of 0.6.

In general, the pair is the belief and plausibility of Dempster–Shafer theory for the random
set obtained by combining the α-cuts with the probabilistic model.

### Fuzzy Truth

A property of type `Deg` contributes its degree instead of 0 or 1, so the interval bounds the
expected degree of truth. The connectives follow the active fuzzy logic.

### Systems and Temporal Properties

A configuration of a system consists of a world, the values of the state variables and
whether the system has crashed. A step runs the step block. A failed `assert` crashes the
system, and a crashed configuration never changes. The kernel computes the exact
distribution of configurations step by step, merging equal configurations:

* `after[k] φ` is the expected degree of `φ` at step `k`.
* `always[k] φ` follows the minimum degree of `φ` along each path from step 0 to step `k`.
  Paths whose minimum reaches 0 are dropped.
* `eventually[k] φ` follows the maximum degree along each path. Paths whose maximum reaches
  1 count as satisfied and are not explored further.

When a path ends in an unknown outcome, the rest of the path is unknown. It counts as a
failure for the lower bound `lo` and as a success for the upper bound `hi`.

### Relevance Projection

Before checking a property, Haze reduces each world to the global variables that the
property can read, either directly or through node definitions, called functions and the
system's initialization and step (`Haze.Kernel.relevantGlobals`). Worlds that become equal
are merged. This doesn't change the result, because the property can't observe the other
variables, and it makes the state space smaller.

### Claims and Theorems

* A claim without a bound is always accepted, and its interval is stored.
* A claim `with prob >= q` is accepted if `q ≤ Bel`, and a claim `with prob <= q` is accepted
  if `Pl ≤ q`.
* A theorem is accepted if `Bel = 1`. This means that it holds on every path of positive
  probability, for every parameter assignment of positive possibility, without any unknown
  outcomes.

When a theorem or bound is rejected, Haze reports the first configuration that violates the
property. If the property begins with `forall` quantifiers or conjunctions, it also reports
values of the bound variables that falsify it.

## Trust and Testing

* **Trusted code.** The kernel is in [`Haze/Kernel`](../Haze/Kernel), about 1000 lines of
  Lean including documentation. `Haze.Kernel.addDecl` checks every type and grade of the
  elaborator's output again.
* **Kernel theorems.** [`Haze/Theory.lean`](../Haze/Theory.lean) proves, using only Lean's
  standard axioms, the lattice laws that latent-grade inference relies on and the algebraic
  laws of the fuzzy connectives that the evaluator uses: commutativity, units, the bound by
  `min` and De Morgan duality.
* **Tests.** Every file in [`tests`](../tests) and [`examples`](../examples) is a golden
  test (see the [test suite](../tests/README.md)). The expected outputs include results
  that were checked by hand: 2/3 for the Monty Hall problem, a posterior of 19/118 after a
  positive medical test, binomial counts of coin flips, a necessity and possibility pair, a
  Łukasiewicz implication, a probability of 0.19³ of giving up after three retries, a
  stale-read risk of 0.128 and a root-cause posterior of 567/955.

## References

* Didier Dubois and Henri Prade. *Possibility Theory: An Approach to Computerized Processing
  of Uncertainty* (1988).
* Glenn Shafer. *A Mathematical Theory of Evidence* (1976).
* Christel Baier and Joost-Pieter Katoen. *Principles of Model Checking* (2008).
* Leonardo de Moura and Sebastian Ullrich. "The Lean 4 Theorem Prover and Programming
  Language" (2021).
