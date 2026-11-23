---
name: haze-check
description: Run Haze on a model, read the results, and report them to the user. Use it after writing or changing a `.hz` file, after changing code that a `haze:` comment links to a model, when a Haze hook reports a rejected claim, and when the user asks whether a reliability requirement holds.
haze_version: {{HAZE_VERSION}}
---

# Checking a Haze model

Haze's verdict belongs to the user. Your job is to run it, explain what it found in terms of the
user's code, and propose what to do. Don't change a requirement to make it pass.

## Run it

```bash
haze models/payments.hz          # readable output
haze --json models/payments.hz   # one JSON record per message, for you to parse
```

Exit status 0 means every claim and theorem was accepted, 1 means at least one was rejected or a
declaration had an error, and 2 means the arguments were wrong or a file couldn't be read. To
check every model linked from the code, run `haze agent links --check`.

Each JSON record has `file`, `line`, `column`, `severity` (`info` or `error`) and `message`,
plus fields that depend on `kind`:

- `claim` and `theorem`: `name`, `accepted`, `grade`, `belief`, `plausibility`, `branches`
  (results by parameter value) and `counterexample` (parameters, inputs and state, or null).
- `prob`: `belief` and `plausibility`.
- `expect`: `lower` and `upper` (null means infinite).
- `tests`: see the `haze-tests` skill.

Numbers are exact fractions written as strings, such as `"15991/16000"`.

## Read it

- **probability p**: no rate on this path is uncertain, and `p` is exact.
- **belief b · plausibility p**: some rate is only roughly known. The belief is how strongly
  what the user knows guarantees the property; the plausibility is how strongly it allows it.
  `with prob >= q` passes when the belief is at least `q`, and `with prob <= q` when the
  plausibility is at most `q`. A wide gap means the answer depends on the estimate.
- **The table by parameter value** (or by possibility level, for ranges) shows which values
  are responsible. **"what moves the result most"** ranks the estimates; better data on the
  first one narrows the answer most.
- **A counterexample** gives the parameter values, inputs, state and step where a claim
  breaks. For a `with prob <=` bound, it's a run where the bad outcome happens.
- **Notes.** "exploration stopped at N states" means unexplored states count as unknown; raise
  `explore` or bound the counters. Notes about possibility levels or cautious bounds mean the
  bounds are guaranteed but not as tight as they could be; `levels N` tightens the first. Notes
  about floating point mean large components were solved numerically and the bounds were then
  checked exactly; the result is still guaranteed.
- **holds with certainty, fails with certainty, graded** describe the result in words.

## Report it

Give the user a short report, in this order:

1. One line per claim or theorem: its name, the result, and accepted or rejected.
2. For anything rejected: what the counterexample means in the real code (which function, which
   branch, which failure), and the smallest change that would fix the design.
3. If there are uncertain rates: which estimate matters most, and what data would settle it.
4. Anything in the notes that changes how much to trust the numbers.

Keep numbers as Haze printed them. Don't round a belief up or describe a graded result as a pass.

## When a claim fails

Work out which of these it is, and say which:

- **The code has a bug the model reproduces.** Propose a fix to the code, update the model to
  match the fixed design, and run both again.
- **The model doesn't match the code.** Fix the model, and tell the user what was wrong with it.
- **The requirement can't be met with the rates the user gave.** Present the numbers and the
  options (a different design, better data, or a different requirement) and let the user choose.

## Hard rules

- Never change a bound, a possibility, a horizon, or a theorem into a claim, to make a check
  pass without the user's explicit agreement. If you propose such a change, say that it weakens
  the requirement.
- Never delete or comment out a failing claim or theorem.
- Report a rejected result before changing anything, then change only what the user agrees to.
- Never present a number from a rate you made up as a finding.
