# Benchmarks

These models exercise the parts of the checker that take the most time, each in a different way:

- `fuzzy_grid.hz` has 81 parameter assignments of a small queue, so its assignments can run in
  parallel.
- `timers.hz` has few states but 4,096 random combinations in every step, so the work inside a
  step has to be split.
- `random_walk.hz` has a frontier of a few thousand configurations.
- `long_horizon.hz` runs a small chain for 2,000 steps, which can't be parallelized and spends
  most of its time on exact arithmetic with large numbers.

Build Haze, then run `python scripts/bench.py` to time them. It prints the fastest of three
runs of each model.
