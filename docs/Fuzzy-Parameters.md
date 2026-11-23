# Fuzzy parameters

Some quantities in a model aren't random but aren't known exactly either, such as a packet loss
rate you've estimated from a dashboard. Haze models them as fuzzy parameters. This guide covers
when to use one, how to choose its possibilities, and what the belief and plausibility in the
answer mean. The syntax is in the [language reference](Language-Reference.md#fuzzy-parameters),
and the formal definitions are in [Design and semantics](Design.md#fuzzy-parameters).

## Random inputs and fuzzy parameters

Haze has two ways to describe something you don't control, and they mean different things.

An `input` is random. Each run draws a value, with the probabilities you give:

```haze
input region : Region ~ {East: 0.5, West: 0.3, Asia: 0.2}
```

A `param` is fixed but not known exactly. It has one true value, and you list the values it might
have, each with a possibility from 0 to 1:

```haze
param loss : Num ~= {0.01: 0.6, 0.02: 1, 0.05: 0.5, 0.1: 0.2}
```

A packet loss rate is a good example of a parameter. Each packet is lost or not at random, which
`flip(loss)` models, but the rate itself is a property of the network that you've estimated from
dashboards, a vendor's figure, or a guess. Making it a parameter keeps the randomness of the
model separate from your uncertainty about the model, and the answer shows both.

## Choosing possibilities

Possibilities aren't probabilities. They don't need to add up to 1, and they don't say how often
a value occurs. A possibility says how acceptable a value is as an estimate:

- 1 means the value is fully consistent with what you know. At least one value must have
  possibility 1.
- Values between 0 and 1 are less consistent with what you know, but can't be ruled out.
- A value you're sure is wrong should be left out.

A practical way to choose them is to start from a statement like "the loss rate is around 2%,
it's been as low as 1%, and it could reach 5% on a bad day; 10% would be surprising". The most
likely value gets 1, the values you've seen get high possibilities, and the bad cases get lower
ones:

```haze
param loss : Num ~= {0.01: 0.6, 0.02: 1, 0.05: 0.5, 0.1: 0.2}
```

The exact possibilities matter less than which values you include. Including a pessimistic value
with a low possibility lowers the belief in a requirement, and leaving it out raises it. The
table in the output shows the result for each value, so you can always see what a single value
would give.

## What the answer means

With fuzzy parameters, a result is a pair: the belief and the plausibility. Take the client from
[Your first model](Getting-Started.md), with `fail ≈ {0.05: 0.5, 0.1: 1, 0.2: 0.3}`:

```
  belief 0.9969 · plausibility 0.999438 (=15991/16000) · graded
  by fuzzy parameter (π = possibility):
    fail = 0.05  π 0.5     0.999875
    fail = 0.1   π 1       0.999
    fail = 0.2   π 0.3     0.992
```

Haze computes the belief by looking at the values in order of possibility:

- Above possibility 0.5, only `fail = 0.1` is possible. The worst result there is 0.999.
- Between 0.3 and 0.5, `fail = 0.05` is possible too. The worst result is still 0.999.
- Below 0.3, all three are possible. The worst result is 0.992.

The belief weights each worst case by the width of its band: 0.5 × 0.999 + 0.2 × 0.999 +
0.3 × 0.992 = 0.9969. The plausibility does the same with the best case in each band, which
gives 0.999438. A pessimistic value with a low possibility only affects a thin band, so it pulls
the belief down a little rather than all the way.

The two numbers are the belief and plausibility of Dempster–Shafer theory. When a property doesn't
involve chance, they're the necessity and possibility of possibility theory. In
[`tests/basics.hz`](../tests/basics.hz), `load ≈ {50: 0.5, 70: 1, 90: 0.4}` gives `load > 80` a
plausibility of 0.4, because its only supporting value has possibility 0.4, and `load <= 80` a
belief of 0.6.

## Bounds and theorems

The two numbers are checked differently, and each check is the cautious one:

- `with prob >= q` passes if the belief is at least `q`. The requirement has to hold even after
  the pessimistic values are taken into account, in proportion to their possibility.
- `with prob <= q` passes if the plausibility is at most `q`. The bad outcome has to stay below
  `q` even when the uncertain values are read in its favor.
- A `theorem` passes only if the belief is 1. Since every listed value has a possibility above 0,
  this means the property holds for every value of every parameter.

When a bound fails, the counterexample comes from a parameter value that breaks it.

## Continuous parameters

A list of values checks only the values you list. If the loss rate is "around 2%, somewhere
between 1% and 5%", it could be 3.7%, and a list of four values wouldn't check that. A triangle
covers every value in the range:

```haze
param p : Num ~= tri(0.01, 0.02, 0.05)
```

`tri(a, m, b)` gives `m` possibility 1 and falls linearly to 0 at `a` and `b`. `trap(a, b, c, d)`
is fully possible from `b` to `c` instead of at one point. Here is a client that tries a request
up to three times, with `p` the chance that one attempt fails, from
[`tests/continuous.hz`](../tests/continuous.hz):

```
#prob Retry |= eventually phase == Done
  belief ≈0.999943 · plausibility ≈0.999997
  10 possibility levels: the exact belief is at most ≈0.999955, the exact plausibility at least ≈0.999996 (more with `levels N`)
  at the most possible values, p = 0.02: 0.999992
  by possibility level (lowest to highest over the values at least that possible):
    π ≥ 0.9  p in [0.019, 0.023]   ≈0.999988 to ≈0.999993
    π ≥ 0.5  p in [0.015, 0.035]   ≈0.999957 to ≈0.999997
    all values  p in [0.01, 0.05]  0.999875 to 0.999999
```

The values with possibility at least some level form a range, which gets narrower as the level
rises. For each level, Haze finds the lowest and the highest result over the whole range, and the
belief and plausibility combine them as before. The table shows three of the levels.

Haze doesn't sample the range. It checks the model once with `p` standing for the whole range,
which gives bounds that hold for every value in it, and it checks single values, which show how
close those bounds are. When the result moves the same way as the parameter, as it does here, the
two meet at an end of the range, and that level is done. Otherwise Haze splits the range and
checks the pieces, until the bounds meet the best values found or it has spent its budget. A
range is split first at the constants the model compares the parameter with, so that a condition
like `if p > 0.6` is decided on every piece. If some range can't be narrowed down, the result
says the bounds are cautious. They are still guaranteed, just wider than the truth. This
happens when one step uses the same parameter in two random choices whose effects pull in
different directions.

The levels are the one approximation. Haze uses 10 of them, plus the possibilities of any listed
parameters, and between two levels it uses the wider range. So the belief it reports is at most
the exact belief of the triangle, and the plausibility at least the exact plausibility, which
keeps `with prob` checks on the cautious side. The note gives the other side of each: here the
exact belief is between 0.999943 and 0.999955. `levels 50` narrows the gap.

A theorem with a continuous parameter has to hold for every value in its range.

## Parameters from data

If you have counts, Haze can turn them into a parameter. After 3 failures in 200 calls:

```haze
param r : Num ~= likelihood(3, 200)
```

The possibility of each failure rate is its likelihood, `r³ (1 - r)¹⁹⁷`, divided by the likelihood
of the observed rate `3/200`. So `3/200` is fully possible, and rates that make the data unlikely
have low possibility. The values with possibility at least 0.15 are close to a 95% confidence
interval for the rate. More data gives a narrower distribution and a smaller gap between belief
and plausibility.

```
#prob Learned |= after[1] ok
  belief ≈0.968474 · plausibility ≈0.993478
  14 possibility levels: the exact belief is at most ≈0.972674, the exact plausibility at least ≈0.992121 (more with `levels N`)
  at the most possible values, r = 0.015: 0.985
  by possibility level (lowest to highest over the values at least that possible):
    π ≥ 0.9  r in [≈0.011388, ≈0.019292]  ≈0.980708 to ≈0.988612
    π ≥ 0.5  r in [≈0.006999, ≈0.027452]  ≈0.972548 to ≈0.993001
    all values  r in [0, 1]               0 to 1
```

Every rate from 0 to 1 has some possibility, so Haze adds a few levels close to 0, which keeps
the extreme rates from weighing on the result more than their possibility says. The ends of each
range are rounded outward and checked in exact arithmetic.

## Several parameters

With more than one parameter, Haze checks every combination of their values. The possibility of
a combination is the smallest possibility among its values. Four parameters with four values each
make 256 combinations, and each one is a separate model check, run in parallel across your
processor's cores.

Continuous parameters don't add combinations. They are searched together, one range of values per
level. When there is more than one parameter, the output also ranks them by how much the
result moves when each one is varied alone over its range, with the others at their most possible
values. [`proof_checkers.hz`](../examples/Gallery/proof_checkers.hz) is an example.

With more than six combinations, the output shows a summary and ranks the parameters by how much
each one moves the result on its own (see [Reading results](Reading-Results.md#results-by-parameter-value)).
That ranking tells you which estimate is worth improving first.

## Parameters and evidence

An `observe` after a fuzzy parameter takes the evidence into account for every value. Values that
make the evidence impossible are ruled out. If the evidence rules out every value of possibility
1, the remaining possibilities are scaled up so that the most possible value counts as fully
possible; [Design and semantics](Design.md#fuzzy-parameters) gives the details.

An observation can't depend on a continuous parameter yet. For counts of failures, use
`likelihood` instead.

## Tests

`#tests` lists runs at the most possible parameter values, since those are the runs you most
expect. Its statistical test is sized for the possible values under which the property fails
most often, so that correct code passes it even in the pessimistic case.

## Fuzzy sets are something else

Haze also has fuzzy sets, for requirements without a sharp cutoff, such as "the request is fast".
A fuzzy set is a function that returns a degree of truth (`Deg`), and `is` tests membership:

```haze
def fast(ms : Num) : Deg := ramp_down(ms, 200, 1000)
```

Fuzzy sets describe vague requirements, while fuzzy parameters describe uncertain quantities. A
model can use both. The `logic` setting changes how `and`, `or` and `not` combine degrees of
truth; it doesn't change how parameters are combined.
