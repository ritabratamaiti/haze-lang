# How Haze compares

People usually ask how Haze relates to the probabilistic model checkers PRISM and Storm, to Lean,
to probabilistic programming languages, and to testing tools. Haze is version 0.1 and much smaller
than any of them, so the sections below also say where each one is the better choice.

## PRISM and Storm

[PRISM](https://www.prismmodelchecker.org/) and [Storm](https://www.stormchecker.org/) are the
established probabilistic model checkers, and Haze does the same kind of job: you describe a
system as a Markov chain and check temporal properties of it. They are much more capable than
Haze in most respects:

- **Models.** PRISM supports discrete- and continuous-time Markov chains, Markov decision
  processes (which add nondeterministic choices), probabilistic timed automata and partially
  observable models. Storm supports Markov chains, Markov decision processes and Markov automata.
  Haze supports only discrete-time Markov chains: there's no nondeterminism and no continuous
  time.
- **Properties.** Both check rich temporal logics (PCTL, CSL, LTL) with rewards. Haze checks a
  single `after`, `always` or `eventually` per property, with or without a bound, optionally
  conditioned with `given`, plus expected values and expected steps until a property holds. It
  has no `until`, no nested operators and no rewards beyond `#expect`.
- **Scale.** Both have symbolic engines, based on decision diagrams, that handle state spaces far
  larger than Haze's explicit enumeration. Haze keeps at most 2 million configurations per step,
  and the models in its repository have up to about a thousand.
- **Maturity.** Both have been developed and used in research for many years, with many
  published case studies. Haze is new.

If you need any of these, use PRISM or Storm.

Haze differs in a few ways that matter for checking software:

- **Exact by default.** PRISM and Storm compute in floating point by default, with iterative
  methods that stop at a chosen precision. Both have exact modes: Storm can compute with rational
  numbers, and PRISM's exact model checking works through its parametric engine on small models.
  Haze always computes with fractions. For large parts of a problem it uses floating point only to
  find bounds, which it then checks exactly.
- **Rates you only roughly know.** PRISM supports interval Markov chains and MDPs, where a
  transition probability is an interval, and both tools support parametric models, where a
  probability is a symbol and the result is a function of it. Haze's fuzzy parameters take a
  different approach: a parameter has a few candidate values, each with a possibility, and the
  answer is a belief and plausibility pair, with a table of results by value. That's less general
  than a parametric result, but it gives one answer to compare with a requirement, and it says
  which estimate moves the result most.
- **Counterexamples for probabilistic properties.** When a theorem or a probability bound fails,
  Haze shows a run that breaks it, with the parameter values and the state at the step where it
  breaks. PRISM generates counterexample paths for properties without probabilities, such as
  `A [ G "inv" ]`.
- **Tests from the model.** `#tests` lists a model's runs in order of probability as test cases,
  reports how much of the probability they cover, and sizes a statistical test with a known
  false-alarm rate. [Testing real code](../examples/Conformance/README.md) uses these to test a
  Python client against its model.
- **The language.** A Haze step is written like code, with assignments, `if`, `match`, local
  variables, functions and `assert`. PRISM's language, which Storm also reads, describes modules
  as guarded commands, which is more general but further from the code being modeled.

## Lean

Haze is written in [Lean 4](https://lean-lang.org/) and follows Lean's design, with an untrusted
elaborator and a small kernel that checks every declaration again. [Design and
semantics](Design.md#starting-from-lean) explains the correspondence.

A proof in Lean holds for every input and every size: for all `N`, for all message orders. A Haze
theorem holds for the finite model you wrote, such as three replicas, a horizon of six steps, and
the parameter values you listed. In exchange, Haze needs no proofs: it checks the model
automatically and computes probabilities, which are hard to reason about in a proof assistant.

Haze's own trust story is also weaker than Lean's. Some of its foundations, such as the laws of
the grade lattice and of the fuzzy connectives, are proved in Lean, but the checker itself isn't
verified. It's tested against hand-computed results and independent calculations
([Trust and testing](Design.md#trust-and-testing)).

## Probabilistic programming languages

Probabilistic programming languages such as [Stan](https://mc-stan.org/) and
[PyMC](https://www.pymc.io/) are built for statistics: fitting models with continuous parameters
to data, by sampling or approximate inference. Haze has no continuous distributions and doesn't
learn from data sets.

Some probabilistic languages compute exact answers for discrete programs, such as
[Dice](https://github.com/SHoltzen/dice) and [PSI](https://psisolver.org/). Haze's `observe`
gives exact posteriors the same way, but its focus is different: systems that run for many
steps, temporal properties, and requirements that are checked rather than queries that are
answered.

## Testing tools

Property-based testing tools such as Hypothesis and QuickCheck run code on many random inputs,
and simulation estimates probabilities by running a model many times. Both work on real code of
any size, which Haze doesn't. What Haze adds is exhaustiveness on the model: it considers every
run, so it finds a one-in-a-million failure as reliably as a common one, and its probabilities
are exact rather than estimates. A good use of both is to check the design in Haze and test the
implementation against the same model, as [Testing real code](../examples/Conformance/README.md)
does.

## Summary

| | Haze | PRISM, Storm | Lean | Stan, PyMC |
|---|---|---|---|---|
| Answers | Exact probabilities and expectations, with certified bounds for large unbounded problems; counterexamples; generated tests | Probabilities, expectations and rewards for temporal logics | Proofs that hold for every input and size | Posterior distributions |
| Uncertain rates | Fuzzy parameters, giving belief and plausibility | Parametric and interval models | Whatever you formalize | Priors over parameters |
| Arithmetic | Exact fractions | Floating point by default, with exact modes | Exact | Floating point, sampling |
| Models | Discrete-time Markov chains | DTMCs, CTMCs, MDPs, PTAs, POMDPs, Markov automata | Any mathematics | Statistical models, often continuous |
| Scale | Explicit states, up to 2 million configurations per step | Much larger, with symbolic engines | Unbounded, with effort | Large data sets |
| Effort | Write a model; checking is automatic | Write a model; checking is automatic | Write the proofs | Write a model; tune inference |
