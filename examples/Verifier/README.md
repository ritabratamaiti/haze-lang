# Haze as a grader

[`retry_policy.hz`](retry_policy.hz) is a small task with a fixed specification, and
[`grade.py`](grade.py) grades answers to it with Haze. It shows how a Haze model can serve as an
exact, automatic checker for an AI evaluation or an RL environment: the task author writes the
model and the requirements, the agent submits a decision, and Haze either accepts it or returns
the run that breaks it.

The task: a payment client sends a charge request and waits for the reply. Either message can be
lost, and the loss rate is about 1%, maybe 5%, at worst 10%. Choose how many attempts the client
makes and whether requests carry an idempotency key, so that payments go through at least 99.9% of
the time and no customer is ever charged twice.

```sh
python grade.py '{"max_attempts": 5, "idempotent": true}'
```

The answer replaces the two definitions marked "submission" in the model. The requirements below
them are part of the task, so an answer can't change what is checked. The verdict is JSON:

| Answer | Verdict |
|---|---|
| 5 attempts, idempotency keys | passes: delivered with belief ≈0.999923, never charged twice |
| 4 attempts, idempotency keys | passes, with less margin: belief ≈0.999582 |
| 3 attempts, idempotency keys | fails `delivered`: belief ≈0.997661. The counterexample is a run at a 10% loss rate where all three attempts fail. |
| 5 attempts, no idempotency keys | fails `never_charged_twice`. The counterexample is the classic bug: at step 3 the card has been charged twice, after a lost reply and a retry. |

Probabilities in the verdict are exact fractions, so two runs of the grader always agree, and a
pass can't come from a lucky simulation. A failing answer comes with a concrete counterexample,
which is useful feedback for an agent and a way to audit the grader itself. Answers that aren't
well formed get exit status 2 and an error message.

The grader checks the decision against the model, not against a real payment system. Whether
the model matches real code is a separate question; see [Testing real code](../Conformance/README.md).
