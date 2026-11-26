# Checking Haze against PRISM and Storm

We checked 26 properties across 13 discrete-time model instances from
[PRISM](https://www.prismmodelchecker.org/). Haze returned the exact reference fraction in 21
cases. In the other five it returned certified intervals containing the reference value,
each narrower than 10⁻¹¹ relative to that value. The comparison uses the exact engines of
[Storm](https://www.stormchecker.org/) and PRISM, as described below.

## The models

The models are PRISM's own examples, translated by
[`bench/prism/gen.py`](../bench/prism/gen.py). The translations are in
[`bench/prism/models`](../bench/prism/models).

- **Knuth and Yao's die** (`simple/dice`): the probability of rolling a 6, and the expected
  number of coin flips per roll.
- **Herman's self-stabilizing ring** (`dtmcs/herman`) with 3 to 9 processes: the probability of
  reaching a stable state within 10 steps, and the expected number of steps to get there. PRISM's
  model starts in every state at once; all the tools were given the state where every process
  holds a token instead.
- **Itai and Rodeh's synchronous leader election** (`dtmcs/leader_sync`) with 3 to 6 processes,
  each choosing from 2 or 4 values: the probability of electing a leader in the first round, and
  the expected number of rounds. The Haze model follows PRISM's step for step, with a pick, N - 1
  reads and a decision in each round.

The tools were Haze 0.1.0, PRISM 4.11 with its default engine and with `-exact`, and Storm 2.0.0
with its default engine and with `--exact`.

## Results

The exact value is Storm's `--exact` result, or PRISM's `-exact` result where Storm's isn't
available. The error columns give the relative difference between it and the default engines of
PRISM and Storm.

| Model | Property | Exact value | Haze | PRISM error | Storm error |
|---|---|---|---|---|---|
| Knuth-Yao die | probability of a 6 | 1/6 | 1/6 (same) | 1e-06 | 2e-10 |
| Knuth-Yao die | expected coin flips | 11/3 | 11/3 (same) | 4e-07 | 9e-11 |
| Herman N = 3 | stable within 10 steps | 1048575/1048576 | 1048575/1048576 (same) | 0 | 3e-11 |
| Herman N = 3 | expected steps to stabilize | 4/3 | 4/3 (same) | 4e-08 | 3e-10 |
| Herman N = 5 | stable within 10 steps | ≈0.9855737686 | ≈0.9855737686 (same) | 0 | 2e-11 |
| Herman N = 5 | expected steps to stabilize | 44/15 | 44/15 (same) | 1e-06 | 5e-10 |
| Herman N = 7 | stable within 10 steps | ≈0.875709787 | ≈0.875709787 (same) | 0 | 6e-11 |
| Herman N = 7 | expected steps to stabilize | 130472/23751 | 130472/23751 (same) | 4e-06 | 1e-08 |
| Herman N = 9 | stable within 10 steps | ≈0.7083375943 | ≈0.7083375943 (same) | 5e-16 | 4e-11 |
| Herman N = 9 | expected steps to stabilize | ≈8.921607607 | 8.921607607, certified to ±1e-12 | 6e-06 | 6e-09 |
| Leader election N = 3, K = 2 | leader in the first round | 3/4 | 3/4 (same) | 0 | 0 |
| Leader election N = 3, K = 2 | expected rounds | 4/3 | 4/3 (same) | 2e-07 | 3e-10 |
| Leader election N = 3, K = 4 | leader in the first round | 15/16 | 15/16 (same) | 0 | 0 |
| Leader election N = 3, K = 4 | expected rounds | 16/15 | 16/15 (same) | 6e-08 | 3e-10 |
| Leader election N = 4, K = 2 | leader in the first round | 1/2 | 1/2 (same) | 0 | 0 |
| Leader election N = 4, K = 2 | expected rounds | 2 | 2 (same) | 1e-06 | 0 |
| Leader election N = 4, K = 4 | leader in the first round | 27/32 | 27/32 (same) | 0 | 0 |
| Leader election N = 4, K = 4 | expected rounds | 32/27 | 1.185185185, certified to ±4e-13 | 6e-08 | 2e-10 |
| Leader election N = 5, K = 2 | leader in the first round | 5/16 | 5/16 (same) | 0 | 0 |
| Leader election N = 5, K = 2 | expected rounds | 16/5 | 16/5 (same) | 2e-06 | 0 |
| Leader election N = 5, K = 4 | leader in the first round | 225/256 | 225/256 (same) | 0 | 0 |
| Leader election N = 5, K = 4 | expected rounds | 256/225 | 1.137777778, certified to ±3e-13 | 5e-08 | 2e-10 |
| Leader election N = 6, K = 2 | leader in the first round | 3/16 | 3/16 (same) | 0 | 0 |
| Leader election N = 6, K = 2 | expected rounds | 16/3 | 5.333333333, certified to ±4e-12 | 4e-06 | 6e-11 |
| Leader election N = 6, K = 4 | leader in the first round | 429/512 | 429/512 (same) | 0 | 0 |
| Leader election N = 6, K = 4 | expected rounds | 512/429 | 1.193473193, certified to ±4e-13 | 8e-08 | 4e-10 |

The five intervals come from unbounded expected-time queries on Herman's nine-process ring and
the larger leader elections. When a strongly connected component has more than 120 states, Haze
uses floating point to propose bounds and checks them in rational arithmetic. For example, the
six-process leader election with four values takes exactly 512/429 rounds in expectation; the
last row shows Haze's interval around that value.

The error columns compare *printed default-mode answers* with the exact reference, so both
solver settings and output precision matter. PRISM 4.11 uses a default relative convergence
tolerance of 10⁻⁶; this is a stopping criterion, not a guarantee of relative error. Storm 2.0.0
prints ten significant digits by default. PRISM's `-exact` engine in this benchmark does not
handle step-bounded properties such as `F<=10`.

These runs compare numerical answers, not throughput, memory use or maximum model size. The
[language reference](Language-Reference.md#limits) gives Haze's exploration budgets;
[How Haze compares](Comparison.md#prism-and-storm) describes the model types and results.

## Reproducing

On Linux, with Java for PRISM and Docker for Storm:

```sh
python3 bench/prism/gen.py
docker run -d --name storm -v ~/hazebench/work:/work movesrwth/storm:stable sleep infinity
python3 bench/prism/run.py path/to/haze path/to/prism-4.11-linux64-x86 --storm storm
python3 bench/prism/summarize.py
```

`run.py` writes [`bench/prism/results.json`](../bench/prism/results.json), the raw results behind
the table.
