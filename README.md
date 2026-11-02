# Haze: Verifying Software with Uncertain Outcomes

[![License: PolyForm Noncommercial 1.0.0](https://img.shields.io/badge/License-PolyForm%20Noncommercial%201.0.0-blue.svg)](LICENSE.md)
[![Lean 4](https://img.shields.io/badge/built%20with-Lean%204-blue.svg)](https://lean-lang.org)

Haze is a language for (1) modeling software systems whose behavior depends on chance and
on quantities that are only vaguely known, (2) stating their properties, and (3) checking
those properties exactly.

A network drops packets, an upstream service fails and a build might contain a defect. Haze
treats each of these as part of the model. Random events have exact probabilities. Vague
knowledge, such as "packet loss is around 2%, possibly worse", is a _fuzzy parameter_.
Instead of answering true or false, Haze reports how strongly the evidence supports each
property as a [belief, plausibility] interval, and it gives a counterexample when a
theorem fails.

Haze is implemented in [Lean 4](https://lean-lang.org/) and follows Lean's architecture: a
parser, an elaborator that isn't trusted, and a small kernel that checks every declaration
before it is accepted. The kernel is new. Its typing judgement records which kinds of
uncertainty each term carries, and stochastic conditionals, random choice and system state
are part of its core language.

## Example

The following model describes a payment client that retries when a request or its response
is lost. The server charges the card each time it receives the request:

```haze
param loss : Num ~= {0.01: 0.6, 0.02: 1, 0.05: 0.5, 0.1: 0.2}

system Naive {
  var phase : Phase := Sending
  var charges : Num := 0
  ...
}

claim delivered : Naive |= eventually[6] phase == Done with prob >= 0.99
theorem naive_single_charge : Naive |= always[6] charges <= 1
```

Haze accepts the claim and rejects the theorem, showing a run in which the customer is
charged twice:

```
payments_retry.hz:85:1: info: claim delivered
  belief ≈0.998319 · plausibility ≈0.99997 — graded
  bound holds: belief ≥ 0.99
payments_retry.hz:88:1: error: theorem naive_single_charge
  belief ≈0.955681 · plausibility ≈0.986011 — graded
  theorem rejected: belief is ≈0.955681, not 1
  counterexample at step 3 (path mass ≈0.000098, degree 0):
    parameters: loss = 0.01
    state: phase = Waiting, attempts = 2, charges = 2, acked = false, latency = 1000
```

With an idempotency key, the same property is accepted as a theorem for every possible
loss rate. The complete model is [`examples/payments_retry.hz`](examples/payments_retry.hz).

## Using Haze with Real Code

A Haze model can serve as the specification of an implementation. The
[`conformance/payments`](conformance/payments) folder contains a Python payment client, its
Haze model, and a test that checks that the client's outcome distributions are exactly those
of the model, for every admissible loss rate. Continuous integration runs this test on every
push. [`docs/Workflow.md`](docs/Workflow.md) describes the workflow.

## Learn Haze

The [`examples/Tutorial`](examples/Tutorial) folder contains a commented walkthrough:

- [`examples/Tutorial/JobWorker.hz`](examples/Tutorial/JobWorker.hz) models a background
  job worker that retries calls to a downstream service. It introduces random values,
  functions, fuzzy parameters, transition systems, theorems and claims, fuzzy requirements,
  and observations. Its output is in [`JobWorker.expected`](examples/Tutorial/JobWorker.expected).

The [`examples`](examples) folder contains models of common reliability patterns:

| Example | What it checks |
|---|---|
| [`payments_retry.hz`](examples/payments_retry.hz) | Retries after lost responses charge customers twice; idempotency keys prevent it. |
| [`quorum_replication.hz`](examples/quorum_replication.hz) | Read-your-writes holds when R + W > N, and stale reads occur when R = 1. |
| [`circuit_breaker.hz`](examples/circuit_breaker.hz) | Circuit-breaker invariants, trip time and load shedding with a flaky upstream. |
| [`canary_rollout.hz`](examples/canary_rollout.hz) | Whether a defective build reaches all traffic during a staged rollout. |
| [`incident_triage.hz`](examples/incident_triage.hz) | The probable root cause of an incident, given the alerts that fired. |
| [`probability_classics.hz`](examples/probability_classics.hz) | Classic problems with known answers: dice, the birthday problem, Pólya's urn, the coupon collector, gambler's ruin and the boy–girl paradox. |

The [`examples/Gallery`](examples/Gallery) folder contains models from other fields. Each
answer agrees with a closed-form result or an independent exact calculation:

| Example | Field | What it computes |
|---|---|---|
| [`genetics.hz`](examples/Gallery/genetics.hz) | Genetics | Fixation by genetic drift, Hardy–Weinberg proportions with a vague allele frequency, a Mendelian cross. |
| [`epidemic.hz`](examples/Gallery/epidemic.hz) | Epidemiology | The final size of a household outbreak (Reed–Frost) with a vague transmission probability, with and without vaccination. |
| [`physics.hz`](examples/Gallery/physics.hz) | Physics | Radioactive decay, diffusion in the Ehrenfest model and the return of a random walk. |
| [`reliability.hz`](examples/Gallery/reliability.hz) | Reliability engineering | Triple modular redundancy (a theorem that one failure is masked), series–parallel systems and server availability. |
| [`finance.hz`](examples/Gallery/finance.hz) | Finance | Binomial option prices, put–call parity, prices under vague volatility and an insurer's risk of ruin. |
| [`games.hz`](examples/Gallery/games.hz) | Games | Craps (244/495), a game of tennis with deuce and Penney's game. |
| [`queueing.hz`](examples/Gallery/queueing.hz) | Networking | Buffer occupancy and packet drops under a vague arrival rate. |
| [`game_physics.hz`](examples/Gallery/game_physics.hz) | Video games | Tunneling through walls, energy drift of integrators, bouncing, frame-rate dependent jumps and a jetpack in gusty wind. |

A description of every construct of the language is in
[`docs/Language-Reference.md`](docs/Language-Reference.md).

## Build

Haze requires [elan](https://github.com/leanprover/elan), the Lean toolchain manager. The
Lean version is pinned in [`lean-toolchain`](lean-toolchain), and elan installs it
automatically.

* To build the library, its theorems and the `haze` command, run `lake build`.
* To check a model, run `lake exe haze FILE.hz`. The command exits with status 1 if any
  declaration is rejected.
* To change the bound on nested function calls, pass `--fuel N` (the default is 1000).
* To print results as JSON for other programs, pass `--json`.
* To run all tests, run `lake test`.

## Documentation

- [Language Reference](docs/Language-Reference.md)
- [Design and Semantics](docs/Design.md), including how Haze relates to Lean's implementation
- [Using Haze in a Development Workflow](docs/Workflow.md): checking an implementation against
  its Haze model in continuous integration
- [Test Suite](tests/README.md)
- [Release Notes](RELEASES.md)
- [Contribution Guidelines](CONTRIBUTING.md)

## License

Haze is available under the [PolyForm Noncommercial License 1.0.0](LICENSE.md). You may use
it for personal, research, educational and other non-commercial purposes. For commercial
use, please contact the author.

Required Notice: Copyright (c) 2026 Ritabrata Maiti
