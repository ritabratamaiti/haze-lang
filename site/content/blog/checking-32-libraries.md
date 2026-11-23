---
title: Checking 32 resilience libraries against their own docs
date: 2026-11-23
order: 0
author: Ritabrata Maiti
summary: I took the timing, limit and rate promises that 32 open-source libraries make in their docs, modelled the risky ones in Haze and tested every violation on the libraries' latest releases. Most promises held. Seven, in six libraries, didn't.
---
# Checking 32 resilience libraries against their own docs

Retry loops, circuit breakers, rate limiters and samplers mostly sit idle. They matter on the bad
day, when a dependency is failing and everything leans on them doing exactly what their docs say.
And their docs make precise promises: give up after `maxRetryTime`, let one trial call through,
keep 10% of traces, keep false positives under 0.01%. Each of those is a statement about every
possible ordering of events, or about a probability, which a handful of unit tests can't settle.

[Haze](https://github.com/ritabratamaiti/haze-lang) is built for statements like that. You
describe the code's random choices and the orders its events can happen in, and Haze checks a
property against all of them, with probabilities computed exactly. I used it on 32 open-source
libraries.

## How I went about it

For each library I:

1. collected the promises its README and API docs make about time, concurrency, limits or rates;
2. read the code behind each promise and wrote a small Haze model of it, with the promise as a
   theorem or claim;
3. when Haze found a violation, wrote a program that uses the latest release of the library to
   produce the same sequence of events;
4. had the finding reviewed by a separate pass that tried to show it wasn't a bug, by going
   through the project's docs, tests, changelog and old issues, comparing the model with the code
   line by line, rerunning everything on a clean install and checking every figure;
5. filed an issue with the reproduction, the model and a proposed fix.

The review in step 4 didn't overturn any finding, but it was far from a formality. It corrected
figures in most of the reports, removed a suggested fix for resilience4j that wouldn't have
worked, narrowed one failsafe-go claim to the part that isn't debatable, and found a second bug
path in pybreaker.

## Where docs and code disagree

| library | documented | observed | issue |
|---|---|---|---|
| [bloom-filters](https://github.com/Callidon/bloom-filters) (npm) | `PartitionedBloomFilter.create(n, p)` gives false positive rate `p` | can't go below about `0.5 / n`: asking for 1e-4 with 1,000 items gives 6.4e-4 | [#133](https://github.com/Callidon/bloom-filters/issues/133) |
| [failsafe-go](https://github.com/failsafe-go/failsafe-go) | half-open allows a configured number of trials, and they decide | older calls return permits they didn't take and count toward the decision | [#148](https://github.com/failsafe-go/failsafe-go/issues/148) |
| [resilience4j](https://github.com/resilience4j/resilience4j) | half-open permits `permittedNumberOfCallsInHalfOpenState` calls | an ignored exception from an older call adds a permit | [#2602](https://github.com/resilience4j/resilience4j/issues/2602) |
| [pybreaker](https://github.com/danielfm/pybreaker) | half-open lets the next call through, and a failed trial keeps it open | with `calling()`, several trials run, and a late success closes it after a failure | [#113](https://github.com/danielfm/pybreaker/issues/113) |
| [retry](https://github.com/tim-kos/node-retry) (npm) | the operation runs for at most `maxRetryTime` | the last wait isn't shortened, so an attempt can start well after the limit | [#102](https://github.com/tim-kos/node-retry/issues/102) |
| retry (npm) | with `randomize`, retry *i* waits `random * minTimeout * factor^i` | the waits are sorted, so with `factor: 1` the first is under 1.1s 65% of the time instead of 10% | [#103](https://github.com/tim-kos/node-retry/issues/103) |
| [go-retry](https://github.com/sethvargo/go-retry) | `NewFibonacci` waits 1, 1, 2, 3, so 4 retries take at most 7s | it waits 1, 2, 3, 5, so they take 11s | [#54](https://github.com/sethvargo/go-retry/issues/54) |

None of these crashes anything. Each is a gap between what the docs say and what the code does, in
places where people size timeouts, budgets and capacity from the docs. For go-retry, and for the
`randomize` case in retry, the right fix may be in the docs rather than the code, and the issues
say so.

Two of them have longer write-ups:
[A Bloom filter that can't reach the error rate you ask for](https://haze-lang.pages.dev/blog/bloom-filter-error-rate-floor/)
and [Three circuit breakers, one bug](https://haze-lang.pages.dev/blog/three-circuit-breakers-one-bug/).

## What held up

Most of what I checked was correct, and that's as useful to know:

- **Trace sampling.** The ratio-based samplers in OpenTelemetry's Python, Go, JavaScript, Java,
  .NET, Rust, Ruby, C++ and PHP SDKs, and the collector's probabilistic sampler, keep the fraction
  they're configured for, apart from tiny rounding effects. Java takes `Math.abs` of a signed 64-bit
  value, which usually signals a bug, but here the count comes out exact.
- **Retry and backoff.** tenacity, urllib3, p-retry, cenkalti/backoff and avast/retry-go keep
  their waits inside the documented bounds and count attempts as documented. Where one can run past
  a deadline, its docs say so.
- **Load balancing.** grpc-go's weighted round robin, ring hash, least-request and random
  subsetting pick in the documented proportions, and mroth/weightedrand picks exactly.
- **Retry quotas.** The AWS SDK for Go v2 spends and refunds retry tokens as documented, and its
  adaptive rate limiting follows the reference implementation in botocore.
- **gobreaker** counts consecutive failures correctly in its rolling window, and it already tags
  each call with a generation number, which is exactly what the other three breakers are missing.

A few more findings aren't in this list yet. Some overlap reports that already exist, and one
project asks for reports written entirely by hand, so those are still being written up.

## A bug in Haze

Haze had one too. A property that read only some of a model's variables could fail with "expected
a number, got bool false". Haze leaves out variables that can't affect the property, but it still
evaluated conditions that read them. That's fixed in
[4953781](https://github.com/ritabratamaiti/haze-lang/commit/4953781) with a regression test.

## Running the models

The models are in [`examples/Found`](https://github.com/ritabratamaiti/haze-lang/tree/main/examples/Found).
Each one lists the source lines it describes, and where the fix belongs in the code rather than the
docs, the model includes it, so you can see the checks pass with it. They run as part of Haze's test suite. To run them
yourself, [install Haze](https://haze-lang.pages.dev/docs/installation/) and:

```
git clone https://github.com/ritabratamaiti/haze-lang
cd haze-lang/examples/Found
haze go_retry.hz
```

To model a library of your own, the [documentation](https://haze-lang.pages.dev/docs/) starts with
a short [first model](https://haze-lang.pages.dev/docs/first-model/), and the
[issue tracker](https://github.com/ritabratamaiti/haze-lang/issues) is open for questions.
