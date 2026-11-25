# Haze in CI and scripts

`haze` is meant to run unattended. Its exit status says whether every declaration was accepted,
and `--json` prints results in a form other programs can read.

## Exit status

`haze` exits with status 0 when every declaration in every file is accepted, 1 when any
declaration is rejected, and 2 when it can't run at all, for example because a file is missing or
an option is wrong. A rejected declaration is a failed theorem, a claim whose bound doesn't hold,
an impossible observation, or a mistake such as a type error.

Queries such as `#prob` and claims without a bound never fail. To make a CI job fail on a
result, write it as a `theorem` or as a claim with a `with prob` bound:

```haze
claim delivered : Client |= eventually[6] phase == Done with prob >= 0.99
theorem single_charge : Client |= always[6] charges <= 1
```

## GitHub Actions

The Haze repository is also a GitHub Action. It downloads a release, checks it against the
release's checksums, puts `haze` on the `PATH`, and optionally checks some files:

```yaml
jobs:
  models:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: ritabratamaiti/haze-lang@v0.1.0
        with:
          files: models/*.hz
```

The step fails if `haze` exits with a nonzero status. The action's inputs are:

| Input | Default | Meaning |
|---|---|---|
| `files` | none | Files to check, separated by spaces. Glob patterns such as `models/*.hz` work. Without `files`, the action only installs `haze`, for later steps to use. |
| `args` | none | Extra options for `haze`, such as `--json` or `--states 5000`. |
| `version` | `latest` | The release to install, such as `v0.1.0`. |
| `token` | `github.token` | The token used to download the release. |

It sets one output, `version`, the release it installed. It runs on Linux and Windows runners on
x86-64, and on macOS runners on Apple silicon.

## Other CI systems

Elsewhere, use the Docker image or the install script. With Docker:

```sh
docker run --rm -v "$PWD:/work" ghcr.io/ritabratamaiti/haze-lang models/payments.hz
```

With the install script, on a Linux or macOS runner:

```sh
curl -sSfL https://raw.githubusercontent.com/ritabratamaiti/haze-lang/main/install.sh | sh
~/.local/bin/haze models/*.hz
```

Set `HAZE_VERSION` to pin a release, so that a new version of Haze can't change your build.

## Reading results from a program

`haze --json` prints one JSON object per line, one for each message. Every record has `file`,
`line`, `column`, `severity` and `message` fields, and records for results also have a `kind`
and fields that depend on it. Numbers are exact fractions written as strings, such as `"999/1000"`,
so they can be read without rounding.

This Python script runs Haze on the model from [Your first model](Getting-Started.md) and checks
one claim:

```python
import json
import subprocess
from fractions import Fraction

out = subprocess.run(["haze", "--json", "client.hz"], capture_output=True, text=True).stdout
for line in out.splitlines():
    record = json.loads(line)
    if record.get("kind") == "claim" and record["name"] == "usually_succeeds":
        belief = Fraction(record["belief"])
        print(f"usually_succeeds: belief {belief} = {float(belief):.6f}")
        assert belief >= Fraction(999, 1000)
```

```
usually_succeeds: belief 999/1000 = 0.999000
```

The full list of fields is in [Command line and JSON](Command-Line.md#json-output).
[Testing real code](../examples/Conformance/README.md) uses this output to check a Python
implementation against its model.

## Keeping checks fast

Checking time depends on how many configurations the property distinguishes, how many parameter
assignments it uses and the size of the rational numbers involved. If a model gets slow:

- Check the `states/step` and `reachable states` figures in the output. They show which property
  is expensive.
- Remove state that the property doesn't need, such as a counter with no upper limit. Haze already
  ignores variables that can't affect the property, but it can't ignore ones that do.
- Lower the horizon of `always[k]` and `eventually[k]`, or set a smaller `explore` limit for
  properties without a bound. A smaller limit gives a wider interval rather than a wrong answer.
- Check fewer combinations of fuzzy parameter values. The cost grows with the number of
  combinations.
