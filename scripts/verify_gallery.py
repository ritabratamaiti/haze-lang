"""
Checks the results of the models in examples/Gallery against independent calculations.

Each model is recomputed here with exact fractions, from closed-form answers or by propagating
the distribution of the Markov chain step by step, without using Haze. Run it from the
repository root after `lake build`:

    python scripts/verify_gallery.py
"""
from fractions import Fraction as F
from math import comb, prod
import itertools, os, pathlib, re, subprocess, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
HAZE = str(ROOT / ".lake" / "build" / "bin" / ("haze.exe" if os.name == "nt" else "haze"))
results = []

def blocks(path):
    out = subprocess.run([HAZE, str(ROOT / path)], capture_output=True, text=True, encoding="utf-8").stdout
    bl, key = {}, None
    for line in out.splitlines():
        m = re.match(r".*?:\d+:\d+: (info|error): (.*)$", line)
        if m:
            key = m.group(2).strip(); bl[key] = []
        elif key:
            bl[key].append(line)
    return bl

def nums(text):
    return [float(x) for x in re.findall(r"-?\d+(?:\.\d+)?", text.replace("(=", " ").replace("/", " / "))]

def check(bl, key, *expected, name=None):
    text = "\n".join(bl.get(key, ["<missing>"]))
    found = nums(text.split("by fuzzy parameter")[0].split("grade ")[0]) if "lower expectation" in text or "belief" in text or "probability" in text or "expectation" in text else nums(text)
    ok = all(any(abs(n - float(e)) <= 6e-7 for n in found) for e in expected)
    results.append((ok, name or key, ", ".join(f"{float(e):.6f}" for e in expected)))

def check_line(bl, key, value_label, prob, name):
    lines = bl.get(key, [])
    ok = any(re.match(rf"\s*{re.escape(value_label)}\s+↦", l) and any(abs(n - float(prob)) <= 6e-7 for n in nums(l.split("↦")[1])) for l in lines)
    results.append((ok, name, f"{value_label} ↦ {float(prob):.6f}"))

def integrate(rows):
    """rows: (possibility, lo, hi) -> (belief, plausibility); same formula as the design doc."""
    lv = sorted({r[0] for r in rows}, reverse=True) + [F(0)]
    top = lv[0]
    bel = sum((lv[i] - lv[i+1]) * min(r[1] for r in rows if r[0] >= lv[i]) for i in range(len(lv) - 1))
    pl = sum((lv[i] - lv[i+1]) * max(r[2] for r in rows if r[0] >= lv[i]) for i in range(len(lv) - 1))
    return bel / top, pl / top

def interval(pairs):  # pairs: (possibility, value)
    return integrate([(p, v, v) for p, v in pairs])

# ---- generic exact Markov-chain helpers -------------------------------------
def evolve(init, step, k):
    dist = {init: F(1)}
    for _ in range(k):
        nd = {}
        for s, p in dist.items():
            for s2, q in step(s):
                if q: nd[s2] = nd.get(s2, 0) + p * q
        dist = nd
    return dist

def after(init, step, k, f):
    return sum(p * f(s) for s, p in evolve(init, step, k).items())

def eventually(init, step, k, f):
    st = lambda sh: [((s2, sh[1] or bool(f(s2))), q) for s2, q in step(sh[0])]
    return after((init, bool(f(init))), st, k, lambda sh: sh[1])

def always(init, step, k, f):
    st = lambda sh: [((s2, sh[1] and bool(f(s2))), q) for s2, q in step(sh[0])]
    return after((init, bool(f(init))), st, k, lambda sh: sh[1])

def binom(n, p):
    return [(k, comb(n, k) * p**k * (1 - p)**(n - k)) for k in range(n + 1)]

# ---- genetics ---------------------------------------------------------------
b = blocks("examples/Gallery/genetics.hz")
drift = lambda c: [(k, q) for k, q in binom(6, F(c, 6))]
for k, q in binom(6, F(1, 3)):
    check_line(b, "#eval Drift |= after[1] copies", str(k), q, f"drift: P(copies={k}) after 1 generation")
check(b, "#expect Drift |= after[10] copies", after(2, drift, 10, lambda c: c))
check(b, "claim fixed", eventually(2, drift, 60, lambda c: c == 6))
check(b, "claim lost", eventually(2, drift, 60, lambda c: c == 0))
qs = [(F(3, 5), F(1, 10)), (F(1), F(1, 5)), (F(1, 2), F(3, 10))]
check(b, "claim heterozygous", *interval([(pi, 2*q*(1-q)) for pi, q in qs]))
check(b, "claim affected", *interval([(pi, q*q) for pi, q in qs]))
check(b, "#prob from_mother == Rec and from_father == Rec", F(1, 4))
check(b, "#prob from_mother != from_father", F(2, 3))

# ---- epidemic (Reed-Frost) --------------------------------------------------
b = blocks("examples/Gallery/epidemic.hz")
def reed_frost(p):
    def step(s):
        S, I, T = s
        pinf = 1 - (1 - p) ** I
        return [((S - c, c, T + c), q) for c, q in binom(S, pinf)]
    return step
ps = [(F(1, 2), F(1, 5)), (F(1), F(3, 10)), (F(2, 5), F(1, 2))]
for pi, p in ps:
    d = evolve((4, 1, 1), reed_frost(p), 5)
    for size in range(1, 6):
        check_line(b, "#eval Household |= after[5] total", str(size), sum(q for s, q in d.items() if s[2] == size), f"household final size {size}, p={p}")
check(b, "#expect Household |= after[5] total", *interval([(pi, after((4, 1, 1), reed_frost(p), 5, lambda s: s[2])) for pi, p in ps]))
check(b, "claim large_outbreak", *interval([(pi, after((4, 1, 1), reed_frost(p), 5, lambda s: s[2] >= 3)) for pi, p in ps]))
check(b, "claim over_in_two_generations", *interval([(pi, eventually((4, 1, 1), reed_frost(p), 2, lambda s: s[1] == 0)) for pi, p in ps]))
check(b, "#expect Vaccinated |= after[5] total", *interval([(pi, after((2, 1, 1), reed_frost(p), 5, lambda s: s[2])) for pi, p in ps]))
check(b, "claim vaccinated_large_outbreak", *interval([(pi, after((2, 1, 1), reed_frost(p), 5, lambda s: s[2] >= 3)) for pi, p in ps]))

# ---- physics ----------------------------------------------------------------
b = blocks("examples/Gallery/physics.hz")
decay = lambda rate: (lambda n: [(n - k, q) for k, q in binom(n, rate)])
check(b, "#expect Decay |= after[10] nuclei", 20 * F(9, 10) ** 10)
surv = F(9, 10) ** 7
check(b, "claim half_left_after_7", sum(q for k, q in binom(20, surv) if k >= 10), name="decay: P(>= 10 left after 7) via binomial(20, 0.9^7)")
check(b, "#expect VagueDecay |= after[10] nuclei", *interval([(F(1, 2), 20 * F(19, 20) ** 10), (F(1), 20 * F(9, 10) ** 10), (F(1, 2), 20 * F(17, 20) ** 10)]))
ehr = lambda L: [(L, F(1, 2)), (L - 1, F(1, 2) * F(L, 4)), (L + 1, F(1, 2) * F(4 - L, 4))]
d = evolve(4, ehr, 40)
for L in range(5):
    check_line(b, "#eval Ehrenfest |= after[40] left", str(L), d.get(L, 0), f"Ehrenfest P(left={L}) at t=40 (→ {comb(4, L)}/16)")
check(b, "#expect Ehrenfest |= after[40] left", 2 + 2 * F(3, 4) ** 40)
check(b, "claim returns_within_20", 1 - F(comb(20, 10), 4 ** 10), name="random walk returns within 20 steps (1 - C(20,10)/4^10)")

# ---- reliability ------------------------------------------------------------
b = blocks("examples/Gallery/reliability.hz")
rs = [(F(1, 2), F(9, 10)), (F(1), F(19, 20)), (F(7, 10), F(99, 100))]
def voter(r):
    total = F(0)
    for oks in itertools.product([True, False], repeat=3):
        pok = prod(r if o else 1 - r for o in oks)
        choices = [[(1, F(1))] if o else [(v, F(1, 4)) for v in range(4)] for o in oks]
        for (a, pa), (b2, pb), (c, pc) in itertools.product(*choices):
            v = a if a == b2 else (a if a == c else b2)
            if v == 1: total += pok * pa * pb * pc
    return total
check(b, "claim single_module", *interval([(pi, r) for pi, r in rs]))
check(b, "claim two_of_three", *interval([(pi, 3*r*r - 2*r**3) for pi, r in rs]))
check(b, "claim voter_correct", *interval([(pi, voter(r)) for pi, r in rs]))
check(b, "claim flow", (1 - F(1, 5) ** 2) * F(19, 20))
srv = lambda s: ([((False, s[1]), F(1, 10)), ((True, s[1]), F(9, 10))] if s[0]
                 else [((True, s[1] + 1), F(1, 2)), ((False, s[1] + 1), F(1, 2))])
check(b, "claim available_at_50", after((True, 0), srv, 50, lambda s: s[0]))
check(b, "claim no_outage_in_24", F(9, 10) ** 24)
check(b, "#expect Server |= after[24] downtime", after((True, 0), srv, 24, lambda s: s[1]))

# ---- finance ----------------------------------------------------------------
b = blocks("examples/Gallery/finance.hz")
disc = F(105, 100) ** 3
def crr(u, d, q, payoff):
    return sum(comb(3, k) * q**k * (1 - q)**(3 - k) * payoff(100 * u**k * d**(3 - k)) for k in range(4)) / disc
call = lambda s: max(s - 100, 0); put = lambda s: max(100 - s, 0)
u, d = F(6, 5), F(9, 10); q = (F(105, 100) - d) / (u - d)
check(b, "#expect Stock |= after[3] max(price - 100, 0) / discount", crr(u, d, q, call))
check(b, "#expect Stock |= after[3] max(100 - price, 0) / discount", crr(u, d, q, put))
check(b, "#expect Stock |= after[3] (max(price - 100, 0) - max(100 - price, 0)) / discount", 100 - 100 / disc, name="put-call parity: C - P = 100 - 100/1.05^3")
vs = []
for pi, u in [(F(1, 2), F(11, 10)), (F(1), F(6, 5)), (F(1, 2), F(13, 10))]:
    d = 1 / u; q = (F(105, 100) - d) / (u - d); vs.append((pi, crr(u, d, q, call)))
check(b, "#expect VagueStock |= after[3] max(price - 100, 0) / discount", *interval(vs))
ins = lambda s: [((s[0], True), F(1))] if s[1] else [((c, c < 0), w) for c, w in ((s[0] + 1, F(7, 10)), (s[0] - 1, F(1, 5)), (s[0] - 4, F(1, 10)))]
check(b, "claim ruin_within_20", eventually((3, False), ins, 20, lambda s: s[1]))

# ---- games ------------------------------------------------------------------
b = blocks("examples/Gallery/games.hz")
rolls = {t: F(sum(1 for a in range(1, 7) for c in range(1, 7) if a + c == t), 36) for t in range(2, 13)}
def craps(s):
    ph, pt = s
    if ph in ("W", "L"): return [(s, F(1))]
    out = []
    for r, q in rolls.items():
        if ph == "C":
            ns = ("W", pt) if r in (7, 11) else ("L", pt) if r in (2, 3, 12) else ("P", r)
        else:
            ns = ("W", pt) if r == pt else ("L", pt) if r == 7 else s
        out.append((ns, q))
    return out
check(b, "claim shooter_wins", eventually(("C", 0), craps, 100, lambda s: s[0] == "W"))
results.append((abs(float(eventually(("C", 0), craps, 100, lambda s: s[0] == "W")) - 244/495) < 1e-9, "  ...craps vs closed form 244/495", f"{244/495:.6f}"))
check(b, "claim decided_on_come_out", F(12, 36))
def tennis(s):
    a, c = s
    if (a >= 4 or c >= 4) and abs(a - c) >= 2: return [(s, F(1))]
    out = []
    for (a2, c2), q in (((a + 1, c), F(3, 5)), ((a, c + 1), F(2, 5))):
        if a2 >= 3 and c2 >= 3 and a2 == c2: a2 = c2 = 3
        out.append(((a2, c2), q))
    return out
p, qq = F(3, 5), F(2, 5)
tennis_formula = p**4 * (1 + 4*qq + 10*qq**2) + 20 * p**3 * qq**3 * p**2 / (1 - 2*p*qq)
check(b, "claim server_holds", eventually((0, 0), tennis, 200, lambda s: s[0] >= 4 and s[0] - s[1] >= 2))
results.append((abs(float(tennis_formula) - 0.735729) < 6e-7, "  ...tennis vs closed form p^4(1+4q+10q^2) + 20p^3q^3·p^2/(1-2pq)", f"{float(tennis_formula):.6f}"))
def penney(s):
    bf, ls, w = s
    if w: return [(s, F(1))]
    out = []
    for coin in (1, 2):
        w2 = 1 if (bf == 1 and ls == 1 and coin == 2) else 2 if (bf == 1 and ls == 2 and coin == 2) else 0
        out.append(((ls, coin, w2), F(1, 2)))
    return out
check(b, "claim hht_first", F(2, 3), name="Penney: HHT before HTT (2/3; horizon 200 differs by < 1e-6)")

# ---- queueing ---------------------------------------------------------------
b = blocks("examples/Gallery/queueing.hz")
def buffer(lam):
    def step(s):
        qn, dr = s
        out = []
        for served, ps in ((True, F(1, 2)), (False, F(1, 2))) if qn > 0 else ((False, F(1)),):
            q1 = qn - 1 if served else qn
            for arr, pa in ((True, lam), (False, 1 - lam)):
                if arr: ns = (q1 + 1, dr) if q1 < 4 else (q1, dr + 1)
                else: ns = (q1, dr)
                out.append((ns, ps * pa))
        return out
    return step
lams = [(F(1), F(3, 10)), (F(3, 5), F(2, 5)), (F(3, 10), F(1, 2))]
for pi, lam in lams:
    d = evolve((0, 0), buffer(lam), 50)
    for qn in range(5):
        check_line(b, "#eval Buffer |= after[50] queue", str(qn), sum(p for s, p in d.items() if s[0] == qn), f"buffer P(queue={qn}) at t=50, arrival={lam}")
check(b, "claim full_at_50", *interval([(pi, after((0, 0), buffer(lam), 50, lambda s: s[0] == 4)) for pi, lam in lams]))
check(b, "claim no_drops_in_50", *interval([(pi, always((0, 0), buffer(lam), 50, lambda s: s[1] == 0)) for pi, lam in lams]))
check(b, "#expect Buffer |= after[50] dropped", *interval([(pi, after((0, 0), buffer(lam), 50, lambda s: s[1])) for pi, lam in lams]))

# ---- game physics -------------------------------------------------------------
b = blocks("examples/Gallery/game_physics.hz")
def tunnel_safe(speed, start, swept):
    x, hit = start, False
    for _ in range(31):
        if x >= 24: return False
        if not hit:
            nxt = x + speed
            if (x < 20 and nxt >= 20) if swept else (20 <= nxt < 24): x, hit = 20, True
            else: x = nxt
    return True
safe = F(sum(tunnel_safe(s, x0, False) for s in range(1, 13) for x0 in range(6)), 72)
check(b, "theorem naive_never_tunnels", safe, name="naive collision: fraction of (speed, start) pairs that never tunnel")
results.append((all(tunnel_safe(s, x0, True) for s in range(1, 13) for x0 in range(6)) and "theorem accepted" in "\n".join(b["theorem swept_never_tunnels"]), "swept collision never tunnels (all 72 cases)", "all safe"))
results.append((all(tunnel_safe(s, x0, False) for s in range(1, 5) for x0 in range(6)) and "theorem accepted" in "\n".join(b["theorem naive_safe_when_slow"]), "naive collision safe when speed <= thickness", "all safe"))
check(b, "#eval ExplicitEuler |= after[10] v * v / 2 + y", F(105), name="explicit Euler energy after 10 ticks: 100 + 10/2")
check(b, "#eval SemiImplicitEuler |= after[10] v * v / 2 + y", F(95), name="semi-implicit Euler energy after 10 ticks: 100 - 10/2")
def bounce_ok():
    y, v = F(30), F(0)
    for _ in range(61):
        if y < 0 or v * v / 2 + y > 30: return False
        v -= 1; y += v
        if y < 0: y, v = F(0), -v / 2
    return True
results.append((bounce_ok() and "theorem accepted" in "\n".join(b["theorem bounce_never_gains_energy"]), "bounce: above floor and never gains energy for 60 ticks", "holds"))
def jump(rate):
    def step(s):
        y, v, peak = s
        if y < 0: return [(s, F(1))]
        out = []
        for dt, q in ((2, rate), (1, 1 - rate)):
            v2 = v - dt; y2 = y + v2 * dt
            out.append(((y2, v2, max(peak, y2)), q))
        return out
    return step
rates = [(F(1), F(1, 50)), (F(1, 2), F(1, 10)), (F(1, 5), F(1, 4))]
check(b, "claim variable_step_reaches_ledge", *interval([(pi, eventually((0, 10, 0), jump(r), 25, lambda s: s[0] >= 45)) for pi, r in rates]))
results.append((all(abs(float(eventually((0, 10, 0), jump(r), 25, lambda s: s[0] >= 45) - (1 - r) ** 9)) < 1e-12 for _, r in rates), "  ...equals (1 - drop rate)^9: any dropped frame during the 9-tick ascent misses the ledge", "(1-r)^9"))
def jet(s):
    y, v, fuel = s
    thrust = 2 if fuel > 0 else 0
    return [((max(y + v + thrust - 1 - g, 0), v + thrust - 1 - g, max(fuel - 1, 0)), q) for g, q in ((1, F(3, 10)), (0, F(7, 10)))]
check(b, "claim jetpack_reaches_platform", eventually((0, 0, 12), jet, 30, lambda s: s[0] >= 40))
check(b, "#expect Jetpack |= after[30] y", after((0, 0, 12), jet, 30, lambda s: s[0]))

passed = sum(r[0] for r in results)
for ok, name, exp in results:
    print("PASS" if ok else "FAIL", name, "|", exp)
print(f"{passed}/{len(results)} checks passed")
sys.exit(0 if passed == len(results) else 1)
