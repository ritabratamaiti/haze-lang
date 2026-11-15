# Security policy

## Supported versions

Haze is at version 0.1. Security fixes go into the latest release only.

## Reporting a vulnerability

Please don't report security problems in public issues. Use GitHub's
[private vulnerability reporting](https://github.com/ritabratamaiti/haze-lang/security/advisories/new)
instead, or email ritabratamaiti@gmail.com. Include the version (`haze --version`), what you
did, and what happened. You should get a reply within a week.

These are the parts of Haze where a problem would be a security issue:

- **Installing.** `install.sh`, `install.ps1` and the GitHub Action download release archives and
  check them against `SHA256SUMS`. A way to make them install something that doesn't match the
  published checksums is a vulnerability.
- **Releases.** The archives are built by GitHub Actions and carry build provenance
  attestations. A gap in that chain is worth reporting.
- **The website.** The playground runs code from share links in a web worker. A way for a link
  to run JavaScript in the page, or to read anything outside the worker, is a vulnerability.
- **Checking files.** `haze` reads `.hz` files and doesn't run them as programs: it has no file,
  network or process access in the language. A file that makes `haze` read or write other files,
  or run code, is a vulnerability.

A model that makes `haze` use a lot of memory or time isn't a security issue on its own, since
models are meant to be checked exhaustively. A wrong answer is a bug rather than a vulnerability;
please report it as an [issue](https://github.com/ritabratamaiti/haze-lang/issues/new?template=bug_report.md).
