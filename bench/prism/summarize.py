"""
Turns bench/prism/results.json into the table in docs/Benchmarks.md.

    python bench/prism/summarize.py
"""
import json, pathlib, re
from fractions import Fraction

HERE = pathlib.Path(__file__).resolve().parent
rows = json.loads((HERE / "results.json").read_text())


def frac(s):
    s = s.rstrip(".")
    return Fraction(s) if re.fullmatch(r"-?\d+(/\d+)?", s) else None


def flt(s):
    try: return float(s.rstrip("."))
    except ValueError: return None




def g(x):
    return f"{x:.10g}"


def short(q):
    s = str(q)
    return s if len(s) <= 21 else f"≈{float(q):.10g}"


lines_acc = []
for r in rows:
    name = f"{r['model']} {r['size']}".strip()
    for i, prop in enumerate(r["props"]):
        ref = None
        for k in ("storm_exact", "prism_exact"):
            v = r.get(k)
            if v and v["values"] and len(v["values"]) == len(r["props"]):
                ref = frac(v["values"][i]); break
            if v and v["values"] and k == "prism_exact" and len(v["values"]) == 1 and i == len(r["props"]) - 1:
                ref = frac(v["values"][0]); break      # PRISM's exact engine skips step-bounded properties
        h = r["haze"]["values"][i] if r["haze"]["values"] else None
        if h is None: hz = "timeout"
        else:
            lo, hi = Fraction(h[0]), Fraction(h[1])
            if lo == hi: hz = short(lo) + (" (same)" if ref is not None and lo == ref else "" if ref is None else " (DIFFERENT)")
            else:
                mid = (lo + hi) / 2
                hz = f"{g(float(mid))}, certified to ±{float((hi - lo) / 2 / abs(mid)):.0e}" + ("" if ref is None else "" if lo <= ref <= hi else " (MISSES IT)")
        def err(k):
            v = r.get(k)
            if not v or not v["values"] or ref is None or len(v["values"]) <= i: return "n/a" if v and v["time"] else "timeout"
            x = flt(v["values"][i]); e = abs(x - float(ref)) / abs(float(ref)) if ref else abs(x)
            return "0" if e == 0 else f"{e:.0e}"
        lines_acc.append(f"| {name} | {prop} | {short(ref) if ref is not None else 'n/a'} | {hz} | {err('prism')} | {err('storm')} |")

out = ["| Model | Property | Exact value | Haze | PRISM error | Storm error |", "|---|---|---|---|---|---|", *lines_acc]
print("\n".join(out))
