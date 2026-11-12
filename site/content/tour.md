## Exact probabilities

Haze computes probabilities exactly, with fractions, instead of estimating them by running a
simulation many times. A random value is declared with `input` and a distribution after `~`.
`flip(p)` is true with probability `p`, and `uniform(a, b)` picks a whole number from `a` to `b`.

`#prob` asks how likely something is, and `#eval` shows a whole distribution. Hover over a
number to see its exact value. Try changing the dice to `uniform(1, 8)`.

```haze
input die1 : Num ~ uniform(1, 6)
input die2 : Num ~ uniform(1, 6)
#prob die1 + die2 == 7
#prob die1 == die2
#eval die1 + die2
```

## Definitions and distributions

`def` names a value, which can depend on random inputs. A distribution can also be written out
in full, listing each value with its probability. Here a request goes to one of three regions,
and each region has its own failure rate.

```haze
enum Region = East | West | Asia

input region : Region ~ {East: 0.5, West: 0.3, Asia: 0.2}
def fail_rate : Num := match region { East => 0.01, West => 0.02, Asia => 0.05 }
input failed : Bool ~ flip(fail_rate)

#prob failed
#eval region
```

## Systems that change over time

Most software has state that changes step by step. A `system` declares state variables and a
`step` block that runs once per time step. A property about a system says when to look:
`after[k]` at step `k`, `always[k]` at every step up to `k`, and `eventually[k]` at some step up
to `k`.

This worker calls a service that fails 20% of the time and retries up to three times.

```haze
system Worker {
  var calls : Num := 0
  var done : Bool := false
  step {
    if not done and calls < 3 {
      calls := calls + 1
      if flip(0.8) { done := true }
    }
  }
}

#prob Worker |= eventually[3] done
#eval Worker |= after[3] calls
```

## Theorems and counterexamples

A `theorem` must hold on every run that can happen. When it doesn't, Haze shows a run that
breaks it. This client retries a payment when a message is lost, and the server charges the
card every time a request reaches it. Change `charges := charges + 1` to
`if charges == 0 { charges := 1 }` (an idempotency key) and Haze proves the theorem.

```haze
system Client {
  var attempts : Num := 0
  var charges : Num := 0
  var done : Bool := false
  step {
    if not done and attempts < 3 {
      attempts := attempts + 1
      if flip(0.9) {                      -- the request arrives
        charges := charges + 1
        if flip(0.9) { done := true }      -- and so does the reply
      }
    }
  }
}

theorem never_charged_twice : Client |= always[6] charges <= 1
```

## Claims with bounds

A `claim` says how likely something must be, with `with prob >= q` or `with prob <= q`. It's
checked exactly, so a bound of 0.999 means 0.999 and not "roughly". A claim that fails shows a
run, just as a theorem does.

```haze
system Retry {
  var tries : Num := 0
  var ok : Bool := false
  step {
    if not ok and tries < 3 {
      tries := tries + 1
      ok := flip(0.95)
    }
  }
}

claim usually_works : Retry |= eventually[3] ok with prob >= 0.999
claim rarely_three_tries : Retry |= eventually[3] tries == 3 with prob <= 0.01
```

## Rough numbers

You rarely know a rate exactly. A fuzzy parameter (`param ... ~=`) lists the values you think
are possible, each with how plausible it is, from 0 to 1. The answer is then a range: the
*belief* is how strongly what you know guarantees the property, and the *plausibility* is how
strongly it allows it. The table shows the result for each value. Here the claim fails: at the
pessimistic 5% rate, one retry isn't quite enough. Try `with prob >= 0.99`.

```haze
param fail : Num ~= {0.01: 0.5, 0.02: 1, 0.05: 0.4}

input first : Bool ~ flip(fail)
input second : Bool ~ flip(fail)

claim one_retry_is_enough : not (first and second) with prob >= 0.999
#prob first and second
```

## Evidence and Bayes' rule

`observe` tells Haze something was seen to be true, and every later answer takes it into
account. `given` asks a conditional question without changing the model. Here an alert fired,
and the question is which component is at fault.

```haze
enum Cause = Database | Network | Deploy
input cause : Cause ~ {Database: 0.5, Network: 0.3, Deploy: 0.2}
input alert : Bool ~ match cause { Database => flip(0.9), Network => flip(0.6), Deploy => flip(0.2) }

#prob cause == Deploy given alert
observe alert
#eval cause
```

## Runs of any length

Without a bound, `eventually` and `always` look at the whole run, however long it lasts.
`#expect ... steps until` gives the expected number of steps until something happens. In this
game the gambler starts with 3 and stops at 0 or 6.

```haze
system Game {
  var money : Num := 3
  step {
    if money > 0 and money < 6 {
      if flip(0.5) { money := money + 1 } else { money := money - 1 }
    }
  }
}

claim win : Game |= eventually money == 6
#expect Game |= steps until money == 0 or money == 6
theorem never_negative : Game |= always money >= 0
```

## Tests ranked by probability

`#tests` turns a model into test cases for the real code. It lists the runs from the most likely
to the least, so a few tests cover almost all the behaviour that actually happens, and it adds
the rare runs where the property fails. For a property that fails by design some of the time,
it also sizes a statistical test with a known false-alarm rate. The rest of the documentation is
on the [docs](../docs/) page.

```haze
system Job {
  var tries : Num := 0
  var done : Bool := false
  step {
    if not done and tries < 3 {
      tries := tries + 1
      let failed := flip(0.2)
      if not failed { done := true }
    }
  }
}

#tests[3] Job |= after[3] done
```
