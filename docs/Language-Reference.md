# Language reference

The language reference describes every part of Haze as of version 0.1. It's reference material
rather than a tutorial: to learn the language, start with [your first model](Getting-Started.md)
or the [tour](https://haze-lang.pages.dev/tour/).

A Haze file holds a model and the questions you want to ask about it. Haze reads the file
from top to bottom, one declaration at a time, checking each one with its kernel and then
running it. If a declaration is rejected, Haze reports the error, skips it and carries on with
the next one, so one mistake doesn't hide the results of the rest of the file.

## The parts of a file

Because a declaration can only refer to the ones before it, most files follow the same order:

1. Settings, such as the fuzzy logic in use
2. Enumeration types
3. Fuzzy parameters
4. Random inputs and derived values
5. Functions, including fuzzy sets
6. Observations
7. Transition systems
8. Claims and theorems
9. Queries

The sections below go through these parts in order. After them come the expression language,
types and grades, and how to read Haze's output.

### Settings

When `and`, `or` and `implies` combine degrees of truth, there is more than one reasonable way
to do it. `logic` picks one, and the choice applies to the declarations that follow it:

```haze
logic godel        -- min and max (the default; `zadeh` is a synonym)
logic product      -- multiplication and probabilistic sum
logic lukasiewicz  -- max(0, a + b - 1) and min(1, a + b)
```

`explore N` sets how many states Haze explores for an unbounded property (see
[Claims and theorems](#claims-and-theorems)), from that point in the file on. The default is
100,000, and `haze --states N` changes the default for a whole run.

```haze
explore 5000
```

`levels N` sets how many possibility levels Haze uses for continuous fuzzy parameters (see
[Fuzzy parameters](#fuzzy-parameters)), from that point in the file on. The default is 10.

```haze
levels 20
```

### Enumeration types

An enumeration type lists its possible values. The names of the values must be unique in the
file:

```haze
enum Phase = Sending | Waiting | Done | GaveUp
```

### Fuzzy parameters

Use a fuzzy parameter for a quantity you can't pin down but that isn't random either, such as
a loss rate you only know roughly. You list the values it could plausibly have, each with a
degree of possibility between 0 and 1:

```haze
param loss : Num ~= {0.01: 0.6, 0.02: 1, 0.05: 0.5, 0.1: 0.2}
```

The values must be literals of the declared type, none may be listed twice, and at least one
must have possibility 1 (the parameter must be _normal_, meaning that at least one value is
fully possible). Anything that depends on a fuzzy parameter has the grade `fuzzy`.

A `Num` parameter can also range over an interval, with a possibility for every value in it:

```haze
param loss : Num ~= tri(0.01, 0.02, 0.05)        -- 0.02 is fully possible, 0.01 and 0.05 barely
param latency : Num ~= trap(80, 100, 150, 300)   -- 100 to 150 is fully possible
param timeouts : Num ~= likelihood(3, 1000)      -- learned from 3 failures in 1000 calls
```

- `tri(a, m, b)` has possibility 1 at `m`, falling linearly to 0 at `a` and at `b`.
- `trap(a, b, c, d)` has possibility 1 from `b` to `c`, falling linearly to 0 at `a` and at `d`.
- `likelihood(k, n)` is the possibility of a probability after `k` failures in `n` trials: the
  binomial likelihood `p^k (1 - p)^(n - k)`, scaled so that `k / n` has possibility 1.

The arguments must be constant, the corners in increasing order, and `n` at most 100,000.
Claims and `#prob` take every value in each range into account and give certified bounds (see
[Fuzzy parameters](Fuzzy-Parameters.md#continuous-parameters)). The other queries use the most
possible value and say so. An `observe` can't depend on a continuous parameter.

### Random inputs and derived values

`input` declares a random value with a given distribution. `def` without parameters declares a
value computed from earlier ones, and it may make random choices of its own:

```haze
input size : Size ~ {Small: 0.6, Medium: 0.3, Large: 0.1}
def work_ms : Num := match size { Small => 40, Medium => 200, Large => 900 }
```

Either way, the value is drawn once per _world_, so every later reference to `size` sees the
same value. The only difference between the two is in Haze's messages: `#outcomes` and
counterexamples show the values of inputs but not of other definitions.

You can write the grade you expect after the type, and the kernel rejects the definition if
its actual grade is higher:

```haze
def noisy : Num @crisp := uniform(1, 3)   -- rejected: the term has grade prob
```

### Functions and fuzzy sets

A `def` with a parameter list declares a function. Unlike a value, a function makes fresh
random choices every time it's called, which is what you want for something like a network
request:

```haze
def call_succeeds(timeout : Num) : Bool :=
  if work_ms <= timeout then flip(0.95) else flip(0.2)

def stored() : Bool := not flip(drop)    -- a new coin flip on every call
```

Functions may be recursive. Each nested call uses one unit of _fuel_ (1000 by default, or the
value of `--fuel`). When the fuel runs out, the outcome is treated as unknown rather than
guessed, and it widens the result interval. Recursive functions have the grade `partial`.

A function that takes one argument and returns a `Deg` describes a _fuzzy set_, such as "hot"
or "slow", and you can test membership in it with `is`:

```haze
def hot(x : Num) : Deg := ramp_up(x, 25, 35)
claim warm_day : temp is hot
claim very_warm_day : temp is very hot
```

### Observations

`observe` tells Haze that something was seen to be true. Worlds where it's false are discarded,
and the probabilities of the rest are rescaled by Bayes' rule:

```haze
observe timeouts
observe not cache_misses
```

Haze reports how likely the evidence was. An observation is rejected if it's impossible under
every parameter value, or if Haze can't decide it because it ran out of fuel.

### Transition systems

A system has state variables, each with an initial value, and a `step` block that runs once
per time step:

```haze
system Worker {
  var phase : Phase := Calling
  var calls : Num := 0
  step {
    match phase {
      Calling => {
        calls := calls + 1
        if flip(0.9) { phase := Done } else { phase := Backoff }
      }
      Backoff => { if calls < 3 { phase := Calling } else { phase := Failed } }
      _ => skip
    }
    assert calls <= 3
  }
}
```

The statements you can use in a step are:

* `x := e`, which assigns to a state variable,
* `let x := e`, which binds a local variable for the rest of the block,
* `if c { … } else if c' { … } else { … }`, where the `then` keyword is optional,
* `match e { C => { … }, _ => … }`, where an arm is a block or a single statement and the
  commas between arms are optional; constructors without an arm do nothing,
* `assert e`, and
* `skip`.

Semicolons between statements are optional. If an `assert` fails, the system _crashes_: the
rest of the step is skipped and the state never changes again. Properties can check for this
with `crashed`.

A system can take parameters, which makes it easy to compare variants of one design. Parameters
are read like state variables but can't be assigned, and the initial values of state variables
can use them. A property gives a value for every parameter:

```haze
system Pipeline(generated_tests : Bool, review : Bool) {
  var stage : Stage := Writing
  …
}
claim wrong_merge : Pipeline(true, false) |= after[3] (stage == Merged and wrong)
```

### Claims and theorems

Claims and theorems are the questions you ask about a model. A claim asks how strongly a
property holds, optionally with a bound it has to meet; a theorem asks Haze to show that the
property always holds:

```haze
claim double_charge_risk : Naive |= eventually[6] charges >= 2
claim delivered : Naive |= eventually[6] phase == Done with prob >= 0.99
claim stay_wins : pick == car with prob <= 0.34
theorem single_charge : Idempotent |= always[6] charges <= 1
```

A claim without a bound is always accepted, and Haze reports how strongly the property holds.
A claim `with prob >= q` is accepted if the belief is at least `q`, and one `with prob <= q` if
the plausibility is at most `q`. A theorem is accepted only if the belief is 1: the property
holds on every path that can happen, for every possible parameter value, with no unknown
outcomes.

A property is a term of type `Bool` or `Deg`, optionally about a system:

| Form | Meaning |
|---|---|
| `φ` | `φ` in the current worlds |
| `S \|= φ` | `φ` in the initial states of `S` |
| `S \|= after[k] φ` | `φ` after `k` steps |
| `S \|= always[k] φ` | `φ` at every step from 0 to `k` |
| `S \|= eventually[k] φ` | `φ` at some step from 0 to `k` |
| `S \|= always φ` | `φ` at every step, forever |
| `S \|= eventually φ` | `φ` at some step, however late |

In a property about `S`, you can use the state variables of `S` and `crashed`. For a `Deg`
property, `always` takes the lowest degree along each path and `eventually` the highest.

Without a bound, `always` and `eventually` look at the whole infinite run. Haze explores every
reachable state and solves the resulting equations, so a game that can last any number of rounds
gets its exact answer rather than an approximation from a long horizon:

```haze
claim shooter_wins : Craps |= eventually phase == Won       -- exactly 244/495
#expect Game(0.5) |= steps until money == 0 or money == 6   -- exactly 9
```

`#expect S |= steps until φ` is the expected number of steps until a `Bool` property first
holds. It is infinite, and Haze says so, when there is a positive probability that `φ` never
holds.

A system can have infinitely many states, for example when a counter has no upper limit. Haze
then stops after the number of states set by `explore`, and treats what happens after the
unexplored states as unknown. The answer is an interval that contains the true value. It is
narrow when the unexplored states are unlikely to be reached, as in a queue that usually stays
short, and wide when they aren't, as in a random walk that drifts away; exploring further
can't help in that case.

A property can be conditioned with `given`, which asks how likely it is among the runs or
worlds where a condition holds:

```haze
#prob Pipeline(true, true) |= after[3] wrong given stage == Merged
claim precision_target : Pipeline(true, true) |= after[3] wrong given stage == Merged
  with prob <= 0.02
```

The condition is checked at the same step as the property, so `given` works with `after[k]` and
with properties that have no temporal operator, in claims, theorems and `#prob`. The condition
must be possible for every parameter value.

When a theorem or a `with prob >=` bound is rejected, Haze shows a counterexample: the parameter
values, inputs and state at the first step where the property fails, and values for any leading
`forall` variables that make it false. When a `with prob <=` bound is rejected, it shows a run
where the property does hold, since that is what the bound was meant to rule out. Either way the
example comes from a parameter value that breaks the bound. Variables that can't affect the
property aren't shown.

### Queries

Queries print information about the model without changing it:

| Command | Prints |
|---|---|
| `#check e` | The type and grade of `e`. |
| `#eval e` | The exact distribution of `e`, for each parameter value if they differ. With `S \|= after[k] e`, the distribution at step `k`. |
| `#prob φ` | The belief and plausibility of a property. |
| `#expect e` | The expectation of a number, or its lower and upper expectations when fuzzy parameters are involved. With `S \|= steps until φ`, the expected number of steps until `φ` holds. |
| `#outcomes e` | The outcome of `e` for each combination of input values, with its probability. |
| `#tests[n] S \|= φ` | The `n` most likely runs of `S` as test cases (10 without `[n]`), how much of the probability they cover, the most likely failing runs, and a statistical test for code that should match the model. See below. |
| `#print x` | A summary of the declaration `x`, including its grade or result. |

### Probability-weighted tests

`#tests[n] S |= φ` turns a model into test cases for the code it describes. `φ` needs a bounded
modality (`after[k]`, `always[k]` or `eventually[k]`), and `given` isn't allowed. Haze lists runs
of `S` in order of decreasing probability, which is exact: a run is listed only after every more
likely run. For each run it shows its probability, the running total, whether `φ` holds on it,
the random decisions made at each step, and the final state:

```
run 2 · probability 0.019208 · cumulative 0.979608 · passes
  step 1: request_lost = true
  step 3: request_lost = false, response_lost = false
  state: phase = Done, attempts = 2, charges = 1, acked = true, latency = 1080
```

A decision is labeled with the name it is assigned to (by `let` or to a state variable), or
with the condition of an `if` or `match`. Naming random decisions with `let` makes runs easier
to replay against real code. Runs that reach the same state by different decisions are listed
separately, since a test has to make those decisions. A run ends at the horizon, when the system
stops changing, or as soon as the result is settled: when an `always` property fails or an
`eventually` property holds.

The first `n` runs form the suite, and Haze reports the share of the probability they cover.
If `φ` can fail, Haze also lists the most likely failing runs after the suite, up to three of
them or until they account for all the failure probability.

The last line is a statistical test, for checking code against a property that fails by design
some of the time. If a run of code that matches the model fails `φ` with probability `q`, Haze
gives the smallest number of runs, and the number of failures to allow, so that matching code
fails the test with probability at most one in a million, while code that fails twice as often
(for `q ≥ 1/2`, with probability halfway between that and 1) is caught with probability at least 0.99. If `φ` never fails,
one run is a deterministic test.

With fuzzy parameters, the runs use the most possible parameter values, and the statistical
test uses the possible values under which `φ` fails most often.

## Expressions

The table lists the forms of expression from the loosest-binding to the tightest:

| Syntax | Meaning |
|---|---|
| `if c then a else b` | A conditional. If `c : Deg`, it's a _stochastic_ conditional that takes `a` with probability `c`. |
| `let x := e in b` | A local definition. |
| `forall x in a..b, φ`, `exists x in a..b, φ` | Quantifiers over the integers from `a` to `b`. On degrees they take the minimum or maximum. |
| `φ implies ψ`, `φ -> ψ` | Implication. |
| `φ or ψ` | Disjunction. |
| `φ and ψ` | Conjunction. |
| `not φ` | Negation. |
| `==`, `!=`, `<`, `<=`, `>`, `>=` | Comparisons, which return `Bool`. |
| `x is f`, `x is very f`, `x is not f` | Membership in a fuzzy set, with hedges. |
| `+`, `-` and then `*`, `/` | Arithmetic on exact rational numbers. |
| `-x` | Negation of a number. |

When both sides are `Bool`, the connectives are ordinary Boolean logic. If either side is a
`Deg`, they use the active fuzzy logic instead, treating `true` as 1 and `false` as 0, and `not`
becomes `1 - x`. The hedge `very` squares a degree, which makes a fuzzy set stricter.

The simplest expressions are numbers such as `3` and `0.25`, `true` and `false`, names,
function calls, expressions in parentheses, `match e { C => a, _ => b }`, and categorical
distributions, which list values with their probabilities:

```haze
{Small: 0.6, Medium: 0.3, Large: 0.1}
```

The weights can be constants, in which case the kernel checks that they sum to 1, or terms
that depend on parameters and other values, such as `{Correct: solves, Wrong: 1 - solves}`.
Computed weights are checked when the distribution is evaluated: none may be negative, and
together they must sum to exactly 1.

### Built-in functions

| Function | Result |
|---|---|
| `flip(p)`, `bernoulli(p)` | `true` with probability `p`. |
| `uniform(a, b)` | An integer from `a` to `b`, each with the same probability. |
| `binomial(n, p)` | The number of successes in `n` independent trials with probability `p`. |
| `tri(x, a, b, c)` | A triangular membership degree: 0 outside `a`–`c` and 1 at `b`. |
| `trap(x, a, b, c, d)` | A trapezoidal membership degree: rising from `a` to `b`, 1 until `c`, falling until `d`. |
| `ramp_up(x, a, b)`, `ramp_down(x, a, b)` | A degree that rises (or falls) linearly from `a` to `b`. |
| `abs`, `floor`, `min`, `max` | The usual operations on numbers. |
| `deg(e)`, `num(e)` | Conversions to `Deg` (checked to be between 0 and 1) and to `Num`. |

## Types and grades

There are four kinds of type: `Bool`, `Num` (exact rational numbers), `Deg` (degrees of truth
between 0 and 1) and the enumeration types you declare. A `Bool` can be used where a `Deg` is
expected, and a `Deg` where a `Num` is expected; a number can be used as a `Deg` if it lies
between 0 and 1. When the branches of a conditional have different types, the result takes the
more general one.

Every term also has a _grade_, which records the kinds of uncertainty it can carry:

| Grade | Meaning |
|---|---|
| `crisp` | Deterministic, with no fuzzy parameters, and always terminating. |
| `prob` | Depends on random choices. |
| `fuzzy` | Depends on fuzzy parameters. |
| `partial` | Calls a recursive function, so its outcome can be unknown. |

Grades combine, as in `prob+fuzzy`. `#check` and `#print` show them, and an `@` annotation on a
definition sets an upper limit.

## Lexical structure

* Line comments start with `--`, and block comments are written `/- … -/`.
* Identifiers start with a letter and contain letters, digits, `_` and `'`.
* The keywords are `logic`, `enum`, `param`, `input`, `def`, `observe`, `system`, `var`,
  `step`, `claim`, `theorem`, `with`, `prob`, `if`, `then`, `else`, `let`, `in`,
  `forall`, `exists`, `match`, `and`, `or`, `not`, `implies`, `is`, `very`, `true`,
  `false`, `assert`, `skip`, `always`, `eventually`, `after` and `given`.
* `explore`, `steps` and `until` have a special meaning only where they're used, at the start of
  a declaration and after `|=`, and can be used as names elsewhere.
* The symbols `≈`, `≤`, `≥`, `≠`, `⊨`, `→` and `⇒` may be written instead of `~=`, `<=`,
  `>=`, `!=`, `|=`, `->` and `=>`.

## Results and messages

Every message has the form `file:line:column: severity: text`, where the severity is `info`
or `error`.

When there are no fuzzy parameters and no unknown outcomes, the result of a claim or `#prob`
is a single probability. Otherwise it's a pair: the _belief_, how strongly the model
guarantees the property, and the _plausibility_, how strongly it allows it. If the result
depends on the values of fuzzy parameters, a table shows the result for each value together
with its possibility `π`. [Reading results](Reading-Results.md) explains how to read them, and [Design and semantics](Design.md#fuzzy-parameters) gives the precise definitions.

With more than six parameter assignments, the table is replaced by a summary. It shows the
assignments with the lowest, highest and most possible results, and then varies each parameter
on its own, keeping the others at their most possible values, to rank the parameters by how
much they move the result. That ranking says which estimate is worth improving first. Parameters
that a property can't read are left out.

Results of unbounded properties can carry two notes. One says that exploration stopped at the
`explore` limit, so the interval also accounts for the unexplored states. The other says that
part of the state space was too large to solve exactly; Haze then solves it in floating point
and checks the resulting bounds in exact arithmetic, so the interval is guaranteed to contain
the true value but is no longer a single exact number.

All numbers are exact. A number with a long decimal expansion is rounded and marked with `≈`,
followed by the exact fraction when it's short, as in `0.666667 (=2/3)`. Numbers below 0.001 are
shown in scientific notation, as in `≈1.37018e-8 (=1/72982849)`.

## Limits

Haze gets exact answers by enumerating every state, so models have to be finite and not too
large. Temporal properties can look at most 100,000 steps ahead, `uniform` ranges and quantifier
ranges can have at most 100,000 values, and `binomial` allows at most 10,000 trials. At most
2,000,000 distinct configurations are kept per step, after merging equal configurations and
dropping variables the property can't read.

Unbounded properties explore at most 100,000 states unless `explore` says otherwise.
Groups of states that can all reach each other are solved exactly when they have at most 120
states, and with certified bounds when they are larger.

For continuous fuzzy parameters, the search over each range of values spends at most 40 interval
checks on each bound. If that isn't enough to narrow a range down, the result says so, and the
bound stays certified but is more cautious.

Checking spreads its work across processor cores where it can. The parameter assignments of a
query are checked in parallel, large frontiers and breadth-first levels are expanded in parallel,
and when a frontier is small, a step's own random choices are split across cores. Results don't
depend on the number of cores.

Two reductions keep this manageable. Each query builds only the inputs and parameters that it,
or an earlier observation, can read, so unrelated inputs don't multiply the number of worlds. And
a state variable that can't influence the property, directly or through the variables it's
computed from and the conditions around its assignments, isn't tracked at all. A clock or a
counter that a property never reads doesn't split its states. For scale, the models in this repository have up to
about a thousand states per step, and each file checks in well under a minute.

The `haze` command's options, its exit status and its JSON output are described in
[Command line and JSON](Command-Line.md).
