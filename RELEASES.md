# Haze Releases

There is not yet a guarantee of backwards compatibility between versions. Breaking changes
will be described in the release notes.

## v0.1.0 (unreleased)

The first version of Haze.

### Language

* Enumeration types, fuzzy parameters (`param x : T ~= {…}`), random inputs
  (`input x : T ~ e`), definitions and possibly recursive functions.
* Exact random primitives: `flip`, `uniform`, `binomial` and categorical distributions.
* Stochastic conditionals: `if` on a condition of type `Deg`.
* Fuzzy sets with hedges (`x is very hot`) and three fuzzy logics: Gödel, product and
  Łukasiewicz.
* Bayesian conditioning with `observe`.
* Transition systems with assignments, conditionals, `match`, local definitions and `assert`.
* Bounded temporal properties: `always[k]`, `eventually[k]` and `after[k]`.
* Claims, claims with probability bounds, and theorems.
* The queries `#check`, `#eval`, `#prob`, `#expect`, `#outcomes` and `#print`.

### Kernel

* A graded type system that records randomness, fuzziness and possible non-termination, and
  enforces declared grades.
* Exact semantics with rational arithmetic. Outcomes that run out of fuel are unknown and
  widen the result interval.
* Belief and plausibility for fuzzy parameters, computed by integration over α-cuts.
* Bounded model checking with counterexamples.
* Theorems in Lean about the grade lattice and the fuzzy connectives.

### Tools

* The `haze` command, with the `--fuel` option and JSON output (`--json`).
* Golden tests, run with `lake test`.
* A conformance test that checks a Python implementation against its Haze model, and continuous
  integration that runs it.
