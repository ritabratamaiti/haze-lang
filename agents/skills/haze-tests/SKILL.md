---
name: haze-tests
description: Turn a Haze model into tests for the real code. Use it when the user wants tests for retry, failover or other failure-handling code that a Haze model describes, or wants to check that the implementation behaves like the model.
haze_version: {{HAZE_VERSION}}
---

# Tests from a Haze model

`#tests` lists the runs of a system in order of probability, with the random decisions made at
each step. Each run is a test: make the same decisions happen in the real code, then check that
it ends in the same state and that the property holds. A statistical test at the end checks
behavior that fails by design some of the time.

## Generate the runs

Add a query to the model (or a copy of it) and run it with `--json`:

```haze
#tests[20] Client(5, true) |= always[12] charges <= 1
```

The property needs a bounded modality (`after[k]`, `always[k]` or `eventually[k]`) and can't
use `given`. Range parameters use their most possible value.

The JSON record has `kind: "tests"`, and:

- `runs`: in order of probability. Each has `probability`, `suite` (true for the first `n`),
  `passes`, `inputs`, `initial` (the starting state) and `steps`. Each step has `step`,
  `choices` (each with `what`, the name of the decision, and `value`) and `state`.
- `covered`: the share of the probability the suite covers.
- `failure_probability`: how often the property fails in the model.
- `statistical`: `runs`, `allowed_failures`, `false_alarm` and `power`, or null.

## Write the tests

1. **Find where the code makes each decision.** Every `choices[].what` names a random event in
   the model, such as `request_lost` or `reply_lost`. Find the place in the code where that
   happens (a network call, a timeout, a crash) and make it controllable from a test: a fake
   client, an injected clock, a fault-injection hook. Prefer the seams the project's tests
   already use.
2. **Write one test per run in the suite.** Replay the choices in step order, run the code, and
   assert the final state (the `state` of the last step) and the property. Name each test after
   the decisions it makes, and put the run's probability in a comment so readers know how common
   the case is.
3. **Include the failing runs Haze lists after the suite.** They are the most likely ways the
   property fails; if the design is meant to prevent them, they are the most valuable tests.
4. **Add the statistical test** when `statistical` isn't null: run the real code with its
   real randomness `runs` times, and fail if more than `allowed_failures` runs break the
   property. Code that matches the model fails this test only with probability `false_alarm`.
5. **Link the tests to the model** with a `haze: models/<name>.hz` comment, so a change to
   either side leads someone to check the other.

When the model changes, regenerate the runs and update the tests in the same change.

A complete example, with a Python client tested against its model, is at
https://github.com/ritabratamaiti/haze-lang/tree/main/examples/Conformance.

## Hard rules

- Don't change the model to fit what the code does. If the code and the model disagree, report
  the run and let the user decide which one is wrong.
- Don't drop a failing run from the tests because the code fails it. That failure is the
  finding.
