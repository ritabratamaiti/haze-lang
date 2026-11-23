---
name: haze-model
description: Write or update a Haze model of code that has to cope with things going wrong some of the time, such as retries, timeouts, failover, replication, queues, rollouts or sampling. Use it when the user asks how likely an outcome is or whether a reliability target holds, and when you change code that a `haze:` comment links to a model.
haze_version: {{HAZE_VERSION}}
---

# Modeling with Haze

Haze checks systems that fail some of the time. A model describes the design: what can go wrong,
how often, and what the code does about it. Haze computes exact probabilities for claims about
it, gives a belief and plausibility pair when a rate is only roughly known, and shows a run that
breaks any claim that fails. The `haze` command is the only tool you need; `haze --help` lists
its options.

## When to reach for it

Use Haze when correctness depends on chance or on rates nobody knows exactly:

- retry, backoff and timeout policies, and how often a request finally succeeds;
- duplicate side effects (double charges, double sends) after lost replies;
- failover, leader election, quorums and replication under message loss;
- rollouts, sampling, alerting and other decisions made on noisy data;
- anything with a target such as "99.9% of requests" or "fewer than 1 in 10,000".

Don't use it for properties that hold on every input regardless of chance (use types and
tests), or for code whose state space can't be kept small (thousands of distinct states per
step is fine; millions is not).

## Workflow

1. **Read the code first.** Find the random events (what fails and how often), the decisions the
   code makes (retry limits, backoff caps, fallbacks), the state those decisions read, and the
   requirement. Write the requirement down in the user's words before writing any Haze.
2. **Ask for the numbers you don't have.** Never invent a failure rate silently. If the user
   gives a range ("about 2%, maybe 5%"), make it a fuzzy parameter. If there are counts in logs
   or metrics ("12 timeouts in 4000 calls"), use `likelihood(12, 4000)`. Say in the model where
   each number came from.
3. **Write the model** in `models/<name>.hz`, unless the project already keeps models
   somewhere else. Model only what can affect the requirement.
4. **Link the code to the model.** Put a comment containing `haze: models/<name>.hz` next to
   each function or module the model describes, in whatever comment syntax the language uses.
   The Haze hooks use these links to remind you to re-check the model when that code changes.
5. **Check it** with `haze models/<name>.hz` and follow the `haze-check` skill to read the
   results and report them. Iterate on the model until it describes the code, not until the
   claims pass.

## The language in one page

```haze
-- comments start with two dashes
enum Phase = Sending | Waiting | Done | GaveUp

-- rates you only roughly know (possibilities, not probabilities; one value must have 1)
param loss : Num ~= {0.01: 0.6, 0.02: 1, 0.05: 0.5}
param timeout_rate : Num ~= tri(0.001, 0.003, 0.01)   -- every value in a range
param error_rate : Num ~= likelihood(12, 4000)         -- learned from 12 failures in 4000

input region : Bool ~ flip(0.3)             -- a random input, drawn once per world
def retries : Num := 3                      -- a constant or derived value
def lost() : Bool := flip(loss)             -- a function: fresh randomness on every call

system Client(max_attempts : Num, idempotent : Bool) {
  var phase : Phase := Sending
  var attempts : Num := 0
  var charges : Num := 0
  step {
    match phase {
      Sending => {
        attempts := attempts + 1
        let request_lost := flip(loss)        -- naming a random decision helps #tests
        if request_lost { phase := Waiting }
        else {
          if not idempotent or charges == 0 { charges := charges + 1 }
          let reply_lost := flip(loss)
          if reply_lost { phase := Waiting } else { phase := Done }
        }
      }
      Waiting => { if attempts < max_attempts { phase := Sending } else { phase := GaveUp } }
      _ => skip
    }
    assert charges <= max_attempts
  }
}

claim delivered : Client(5, true) |= eventually phase == Done with prob >= 0.999
theorem single_charge : Client(5, true) |= always charges <= 1
#prob Client(5, false) |= eventually charges >= 2
#tests[10] Client(5, true) |= always[12] charges <= 1
```

- Types: `Bool`, `Num` (exact fractions), `Deg` (a degree of truth from 0 to 1) and enums.
- Randomness: `flip(p)`, `uniform(a, b)` (integers), `binomial(n, p)`, and categorical
  choices `{A: 0.2, B: 0.8}`. `if` on a `Deg` is a stochastic choice.
- Statements in a step: `x := e`, `let x := e`, `if … { } else { }`, `match`, `assert e`,
  `skip`. A failed `assert` crashes the system; properties can read `crashed`.
- Properties: `S |= φ`, `after[k] φ`, `always[k] φ`, `eventually[k] φ`, and unbounded
  `always φ` and `eventually φ`, which Haze solves exactly however long the run is.
  `given c` conditions on `c` (with `after[k]` or no modality).
- Claims: `claim n : P` reports a result; `with prob >= q` checks the belief, `with prob <= q`
  checks the plausibility. `theorem n : P` must hold on every run for every parameter value.
- Queries: `#prob P`, `#eval e`, `#expect e`, `#expect S |= steps until φ`, `#outcomes`,
  `#tests[n] S |= φ`, `#check e`, `#print x`.
- Settings: `explore N` (states explored for unbounded properties), `levels N` (possibility
  levels for range parameters), `logic godel|product|lukasiewicz`.

The full reference is at https://haze-lang.pages.dev/docs/reference/ and worked examples are at
https://github.com/ritabratamaiti/haze-lang/tree/main/examples.

## Choosing how to write an uncertain number

| What the user knows | Write |
|---|---|
| An exact rate from a spec or a design decision | a literal, such as `flip(0.01)` |
| A few candidate values, some more believable than others | `{0.01: 0.6, 0.02: 1, 0.05: 0.5}` |
| A range with a most likely value | `tri(low, likely, high)` or `trap(a, b, c, d)` |
| Counts of failures and attempts | `likelihood(failures, attempts)` |
| A genuinely random quantity that varies from run to run | `input x : Num ~ {…}` |

Possibilities aren't probabilities: they don't need to add up to 1, and they say how acceptable
a value is as an estimate. The value the user considers most likely gets 1.

## Modeling rules

- **Keep the state finite and small.** Cap counters at the limit the code enforces. A counter
  with no limit makes unbounded properties explore up to `explore` states and report an
  interval; prefer a horizon such as `eventually[20]` when the code has a natural bound.
- **Model the design, not the implementation.** One state variable per thing a decision
  reads. Leave out logging, metrics and anything the requirement doesn't depend on.
- **Compare designs with system parameters** (`Client(3, false)` against `Client(5, true)`)
  instead of copying a system.
- **State requirements as claims with bounds, and must-never properties as theorems.** Use
  `#prob` while exploring and turn the answer into a claim once the user agrees on the bound.
- **Name random decisions with `let`** so that `#tests` output reads like a script for a test.

## Pitfalls

- `step` is a keyword and can't be used as a name.
- `given` works only with `after[k]` or with no modality.
- An `observe` can't depend on a range parameter (`tri`, `trap`, `likelihood`).
- `#eval`, `#expect`, `#outcomes` and `#tests` use the most possible value of a range
  parameter, and say so in their output.
- If a check is slow, shorten the horizon, cap counters, or split the model; don't remove the
  property you were asked to check.

## Anti-patterns

- Inventing a rate and presenting the result as fact.
- Tuning possibilities, horizons or bounds until a claim passes.
- Modeling the code so closely that the model is as hard to read as the code.
- Leaving a model without a `haze:` link from the code it describes.
