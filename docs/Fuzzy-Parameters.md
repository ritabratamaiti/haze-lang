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
it's been as low as 1%, and it could reach 5% on a bad day; 10% would be surprising". Here
2% gets possibility 1. The other rates get less support, with 10% getting the least:

```haze
param loss : Num ~= {0.01: 0.6, 0.02: 1, 0.05: 0.5, 0.1: 0.2}
```

Both the rates and their possibilities matter. A 10% loss rate with possibility 0.2 can
affect the worst case in the bottom fifth of the possibility range. Give it possibility
1 and it can affect the worst case at every level.

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

A witness explains a particular run at a particular parameter value. The probability bound
is decided by the full calculation, not by that one run.

## Continuous parameters

If the loss rate is "around 2%, somewhere between 1% and 5%", it could be 3.7%. A triangle
covers that rate without requiring it to appear in a list. Continuous parameter declarations
are available on the `continuous-params` development branch, not in v0.1.0.

```haze
param p : Num ~= tri(0.01, 0.02, 0.05)
```

`tri(a, m, b)` gives `m` possibility 1 and falls linearly to 0 at `a` and `b`. `trap(a, b, c, d)`
is fully possible from `b` to `c` instead of at one point. In either case the same value of the
parameter applies to every attempt; it isn't drawn again when the client retries.

### Checking a delivery target

The client sends until it succeeds. Check delivery after three steps, with a belief target
of 0.999945. To run this example locally, save it as `delivery.hz` in a checkout of this
[development branch](Installation.md#building-from-source) and run `lake exe haze delivery.hz`:

```haze
param p : Num ~= tri(0.01, 0.02, 0.05)

system Send {
  var delivered : Bool := false
  step { if not delivered { delivered := not flip(p) } }
}

levels 10
#prob Send |= after[3] delivered

levels 50
claim delivered_enough : Send |= after[3] delivered with prob >= 0.999945
```

| Levels | Lower bound on belief | Upper bound on belief | Is 0.999945 certified? |
|---:|---:|---:|---|
| 10 | ≈0.999943 | ≈0.999955 | No: the target falls inside the bracket. |
| 50 | ≈0.999948 | ≈0.999950 | Yes: the lower bound clears the target. |

These are two bounds on **belief**, not the belief/plausibility pair. In the playground,
open **Text** to see both bounds. The displayed decimals are rounded.
At a fixed loss rate the chance of delivery is `1 - p³`. At possibility level
`α`, the highest loss rate is `0.05 - 0.03α`, which gives the lowest delivery probability.
Integrating `1 - (0.05 - 0.03α)³` from 0 to 1 gives the exact belief, 0.99994925.

If you move the claim above `levels 50`, Haze prints `bound fails`: the 10-level lower
bound didn't establish the requirement. That's not evidence that the exact belief missed
it. Both runs describe the same client. Nor does the 50-level result mean every single
rate meets the target: at 4% loss, delivery is 0.999936.

Haze bounds the result over the whole range at each level, not just at sampled points. It
can split a range further; for example, a comparison with a constant gives a place to split.
If the search budget is exhausted or the levels are coarse, the bounds may remain wide.
An accepted theorem covers every possible parameter value. [Design and semantics](Design.md#continuous-parameters)
describes the interval search and how the level bounds are combined.

## Parameters from data

If you have counts, Haze can turn them into a parameter. After 3 failures in 200 calls:

```haze
param r : Num ~= likelihood(3, 200)
```

The possibility of each failure rate is its binomial likelihood, `r³ (1 - r)¹⁹⁷`, divided by
the likelihood at the observed rate `3/200`. So `3/200` has possibility one. A cut at 0.5
contains the rates whose likelihood is at least half the maximum. That level is neither a
posterior probability nor a confidence level.

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

For these counts every rate strictly between zero and one has positive likelihood; the two
endpoints have zero. Haze includes the full closed interval in its outer bound and adds
levels near zero for the tails. The ends of each range are rounded outward and checked in
exact arithmetic.

The [retry-budget model](../examples/Gallery/learned_rates.hz) combines 12 timeouts in 4,000
calls with a triangular estimate for the chance that a retry hits the same overloaded replica.
At the two best-supported rates, three attempts deliver with probability about 0.999726.
Across the ranges, the three-attempt belief bracket straddles the 0.999 requirement
(about 0.998931 to 0.999134). Five attempts certify it: the lower bound is about 0.999712.
The [recorded output](../examples/Gallery/learned_rates.expected) shows both checks.

## Several parameters

For listed parameters, Haze checks every relevant combination. The possibility of a
combination is the smallest possibility among its values. Four parameters with four values
each make 256 combinations before dropping any irrelevant to the query.

Continuous parameters are searched together as a box with one range per parameter at each
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

`#tests` generates runs at a most possible parameter assignment. Its statistical test uses
the largest failure rate among the discrete assignments checked, with each continuous rate
held at its reported representative value. It does not certify the test size over a continuous
range. Use a probability claim or `#prob` for a bound over that range.

## Fuzzy sets are something else

Haze also has fuzzy sets, for requirements without a sharp cutoff, such as "the request is fast".
A fuzzy set is a function that returns a degree of truth (`Deg`), and `is` tests membership:

```haze
def fast(ms : Num) : Deg := ramp_down(ms, 200, 1000)
```

Fuzzy sets describe vague requirements, while fuzzy parameters describe uncertain quantities. A
model can use both. The `logic` setting changes how `and`, `or` and `not` combine degrees of
truth; it doesn't change how parameters are combined.
