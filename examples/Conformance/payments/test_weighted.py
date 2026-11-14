"""
Probability-weighted testing of payments_client.py, using the tests that Haze generates from
payments.hz with `#tests`.

Ordinary test suites are measured by how much code they run. This one is measured by how much of
the system's probable behavior it covers. Haze lists the runs of the model in order of
probability, with the random decisions behind each one, and this script replays each run against
the real client with a scripted network. Its coverage is the total probability of the runs that
pass.

It runs in three steps:

1. Replay the most likely runs, which `#tests[6]` lists, and the failing runs, which
   `#tests[3] Client |= after[6] acked` adds. The implementation must end in exactly the state the
   model predicts on each run.
2. Run the statistical test that Haze sized for the delivery requirement. A payment can fail by
   design when every message is lost, so a single run proves nothing. Haze computes how many runs
   to make and how many failures to allow, so that a correct client fails the test less than once
   in a million while a client that fails twice as often is caught.
3. Repeat both against mutants of the client, and report the probability of the behavior on which
   each mutant was caught.

Run it from the repository root after `lake build`:

    python examples/Conformance/payments/test_weighted.py
"""
from fractions import Fraction
import json, os, pathlib, random, subprocess, sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent.parent
HAZE = ROOT / ".lake" / "build" / "bin" / ("haze.exe" if os.name == "nt" else "haze")
sys.path.insert(0, str(HERE))
import payments_client as impl  # noqa: E402


def generated_tests():
    proc = subprocess.run([str(HAZE), "--json", str(HERE / "payments.hz")],
                          capture_output=True, text=True, encoding="utf-8")
    records = [json.loads(line) for line in proc.stdout.splitlines() if line.strip()]
    return [r for r in records if r.get("kind") == "tests"]


class NeedMore(Exception):
    pass


class ScriptedNetwork(impl.Network):
    def __init__(self, script):
        self.script, self.used = script, 0

    def lost(self):
        if self.used == len(self.script):
            raise NeedMore
        self.used += 1
        return self.script[self.used - 1]


class RandomNetwork(impl.Network):
    def __init__(self, loss, rng):
        self.loss, self.rng = loss, rng

    def lost(self):
        return self.rng.random() < self.loss


def replay(run, make_server):
    """Replays one generated run. Returns None if the implementation matches the model, or a
    description of the difference."""
    # the model's decisions, in the order the client consults the network
    script = [c["value"] for s in run["steps"] for c in s["choices"]
              if c["what"] in ("request_lost", "response_lost")]
    net = ScriptedNetwork(script)
    try:
        res = impl.pay(net, make_server(), key="order-42", amount=1999)
    except NeedMore:
        return "the client asked the network more often than the model does"
    if net.used != len(script):
        return "the client stopped before the model's run ended"
    final = run["steps"][-1]["state"] if run["steps"] else run["initial"]
    got = {"phase": res.status, "attempts": res.attempts, "charges": res.charges,
           "acked": res.acked, "latency": res.latency_ms}
    want = {k: (Fraction(v) if k in ("attempts", "charges", "latency") else v) for k, v in final.items()}
    diffs = [f"{k} {got[k]} (model {want[k]})" for k in want if got[k] != want[k]]
    return ", ".join(diffs) or None


def unique_runs(tests):
    """The generated runs, without the ones that several #tests queries share."""
    seen = {}
    for rec in tests:
        for run in rec["runs"]:
            key = json.dumps([s["choices"] for s in run["steps"]], sort_keys=True)
            seen.setdefault(key, run)
    return list(seen.values())


def replay_all(tests, make_server):
    """Replays every generated run. Returns the probability of the runs that pass and those that
    don't, and the most likely run that caught a difference."""
    passed, failed, first = Fraction(0), Fraction(0), None
    for run in unique_runs(tests):
            p = Fraction(run["probability"])
            diff = replay(run, make_server)
            if diff is None:
                passed += p
            else:
                failed += p
                if first is None or p > first[0]:
                    first = (p, diff)
    return passed, failed, first


def statistical(plan, make_server, seed=1):
    """Runs the real client `plan["runs"]` times on a random network and counts failed payments."""
    loss = float(Fraction(plan["parameters"]["loss"]))
    rng = random.Random(seed)
    failures = 0
    for _ in range(plan["runs"]):
        res = impl.pay(RandomNetwork(loss, rng), make_server(), key="order-42", amount=1999)
        failures += not res.acked
    return failures, failures <= plan["allowed_failures"]


class NonIdempotentServer(impl.PaymentServer):
    def __init__(self):
        super().__init__(charges=[])

    def charge(self, key, amount):
        self.charges.append(amount)
        return "receipt"


MUTANTS = {
    "server without idempotency keys": (None, None, NonIdempotentServer),
    "timeout of 900 ms instead of 1000 ms": ("TIMEOUT_MS", 900, impl.PaymentServer),
    "one retry too many (MAX_ATTEMPTS = 4)": ("MAX_ATTEMPTS", 4, impl.PaymentServer),
    "one retry too few (MAX_ATTEMPTS = 2)": ("MAX_ATTEMPTS", 2, impl.PaymentServer),
}


def main():
    tests = generated_tests()
    suite = [r for r in tests if all(run["suite"] for run in r["runs"])]
    plan = next(r["statistical"] for r in tests if r["statistical"])
    n_runs = len(unique_runs(tests))

    print(f"1. Replaying the {n_runs} runs that Haze generated")
    passed, failed, first = replay_all(tests, impl.PaymentServer)
    covered = max(Fraction(r["covered"]) for r in suite)
    print(f"  the most likely runs cover {float(covered):.6f} of the probability")
    print(f"  the runs that pass have total probability {float(passed):.6f}; the runs that don't, {float(failed):.6f}")
    ok = failed == 0

    print("2. Statistical test of the delivery requirement")
    failures, passes = statistical(plan, impl.PaymentServer)
    print(f"  {plan['runs']} payments at loss {Fraction(plan['parameters']['loss'])}: "
          f"{failures} failed, {plan['allowed_failures']} allowed -> {'pass' if passes else 'FAIL'}")
    print(f"  (a correct client fails this test with probability {float(plan['false_alarm']):.2e})")
    ok &= passes

    print("3. Mutants")
    caught_all = True
    for name, (attr, value, server) in MUTANTS.items():
        saved = getattr(impl, attr) if attr else None
        if attr:
            setattr(impl, attr, value)
        try:
            _, m_failed, m_first = replay_all(tests, server)
            failures, passes = statistical(plan, server)
        finally:
            if attr:
                setattr(impl, attr, saved)
        if m_first:
            how = f"by a replayed run of probability {float(m_first[0]):.3g} ({m_first[1]})"
        elif not passes:
            how = f"by the statistical test ({failures} failures, {plan['allowed_failures']} allowed)"
        else:
            how = None
        caught_all &= how is not None
        print(f"  mutant {'caught' if how else 'MISSED'}  {name}" + (f"\n         {how}" if how else ""))

    if ok and caught_all:
        print("PASS")
        return 0
    print("FAIL")
    return 1


if __name__ == "__main__":
    sys.exit(main())
