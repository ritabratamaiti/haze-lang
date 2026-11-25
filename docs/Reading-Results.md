# Reading results

Haze prints one message for each declaration it checks. A result has a probability or a pair of
bounds, a word that describes it, and for claims and theorems, a verdict and sometimes a
counterexample. The sections below go through each part, with output from the examples in the
repository.

## Messages

Every message starts with a location and a severity:

```
client.hz:16:1: info: theorem at_most_three
```

The location is the file, line and column of the declaration. The severity is `info` for results
and accepted declarations, and `error` for rejected declarations and mistakes in the file. Haze
carries on after an error, so one rejected theorem doesn't hide the results after it. `haze`
exits with status 1 if there was any error, and 0 otherwise.

## Probabilities, belief and plausibility

When a result doesn't depend on any fuzzy parameter, Haze prints a single probability:

```
  probability 0.999
```

When it does, Haze prints two numbers:

```
  belief 0.9969 · plausibility 0.999438 (=15991/16000)
```

The *belief* is how strongly what you know guarantees the property, and the *plausibility* is
how strongly it allows it. The belief is never larger than the plausibility. When they're equal,
Haze prints a single probability again. [Fuzzy parameters](Fuzzy-Parameters.md) explains how
they're computed.

The two numbers can also differ without fuzzy parameters, when some outcomes are unknown. That
happens when a recursive function runs out of fuel (`--fuel`), or when an unbounded property
stops exploring at its limit. An unknown outcome counts against the belief and for the
plausibility, so the true probability is always between the two.

## Exact numbers

All numbers in results are exact. A number with a short decimal expansion is printed as it is.
A longer one is rounded, marked with `≈`, and followed by the exact fraction when the fraction is
short:

```
  probability 0.666667 (=2/3)
  probability ≈0.492929 (=244/495)
  belief ≈0.998319 · plausibility ≈0.99997
```

Numbers below 0.001 are written in scientific notation, as in `≈1.37018e-8 (=1/72982849)`. In
`--json` output every number is an exact fraction, written as a string such as `"244/495"`.

## Claims and theorems

A claim or theorem prints its result, a word describing it, a line of statistics, and a verdict:

```
client.hz:15:1: info: claim usually_succeeds
  probability 0.999 · graded
  grade prob · 1 parameter assignment(s) · ≤1 states/step
  bound holds: belief ≥ 0.999
```

The word after the result is one of these:

| Word | Meaning |
|---|---|
| `proved` | The belief is 1, and the property doesn't involve chance or fuzzy parameters. |
| `holds with certainty` | The belief is 1, for a property that involves chance or fuzzy parameters. |
| `refuted` | The plausibility is 0, and the property doesn't involve chance or fuzzy parameters. |
| `fails with certainty` | The plausibility is 0, for a property that involves chance or fuzzy parameters. |
| `graded` | Anything in between. |

The statistics line gives the property's grade (see [Types and grades](Language-Reference.md#types-and-grades)),
how many combinations of fuzzy parameter values Haze checked, and the size of the problem: the
largest number of states it tracked at one step, or for a property without a bound, the number
of reachable states. The state count only includes the variables the property can depend on,
which is why it's sometimes smaller than you'd expect.

The verdict says whether the declaration was accepted:

| Verdict | When |
|---|---|
| `theorem accepted` | The belief is 1. |
| `theorem rejected: belief is …, not 1` | The belief is below 1. |
| `bound holds: belief ≥ q` | A `with prob >= q` bound, when the belief is at least `q`. |
| `bound fails: belief … < q` | The same bound, when the belief is below `q`. |
| `bound holds: plausibility ≤ q` | A `with prob <= q` bound, when the plausibility is at most `q`. |
| `bound fails: plausibility … > q` | The same bound, when the plausibility is above `q`. |

A claim without a bound is always accepted. It only reports the result.

## Results by parameter value

When a result depends on fuzzy parameters, a table shows the result for each combination of
values, with its possibility `π`:

```
  by fuzzy parameter (π = possibility):
    fail = 0.05  π 0.5     0.999875
    fail = 0.1   π 1       0.999
    fail = 0.2   π 0.3     0.992
```

With more than six combinations, Haze prints a summary instead. It shows the combinations with the
lowest and highest results and the most possible one, and then varies each parameter on its own,
keeping the others at their most possible values:

```
  by fuzzy parameter (π = possibility), 9 assignments:
    lowest          a1 = 0.1, a2 = 0.4  π 0.5     0.04
    highest         a1 = 0.3, a2 = 0.6  π 0.5     0.18
    most possible   a1 = 0.2, a2 = 0.5  π 1       0.1
  what moves the result most (each parameter varied alone, the others at their most possible values):
    a1: 0.1 → 0.05, 0.2 → 0.1, 0.3 → 0.15  (range 0.1)
    a2: 0.4 → 0.08, 0.5 → 0.1, 0.6 → 0.12  (range 0.04)
```

The parameters are listed in order of how much they move the result. Here `a1` matters more than
`a2`, so a better estimate of `a1` would narrow the answer the most. Parameters the property
can't depend on are left out.

## Counterexamples

When a theorem or a `with prob >=` bound is rejected, Haze shows an example of the property
failing:

```
payments_retry.hz:97:1: error: theorem naive_single_charge
  ...
  counterexample at step 3 (path mass ≈9.801e-5 (=9801/100000000), degree 0):
    parameters: loss = 0.01
    state: phase = Waiting, attempts = 2, charges = 2
```

The step is the first one at which the property fails on this run. The *path mass* is the
probability of the run up to that step. The *degree* is how true the property is on the run: 0
for a true-or-false property that fails, or a number between 0 and 1 for a fuzzy property. For
an `eventually` property, the degree is replaced by "never reached on this path". The lines below
give the values of the fuzzy parameters, the random inputs, and the state. Variables that can't
affect the property are left out.

Haze picks the example from a parameter value that breaks the bound, so the example is relevant
to the failure. It's one run among possibly many. It isn't necessarily the most likely failing
run; `#tests` lists those in order.

For a property with `forall` at the front, a further line gives values that make the property
false:

```
    falsified by x = 7
```

When a `with prob <=` bound fails, the bound was meant to rule something out, so Haze shows a
run where it happens instead:

```
  bound fails: plausibility 1 > 0.5
  a run where it happens, at step 3 (path mass 1):
    state: n = 3
```

For a property without a system, there are no steps, so Haze shows a *world*: one combination of
the random inputs, with its probability.

## Properties without a bound

Results for `always` and `eventually` without a bound, and for `#expect … steps until`, can carry
two notes:

```
  exploration stopped at 300 states; what follows the unexplored states counts as unknown (raise the limit with `explore N` or --states)
  components with more than 120 states were solved in floating point, and their bounds checked in exact arithmetic
```

The first means the system had more reachable states than the limit, so the result is an
interval that contains the true value. Raising the limit narrows it when the unexplored states
are unlikely to be reached, as in a queue that's usually short. It can't help when they are
likely, as in a random walk that drifts away.

The second identifies a component that crossed the 120-state threshold for the certified
solver. Floating point proposes lower and upper bounds; rational arithmetic checks them. The
reported interval contains the true value.

An expected number of steps can be infinite:

```
  expected steps ∞
  with positive probability the property never holds, so the expectation is infinite
```

## Tests

`#tests` output is described in [Probability-weighted tests](Language-Reference.md#probability-weighted-tests),
and [Testing real code](../examples/Conformance/README.md) shows how to use it.

## Machine-readable output

`haze --json` prints the same results as one JSON object per line, with exact fractions. The
fields are listed in [Command line and JSON](Command-Line.md#json-output).
