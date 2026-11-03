# Release Notes

Haze doesn't promise backwards compatibility between versions yet. When a release breaks
existing models, its notes will say so.

## v0.1.0 (unreleased)

This is the first version of Haze.

### Language

You can declare enumeration types, fuzzy parameters (`param x : T ~= {…}`), random inputs
(`input x : T ~ e`), definitions, and functions, which may be recursive. Randomness comes from
`flip`, `uniform`, `binomial` and categorical distributions, all computed exactly. An `if`
whose condition is a degree of truth (`Deg`) becomes a stochastic conditional. Fuzzy sets can
be used with hedges, as in `x is very hot`, and the connectives follow one of three fuzzy
logics: Gödel, product or Łukasiewicz. `observe` conditions the model on evidence.

Systems are described by state variables and a step made of assignments, conditionals,
`match`, local definitions and `assert`. Properties can look at a single step (`after[k]`),
every step (`always[k]`) or some step (`eventually[k]`) up to a bound. Claims (optionally with
probability bounds) and theorems state what should hold, and the queries `#check`, `#eval`,
`#prob`, `#expect`, `#outcomes` and `#print` inspect the model.

Systems can take parameters (`system Pipeline(review : Bool) { … }`), so variants of a design
can be compared without copying the model. Properties can be conditioned with `given`, and the
weights of a categorical distribution can be computed from parameters and other values.

### Kernel

The kernel's type system records whether a term depends on chance, on fuzzy parameters, or on
a computation that might not finish, and it enforces declared grades. All arithmetic is exact.
Outcomes that run out of fuel count as unknown and widen the result instead of being guessed.
Fuzzy parameters give results as belief and plausibility, computed by integrating over
α-cuts. Systems are model checked up to a bound, with counterexamples when a property fails,
and the grade lattice and the fuzzy connectives come with theorems proved in Lean.

Checking only tracks what a property can observe. Each query builds just the inputs and
parameters that it or an earlier observation reads, and state variables outside the property's
cone of influence aren't tracked. A failed `with prob <=` bound now shows a run where the
property holds, taken from a parameter value that breaks the bound.

### Tools

The `haze` command checks models and supports `--fuel` and JSON output (`--json`). The test
suite runs with `lake test`. When a result depends on more than six parameter assignments, the
output summarizes them and ranks the parameters by how much each one moves the result.

### Examples

New examples model AI agents (consistency across repeated runs from τ-bench, and a coding
agent's wrong merges in CI from the PatchDiff study), Raft leader election with and without
randomized timeouts, and a randomized-response survey with its privacy guarantee.
