# Design and semantics

This document explains how Haze is put together and what its answers mean precisely. It's
written for readers who know some typed functional programming and basic probability. If you
want to learn the language rather than its internals, the
[tutorial](../examples/Tutorial/JobWorker.hz) and the
[language reference](Language-Reference.md) are better places to start.

## Starting from Lean

Haze follows the architecture of Lean 4, so it helps to recall how Lean is organized. The file
references below point into the Lean sources that come with the pinned toolchain, under
`~/.elan/toolchains/leanprover--lean4---v4.35.0/src/lean`.

| Stage | In Lean | What it does |
|---|---|---|
| Syntax | `Syntax` (`Init/Prelude.lean:5119`), `Lean/Parser` | An extensible parser produces untyped syntax trees, which macros can rewrite before elaboration. |
| Elaboration | `Lean/Elab`, `elabTermAux` (`Lean/Elab/Term/TermElabM.lean:1851`) | The elaborator turns syntax into typed terms: it resolves names, inserts coercions and implicit arguments, solves metavariables and runs tactics. Elaborators for each kind of syntax are looked up in the `termElabAttribute` table (`TermElabM.lean:637–654`), which built-in and user-defined elaborators share. |
| Core terms | `Expr` (`Lean/Expr.lean:298`) | Terms of a dependent type theory with universes and inductive types. Bound variables are de Bruijn indices, and binder names are kept only for printing. |
| Declarations | `Declaration` (`Lean/Declaration.lean:185`), `ConstantInfo` (`:430`) | Axioms, definitions, theorems, opaque constants and inductive types. A theorem is a constant whose value is a proof. |
| Kernel | `addDecl` (`Lean/AddDecl.lean:229`), `lean_add_decl` (`Lean/Environment.lean:296`) | A small type checker, written in C++, checks every declaration again before it enters the environment. |
| Driver | `processCommand`, `processCommands` (`Lean/Elab/Frontend.lean:64, 79`) | Commands are parsed and elaborated one at a time, threading the environment and collecting messages. |

The important idea is the split between the elaborator and the kernel. The elaborator does
the hard, heuristic work and may have bugs; the kernel is small and checks its output, so only
the kernel has to be trusted.

### Why Haze has its own kernel

Lean's kernel answers one question: does this term have this type? A proposition is either
proved or it isn't. The questions Haze is built for are graded instead: how likely is it that a
property holds, given random events and parameters that are only roughly known? Changing Lean's
kernel to answer that would change the meaning of every existing Lean proof, and it would mean
maintaining a fork of Lean's compiler and runtime.

So Haze keeps the architecture and replaces what sits inside it. It has its own elaborator, an
environment of checked declarations, and a small kernel that checks every declaration again,
but its core language and the judgment its kernel decides are different. Because Haze is
written in Lean, its kernel can be read, run and partly proved correct in the same system (see
[Trust and testing](#trust-and-testing)).

### How the parts correspond

| Lean | Haze | What changes |
|---|---|---|
| `Lean.Syntax`, `Lean.Parser` | `Haze.Syntax` | A fixed grammar for systems, claims and fuzzy literals. |
| `Lean.Elab` | `Haze.Elab` | An `if` whose condition is a `Deg` becomes the stochastic conditional `Expr.choose`. |
| `Lean.Expr` | `Haze.Expr`, `Haze.Stmt` | Adds stochastic conditionals, random primitives, categorical choice, system state and bounded quantifiers, and drops universes and dependent types. |
| `Lean.Declaration` | `Haze.Decl` and the records in `Haze.Env` | Adds fuzzy parameters, random nodes, transition systems, and theorems that store a belief–plausibility interval instead of a proof. |
| The kernel type checker | `Haze.Kernel.Check` | Decides the graded judgment `Γ ⊢ e : T @ g`, described below. |
| Kernel reduction | `Haze.Kernel.Eval`, `Haze.Kernel.Verify` | Computes exact results: a distribution monad, model checking and α-cut integration. |
| `Lean.Environment.addDecl` | `Haze.Kernel.addDecl`, `Haze.Frontend.processDecl` | A declaration is added only after both the type checker and its semantic action succeed. |

## Grades

Alongside its type, every term in Haze has a grade that records which kinds of uncertainty it
can carry. A grade is a subset of `{prob, fuzzy, partial}`: `prob` means the term depends on a
random choice, `fuzzy` that it depends on a fuzzy parameter, and `partial` that computing it
might run out of fuel. Grades are ordered by inclusion, and combining two terms takes the union
of their grades. The main rules are:

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

A function call adds the function's latent grade, the uncertainty its body introduces. For a
recursive function this depends on itself, so the kernel computes it as a least fixed point,
starting from `partial` and iterating. The theorems `Grade.le_iff_join` and `Grade.le_top` in
[`Haze/Theory.lean`](../Haze/Theory.lean) show that grades form a finite join-semilattice with a
top element, which is why the iteration always stops, after at most four rounds.

You can also state the grade you expect, and the kernel holds you to it:
`def noisy : Num @crisp := uniform(1, 3)` is rejected, because `uniform` is random.

## Semantics

### Exact numbers

Numbers are exact rationals (Lean's `Rat`). Every probability Haze reports is either exact or,
for large components of an unbounded property, a pair of bounds checked in exact arithmetic (see
[Unbounded properties](#unbounded-properties)). When a
fraction is long, messages round it and show the exact value next to it, as in
`0.666667 (=2/3)`, and very small numbers are written in scientific notation, as in
`≈1.37018e-8 (=1/72982849)`.

### Expressions

An expression denotes a finite probability distribution over outcomes, which `Haze.Kernel.M` represents
as a list of outcomes with exact weights. An outcome is either a value or `Res.stuck`, which
means a computation ran out of fuel and its result is unknown. Runtime faults, such as division
by zero or a degree outside the range from 0 to 1, are reported as errors rather than treated
as outcomes.

### Worlds

Haze processes declarations in order, and they define a distribution over worlds. Each random
node adds one value to every world, so all later references to the node see the same value.
`observe` keeps only the worlds in which its condition holds and rescales their probabilities by
Bayes' rule.

The worlds aren't built once for the whole file. The front end records the parameters, nodes
and observations, and each query has the kernel replay them (`Haze.Kernel.buildBranches`),
including only what the query or an earlier observation can read. The rest get the unknown
outcome without being evaluated. Twenty independent inputs with a hundred values each would
otherwise mean 100²⁰ worlds before the first query. A node is still evaluated once when it's
declared, with what it depends on, so its runtime errors are reported where it is written.

### Fuzzy parameters

A fuzzy parameter is a normal possibility distribution `π` over finitely many values: every
value has a possibility between 0 and 1, and at least one has possibility 1. Haze reads it as a
random set. Drawing `α` uniformly from `(0, 1]` gives the α-cut `{v | π v ≥ α}`, the set of
values that are still possible at level `α`.

To evaluate a property, Haze goes through every joint assignment `y` of the fuzzy parameters.
The possibility of an assignment is the smallest possibility among its values. With `y` fixed,
the model is an ordinary finite Markov chain, and the property gets an exact interval
`[lo y, hi y]`; the two ends differ only because of outcomes that are unknown. Haze
then combines the assignments into a belief and a plausibility:

```
Bel = (1 / π*) · Σⱼ (αⱼ - αⱼ₊₁) · min { lo y | π y ≥ αⱼ }
Pl  = (1 / π*) · Σⱼ (αⱼ - αⱼ₊₁) · max { hi y | π y ≥ αⱼ }
```

Here `α₁ > α₂ > … > αₙ` are the distinct possibilities of the assignments, `αₙ₊₁ = 0`, and `π*`
is the largest possibility. `π*` is 1 unless an observation has ruled out every assignment of
possibility 1.

Two special cases make these numbers easier to read. Without fuzzy parameters, belief and
plausibility are both just the exact probability. For a true-or-false property that depends only
on fuzzy parameters, they are the necessity and possibility of possibility theory: in
[`tests/basics.hz`](../tests/basics.hz), the parameter `load ≈ {50: 0.5, 70: 1, 90: 0.4}` gives
`load > 80` a possibility of 0.4 and `load <= 80` a necessity of 0.6. In general, the pair is the
belief and plausibility of Dempster–Shafer theory for the random set formed by combining the
α-cuts with the probabilistic model.

### Continuous parameters

A continuous parameter (`tri`, `trap` or `likelihood`) has a possibility for every number in an
interval, and its α-cuts are intervals. The formulas above still define belief and plausibility,
with the sum replaced by an integral over `α` and the minimum and maximum taken over a range of
values. Haze computes them in three steps (`Haze.Kernel.Continuous`).

**Levels.** The integral is split at the levels `j / N` for `j = 1, …, N` (`levels N`, 10 by
default), at the possibilities of the listed parameters, and, for a likelihood, at a few levels
close to 0. On the band between two levels `n < l`, every α-cut lies inside the cut at `n`. Taking
the minimum over the cut at `n` can only lower it, so the result is a lower bound on the belief;
likewise the maximum gives an upper bound on the plausibility. The cuts at `l` bound them from the
other side, which is the bracket the output reports.

**Bounds over a range.** To bound the result over a range of values, Haze checks the model with
the parameter's value an interval. Arithmetic on intervals gives intervals that contain every
possible result. A probability that is an interval from `l` to `h` gives each outcome at least its
lowest probability, and the remaining `h - l` becomes an *ambiguous* outcome (`Res.amb`), one of a
set of outcomes without saying which. A comparison that an interval can't decide is ambiguous in
the same way. Each step of the system then moves, with known probabilities, either to a state or
to one of a set of states. This is the *parameter lifting* of Quatmann et al.: every occurrence
of the parameter may take a different value from the range, which allows more behaviors than any
single value does. The smallest and largest probabilities over all ways of resolving the
ambiguity are bounds that hold for every value in the range (`Haze.Kernel.Robust`). They're
computed by policy iteration and then checked against the defining equations in exact arithmetic:
an upper bound `u` must satisfy `F u ≤ u`, and a lower bound `l` must satisfy `l ≤ F l` once the
states from which the goal can be avoided forever are set to 0. Bounded properties use the same
solver on the state space unrolled up to the bound.

**Search.** Checking single values gives results that the minimum can't exceed, and the maximum
can't fall below. Branch and bound splits the piece of the range with the weakest bound until the
bound is within a relative tolerance of the best single value, or a budget of 40 interval checks
is spent. Pieces are split first at the constants of the model, as a single value with the open
ranges on either side, so that comparisons with those constants are decided. The reported bound
is the weakest bound over all the pieces, so it is certified even when the search stops early.
When the result moves monotonically with every occurrence of the parameter, the bound over a range
is reached at one of its ends and the search ends at once.

### Fuzzy truth

A property of type `Deg` contributes its degree of truth rather than 0 or 1, so the interval
bounds its expected degree. `and`, `or` and `not` follow whichever fuzzy logic is active.

### Systems and temporal properties

A system's configuration is a world, the values of its state variables, and whether it has
crashed. Each step runs the step block; a failed `assert` crashes the system, and a crashed
configuration never changes again. The kernel computes the exact distribution of
configurations one step at a time and merges configurations that are equal. On top of that:

- `after[k] φ` is the expected degree of `φ` at step `k`.
- `always[k] φ` tracks the lowest degree of `φ` along each path from step 0 to step `k`. Paths
  whose lowest degree reaches 0 are dropped.
- `eventually[k] φ` tracks the highest degree along each path. Paths that reach 1 count as
  satisfied and aren't explored further.

If a path runs into an unknown outcome, the rest of that path is unknown too. It counts as a
failure for the lower bound and as a success for the upper bound.

### Unbounded properties

`always φ` and `eventually φ` without a bound, and `steps until φ`, are about the whole infinite
run. For these, the kernel first explores every reachable configuration breadth first
(`Haze.Kernel.Checker.explore`), giving a finite Markov chain, and then solves linear equations
on it.

For a `Bool` property, `eventually φ` is the probability `x_s` of reaching a state where `φ`
holds. If `h_s` is the probability that `φ` holds in state `s` (it can be random), then
`x_s = h_s + (1 - h_s) Σ_t P(s, t) x_t`. `always φ` is one minus the probability of reaching a
state where `φ` fails. For a `Deg` property, `eventually` is the expected highest degree along
the run and `always` the expected lowest. Both reduce to reachability by the layer-cake formula
`E[X] = Σⱼ (θⱼ - θⱼ₋₁) P(X ≥ θⱼ)`, where the `θⱼ` are the degrees the property takes, so one
system is solved for each `θⱼ`. The expected number of steps until `φ` holds solves
`y_s = c_s (1 + Σ_t P(s, t) y_t)`, where `c_s` is the probability that `φ` doesn't hold in `s`;
it is infinite from states where, with positive probability, `φ` never holds, and graph search
finds those exactly.

`Haze.Kernel.Solve.solve` handles these systems. States that can't reach a positive right-hand
side have value 0, found by graph search. The rest are split into strongly connected
components, which are solved from the ones that can't reach any other component to the ones
that can, so each component only needs the values of components already solved. A component of
up to 120 states is solved exactly by Gauss–Jordan elimination over the rationals.

Exact elimination on a larger component would take too long, so Haze solves it in floating
point and then certifies the answer. The floating-point solution comes from an LU factorization
of the band of `I - A`, which is cheap because breadth-first numbering keeps the band narrow
(and is safe without pivoting because `I - A` is a nonsingular M-matrix). Haze then moves the
solution down and up along a vector `v` with `(I - A) v ≈ 1`, rounds the results to multiples
of 2⁻⁶⁴, and checks in exact arithmetic that the lower vector `l` satisfies `F l ≥ l` and the
upper vector `u` satisfies `F u ≤ u`, where `F x = b + A x`. Since `F` is monotone and its
iterates converge to the unique solution `x*` from any starting point, these inequalities prove
`l ≤ x* ≤ u`. Floating-point error can only make the check fail, in which case Haze widens the
bounds and tries again, falling back to the trivial bounds. It never makes a bound wrong. This is
the idea behind optimistic value iteration (Hartmanns and Kaminski, 2020).

Exploration stops once `explore` states are known. States found but not expanded are treated as
unknown, exactly like outcomes that ran out of fuel: they count as failures for the lower bound
and as successes for the upper bound. This makes systems with infinitely many states usable,
with a result that is always sound and is tight when the unexplored states are unlikely.

### Parallel checking

The kernel is pure, so independent work can run on separate Lean tasks without changing any
result. The parameter assignments of a query are checked in parallel. Within an assignment,
frontiers of 64 or more configurations, breadth-first levels and the property's value in each
state are computed in parallel chunks whose results are joined in their original order. When the
frontier is small, which is common for systems with few states but many random choices per step,
the first point in a step that splits into eight or more outcomes runs the rest of the step
for each outcome in parallel instead (`Haze.Kernel.M.bindSplit`). A query with four or more parameter assignments
doesn't split steps, since its assignments already keep the cores busy.

The benchmarks in [`bench`](../bench) cover these cases; `python scripts/bench.py` times them.
On a 20-thread laptop, the model with 81 parameter assignments went from 37 to 6.5 seconds and
the one with 4,096 random choices per step from 4.6 to 2.1 seconds. A model with a long horizon
on a small chain doesn't benefit, because each step depends on the one before.

Haze doesn't use the GPU. Almost all the time goes into running step programs, with branching
and exact rational arithmetic, and that kind of work suits CPU cores rather than a GPU. The one
GPU-friendly part, the floating-point solve, takes a small share of the time. Because its
answer is certified afterwards, a GPU solver could be added later without trusting it.

### Probability-weighted tests

`#tests` needs the runs of a system, not just its distribution of configurations, so the kernel
can record random decisions while it executes a step (`ECtx.trace`). Each assignment, `let`,
`if`, `match` and `assert` whose term can make a random choice appends what it decided to the
state. Recording is off for every other query, and when it is on it only keeps apart runs that
made different decisions; the probability of each configuration is unchanged.

`Haze.Kernel.Checker.weightedRuns` is a best-first search over partial runs, kept in a heap
ordered by probability. Extending a run multiplies its probability by a factor of at most 1, so
when a complete run is taken from the heap, no run still in the heap, and no extension of one,
can be more likely. Complete runs therefore come out in exactly decreasing order of
probability, and equally likely runs in the order they were found, which keeps the output
deterministic. The search stops after the requested number of runs and enough failing runs, or
after 200,000 expansions.

The statistical test is a one-sided binomial test. For a failure rate `q`, Haze finds the
smallest number of runs `n`, and for it the smallest allowance `c`, with
`P(Bin(n, q) > c) ≤ 10⁻⁶` and `P(Bin(n, q₂) > c) ≥ 0.99`, where `q₂` is twice `q` (or halfway to
1). These tail probabilities are computed in floating point; the test only sizes checks of
other code, so it doesn't affect any result Haze proves.

### Keeping state spaces small

Before checking a property, Haze works out which global variables the property can possibly
read, directly or through node definitions, function calls and the system's initialization and
step (`Haze.Kernel.relevantGlobals`). Only those variables are built into the worlds, and worlds
that become equal are merged. The result doesn't change, since the property can't see the
variables that were dropped, but there are far fewer states to explore.

The same applies to fuzzy parameters. A parameter that neither the property nor an observation
reads doesn't change any assignment's result, and because its possibility distribution is
normal, every α-cut contains at least one of its values. The minimum and maximum over an α-cut
are therefore the same with or without it, and Haze doesn't split on it.

State variables get the classic cone-of-influence reduction from model checking
(`Haze.Kernel.coneOfInfluence`). A state variable depends on the variables read by the
expressions assigned to it, by the local definitions those expressions use, and by the
conditions of the `if`, `match` and random choices around the assignment. The cone of a property
is the set of variables it reads, closed under these dependencies. Variables that an `assert`
reads are always in the cone, since a crash affects everything, and so are the variables that a
function call in an assignment depends on, since a call can run out of fuel. Assignments to the
other variables are removed from the step (`Haze.Kernel.sliceStep`), and those variables stay at
a placeholder value that nothing reads. A clock or a counter that a property never reads no longer splits its configurations.

### Claims and theorems

A claim without a bound is always accepted, and Haze records its interval. A claim
`with prob >= q` is accepted when `q ≤ Bel`, and one `with prob <= q` when `Pl ≤ q`. A theorem is
accepted only when `Bel = 1`, which means it holds on every path of positive probability, for
every parameter assignment of positive possibility, with no unknown outcomes.

A property `φ given ψ` is a conditional probability. For each parameter assignment, Haze
computes `N`, the probability that `ψ` and `φ` both hold, and `C`, the probability that `ψ`
holds and `φ` doesn't, each as an interval because of unknown outcomes. The result is the
interval from `N.lo / (N.lo + C.hi)` to `N.hi / (N.hi + C.lo)`, the least and most favorable
ratios, and these per-assignment intervals are then combined as above. Both are evaluated at the
same step, which is why `given` is limited to `after[k]` and properties without a temporal
operator.

When a theorem or a `with prob >=` bound fails, Haze reports the first configuration that
violates the property, taken from a parameter assignment whose own result breaks the bound. If
the property starts with `forall` quantifiers or conjunctions, it also reports values for the
quantified variables that make it false. When a `with prob <=` bound fails, a violating
configuration would be one where the property is false, which says nothing useful, so Haze
instead looks for a configuration where it holds, as a counterexample to the negated property:
`after[k] ¬φ` for `after[k] φ`, and `always[k] ¬φ` for `eventually[k] φ`.

## Trust and testing

The trusted part of Haze is the kernel in [`Haze/Kernel`](../Haze/Kernel), about 2,000 lines
of Lean including documentation. Floating-point code runs inside it only to propose bounds,
which the kernel then checks in exact arithmetic. `Haze.Kernel.addDecl` re-checks every type and grade that the
elaborator produces, so a mistake in the elaborator can't slip an ill-typed or wrongly graded
declaration past it.

Some of the kernel's foundations are proved in Lean. [`Haze/Theory.lean`](../Haze/Theory.lean)
proves, using only Lean's standard axioms, the lattice laws that latent-grade inference relies
on, and the algebraic laws of the fuzzy connectives the evaluator uses: commutativity, units,
the bound by `min`, and De Morgan duality.

The rest is tested. Every file in [`tests`](../tests) and [`examples`](../examples) is a golden
test (see the [test suite](../tests/README.md)), and many expected results were checked by hand:
2/3 for the Monty Hall problem, a posterior of 19/118 after a positive medical test, a necessity
and possibility pair, a Łukasiewicz implication, a 0.19³ chance of giving up after three retries,
a stale-read risk of 0.128, and a root-cause posterior of 567/955. The models in
[`examples/Gallery`](../examples/Gallery) are also checked against independent calculations by
[`scripts/verify_gallery.py`](../scripts/verify_gallery.py). The test
[`tests/systems_and_conditioning.hz`](../tests/systems_and_conditioning.hz) covers the
reductions above, including a dependency chain long enough to catch a closure that stops
early.

## References

- Didier Dubois and Henri Prade. *Possibility Theory: An Approach to Computerized Processing of
  Uncertainty* (1988).
- Glenn Shafer. *A Mathematical Theory of Evidence* (1976).
- Christel Baier and Joost-Pieter Katoen. *Principles of Model Checking* (2008).
- Leonardo de Moura and Sebastian Ullrich. "The Lean 4 Theorem Prover and Programming Language"
  (2021).
