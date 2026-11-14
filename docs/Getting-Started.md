# Your first model

In this guide you'll write a small Haze model, check it, and read what Haze says about it. You'll
need Haze [installed](Installation.md), or you can follow along in the
[playground](https://haze-lang.pages.dev/play/).

The model is a client that calls a service which fails 10% of the time. The client tries up to
three times. Two questions are worth asking about it: how often does it give up, and can the
number of attempts ever go above three?

## A system

Save this as `client.hz`:

```haze
system Client {
  var attempts : Num := 0
  var ok : Bool := false
  step {
    if not ok and attempts < 3 {
      attempts := attempts + 1
      ok := flip(0.9)
    }
  }
}

#prob Client |= eventually[3] ok
#eval Client |= after[3] attempts
```

A `system` has state variables, each with a starting value, and a `step` block that runs once per
time step. `flip(0.9)` is `true` with probability 0.9, so each attempt succeeds 90% of the time.
Once `ok` is true, or after three attempts, the step does nothing and the state stays the same.

The two lines at the end are queries. `#prob` asks how likely a property is, and
`Client |= eventually[3] ok` means "in a run of `Client`, `ok` becomes true within 3 steps".
`#eval` shows the distribution of a value, here the number of attempts after 3 steps.

Run it:

```sh
haze client.hz
```

```
client.hz:12:1: info: #prob Client |= eventually[3] ok
  probability 0.999
client.hz:13:1: info: #eval Client |= after[3] attempts
  1  ↦ 0.9
  2  ↦ 0.09
  3  ↦ 0.01
```

Each message starts with the file, line and column of the declaration it's about. The client
succeeds with probability 0.999, which is 1 - 0.1³. Haze didn't simulate the client to get that:
it followed every possible run and added up their probabilities exactly. The distribution of
`attempts` says the client needs one attempt 90% of the time, two 9% of the time, and three 1% of
the time.

## Claims and theorems

Queries print information. To have Haze check a requirement, write a `claim` or a `theorem`. Add
these lines to the file:

```haze
claim usually_succeeds : Client |= eventually[3] ok with prob >= 0.999
theorem at_most_three : Client |= always[5] attempts <= 3
theorem always_succeeds : Client |= eventually[3] ok
```

A claim with `with prob >= q` is accepted if the property holds with probability at least `q`. A
theorem must hold on every run that can happen. `always[5]` means "at every step from 0 to 5".
Running the file again prints three more results:

```
client.hz:15:1: info: claim usually_succeeds
  probability 0.999 · graded
  grade prob · 1 parameter assignment(s) · ≤1 states/step
  bound holds: belief ≥ 0.999
client.hz:16:1: info: theorem at_most_three
  probability 1 · holds with certainty
  grade prob · 1 parameter assignment(s) · ≤4 states/step
  theorem accepted
client.hz:17:1: error: theorem always_succeeds
  probability 0.999 · graded
  grade prob · 1 parameter assignment(s) · ≤1 states/step
  theorem rejected: belief is 0.999, not 1
  counterexample at step 3 (path mass 0.001, never reached on this path):
    state: attempts = 3, ok = false
```

The claim holds, since 0.999 meets the bound exactly. The first theorem holds on every run. The
second is rejected, because three failures in a row are possible, and Haze shows that run: after
3 steps, with probability 0.001, the client has used all its attempts and `ok` is still false.
"Never reached on this path" means `ok` never became true on it.

A rejected declaration is reported as an `error`, and `haze` exits with status 1, so a model can
fail a CI build. The other lines in each result, such as `grade` and `states/step`, are explained
in [Reading results](Reading-Results.md).

## A rate you only roughly know

The failure rate of a real service is rarely known exactly. Suppose 10% is your best guess, 5%
is possible, and 20% is less likely but can't be ruled out. A fuzzy parameter says exactly that:

```haze
param fail : Num ~= {0.05: 0.5, 0.1: 1, 0.2: 0.3}

system Client {
  var attempts : Num := 0
  var ok : Bool := false
  step {
    if not ok and attempts < 3 {
      attempts := attempts + 1
      ok := not flip(fail)
    }
  }
}

claim usually_succeeds : Client |= eventually[3] ok with prob >= 0.99
```

Each value of `fail` has a possibility from 0 to 1. At least one value must have possibility 1.
The possibilities aren't probabilities: they say how acceptable each value is as an estimate, and
they don't have to add up to 1.

```
client_rough.hz:14:1: info: claim usually_succeeds
  belief 0.9969 · plausibility 0.999438 (=15991/16000) · graded
  grade prob+fuzzy · 3 parameter assignment(s) · ≤1 states/step
  bound holds: belief ≥ 0.99
  by fuzzy parameter (π = possibility):
    fail = 0.05  π 0.5     0.999875
    fail = 0.1   π 1       0.999
    fail = 0.2   π 0.3     0.992
```

The table at the bottom has the exact probability for each value of `fail`. Above it, Haze
combines them into two numbers. The belief, 0.9969, is how strongly what you know guarantees the
property, and the plausibility, 0.999438, is how strongly it allows it. A `with prob >=` bound is
checked against the belief, so it has to hold even when the pessimistic values are taken into
account. [Fuzzy parameters](Fuzzy-Parameters.md) explains how the two numbers are computed and
how to choose possibilities.

## Tests from the model

A model can also produce test cases for the code it describes. Add this line:

```haze
#tests[3] Client |= eventually[3] ok
```

Haze lists the runs of `Client` from the most likely to the least, with the random decisions made
at each step:

```
client_rough.hz:15:1: info: #tests[3] Client |= eventually[3] ok
  runs at fail = 0.1, the most possible parameter values
  the 3 most likely runs make up 0.999 of the probability
  the property fails with probability 0.001; all the failing runs are listed
  run 1 · probability 0.9 · cumulative 0.9 · passes
    step 1: ok = true
    state: attempts = 1, ok = true
  run 2 · probability 0.09 · cumulative 0.99 · passes
    step 1: ok = false
    step 2: ok = true
    state: attempts = 2, ok = true
  run 3 · probability 0.009 · cumulative 0.999 · passes
    step 1: ok = false
    step 2: ok = false
    step 3: ok = true
    state: attempts = 3, ok = true
  failing run · probability 0.001 · fails
    step 1: ok = false
    step 2: ok = false
    step 3: ok = false
    state: attempts = 3, ok = false
  statistical test at fail = 0.2: a run of code that matches the model fails this property with probability 0.008. Run the real code 8755 times and allow up to 113 failures: code that matches the model then fails the test with probability ≈7.88428e-7, and code that fails twice as often is caught with probability ≈0.990002
```

Each run is a test: make the real client's calls succeed or fail in that order, and check that it
ends in the state shown. The last line is for testing the real client against a real, flaky
service, where individual failures are expected. [Testing real code](../examples/Conformance/README.md) shows how to
connect these to an implementation.

## Next steps

- The [tour](https://haze-lang.pages.dev/tour/) covers the rest of the language in short,
  editable chapters.
- The [tutorial](https://github.com/ritabratamaiti/haze-lang/blob/main/examples/Tutorial/JobWorker.hz)
  builds a larger model of a background job worker, with its output in a file next to it.
- The [gallery](https://haze-lang.pages.dev/gallery/) has complete models from software and other
  fields.
- The [language reference](Language-Reference.md) describes every construct.
