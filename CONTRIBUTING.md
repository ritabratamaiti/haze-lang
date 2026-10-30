External Contribution Guidelines
============

Thank you for your interest in Haze. These guidelines describe how to propose changes.

Helpful links
-------

* [Language Reference](docs/Language-Reference.md)
* [Design and Semantics](docs/Design.md)
* [Testing](tests/README.md)

Before You Submit a Pull Request (PR):
-------

**Start with an Issue**: Before submitting a PR, open an issue that describes the problem you
want to solve or the feature you want to add. Use the prefix `RFC:` (request for comments)
when you propose a new feature. For a language feature, include a small model that shows why
the feature is needed and what its output should be.

**Keep the Kernel Small**: The files in `Haze/Kernel` are the trusted part of Haze. Changes to
them need a clear reason, a precise description of the change in meaning, and tests whose
expected results can be checked by hand. Prefer changes to the elaborator or the front end
when they are enough.

**Understand the Project**: Read the language reference and the design document, and look at
existing issues and recent commits, so that your contribution fits the direction of the
project.

Writing the Pull Request
-------

**Tests**: Add or update golden tests in `tests` or `examples` for every change in behavior,
and run `lake test`. Regenerate expected output only with `lake exe hazetest --update`, and
review the differences before committing them.

**Theorems**: `lake build` checks the theorems in `Haze/Theory.lean`. If you change a
definition that a theorem is about, update the proof. Don't add `sorry`.

**Documentation**: Update the language reference for changes to the language, and add an
entry to [`RELEASES.md`](RELEASES.md). Documentation follows the
[Lean documentation style guide](https://github.com/leanprover/lean4/blob/master/doc/style.md):
US English, active voice and docstrings that make sense on their own in a hover.

**Source files**: Each Lean file starts with a copyright header and a module docstring
(`/-! … -/`) that describes the file and its main definitions. Public definitions have
docstrings.

**Commit messages**: Write a short summary line, followed by a description of what changed
and why.

License
-------

Haze is available under the [PolyForm Noncommercial License 1.0.0](LICENSE.md). By
contributing, you agree that your contribution is available under the same license.
