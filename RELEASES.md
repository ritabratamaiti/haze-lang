# Release notes

Haze doesn't promise backwards compatibility between versions yet. When a release breaks
existing models, its notes will say so.

## v0.1.0 (November 17, 2026)

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
a computation that might not finish, and it enforces declared grades. Probabilities are exact rationals.
Outcomes that run out of fuel count as unknown and widen the result instead of being guessed.
Fuzzy parameters give results as belief and plausibility, computed by integrating over
α-cuts. Systems are model checked up to a bound, with counterexamples when a property fails,
and the grade lattice and the fuzzy connectives come with theorems proved in Lean.

`always` and `eventually` can be used without a bound, and `#expect S |= steps until φ` gives
the expected number of steps until a property holds. The kernel explores the reachable states
and solves the resulting linear equations component by component: exactly for components of up to
120 states, and in floating point for larger ones, with the bounds then checked in exact
arithmetic, and systems with infinitely many
states are explored up to a limit set by `explore N` or `--states`, with the unexplored part
counted as unknown. The craps, tennis, Penney's game, genetic drift and gambler's ruin examples
use unbounded properties.

`#tests` turns a model into tests for the code it describes. It lists the runs of a system from
the most likely to the least, with the random decisions behind each one, reports how much of the
probability they cover, and adds the most likely failing runs. For properties that fail by design
some of the time, it sizes a statistical test with a known false-alarm rate. The conformance
sample replays these runs against a real client.

Checking uses every core: parameter assignments, large frontiers and the random choices within a
step are processed in parallel, and the results don't depend on the number of cores.

Checking only tracks what a property can observe. Each query builds just the inputs and
parameters that it or an earlier observation reads, and state variables outside the property's
cone of influence aren't tracked. When a `with prob <=` bound fails, Haze shows a run where the property holds, taken from a parameter value that breaks the bound.

When a result depends on more than six parameter assignments, the output summarizes them and
ranks the parameters by how much each one moves the result.

### Tools

The `haze` command checks models and supports `--fuel`, `--states`, `--version` and JSON
output (`--json`). Prebuilt binaries are available for Linux (x86-64), macOS (Apple silicon) and
Windows (x86-64), with install scripts for each that check downloads against published
checksums and can also build Haze from source. Haze is also available as a Docker image
(`ghcr.io/ritabratamaiti/haze-lang`), as a GitHub Action (`ritabratamaiti/haze-lang@v0.1.0`), and in
GitHub Codespaces. A website with a playground, a tour and the gallery runs Haze in the
browser, compiled to WebAssembly. Haze is released under the Functional Source
License (FSL-1.1-ALv2).
