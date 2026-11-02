# Sample: Checking an Implementation Against a Haze Model

This sample shows one way to use Haze alongside real code, following a pattern that is common
with Lean in industry: write a model, prove its properties, and then test the implementation
against the model. It is an example, not part of Haze: the only Haze feature it relies on is the
JSON output of `haze` (see the [language reference](../../docs/Language-Reference.md#json-output)).

The [`payments`](payments) folder contains:

- [`payments.hz`](payments/payments.hz): the Haze model of a payment client, which serves as its
  specification;
- [`payments_client.py`](payments/payments_client.py): the implementation, in Python;
- [`test_conformance.py`](payments/test_conformance.py): a test that checks the implementation
  against the model.

Run the test from the repository root after `lake build`:

```sh
python examples/Conformance/payments/test_conformance.py
```

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

## The Model and Its Requirements

[`payments.hz`](payments/payments.hz) models a client that sends a charge request, retries
after a timeout up to three times, and talks to a server that deduplicates requests by
idempotency key. The loss rate of the network is a fuzzy parameter:

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

## The Conformance Test

[`test_conformance.py`](payments/test_conformance.py) checks the implementation as follows:

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

## Applying the Pattern to Your Own Code

* Make the sources of randomness and failure in the implementation injectable: the network,
  the clock, the random number generator. This is good practice anyway, and it makes
  exhaustive or seeded testing possible.
* Model only the decisions that matter for the requirements. A model of a retry policy needs
  the outcome of each request, not the contents of the messages.
* Use a fuzzy parameter for every rate that isn't known precisely. The conformance test then
  checks the implementation at each admissible value.
* Keep the model next to the code, review changes to both in the same pull request, and run
  `haze` and the conformance test in continuous integration.
