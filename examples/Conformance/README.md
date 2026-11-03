# Checking Real Code Against a Haze Model

A Haze model is most useful when it describes code that actually runs. This sample shows one
way to keep the two in step, using a pattern that teams working with Lean use in industry:
write a model of the component, prove what it must guarantee, and then test the real
implementation against the model. Haze itself only provides the model checking and its
[JSON output](../../docs/Language-Reference.md#json-output); everything else here is ordinary
Python.

The [`payments`](payments) folder holds three files: the model,
[`payments.hz`](payments/payments.hz), which serves as the specification; the implementation, a
small Python payment client in [`payments_client.py`](payments/payments_client.py); and
[`test_conformance.py`](payments/test_conformance.py), which checks one against the other. To run
the test, build Haze and run it from the repository root:

```sh
lake build
python examples/Conformance/payments/test_conformance.py
```

## The idea

You start by writing a model of the component: its state, how it reacts to random events such
as lost messages, and which rates you only know roughly. A model like this is short enough to
review the way you'd review a design document.

Next you write down what the component must guarantee. Safety requirements, such as "never
charge a customer twice", become theorems, and service levels, such as "at least 99% of
payments go through", become claims with probability bounds. Haze either proves each theorem or
shows a run that breaks it, and computes the exact probability behind each claim. Since `haze`
exits with an error when a requirement fails, you can run it in CI, and a change to the model
that breaks a guarantee will fail the build.

The model only helps if it matches the code, which is what the conformance test checks. It runs
the real implementation, compares its behavior with the model, and fails if the two disagree.
When the design changes, you change the model first, let Haze check the requirements, and then
change the code until the conformance test passes again.

You need both halves. A model can be proved correct and still not describe the code, and code
can pass many tests and still fail on a rare path that only an exhaustive check would reach.

## The model

[`payments.hz`](payments/payments.hz) describes a client that sends a charge request and, after
a timeout, retries up to three times. The server deduplicates requests by idempotency key, so a
retry never charges the card again. Each request and each reply can be lost, and the loss rate
is only known roughly, so it's a fuzzy parameter:

```haze
param loss : Num ~= {0.01: 0.6, 0.02: 1, 0.05: 0.5, 0.1: 0.2}

theorem single_charge : Client |= always[6] charges <= 1
theorem ack_means_charged : Client |= always[6] (acked implies charges == 1)
claim delivered : Client |= after[6] acked with prob >= 0.99

#eval Client |= after[6] phase
#eval Client |= after[6] latency
```

The `#eval` lines ask Haze for the exact distribution of each outcome, which is what the
implementation will be compared against.

## The conformance test

The test first runs `haze --json` on the model and stops if any theorem or claim is rejected,
since there's no point testing code against a specification that is itself wrong.

Then it runs the implementation. The client takes its network as a parameter, so the test can
decide exactly which messages get lost. It runs the client once for every possible pattern of
lost messages; a run makes at most six such decisions, so there are only fifteen patterns.
Because each pattern has an exact probability for a given loss rate, adding them up gives the
exact distribution of the client's outcomes. The test compares these distributions with the
model's, as exact fractions, for every loss rate in the model, and it checks the theorems on
every run as well.

Finally, it makes sure the comparison is sharp enough to matter. It repeats the check on three
deliberately broken versions of the client (one that retries once too often, one with the wrong
timeout, and one whose server ignores idempotency keys) and requires each of them to fail. The
output looks like this:

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

Trying every pattern only works when each run makes a handful of random decisions, as it does
here. For larger code, run the implementation many times with real randomness and compare the
observed frequencies with the model's probabilities using a statistical test. Because the
model's numbers are exact, the only uncertainty left is the sampling error on the
implementation's side.

## Using this with your own code

The first step is to make the sources of failure in your code injectable: the network, the
clock, the random number generator. That's good practice anyway, and it's what makes exhaustive
or seeded testing possible. Keep the model focused on the decisions that matter for your
requirements; a model of a retry policy needs to know whether each request got through, not
what was in it. Use a fuzzy parameter for any rate you don't know precisely, so that the
conformance test checks the code at every plausible value. And keep the model next to the
code, so that changes to both are reviewed in the same pull request and checked by the same CI.
