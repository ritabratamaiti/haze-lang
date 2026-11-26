<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/logo-dark.svg">
    <img alt="Haze" src="docs/images/logo-light.svg" width="520">
  </picture>
</p>

# Haze: verifying software with uncertain outcomes

[![License: FSL-1.1-ALv2](https://img.shields.io/badge/License-FSL--1.1--ALv2-blue.svg)](LICENSE.md)
[![Lean 4](https://img.shields.io/badge/built%20with-Lean%204-blue.svg)](https://lean-lang.org)
[![Playground](https://img.shields.io/badge/try%20it-in%20your%20browser-0d9488.svg)](https://haze-lang.pages.dev/play/)
[![Open in Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/ritabratamaiti/haze-lang/blob/main/notebooks/try_haze.ipynb)
[![Launch Binder](https://mybinder.org/badge_logo.svg)](https://mybinder.org/v2/gh/ritabratamaiti/haze-lang/main?labpath=notebooks%2Ftry_haze.ipynb)
[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/ritabratamaiti/haze-lang)

Haze is a language for checking what software guarantees when operations can fail. A payment
client can meet its delivery target and still charge twice if a reply gets lost. Write both
requirements in the model: Haze computes the delivery probability and shows the retry that
causes the second charge.

A lost packet is a random event. The packet loss *rate* may be an estimate. Haze keeps those
separate: give the rate several possible values and say how plausible each one is. The checker
reports what happens at each rate and compares your requirement with the resulting belief or
plausibility bound. You don't need a probability distribution over the estimates.

On the `continuous-params` development branch, a fixed rate can also have a whole range of
values. `tri(0.01, 0.02, 0.05)` puts the most support at 2% loss and covers intermediate
rates such as 3.7%. With counts instead, `likelihood(12, 4000)` uses the binomial likelihood
of observing 12 failures in 4,000 trials. [Checking a delivery target](docs/Fuzzy-Parameters.md#checking-a-delivery-target)
shows how to decide a requirement over the range. Build this checkout to run these
declarations; the v0.1.0 release uses listed parameter values.

Haze checks discrete-time models using rational arithmetic; for large components of an
unbounded check it certifies bounds in rational arithmetic. The same model can generate tests
for an implementation. [Model types and limits](docs/Comparison.md#prism-and-storm) and the
[26-property cross-check with PRISM and Storm](docs/Benchmarks.md) give the technical details.
Version 0.1 is experimental; pin the release if your CI depends on a particular syntax.

Haze is written in [Lean 4](https://lean-lang.org/) and borrows its design. Your program is
translated into a small core language, and a separate kernel checks every declaration again
before accepting it. What Haze adds is what that kernel keeps track of: besides the type of
each term, it records whether the term depends on chance, on a rough estimate, or on a
computation that might not finish.

[![Haze in the browser: the chance of a double charge as the loss rate changes, then an idempotency key fixes the bug](docs/images/demo.gif)](https://haze-lang.pages.dev/)

## Example

Take the payment client from above. It retries when a request or its reply is lost, and the
server charges the card every time a request reaches it. It should meet two
requirements: almost every payment goes through, and no customer is ever charged twice.

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

Haze accepts the first requirement and rejects the second. The run it reports is the classic
bug: the first request went through, its reply was lost, and the retry charged the card again.

```
payments_retry.hz:92:1: info: claim delivered
  belief ≈0.998319 · plausibility ≈0.99997 · graded
  bound holds: belief ≥ 0.99
payments_retry.hz:97:1: error: theorem naive_single_charge
  belief ≈0.955681 · plausibility ≈0.986011 · graded
  theorem rejected: belief is ≈0.955681, not 1
  counterexample at step 3 (path mass ≈9.801e-5 (=9801/100000000), degree 0):
    parameters: loss = 0.01
    state: phase = Waiting, attempts = 2, charges = 2
```

Giving each payment an idempotency key fixes this, and with that change Haze proves the theorem
for every loss rate in the model. The full model is in
[`examples/payments_retry.hz`](examples/payments_retry.hz).

## Learn Haze

The best place to start is the tutorial,
[`examples/Tutorial/JobWorker.hz`](examples/Tutorial/JobWorker.hz). It models a background
worker that calls a flaky downstream service, and builds the model up step by step, from a
single random value to a full system with theorems, fuzzy parameters and observations. Its
output is in [`JobWorker.expected`](examples/Tutorial/JobWorker.expected), so you can read the
two side by side. Every construct of the language is described in the
[language reference](docs/Language-Reference.md).

After that, the [`examples`](examples) folder has models of common reliability problems:

| Example | What it checks |
|---|---|
| [`payments_retry.hz`](examples/payments_retry.hz) | Retries after a lost reply charge the customer twice, and idempotency keys prevent it. |
| [`quorum_replication.hz`](examples/quorum_replication.hz) | Reads see the latest write when R + W > N, and can be stale when R = 1. |
| [`circuit_breaker.hz`](examples/circuit_breaker.hz) | A circuit breaker's invariants, how fast it trips, and how much load it sheds when the upstream is flaky. |
| [`canary_rollout.hz`](examples/canary_rollout.hz) | Whether a defective build can reach all traffic during a staged rollout. |
| [`incident_triage.hz`](examples/incident_triage.hz) | The likely root cause of an incident, given which alerts fired. |
| [`probability_classics.hz`](examples/probability_classics.hz) | Textbook problems with known answers, such as the birthday problem, gambler's ruin and the boy-or-girl paradox. |

The models in [`examples/Gallery`](examples/Gallery) also cover probability, engineering and
science. [`scripts/verify_gallery.py`](scripts/verify_gallery.py) checks gallery results against
closed-form answers and independent calculations:

| Example | Field | What it computes |
|---|---|---|
| [`genetics.hz`](examples/Gallery/genetics.hz) | Genetics | How often genetic drift fixes a new allele, Hardy–Weinberg proportions when the allele frequency is only roughly known, and a Mendelian cross. |
| [`epidemic.hz`](examples/Gallery/epidemic.hz) | Epidemiology | How many people in a household catch an infection (the Reed–Frost model), with and without vaccination. |
| [`physics.hz`](examples/Gallery/physics.hz) | Physics | Radioactive decay, diffusion between two chambers, and how often a random walk returns to its start. |
| [`reliability.hz`](examples/Gallery/reliability.hz) | Reliability engineering | A proof that a three-way voter masks any single failure, plus redundant pumps and server availability. |
| [`finance.hz`](examples/Gallery/finance.hz) | Finance | Option prices on a binomial tree, put–call parity, prices when volatility is uncertain, and an insurer's risk of ruin. |
| [`games.hz`](examples/Gallery/games.hz) | Games | The odds in craps (244/495), winning a game of tennis from deuce, and Penney's coin game. |
| [`queueing.hz`](examples/Gallery/queueing.hz) | Networking | How full a network buffer gets and how many packets it drops when the arrival rate is uncertain. |
| [`game_physics.hz`](examples/Gallery/game_physics.hz) | Video games | Objects tunneling through walls, energy drift in physics integrators, and jumps that depend on the frame rate. |
| [`production_test.hz`](examples/Gallery/production_test.hz) | Electronics test | How often a production test with a noisy meter ships out-of-spec parts, why retesting failed parts makes it worse, and which guard band meets a target for every plausible meter error. |
| [`chip_design.hz`](examples/Gallery/chip_design.hz) | Chip design | Why NVIDIA's H100 SXM5 enables only 132 of the 144 SMs on its 814 mm² GH100 die: the die's yield at TSMC's reported defect density, with and without spare SMs. |
| [`security.hz`](examples/Gallery/security.hz) | Security | How often a thief guesses a PIN before a card locks or a phone erases itself, using PIN frequencies from 3.4 million leaked passwords, and why most intrusion-detection alarms are false (Axelsson's base-rate analysis). |

[`examples/Law/sally_clark.hz`](examples/Law/sally_clark.hz) looks at a real court case. In R v
Clark, a mother was convicted of murdering her two sons partly on the strength of a "1 in 73
million" statistic. The model recomputes that figure from the numbers given in court, then
asks the question the jury should have been asked, using the published analysis of the case.

Haze can also generate tests. `#tests` lists the most likely runs of a model as test cases, with
the random decisions behind each one, and reports how much of the probability they cover. For a
property that fails by design some of the time, it sizes a statistical test with a known false-alarm rate, so that a correct implementation fails it less than once in a
million.

Finally, [`examples/Conformance`](examples/Conformance) shows how to use a Haze model as the
specification of real code. One test runs a Python payment client against every pattern of
lost messages and checks that its outcomes match the model's probabilities exactly. Another
replays the runs that `#tests` generates and runs the statistical test Haze sized, and shows
which deliberately broken clients each one catches.

## Install

On Linux (x86-64) and macOS (Apple silicon):

```sh
curl -sSfL https://raw.githubusercontent.com/ritabratamaiti/haze-lang/main/install.sh | sh
```

On Windows, in PowerShell:

```powershell
irm https://raw.githubusercontent.com/ritabratamaiti/haze-lang/main/install.ps1 | iex
```

The [releases page](https://github.com/ritabratamaiti/haze-lang/releases) has the same builds as
archives, each with the examples, so you can run `haze examples/payments_retry.hz` straight
away. Both scripts check each download against the checksums published with the release.

To build Haze from source with Lean's toolchain instead, set
`HAZE_FROM_SOURCE=1` (in PowerShell, `$env:HAZE_FROM_SOURCE = "1"`) before running the script.
It installs [elan](https://github.com/leanprover/elan) if you don't have it, fetches the source
and runs `lake build`; the first build takes a few minutes. Platforms without a prebuilt release
are built from source automatically. This also helps on managed Windows machines that block new
unsigned programs, since a program you build yourself isn't treated as a download.

There are other ways to run Haze:

- **On the website.** The [playground](https://haze-lang.pages.dev/play/) and the
  [tour](https://haze-lang.pages.dev/tour/) run Haze in your browser, compiled to WebAssembly
  from the same Lean code, with nothing to install and no server.
  [`wasm/`](wasm/README.md) explains how that build works.
- **In a notebook.** The *Open in Colab* and *Launch Binder* buttons above open a notebook,
  [`notebooks/try_haze.ipynb`](notebooks/try_haze.ipynb), that installs Haze and walks through a
  few models you can edit and rerun. Both are free; Colab needs a Google account, and Binder needs
  none.
- **In GitHub Codespaces.** The *Open in GitHub Codespaces* button starts an editor with Haze
  installed and the tutorial open.
- **With Docker.** `docker run --rm -v "$PWD:/work" ghcr.io/ritabratamaiti/haze-lang model.hz`
  checks `model.hz` in the current directory.
- **In GitHub Actions.** This step installs Haze and fails the build if any declaration is
  rejected:

  ```yaml
  - uses: ritabratamaiti/haze-lang@v0.1.0
    with:
      files: models/*.hz
  ```

  Without `files`, the step only installs `haze` for later steps. `args` passes options such as
  `--json`, and `version` picks a release.

## Build

You need [elan](https://github.com/leanprover/elan), the Lean toolchain manager. The Lean
version is pinned in [`lean-toolchain`](lean-toolchain), and elan installs it the first time
you build.

```sh
lake build                       # the library, its theorems and the haze command
lake exe haze FILE.hz            # check a model
lake test                        # run the test suite
```

`haze` exits with status 1 if any declaration is rejected and 2 if it can't run, so it can run in
CI. A few options
are worth knowing: `--fuel N` limits how deeply function calls can nest before an outcome counts
as unknown (the default is 1000), `--states N` limits how many states an unbounded property
explores (the default is 100,000), and `--json` prints the results as JSON for other programs.

## Documentation

- [Website](https://haze-lang.pages.dev/), with the playground, a tour and the gallery
- [Installation](docs/Installation.md) and [your first model](docs/Getting-Started.md)
- [Reading results](docs/Reading-Results.md)
- [Coding agents](docs/Agents.md): skills and hooks for Claude Code, Copilot, Codex and Cursor
- [Language reference](docs/Language-Reference.md) and [command line and JSON](docs/Command-Line.md)
- [How Haze compares](docs/Comparison.md) with PRISM, Storm, Lean and probabilistic programming,
  and [checking Haze against PRISM and Storm](docs/Benchmarks.md)
- [FAQ](docs/FAQ.md)

- [Design and semantics](docs/Design.md), including how Haze relates to Lean
- [Releasing](docs/Releasing.md), for maintainers
- [Test suite](tests/README.md)
- [Release notes](RELEASES.md)
- [Contributing](CONTRIBUTING.md), the [code of conduct](CODE_OF_CONDUCT.md) and the [security policy](SECURITY.md)

## License

Haze is available under the [Functional Source License 1.1](LICENSE.md) with Apache 2.0 as the
future license (FSL-1.1-ALv2). You can use, modify and share Haze for any purpose, including
inside a company and in commercial work, except offering it, or a product built on it with the
same functionality, as a competing commercial product or service. Each release becomes
available under the Apache License 2.0 two years after it is published. For a commercial license that covers other uses, email ritabratamaiti@gmail.com.

"Haze" and the Haze logo are trademarks of Ritabrata Maiti; see [TRADEMARKS.md](TRADEMARKS.md).

Copyright 2026 Ritabrata Maiti
