# Haze Language Reference

A Haze file describes a model of a software system and the questions to ask about it. Haze
processes the file from top to bottom, one declaration at a time. Each declaration is
elaborated, checked by the kernel and then executed. A declaration that is rejected produces
an error message and is skipped, and processing continues with the next declaration.

A typical file has the following parts, in this order:

1. Settings, such as the fuzzy logic in use
2. Enumeration types
3. Fuzzy parameters
4. Random inputs and derived values
5. Functions, including fuzzy sets
6. Observations
7. Transition systems
8. Claims and theorems
9. Queries

Later declarations can refer only to earlier ones. Each part is described below, followed by
the expression and statement languages, the types and grades, and the meaning of the
results.

### 1. Settings

`logic` selects the fuzzy logic used by `and`, `or` and `implies` when a degree is involved.
It applies to the declarations that follow it:

```haze
logic godel        -- min and max (the default; `zadeh` is a synonym)
logic product      -- multiplication and probabilistic sum
logic lukasiewicz  -- max(0, a + b - 1) and min(1, a + b)
```

### 2. Enumeration Types

An enumeration type has a fixed list of constructors. Constructor names must be unique in
the file:

```haze
enum Phase = Sending | Waiting | Done | GaveUp
```

### 3. Fuzzy Parameters

A fuzzy parameter is a quantity whose value isn't known precisely and isn't random. It lists
the values it could have, each with a degree of possibility between 0 and 1:

```haze
param loss : Num ~= {0.01: 0.6, 0.02: 1, 0.05: 0.5, 0.1: 0.2}
```

The kernel requires that

* at least one value has possibility 1, so that the parameter is _normal_,
* every possibility lies between 0 and 1, and
* no value is listed twice.

Values must be literals of the declared type. A fuzzy parameter has the grade `fuzzy`.

### 4. Random Inputs and Derived Values

`input` declares a random value. `def` without parameters declares a value derived from
earlier ones, which may also make its own random choices:

```haze
input size : Size ~ {Small: 0.6, Medium: 0.3, Large: 0.1}
def work_ms : Num := match size { Small => 40, Medium => 200, Large => 900 }
```

Both have exactly one value in each _world_: every later reference to `size` sees the same
value. The difference is in messages: the values of inputs are shown in `#outcomes` and in
counterexamples, and the values of other definitions are not.

A definition may declare a grade after its type. The kernel rejects it if the inferred
grade is not below the declared one:

```haze
def noisy : Num @crisp := uniform(1, 3)   -- rejected: the term has grade prob
```

### 5. Functions and Fuzzy Sets

A `def` with a parameter list declares a function. Unlike a value, a function makes fresh
random choices each time it's called:

```haze
def call_succeeds(timeout : Num) : Bool :=
  if work_ms <= timeout then flip(0.95) else flip(0.2)

def stored() : Bool := not flip(drop)    -- a new coin flip on every call
```

Functions may be recursive. Each call uses one unit of _fuel_ (1000 by default, or the
value of `--fuel`). A call that runs out of fuel has an _unknown_ outcome, which widens the
result interval instead of being guessed. Recursive functions have the grade `partial`.

A function with one parameter that returns `Deg` is a _fuzzy set_, and it can be used with
`is`:

```haze
def hot(x : Num) : Deg := ramp_up(x, 25, 35)
claim warm_day : temp is hot
claim very_warm_day : temp is very hot
```

### 6. Observations

`observe` conditions every world on a Boolean term that was observed to be true. The
probabilities of the remaining worlds are rescaled by Bayes' rule:

```haze
observe timeouts
observe not cache_misses
```

The message reports the probability of the evidence. An observation that is impossible under
every parameter value is rejected. An observation whose outcome is unknown because it ran
out of fuel is also rejected.

### 7. Transition Systems

A system has state variables with initial values and a `step` block that runs once per time
step:

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

The statements are

* `x := e`, which assigns to a state variable,
* `let x := e`, which binds a local variable for the rest of the block,
* `if c { … } else if c' { … } else { … }`, where the `then` keyword is optional,
* `match e { C => { … }, _ => … }`, where an arm is a block or a single statement and the
  commas between arms are optional; constructors without an arm do nothing,
* `assert e`, and
* `skip`.

Semicolons between statements are optional. If an `assert` fails, the system is _crashed_:
the rest of the step is skipped and its state never changes again. Properties can refer to
this with `crashed`.

### 8. Claims and Theorems

A claim computes how strongly a property holds:

```haze
claim double_charge_risk : Naive |= eventually[6] charges >= 2
claim delivered : Naive |= eventually[6] phase == Done with prob >= 0.99
claim stay_wins : pick == car with prob <= 0.34
theorem single_charge : Idempotent |= always[6] charges <= 1
```

* A claim without a bound is always accepted, and its interval is reported.
* A claim `with prob >= q` is accepted if the belief is at least `q`.
* A claim `with prob <= q` is accepted if the plausibility is at most `q`.
* A theorem is accepted if the belief is 1. This means that the property holds on every path
  of positive probability, for every parameter value of positive possibility, without any
  unknown outcomes.

A property is a term of type `Bool` or `Deg`, optionally about a system:

| Form | Meaning |
|---|---|
| `φ` | `φ` in the current worlds |
| `S \|= φ` | `φ` in the initial states of `S` |
| `S \|= after[k] φ` | `φ` after `k` steps |
| `S \|= always[k] φ` | `φ` at every step from 0 to `k` |
| `S \|= eventually[k] φ` | `φ` at some step from 0 to `k` |

Within a property about `S`, the state variables of `S` and `crashed` are in scope. For a
`Deg` property, `always` takes the minimum of the degrees along each path and `eventually`
takes the maximum. A rejected theorem or bound is reported with a counterexample: the
parameter values, inputs and state at the first step where the property fails, and the
values of any leading `forall` variables that falsify it.

### 9. Queries

Queries print information without changing anything:

| Command | Prints |
|---|---|
| `#check e` | The type and grade of `e`. |
| `#eval e` | The exact distribution of `e`, for each parameter value if they differ. With `S \|= after[k] e`, the distribution at step `k`. |
| `#prob φ` | The belief and plausibility of a property. |
| `#expect e` | The expectation of a number, or its lower and upper expectations when fuzzy parameters are involved. |
| `#outcomes e` | The outcome of `e` for each combination of input values, with its probability. |
| `#print x` | A summary of the declaration `x`, including its grade or result. |

## Expressions

From the loosest to the tightest binding, expressions are:

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

The connectives are Boolean when both sides are `Bool`. If either side is a `Deg`, they use
the active fuzzy logic, with `true` as 1 and `false` as 0, and `not` is `1 - x`. The hedge
`very` squares a degree.

The atoms are numbers such as `3` and `0.25`, `true` and `false`, names, function calls,
parenthesized expressions, `match e { C => a, _ => b }`, and categorical distributions:

```haze
{Small: 0.6, Medium: 0.3, Large: 0.1}
```

The weights of a categorical distribution must be constants, and the kernel checks that they
sum to 1.

### Built-in Functions

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

## Types and Grades

The types are `Bool`, `Num` (exact rational numbers), `Deg` (degrees between 0 and 1) and the
declared enumeration types. A `Bool` can be used as a `Deg`, and a `Deg` can be used as a
`Num`. A number can be used as a `Deg` if it lies between 0 and 1. The branches of a
conditional are given their least common type.

Every term also has a _grade_, which records the kinds of uncertainty it can carry:

| Grade | Meaning |
|---|---|
| `crisp` | Deterministic, with no fuzzy parameters, and always terminating. |
| `prob` | Depends on random choices. |
| `fuzzy` | Depends on fuzzy parameters. |
| `partial` | Calls a recursive function, so its outcome can be unknown. |

Grades combine, as in `prob+fuzzy`. `#check` and `#print` show them, and `@` annotations
on definitions limit them.

## Lexical Structure

* Line comments start with `--`, and block comments are written `/- … -/`.
* Identifiers start with a letter and contain letters, digits, `_` and `'`.
* The keywords are `logic`, `enum`, `param`, `input`, `def`, `observe`, `system`, `var`,
  `step`, `claim`, `theorem`, `with`, `prob`, `if`, `then`, `else`, `let`, `in`,
  `forall`, `exists`, `match`, `and`, `or`, `not`, `implies`, `is`, `very`, `true`,
  `false`, `assert`, `skip`, `always`, `eventually` and `after`.
* The symbols `≈`, `≤`, `≥`, `≠`, `⊨`, `→` and `⇒` may be written instead of `~=`, `<=`,
  `>=`, `!=`, `|=`, `->` and `=>`.

## Results and Messages

Every message has the form `file:line:column: severity: text`, where the severity is `info`
or `error`. The result of a claim or `#prob` is

* a single probability when there are no fuzzy parameters and no unknown outcomes, or
* a pair of belief and plausibility, where belief is the degree to which the model
  guarantees the property and plausibility is the degree to which it allows it.

When the results differ between parameter values, a table shows the result for each value
and its possibility `π`. The precise definitions are in [`Design.md`](Design.md).

## Limits

Haze computes exact results by enumerating states, so models must be finite and bounded:

* Horizons of temporal properties are at most 100000 steps.
* `uniform` ranges and quantifier ranges have at most 100000 values, and `binomial` allows
  at most 10000 trials.
* At most 2000000 distinct configurations are kept per step. Configurations that are equal
  are merged, and worlds are reduced to the variables that a property can read.
