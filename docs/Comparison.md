# How Haze compares

People usually ask how Haze relates to the probabilistic model checkers PRISM and Storm, to Lean,
to probabilistic programming languages, and to testing tools. The sections below describe what
each one does and what Haze adds.

## PRISM and Storm

[PRISM](https://www.prismmodelchecker.org/) and [Storm](https://www.stormchecker.org/) are the
established probabilistic model checkers, and Haze does the same core job: you describe a system
as a Markov chain and check temporal properties of it. On the models they have in common, the
three tools agree: [Checking Haze against PRISM and Storm](Benchmarks.md) compares their answers
on PRISM's example models.

The tools cover different ground:

- **Models.** PRISM and Storm also check continuous-time Markov chains, Markov decision processes,
  and, between them, probabilistic timed automata, partially observable models and Markov
  automata. Haze checks discrete-time Markov chains.
- **Properties.** PRISM and Storm check temporal logics (PCTL, CSL, LTL) with rewards. Haze checks
  `after`, `always` and `eventually`, bounded or unbounded, conditioned with `given`, along with
  expected values, expected steps until a property holds, and full outcome distributions.
- **Scale.** PRISM and Storm have symbolic engines based on decision diagrams. Haze enumerates
  states explicitly, up to 2 million configurations per step.

What Haze adds:

- **Rates you only roughly know.** A Haze parameter can have a possibility for each value: a few
  listed values, a whole range such as `tri(0.01, 0.02, 0.05)`, or a distribution learned from
  counts, such as `likelihood(3, 1000)`. The answer is a belief and plausibility pair that weighs
  each value by its possibility, with results by possibility level. For a range, Haze uses
  parameter lifting, the technique behind Storm's region checks, to get certified bounds at every
  level, so every value in the range is covered. PRISM and Storm support parametric models, where
  the result is a function of a symbolic parameter, and interval models; neither weighs values by
  possibility. The closest work we found is a research version of Storm that approximates
  triangular fuzzy numbers with a genetic search
  ([Socha, 2023](https://purl.utwente.nl/essays/95019)).
- **Exact by default.** PRISM and Storm compute in floating point by default, with iterative
  methods that stop at a chosen precision. Both have exact modes: Storm can compute with rational
  numbers, and PRISM's exact model checking works through its parametric engine on small models.
  Haze always computes with fractions. For large parts of a problem it uses floating point only to
  find bounds, which it then checks exactly.
- **Counterexamples by default.** When any theorem or probability bound fails, Haze shows a run
  that breaks it, with the parameter values and the state at the step where it breaks. PRISM
  generates counterexample paths for properties without probabilities, such as `A [ G "inv" ]`.
  Storm can generate counterexamples for probability bounds on reachability, either as a minimal
  set of model commands or as the most probable paths that exceed the bound, when you ask for one.
- **Tests from the model.** `#tests` lists a model's runs in order of probability as test cases,
  with the random decisions made at each step, reports how much of the probability they cover,
  and sizes a statistical test with a known false-alarm rate. Storm's most-probable-paths
  counterexamples are related, but they aren't aimed at testing an implementation.
  [Testing real code](../examples/Conformance/README.md) uses these to test a Python client
  against its model.
- **The language.** A Haze step is written like code, with assignments, `if`, `match`, local
  variables, functions and `assert`. PRISM's language, which Storm also reads, describes modules
  as guarded commands, a notation closer to state machines than to the code being modeled.

## Lean

Haze is written in [Lean 4](https://lean-lang.org/) and follows Lean's design, with an untrusted
elaborator and a small kernel that checks every declaration again. [Design and
semantics](Design.md#starting-from-lean) explains the correspondence.

A proof in Lean holds for every input and every size: for all `N`, for all message orders. A Haze
theorem holds for the finite model you wrote, such as three replicas, a horizon of six steps, and
the parameter values you gave. In exchange, Haze needs no proofs: it checks the model
automatically and computes probabilities, which are hard to reason about in a proof assistant.

Some of Haze's foundations, such as the laws of the grade lattice and of the fuzzy connectives,
are proved in Lean. The checker is tested against hand-computed results, independent
calculations, and PRISM and Storm, and its numerical bounds are checked in exact arithmetic
([Trust and testing](Design.md#trust-and-testing)).

## Probabilistic programming languages

Probabilistic programming languages such as [Stan](https://mc-stan.org/) and
[PyMC](https://www.pymc.io/) are built for statistics: fitting models with continuous parameters
to data, by sampling or approximate inference. Haze learns a rate from counts with `likelihood`
and keeps it as a possibility distribution, so the answer shows how much depends on the data,
with certified bounds rather than samples.

Some probabilistic languages compute exact answers for discrete programs, such as
[Dice](https://github.com/SHoltzen/dice) and [PSI](https://psisolver.org/). Haze's `observe`
gives exact posteriors the same way, but its focus is different: systems that run for many
steps, temporal properties, and requirements that are checked rather than queries that are
answered.

## Testing tools

Property-based testing tools such as Hypothesis and QuickCheck run code on many random inputs,
and simulation estimates probabilities by running a model many times. Both run real code. Haze
considers every run of the model, so it finds a one-in-a-million failure as reliably as a common
one, and its probabilities are exact rather than estimates. A good use of both is to check the design in Haze and test the
implementation against the same model, as [Testing real code](../examples/Conformance/README.md)
does.

## Summary

| | Haze | PRISM, Storm | Lean | Stan, PyMC |
|---|---|---|---|---|
| Answers | Exact probabilities and expectations, with certified bounds for large unbounded problems; counterexamples; generated tests | Probabilities, expectations and rewards for temporal logics | Proofs that hold for every input and size | Posterior distributions |
| Uncertain rates | Fuzzy parameters (listed values, ranges, or learned from counts), giving certified belief and plausibility | Parametric and interval models | Whatever you formalize | Priors over parameters |
| Arithmetic | Exact fractions | Floating point by default, with exact modes | Exact | Floating point, sampling |
| Models | Discrete-time Markov chains | DTMCs, CTMCs, MDPs, PTAs, POMDPs, Markov automata | Any mathematics | Statistical models, often continuous |
| Scale | Explicit states, up to 2 million configurations per step | Symbolic engines for very large state spaces | Unbounded, with effort | Large data sets |
| Effort | Write a model; checking is automatic | Write a model; checking is automatic | Write the proofs | Write a model; tune inference |
