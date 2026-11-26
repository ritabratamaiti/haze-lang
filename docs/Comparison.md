# How Haze compares

A client sends a request up to three times. Its delivery target is 99.99%, but the team has
an estimate of the packet loss rate, not a known constant. In [the runnable Haze model](https://haze-lang.pages.dev/play/?example=rough-numbers),
each send can fail independently. The loss rate is fixed across all three sends. At 2% loss the
delivery probability is 0.999992; at 5% it is 0.999875. That difference changes whether the
target holds.

Haze keeps the uncertainty about the rate separate from the randomness of each send. You list
the candidate rates and how plausible each one is. Haze checks the requirement against the
resulting *belief* or *plausibility* bound and reports the results by rate. In this example the
lower bound is about 0.999759, below the target. The output also shows the three lost sends at
5% loss. That run explains how delivery can fail; the bound comes from the full model.

On the `continuous-params` development branch you can specify **a range instead of a list**.
For example, `tri(0.01, 0.02, 0.05)` covers every loss rate between 1% and 5%, with the
most support at 2%. For three independent sends, the delivery probability at a given rate
`p` is `1 - p³`. Haze bounds belief over the whole triangle. At 10 possibility levels the
lower bound is about 0.999943; at 50 it is about 0.999948. Only the latter establishes a
belief target of 0.999945. The [worked example](Fuzzy-Parameters.md#checking-a-delivery-target)
can be run with this branch. The released playground example above uses listed rates.

## PRISM and Storm

Haze, [PRISM](https://www.prismmodelchecker.org/) and [Storm](https://www.stormchecker.org/)
all check probabilities on discrete-time Markov chains. We cross-checked 26 properties on
PRISM's die, ring and leader-election examples. Haze returned the exact reference fraction in
21 cases and a certified interval containing it in the other five. The
[results and reproduction commands](Benchmarks.md) identify the model, property and engine
for each comparison.

For unknown rates, [PRISM's parametric checks](https://www.prismmodelchecker.org/manual/RunningPRISM/ParametricModelChecking/)
can return a rational function of the rate, and its [interval models](https://www.prismmodelchecker.org/manual/ModelTypes/UncertainModels/)
specify ranges for transition probabilities. [Storm](https://www.stormchecker.org/documentation/usage/running-storm-on-parametric-models.html)
can compute a solution function or verify a region of parameter values. In Haze, the input
is a [fuzzy parameter](Fuzzy-Parameters.md): the author specifies how much support each
candidate rate has. A possibility of 0.5 does not mean half the requests use that rate.
The same rate applies to every attempt. For a continuous range this branch checks bounds
over each possibility cut and combines the results, as described in
[Design and semantics](Design.md#continuous-parameters). A related experiment in Storm used a
genetic algorithm for triangular fuzzy transition probabilities (Konrad Socha,
[*Fuzzy Markov Chains*](https://purl.utwente.nl/essays/95019), 2023).

| Feature | Haze | PRISM and Storm |
|---|---|---|
| Model | Discrete-time steps written with assignments, conditionals and assertions. Each parameter assignment defines a Markov chain. The language has no nondeterministic scheduler or continuous-time transitions. | Both support discrete- and continuous-time Markov chains and Markov decision processes. [PRISM](https://www.prismmodelchecker.org/manual/) also supports probabilistic timed automata and partially observable models; [Storm](https://www.stormchecker.org/documentation/background/models.html) also supports Markov automata. |
| Property | A state property or one temporal operator: `after[k]`, `always` or `eventually`. The latter two can be bounded or unbounded. `given` conditions a state or `after[k]` property. `#expect` includes expected steps to a condition. | Temporal logics including PCTL, CSL and LTL, and reward queries. The available properties depend on the model type and engine. |
| State space | Explicit configurations, after merging equal states and dropping variables irrelevant to the property. | Both have explicit and symbolic engines. A symbolic engine can represent sets of states and transitions with a decision diagram. |
| Arithmetic | Rational probabilities at fixed rates, with certified bounds for large components of unbounded checks. For continuous fuzzy rates the checker reports enclosures for belief and plausibility. | Numerical and exact modes. The cross-check records both the default and exact-engine results. |

Haze's [language reference](Language-Reference.md#limits) sets the limit at 2 million distinct
configurations per step for bounded checks. Unbounded checks explore up to 100,000 states by
default; `explore` sets the budget and unexplored behavior counts as unknown. Temporal
operators do not nest. The language has no general `until` operator or separate reward
structure.

Haze can carry a check into an implementation test. On a bounded system property, `#tests`
emits the random decisions along runs in probability order, their cumulative probability and
failing examples. With fuzzy rates it generates runs at the most possible parameter values.
The [payment client test](../examples/Conformance/README.md) replays those
decisions against a Python implementation. A run with a lost reply distinguishes the client
that deduplicates a payment from one that charges twice.

## Lean

In Lean the scope of a proof comes from its statement: a theorem can quantify over the replica
count `N`. In Haze you specify a replica count and a property, and the checker computes the
result without a proof script. The number of replicas and the length of a run are separate:
`always[6]` checks through step six; `always` checks the same model with no time horizon.
Neither declaration changes a three-replica model into a proof about all `N`.

Haze is written in [Lean 4](https://lean-lang.org/). Its kernel rechecks the types and grades
assigned by the elaborator. Lean proofs cover the grade lattice and laws of the fuzzy
connectives; the checker as a whole is not formally verified. [Trust and testing](Design.md#trust-and-testing)
describes the proofs, numerical certificates and independent checks separately.

## Probabilistic programming languages

[Stan](https://mc-stan.org/) and [PyMC](https://www.pymc.io/) fit statistical models to data
and infer distributions over parameters. [Dice](https://github.com/SHoltzen/dice) and
[PSI](https://psisolver.org/) also support exact inference for discrete programs. Haze's
`observe` computes conditional distributions for discrete inputs. Use an `input` if a rate
is drawn from a distribution; use a `param` if the rate is fixed but its value is uncertain.
The same Haze file can state a requirement about what happens after a sequence of steps.
The released language uses discrete random distributions and explicitly listed parameter
values. On this branch, `likelihood(k, n)` converts binomial counts into a *possibility*
distribution for one fixed rate. The likelihood is normalized to a maximum of one, not to
unit area; it is not a Bayesian posterior.

## Testing tools

Hypothesis and QuickCheck exercise an implementation with generated inputs. Simulation
estimates a probability from sampled runs. Haze computes probability from the transitions
in the model, so a rare branch contributes its weight without having to turn up in a sample.
The result describes the model; replay against the implementation checks whether the code
behaves as specified. In [Found with Haze](../examples/Found/README.md), each linked report
pairs the model with a reproduction against the library.

## Summary

For the delivery question, change the loss estimates in the [playground](https://haze-lang.pages.dev/play/?example=rough-numbers)
and rerun the claim. For a requirement such as `charges <= 1`, the
[conformance example](../examples/Conformance/README.md) follows the check through to a test
you can run on the client.
