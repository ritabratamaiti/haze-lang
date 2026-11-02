"""
Conformance test: checks payments_client.py against its Haze specification, payments.hz.

The test follows the verification-guided development pattern (model, prove, then test the
implementation against the model):

1. Haze checks the specification. Every theorem and bound in payments.hz must be accepted.
2. Every possible pattern of lost messages is run through the real implementation, with
   the network injected. Each pattern has an exact probability, so the implementation's
   outcome distributions are computed exactly, for every loss rate in the specification.
3. These distributions must equal the ones that Haze computed from the model: exactly,
   with no statistical tolerance. The safety theorems are also checked on every run.
4. To show that the test can find bugs, it is run against mutants of the implementation,
   and each mutant must be caught.

Run it from the repository root after `lake build`:

    python conformance/payments/test_conformance.py
"""
from collections import defaultdict
from fractions import Fraction
import json, os, pathlib, subprocess, sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
HAZE = ROOT / ".lake" / "build" / "bin" / ("haze.exe" if os.name == "nt" else "haze")
sys.path.insert(0, str(HERE))
import payments_client as impl  # noqa: E402


# ---- 1. The specification ------------------------------------------------------------
def check_spec():
    proc = subprocess.run([str(HAZE), "--json", str(HERE / "payments.hz")],
                          capture_output=True, text=True, encoding="utf-8")
    records = [json.loads(line) for line in proc.stdout.splitlines() if line.strip()]
    rejected = [r for r in records if r["severity"] == "error"]
    for r in records:
        if r.get("kind") in ("theorem", "claim"):
            print(f"  spec  {r['kind']:<7} {r['name']:<18} {'accepted' if r['accepted'] else 'REJECTED'}")
    if proc.returncode != 0 or rejected:
        for r in rejected:
            print(f"  spec  error at line {r['line']}: {r['message'].splitlines()[0]}")
        sys.exit("the specification itself fails; fix payments.hz first")
    return records


def model_distributions(records):
    """Maps (loss rate, observable) to the exact distribution that Haze computed."""
    observables = {"phase": "status", "charges": "charges", "attempts": "attempts",
                   "latency": "latency_ms"}
    model = {}
    for r in records:
        if r.get("kind") != "eval":
            continue
        var = r["query"].split("after[6]")[1].strip()
        for b in r["branches"]:
            loss = Fraction(b["parameters"]["loss"])
            model[(loss, observables[var])] = {
                str(o["value"]): Fraction(o["probability"]) for o in b["distribution"]}
        losses = sorted({loss for loss, _ in model})
    expectations = {}
    for r in records:
        if r.get("kind") == "expect":
            for b in r["branches"]:
                expectations[Fraction(b["parameters"]["loss"])] = Fraction(b["expectation"])
    return model, losses, expectations


# ---- 2. Exhaustive runs of the implementation ----------------------------------------------
class NeedMore(Exception):
    pass


class ScriptedNetwork(impl.Network):
    """Replays a fixed sequence of loss decisions and stops when it runs out."""

    def __init__(self, script):
        self.script, self.used = script, 0

    def lost(self):
        if self.used == len(self.script):
            raise NeedMore
        self.used += 1
        return self.script[self.used - 1]


def all_runs(make_server, loss):
    """Yields (probability, result) for every pattern of lost messages."""
    stack = [()]
    while stack:
        script = stack.pop()
        try:
            net = ScriptedNetwork(script)
            result = impl.pay(net, make_server(), key="order-42", amount=1999)
        except NeedMore:
            stack.extend([script + (True,), script + (False,)])
            continue
        if net.used != len(script):
            raise AssertionError("the implementation stopped before using its whole script")
        p = Fraction(1)
        for lost in script:
            p *= loss if lost else 1 - loss
        yield p, result


def implementation_distributions(make_server, loss):
    dists, expected_latency, total, violations = defaultdict(lambda: defaultdict(Fraction)), Fraction(0), Fraction(0), []
    for p, res in all_runs(make_server, loss):
        total += p
        for obs in ("status", "charges", "attempts", "latency_ms"):
            dists[obs][str(getattr(res, obs))] += p
        expected_latency += p * res.latency_ms
        # the theorems of the specification, checked on every run
        if res.charges > 1: violations.append(f"single_charge violated: {res}")
        if res.acked and res.charges != 1: violations.append(f"ack_means_charged violated: {res}")
        if res.attempts > 3: violations.append(f"bounded_attempts violated: {res}")
    assert total == 1, f"probabilities of all runs sum to {total}"
    return dists, expected_latency, violations


# ---- 3. Comparison ------------------------------------------------------------------------------
def conforms(model, losses, expectations, make_server, verbose):
    ok = True
    for loss in losses:
        dists, exp_latency, violations = implementation_distributions(make_server, loss)
        for obs in ("status", "charges", "attempts", "latency_ms"):
            want = {k: v for k, v in model[(loss, obs)].items() if v}
            got = {k: v for k, v in dists[obs].items() if v}
            if want != got:
                ok = False
                if verbose:
                    keys = sorted(set(want) | set(got))
                    diff = ", ".join(f"{k}: model {want.get(k, 0)} vs impl {got.get(k, 0)}"
                                     for k in keys if want.get(k, 0) != got.get(k, 0))
                    print(f"  loss {loss}: {obs} differs ({diff})")
        if exp_latency != expectations[loss]:
            ok = False
            if verbose:
                print(f"  loss {loss}: expected latency differs (model {expectations[loss]}, impl {exp_latency})")
        if violations:
            ok = False
            if verbose:
                print(f"  loss {loss}: {violations[0]}")
    return ok


# ---- 4. Mutants -------------------------------------------------------------------------------------
class NonIdempotentServer(impl.PaymentServer):
    """Charges on every request, ignoring the idempotency key."""

    def __init__(self):
        super().__init__(charges=[])

    def charge(self, key, amount):
        self.charges.append(amount)
        return "receipt"


MUTANTS = {
    "one retry too many (MAX_ATTEMPTS = 4)": ("MAX_ATTEMPTS", 4, impl.PaymentServer),
    "timeout of 900 ms instead of 1000 ms": ("TIMEOUT_MS", 900, impl.PaymentServer),
    "server without idempotency keys": (None, None, NonIdempotentServer),
}


def main():
    print("1. Checking the specification with Haze")
    model, losses, expectations = model_distributions(check_spec())

    print("2. Comparing the implementation with the model, exactly, for every loss rate")
    real = conforms(model, losses, expectations, impl.PaymentServer, verbose=True)
    for loss in losses:
        d, e, _ = implementation_distributions(impl.PaymentServer, loss)
        print(f"  loss {str(loss):<5}  P(Done) = {d['status']['Done']}  "
              f"P(2+ charges) = {sum(v for k, v in d['charges'].items() if int(k) > 1)}  "
              f"E[latency] = {float(e):.4f} ms")
    print(f"  implementation {'CONFORMS' if real else 'DOES NOT CONFORM'} to payments.hz")

    print("3. Checking that the test catches bugs")
    caught_all = True
    for name, (attr, value, server) in MUTANTS.items():
        saved = getattr(impl, attr) if attr else None
        if attr: setattr(impl, attr, value)
        try:
            caught = not conforms(model, losses, expectations, server, verbose=False)
        finally:
            if attr: setattr(impl, attr, saved)
        caught_all &= caught
        print(f"  mutant {'caught ' if caught else 'MISSED '}  {name}")

    if real and caught_all:
        print("PASS")
        return 0
    print("FAIL")
    return 1


if __name__ == "__main__":
    sys.exit(main())
