# Contributing to Haze

Bug reports, examples and fixes are welcome. For anything larger than a small fix, open an issue
first so we can agree on the approach. The [language reference](docs/Language-Reference.md) and
[Design and semantics](docs/Design.md) describe how the parts fit together.

## Before you open a pull request

Please open an issue first and describe the problem you want to solve or the feature you'd
like to add. If you're proposing a new feature, prefix the title with `RFC:` (request for
comments). For a language feature, include a small model that shows why it's needed and what
its output should be; that usually makes the discussion much shorter.

Changes to the kernel need extra care. The files in `Haze/Kernel` are the part of Haze that has
to be trusted, so a change there needs a clear reason, a precise description of how it changes
the meaning of programs, and tests whose expected results can be checked by hand. If a change
to the elaborator or the front end is enough, prefer that.

## What a pull request should include

Every change in behavior should come with a golden test in `tests` or `examples`, and
`lake test` should pass. Only regenerate expected output with `lake exe hazetest --update`, and
look through the differences in the `.expected` files before you commit them. The
[test suite README](tests/README.md) has the details.

`lake build` also checks the theorems in `Haze/Theory.lean`. If you change a definition that one
of them is about, update the proof rather than adding `sorry`.

If you change the language, update the language reference and add an entry to
[`RELEASES.md`](RELEASES.md). Documentation follows the
[Lean documentation style guide](https://github.com/leanprover/lean4/blob/master/doc/style.md):
US English, the active voice, and docstrings that make sense on their own when shown in an
editor hover. Each Lean file starts with a copyright header and a module docstring
(`/-! … -/`) describing what it contains, and public definitions have docstrings.

Commit messages should start with a short summary line, followed by what changed and why.

## License

Haze is available under the [Functional Source License 1.1](LICENSE.md) (FSL-1.1-ALv2). Before
a pull request can be merged, its author needs to agree to the
[contributor license agreement](CLA.md), by adding a comment to the pull request that says "I
agree to the Haze contributor license agreement". The agreement lets Haze be offered under its
current license, under the Apache License 2.0 when each release converts, and under commercial
licenses, while you keep the copyright to your work.
