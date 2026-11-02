# Using Haze in a Development Workflow

This guide describes how to use Haze alongside an implementation, following the pattern that
is common with Lean in industry: write a model, prove its properties, and then test the
implementation against the model. It uses the payment client in
[`conformance/payments`](../conformance/payments) as a running example.

## The Pattern

1. **Write the model.** A Haze file describes the component: its state, how it reacts to
   random events, and which quantities are only known vaguely. The model is short, so it can
   be reviewed like a design document.
2. **State the requirements.** Safety requirements are theorems, and service-level
   requirements are claims with probability bounds. Haze proves the theorems or gives a
   counterexample, and computes exact probabilities for the claims.
3. **Check the model in continuous integration.** `haze` exits with status 1 if any theorem or
   bound fails, so a change to the model that breaks a requirement fails the build.
4. **Test the implementation against the model.** A conformance test runs the real
   implementation, compares its behavior with the model, and fails if they differ.
5. **Change both together.** When the design changes, change the model first, let Haze check
   the requirements, and then change the implementation until the conformance test passes.

The model is the specification, and the conformance test connects it to the code. Neither one
alone is enough: the model can be proved correct but may not describe the code, and the code
can be tested but random testing rarely finds the rare paths that the model checker
enumerates.

## Step 1 and 2: The Model and Its Requirements

[`payments.hz`](../conformance/payments/payments.hz) models a client that sends a charge
request, retries after a timeout up to three times, and talks to a server that deduplicates
requests by idempotency key. The loss rate of the network is a fuzzy parameter:

```haze
param loss : Num ~= {0.01: 0.6, 0.02: 1, 0.05: 0.5, 0.1: 0.2}

theorem single_charge : Client |= always[6] charges <= 1
theorem ack_means_charged : Client |= always[6] (acked implies charges == 1)
claim delivered : Client |= after[6] acked with prob >= 0.99

#eval Client |= after[6] phase
#eval Client |= after[6] latency
```

The `#eval` commands compute the exact distributions of the outcomes that the implementation
must reproduce.

## Step 3: Machine-Readable Results

With `--json`, `haze` prints one JSON record per message instead of text:

```sh
lake exe haze --json conformance/payments/payments.hz
```

Each record has the fields `file`, `line`, `column`, `severity` and `message`, the text that
`haze` would otherwise print. Records for results have more fields:

| `kind` | Fields |
|---|---|
| `theorem`, `claim` | `name`, `accepted`, `grade`, `belief`, `plausibility`, `branches`, `counterexample` |
| `prob` | `query`, `belief`, `plausibility`, `branches` |
| `expect` | `query`, `lower`, `upper`, `branches`, each with an `expectation` |
| `eval` | `query`, `branches`, each with a `distribution` of `value` and `probability` pairs |
| `check` | `query`, `type`, `grade` |
| `observe` | `query`, `evidence`, the probability of the evidence for each parameter assignment |

`branches` lists the result for each assignment of the fuzzy parameters, with its
`parameters` and `possibility`. A `counterexample` has the `step`, the `parameters`, the
`inputs` and the `state` at which a property fails.

Numbers are exact. Probabilities and numeric values are strings such as `"2/3"`, which
Python's `fractions.Fraction` and similar libraries read directly. Booleans are JSON Booleans,
and enumeration values are the names of their constructors. An unknown outcome, from a
computation that ran out of fuel, has the value `null`.

## Step 4: The Conformance Test

[`test_conformance.py`](../conformance/payments/test_conformance.py) checks the Python
implementation, [`payments_client.py`](../conformance/payments/payments_client.py), against
the model:

1. It runs `haze --json` on the model and stops if any theorem or claim is rejected.
2. The implementation receives its network as a parameter, so the test can decide which
   messages are lost. The test runs the implementation once for every possible pattern of lost
   messages. Each pattern has an exact probability for a given loss rate, so the test obtains
   the exact distribution of the implementation's outcomes.
3. It compares these distributions with the model's, for every loss rate in the model, as
   exact fractions. It also checks the theorems on every run.
4. It runs the same comparison on deliberately broken versions of the implementation, called
   mutants, and requires each one to be caught. This shows that the test is strong enough to
   detect real bugs.

The output looks like this:

```
2. Comparing the implementation with the model, exactly, for every loss rate
  loss 1/100  P(Done) = 999992119401/1000000000000  P(2+ charges) = 0  E[latency] = 100.3033 ms
  ...
  implementation CONFORMS to payments.hz
3. Checking that the test catches bugs
  mutant caught   one retry too many (MAX_ATTEMPTS = 4)
  mutant caught   timeout of 900 ms instead of 1000 ms
  mutant caught   server without idempotency keys
PASS
```

Exhaustive comparison is possible when every run of the implementation makes a small number of
random decisions, as here (at most six). For larger implementations, run the implementation
many times with real randomness instead, and compare the observed frequencies with the model's
probabilities using a statistical test. The model's exact probabilities make such tests
precise, because only the sampling error of the implementation remains.

## Step 5: Continuous Integration

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs on every push and pull request.
It builds Haze, checks the theorems about its kernel, runs the golden tests, checks the
gallery against independent calculations, and runs the conformance test. A change to either
the model or the implementation that makes them disagree fails the build.

## Applying the Pattern to Your Own Code

* Make the sources of randomness and failure in the implementation injectable: the network,
  the clock, the random number generator. This is good practice anyway, and it makes
  exhaustive or seeded testing possible.
* Model only the decisions that matter for the requirements. A model of a retry policy needs
  the outcome of each request, not the contents of the messages.
* Use a fuzzy parameter for every rate that isn't known precisely. The conformance test then
  checks the implementation at each admissible value.
* Keep the model next to the code, and review changes to both in the same pull request.
