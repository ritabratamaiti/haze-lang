# Checking real code against a Haze model

A Haze model is most useful when it describes code that actually runs. This sample shows one
way to keep the two in step, with a common pattern: write a model of the component, prove what it must
guarantee, and then test the real implementation against the model. Haze itself only provides the model checking and its
[JSON output](../../docs/Command-Line.md#json-output); everything else here is ordinary
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

[`payments.hz`](payments/payments.hz) describes a client that sends a charge request and, after a
timeout, tries again, making up to three attempts in all. The server deduplicates requests by idempotency key, so a
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
here. Larger code needs a way to choose which patterns to test and to judge results that are
random. The next section covers both.

## Probability-weighted testing

Coverage usually means how much of the code a test suite runs. A suite can run every line and
still miss the failure that happens most often in production, because it never tried the right
sequence of events. Probability-weighted testing measures a suite by how much of the system's
*probable behavior* it covers instead, and it gives every random test a known false-alarm rate.

`#tests` in the model asks Haze for test cases:

```haze
#tests[6] Client |= always[6] charges <= 1
#tests[3] Client |= after[6] acked
```

Haze lists the runs of the model from the most likely to the least likely, which it can do
exactly, with the random decisions behind each run and the state it ends in. The six most likely
runs of this client cover 99.96% of the probability. When the property can fail, Haze adds the
most likely failing runs as well, however rare they are. Naming each random decision with `let`
(`let request_lost := flip(loss)`) makes the runs readable:

```
run 3 · probability ≈0.018824 · cumulative ≈0.998432 · passes
  step 1: request_lost = false, response_lost = true
  step 3: request_lost = false, response_lost = false
  state: phase = Done, attempts = 2, charges = 1, acked = true, latency = 1080
```

[`test_weighted.py`](payments/test_weighted.py) reads these runs from `haze --json` and replays
each one against the real client, with a network that loses exactly the messages the run says.
The client must end in the state the model predicts.

Some properties fail by design some of the time. A payment gives up when three messages in a row
are lost, so a test that runs the real client against a random network can fail even when the
client is correct. Instead of retrying such a test until it passes, Haze works out its flake
rate and sizes it:

```
statistical test at loss = 0.1: a run of code that matches the model fails this property with
probability 0.006859. Run the real code 10214 times and allow up to 113 failures: code that
matches the model then fails the test with probability ≈8.10684e-7, and code that fails twice as
often is caught with probability ≈0.990011
```

Haze picks the smallest number of runs that keeps false alarms below one in a million and still
catches code that fails twice as often with probability 0.99, and the fewest failures to allow
for that. It uses the possible parameter values under which the property fails most often.

The script runs both kinds of test against the client and four broken versions, and reports the
probability of the behavior on which each broken version was caught:

```
1. Replaying the 9 runs that Haze generated
  the most likely runs cover 0.999569 of the probability
2. Statistical test of the delivery requirement
  10214 payments at loss 1/10: 89 failed, 113 allowed -> pass
3. Mutants
  mutant caught  server without idempotency keys
         by a replayed run of probability 0.0188 (charges 2 (model 1))
  mutant caught  one retry too many (MAX_ATTEMPTS = 4)
         by a replayed run of probability 8e-06 (the client asked the network more often than the model does)
  ...
PASS
```

The client that retries once too often behaves differently only after three lost messages, so
none of the likely runs catch it. The failing runs that `#tests` adds do.

Run it from the repository root after `lake build`:

```sh
python examples/Conformance/payments/test_weighted.py
```

## Using this with your own code

The first step is to make the sources of failure in your code injectable: the network, the
clock, the random number generator. That's good practice anyway, and it's what makes exhaustive
or seeded testing possible. Keep the model focused on the decisions that matter for your
requirements; a model of a retry policy needs to know whether each request got through, not
what was in it. Use a fuzzy parameter for any rate you don't know precisely, so that the
conformance test checks the code at every possible value. And keep the model next to the
code, so that changes to both are reviewed in the same pull request and checked by the same CI.
