---
title: Three circuit breakers, one bug
date: 2026-11-23
order: 1
author: Ritabrata Maiti
summary: In failsafe-go, resilience4j and pybreaker, a call admitted before the breaker opened can finish during half-open and be treated as one of the trial calls. All three then run more trial calls than configured, and failsafe-go and pybreaker can close on results that aren't from a trial.
---
# Three circuit breakers, one bug

When a circuit breaker opens, it waits, then goes half-open: a small, configured number of trial
calls go through to the struggling service, and their results decide whether the breaker closes or
opens again. Of the five breaker libraries I checked, three let calls that started before the
breaker opened take part in that decision. They're reported as
[failsafe-go#148](https://github.com/failsafe-go/failsafe-go/issues/148),
[resilience4j#2602](https://github.com/resilience4j/resilience4j/issues/2602) and
[pybreaker#113](https://github.com/danielfm/pybreaker/issues/113).

## What goes wrong

A breaker keeps one current state and sends every finished call's result to it. In all three
libraries, a call in flight doesn't remember which state let it in. Calls that were admitted while
the breaker was closed are often still running when it goes half-open, and when they finish, their
results land in the half-open state as if they were trials.

| library | an older call finishing in half-open | effect |
|---|---|---|
| failsafe-go 0.9.8 | is counted, and returns a trial permit it never took | 3 trials run at once with a limit of 2, and one trial success closes the breaker |
| resilience4j 2.4.0 | returns a trial permit it never took if it ends with an ignored exception or is cancelled | 2 test calls run at once with a limit of 1 |
| pybreaker 1.4.1 | with `calling()` or a guarded generator, runs without the lock and reports to the state it started in | several trials run at once, and a late success closes the breaker just after another trial failed |

So the breaker either sends more traffic to the service than it was told to, or decides on
evidence that says nothing about whether the service is back.

## Why the test suites pass

Seeing this needs a particular order: start a call, open the breaker while it runs, wait out the
delay, start a trial, and only then let the first call finish. A test that drives the breaker one
call at a time never produces that order. pybreaker's suite even has a test asserting that only
one trial call runs in half-open. It passes, because it goes through `call()`, which holds a lock
for the whole call.

## The model

Instead of tracking individual calls, the [Haze](https://github.com/ritabratamaiti/haze-lang)
models count them. In the failsafe-go model, `trial` is how many running calls hold a permit from
the current half-open period and `others` is how many other calls are still running. Each step,
one of six events happens: a call starts, the delay passes, an older call succeeds or fails, or a
trial succeeds or fails. This is the branch for an older call that succeeds:

```haze
OtherOk => {
  if others > 0 {
    others := others - 1
    if st == HalfOpen and not fixed {
      successes := successes + 1           -- recorded in the half-open stats
      if successes >= 2 {
        st := Closed; others := others + trial; trial := 0
        if trial_successes < 2 { closed_early := true }
      } else {
        permits := permits + 1             -- checkThresholdAndReleasePermit
      }
    }
  }
}
```

Two of the properties, worded after the package documentation:

```haze
-- "In the HalfOpenState a configurable number of trial executions will be allowed"
theorem trials_within_capacity : Breaker(false) |= always trial <= capacity
-- WithSuccessThreshold(2): 2 successful executions in HalfOpen close the circuit
theorem closes_on_own_trials : Breaker(false) |= always not closed_early
```

Haze tries every order of events and finds a violation of each:

```
theorem trials_within_capacity
  theorem rejected: belief is 0, not 1
  counterexample at step 8:
    state: st = HalfOpen, permits = 0, successes = 1, trial = 3, others = 0
theorem closes_on_own_trials
  theorem rejected: belief is 0, not 1
  counterexample at step 7:
    state: st = Closed, successes = 2, trial_successes = 1, closed_early = true
```

Read the first one as: two trials were running when an older call succeeded, that success gave
back a permit, and a third trial started. In the second, the same kind of success counts toward
closing, so the breaker closes after one genuine trial. The probability of 0 comes from the
model's scheduler, which keeps picking events at random: run long enough, it hits a bad order
almost surely. The model's probabilities only make every order possible; the point is that the bad
states are reachable.

The model has a `fixed` parameter. With it set, half-open only counts results from calls that took
their permit in the current half-open period, which is how [gobreaker](https://github.com/sony/gobreaker)
does it, with a generation counter. All three properties then hold, in 61 states.

## Checking each library directly

Before filing, I wrote each counterexample as a program that uses the library itself:

- **failsafe-go:** a single goroutine calls `TryAcquirePermit`, `RecordSuccess` and
  `RecordFailure`, the same methods the executor uses. A third trial is admitted and the breaker
  closes after one trial success, in 200 of 200 runs. Going through `failsafe.With(cb).Run` with
  real goroutines gives the same result in 150 of 150 runs, including with `-race`.
- **resilience4j:** two JUnit tests, which is what the project asks for. One shows a second test
  call getting a permit. The other shows a success from a call admitted while closed closing the
  breaker; a comment in the code suggests late results are meant to be recorded, so the issue
  raises that part as a question. Both tests fail on 2.4.0 and on master.
- **pybreaker:** two threads enter `with breaker.calling():` after the timeout. Both run, B fails
  and reopens the breaker, then A succeeds and closes it, in 60 of 60 runs. Through
  `breaker.call()` only one runs.

Then each report went through a review whose job was to find reasons it was wrong: the docs, tests,
changelogs and old issues of each project, a comparison of every model line with the code, and a
check of every number and link. It didn't overturn any of them, but it dropped a resilience4j fix
I had suggested that wouldn't have worked, made the failsafe-go report more careful about the part
that's debatable, and turned up a second way pybreaker closes early.

## The fix

The same idea works for all three: when a call is admitted, record which state, or which
generation of the breaker, admitted it, and when it finishes, only let it affect that state.
resilience4j needs a new method for this, since `tryAcquirePermission()` returns only a boolean.

## Running the models

All three models are in the Haze repository, with the source lines each part describes listed at
the top:

```
git clone https://github.com/ritabratamaiti/haze-lang
cd haze-lang/examples/Found
haze failsafe_go.hz
haze resilience4j.hz
haze pybreaker.hz
```

Each runs in a second or two. This is one of the findings described in
[Checking 32 resilience libraries against their own docs](https://haze-lang.pages.dev/blog/checking-32-libraries/).
