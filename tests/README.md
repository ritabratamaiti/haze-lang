# Test Suite

This directory contains the tests of Haze. Together with [`examples`](../examples), it forms
a suite of golden tests.

Every `.hz` file in `tests` and `examples`, including subdirectories, is a test. The test
driver, [`HazeTest.lean`](../HazeTest.lean), checks each file and compares its messages with
the `.expected` file next to it. Line endings and surrounding whitespace are ignored. When the
output differs, the driver prints the first line that doesn't match.

## Running the Tests

* To run all tests, run `lake test`.
* After a change that is intended to alter the output, regenerate the expected files with
  `lake exe hazetest --update`. Review the changes to the `.expected` files before committing
  them.
* To check a single file, run `lake exe haze tests/FILE.hz`.

## Files

- `basics.hz`: exact probabilities (the Monty Hall problem, Bayesian updates), crisp
  theorems, fuzzy parameters, stochastic conditionals, grade annotations, recursion that runs
  out of fuel, and a simple transition system.
- `fuzzy_logic.hz`: the connectives of the three fuzzy logics, membership functions, hedges,
  quantifiers over degrees, and fuzzy truth of random quantities.
- `kernel_errors.hz`: declarations that the elaborator or kernel must reject, and processing
  that continues correctly after each error.
- `parse_error.hz`: the report of a syntax error.
- `reference.hz`: the snippets from the [language reference](../docs/Language-Reference.md).

## Adding a Test

Add a `.hz` file to this directory, run `lake exe hazetest --update` to create its
`.expected` file, and check that the expected output is correct. Prefer results that can be
verified by hand, such as small exact probabilities.

## Independent Checks

[`scripts/verify_gallery.py`](../scripts/verify_gallery.py) recomputes every result of the
models in [`examples/Gallery`](../examples/Gallery) without using Haze, from closed-form
answers or with an exact step-by-step calculation in Python, and compares them with the
output of `haze`. Run it with `python scripts/verify_gallery.py` after `lake build`.

The sample in [`examples/Conformance`](../examples/Conformance) has its own test, which checks a
Python implementation against its Haze model.
