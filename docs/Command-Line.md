# Command line and JSON

The `haze` command checks Haze files and prints a message for each declaration. To learn what
the text output means, see [Reading results](Reading-Results.md).

## Running haze

`haze [--fuel N] [--states N] [--json] FILE.hz...` checks each file and prints its messages.
`--fuel N` sets how deeply function calls can nest before an outcome counts as unknown (the
default is 1000), `--states N` sets the default for `explore`, `--version` prints the version, and
`--json` prints one JSON record per message instead of text, as described below. The exit
status is 0 if every declaration was accepted and 1 otherwise, which makes `haze` easy to run in
continuous integration.

`haze agent` sets up coding agents to use Haze: `install`, `uninstall` and `status` manage the
skills and hooks, `links` lists the `haze:` comments that link code to models (`--check` also
checks the models), and `hook` is what the hooks run. [Coding agents](Agents.md) describes them.

## JSON output

With `--json`, each message is printed as a JSON object on its own line. Every record has the
fields `file`, `line`, `column`, `severity` and `message` (the text `haze` would otherwise
print). Records that carry a result also have a `kind` and the fields below:

| `kind` | Fields |
|---|---|
| `theorem`, `claim` | `name`, `accepted`, `grade`, `belief`, `plausibility`, `branches`, `counterexample` |
| `prob` | `query`, `belief`, `plausibility`, `branches` |
| `expect` | `query`, `lower`, `upper`, `branches`, each with an `expectation` (or, for `steps until`, a `lower` and `upper`, which are `null` when infinite) |
| `eval` | `query`, `branches`, each with a `distribution` of `value` and `probability` pairs |
| `check` | `query`, `type`, `grade` |
| `observe` | `query`, `evidence`, the probability of the evidence for each parameter assignment |
| `tests` | `query`, `parameters`, `covered`, `complete`, `failure_probability`, `runs`, `statistical` |

For `tests`, each run has its `probability`, `suite` (whether it's one of the `n` most likely),
`degree`, `passes`, `inputs`, `initial` state, and `steps`. Each step has its number, the
`choices` made in it (each with `what` and `value`) and the `state` after it. `statistical` has
the `parameters` it was sized for, `failure_rate`, `runs`, `allowed_failures`, `false_alarm` and
`power`, or is `null` when the property never fails.

`branches` lists the result for each assignment of the fuzzy parameters, with its `parameters`
and `possibility`; for properties it has the `lower` and `upper` bounds. A `counterexample` has
the `step`, `parameters`, `inputs` and `state` of the example described under
[Claims and theorems](Language-Reference.md#claims-and-theorems), or is `null`.

Numbers stay exact: probabilities and numeric values are strings such as `"2/3"`, which
exact-fraction libraries (Python's `fractions.Fraction`, for example) read directly. Booleans
are JSON Booleans, enumeration values are their names, and an unknown outcome is `null`.
