# Test Suite

Haze is tested with golden tests: each test is a Haze file, and its expected output is stored
next to it in a `.expected` file. Every `.hz` file in this directory and in
[`examples`](../examples), including subdirectories, is a test. The driver,
[`HazeTest.lean`](../HazeTest.lean), checks each file and compares its messages with the
expected output, ignoring line endings and surrounding whitespace. When they differ, it prints
the first line that doesn't match.

## Running the tests

Run `lake test` to run everything, or `lake exe haze tests/FILE.hz` to check a single file.

If you make a change that is meant to alter the output, regenerate the expected files with
`lake exe hazetest --update`, then read through the changes to the `.expected` files before
committing them. A test only protects you if someone has checked that its expected output is
right.

## What's here

- `basics.hz` covers the core features: exact probabilities (the Monty Hall problem, a Bayesian
  update), theorems over bounded ranges, fuzzy parameters, stochastic conditionals, grade
  annotations, recursion that runs out of fuel, and a simple transition system.
- `fuzzy_logic.hz` exercises the connectives of the three fuzzy logics, membership functions,
  hedges, quantifiers over degrees, and fuzzy truth of random quantities.
- `kernel_errors.hz` contains declarations that the elaborator or the kernel must reject, and
  checks that processing carries on correctly after each error.
- `parse_error.hz` checks how a syntax error is reported.
- `reference.hz` contains the snippets from the
  [language reference](../docs/Language-Reference.md), so the reference can't silently drift
  out of date.

## Adding a test

Add a `.hz` file here, run `lake exe hazetest --update` to create its `.expected` file, and check
that the expected output is correct. Results you can verify by hand, such as small exact
probabilities, make the best tests.

## Independent checks

Golden tests catch changes, but they can't tell whether the original answer was right. For the
models in [`examples/Gallery`](../examples/Gallery), [`scripts/verify_gallery.py`](../scripts/verify_gallery.py)
recomputes every result without Haze, from closed-form answers or an exact step-by-step
calculation in Python, and compares them with what `haze` prints. Run it with
`python scripts/verify_gallery.py` after `lake build`.

The sample in [`examples/Conformance`](../examples/Conformance) has its own test, which checks a
Python implementation against its Haze model.
