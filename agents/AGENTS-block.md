## Haze models

This project uses [Haze](https://haze-lang.pages.dev) to check code that has to cope with
failures some of the time (retries, timeouts, failover, replication). Models are `.hz` files,
and code that a model describes carries a comment containing `haze: <path to model>.hz`.

- **When you change code with a `haze:` comment**, check whether the change alters what the
  model describes. If it does, update the model, run `haze <model>.hz`, and report the result.
- **Run** `haze <model>.hz` (or `haze --json <model>.hz` to parse the output). Exit status 0
  means every claim and theorem was accepted, and 1 means something was rejected.
- **Report results to the user** as Haze printed them: each claim's result and verdict, what a
  counterexample means in the code, and which uncertain estimate matters most.
- **Never** change a bound, a rate, a possibility or a horizon to make a check pass, never
  delete a failing claim, and never invent a failure rate. Ask the user for the numbers, use a
  range (`tri(low, likely, high)`) when they only know it roughly, or `likelihood(failures,
  attempts)` when there are counts.
- **New models** go in `models/`. The language is described at
  https://haze-lang.pages.dev/docs/reference/, and `haze agent links --check` checks every
  model the code links to.
