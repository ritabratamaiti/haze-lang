"""
Checks the numbers printed by the models in examples/Gallery against independent calculations.

The script runs the haze binary on each gallery file and then recomputes every result here with
exact fractions, without using Haze: either from a closed-form answer, or by pushing the
probability distribution of the Markov chain forward one step at a time. Build Haze with
`lake build` first, then run it from any directory:

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
    return [float(x) for x in re.findall(r"-?\d+(?:\.\d+)?(?:e-?\d+)?", text.replace("(=", " ").replace("/", " / "))]

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
    """Turn rows of (possibility, lo, hi) into (belief, plausibility), using the formula from the design doc."""
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

# eventually and always pair each state with a flag that records whether f has held at
# some step (or at every step) so far.
def eventually(init, step, k, f):
    st = lambda sh: [((s2, sh[1] or bool(f(s2))), q) for s2, q in step(sh[0])]
    return after((init, bool(f(init))), st, k, lambda sh: sh[1])

def always(init, step, k, f):
    st = lambda sh: [((s2, sh[1] and bool(f(s2))), q) for s2, q in step(sh[0])]
    return after((init, bool(f(init))), st, k, lambda sh: sh[1])

def absorb(init, step, f, steps=False):
    """For a chain that is absorbed with probability 1, the exact probability of reaching a state
    where f holds (or, with steps=True, the expected number of steps until it does), found by
    exploring the chain and solving its linear equations with fractions."""
    states, idx, i = [init], {init: 0}, 0
    while i < len(states):
        s = states[i]; i += 1
        if f(s) or all(t == s for t, q in step(s) if q): continue
        for t, q in step(s):
            if q and t not in idx: idx[t] = len(states); states.append(t)
    n = len(states)
    a = [[F(0)] * (n + 1) for _ in range(n)]
    for k, s in enumerate(states):
        a[k][k] = F(1)
        # an absorbing state where f fails never reaches f: probability 0
        stuck = all(t == s for t, q in step(s) if q)
        if f(s) or stuck:
            a[k][n] = F(0) if steps or not f(s) else F(1)
            continue
        a[k][n] = F(1) if steps else F(0)
        for t, q in step(s):
            if q: a[k][idx[t]] -= q
    for c in range(n):
        piv = next(r for r in range(c, n) if a[r][c] != 0)
        a[c], a[piv] = a[piv], a[c]
        pv = a[c][c]; a[c] = [x / pv for x in a[c]]
        for r in range(n):
            if r != c and a[r][c] != 0:
                fr = a[r][c]; a[r] = [x - fr * y for x, y in zip(a[r], a[c])]
    return a[0][n]

def binom(n, p):
    return [(k, comb(n, k) * p**k * (1 - p)**(n - k)) for k in range(n + 1)]

# ---- genetics ---------------------------------------------------------------
b = blocks("examples/Gallery/genetics.hz")
drift = lambda c: [(k, q) for k, q in binom(6, F(c, 6))]
for k, q in binom(6, F(1, 3)):
    check_line(b, "#eval Drift |= after[1] copies", str(k), q, f"drift: P(copies={k}) after 1 generation")
check(b, "#expect Drift |= after[10] copies", after(2, drift, 10, lambda c: c))
check(b, "claim fixed", absorb(2, drift, lambda c: c == 6), name="drift: fixation probability 1/3")
check(b, "claim lost", absorb(2, drift, lambda c: c == 0), name="drift: loss probability 2/3")
check(b, "#expect Drift |= steps until copies == 0 or copies == 6", absorb(2, drift, lambda c: c in (0, 6), steps=True))
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
check(b, "claim shooter_wins", F(244, 495), name="craps: shooter wins (closed form 244/495)")
results.append((absorb(("C", 0), craps, lambda s: s[0] in "WL") == 1 and absorb(("C", 0), craps, lambda s: s[0] == "W") == F(244, 495), "  ...craps chain solved exactly equals 244/495", "244/495"))
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
check(b, "claim server_holds", tennis_formula, name="tennis: server holds (closed form)")
results.append((abs(float(tennis_formula) - 0.735729) < 6e-7, "  ...tennis vs closed form p^4(1+4q+10q^2) + 20p^3q^3·p^2/(1-2pq)", f"{float(tennis_formula):.6f}"))
def penney(s):
    bf, ls, w = s
    if w: return [(s, F(1))]
    out = []
    for coin in (1, 2):
        w2 = 1 if (bf == 1 and ls == 1 and coin == 2) else 2 if (bf == 1 and ls == 2 and coin == 2) else 0
        out.append(((ls, coin, w2), F(1, 2)))
    return out
check(b, "claim hht_first", F(2, 3), name="Penney: HHT before HTT (2/3)")

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

# ---- chip design -------------------------------------------------------------
b = blocks("examples/Gallery/chip_design.hz")
chip = []
for d0, pd in ((F(9, 10000), F(3, 5)), (F(1, 1000), F(1)), (F(11, 10000), F(3, 5))):
    for area in (3, 4):
        q = 1 - (1 - d0) ** area                      # an SM has at least one defect
        dead = binom(144, q)
        uncore_ok = (1 - d0) ** (814 - 144 * area)
        le = lambda m: sum(w for k, w in dead if k <= m)
        chip.append((min(pd, F(1)), {
            "perfect": (1 - q) ** 144 * uncore_ok, "sellable": le(12) * uncore_ok,
            "dead": 144 * q, "few": le(4), "perfect_given": (1 - q) ** 144 / le(12)}))
check(b, "claim perfect_die", *interval([(pi, r["perfect"]) for pi, r in chip]))
results.append((all(abs(float(r["perfect"]) - 2.718281828459045 ** (-814 * float(d))) < 5e-4
                    for (pi, r), d in zip(chip, [0.0009] * 2 + [0.001] * 2 + [0.0011] * 2)),
                "  ...perfect die close to the Poisson yield e^(-A D0)", "e^-0.814 = 0.443"))
check(b, "claim sellable_as_h100", *interval([(pi, r["sellable"]) for pi, r in chip]))
check(b, "#expect dead_sms", *interval([(pi, r["dead"]) for pi, r in chip]))
check(b, "claim few_dead", *interval([(pi, r["few"]) for pi, r in chip]))
check(b, "#prob dead_sms == 0 given dead_sms <= 12 and uncore_ok", *interval([(pi, r["perfect_given"]) for pi, r in chip]))

# ---- security ----------------------------------------------------------------
b = blocks("examples/Gallery/security.hz")
pins = [F(x) / 100 for x in ("10.713 6.016 1.881 1.197 0.745 0.616 0.613 0.526 0.516 0.512 "
                             "0.451 0.419 0.395 0.391 0.366 0.304 0.303 0.293 0.290 0.285").split()]
check(b, "claim card_three_guesses", sum(pins[:3]), name="PIN: top 3 DataGenetics shares (18.61%)")
check(b, "claim phone_ten_guesses", sum(pins[:10]), name="PIN: top 10 DataGenetics shares (23.335%)")
results.append((sum(pins) == F(26832, 100000), "  ...top 20 shares sum to 26.832% (published: 26.83%)", "0.26832"))
wallets = [(F(1), F(823, 10000)), (F(1), F(563, 10000))]
check(b, "#expect cracked", *interval([(pi, 20 * l) for pi, l in wallets]))
check(b, "#prob cracked >= 1", *interval([(pi, 1 - (1 - l) ** 20) for pi, l in wallets]))
base = F(2, 100000)
ids = [(F(1), dr, fa) for dr in (F(7, 10), F(1)) for fa in (F(1, 100000), F(1, 1000))]
post = lambda dr, fa: base * dr / (base * dr + (1 - base) * fa)
check(b, "#prob intrusion given alarm", *interval([(pi, post(dr, fa)) for pi, dr, fa in ids]))
results.append((abs(float(post(F(1), F(1, 100000))) - 0.6667) < 1e-3 and abs(float(post(F(7, 10), F(1, 100000))) - 0.5833) < 1e-3
                and abs(float(post(F(1), F(1, 1000))) - 0.0196) < 1e-3,
                "  ...Axelsson's figures: 66%, 58% and about 2%", "0.667, 0.583, 0.020"))
check(b, "#expect (if alarm then 100000 else 0)",
      *interval([(pi, 100000 * (base * dr + (1 - base) * fa)) for pi, dr, fa in ids]))

# ---- production test --------------------------------------------------------
# Enumerates the same discretized model directly, without Haze, and compares the out-of-spec
# share with the normal-distribution figure it approximates.
b = blocks("examples/Gallery/production_test.hz")
spread = [((k - 112) * 2 - 1, q) for k, q in binom(225, F(1, 2))]
meter = binom(8, F(1, 2))
units = [(F(1), 2), (F(1, 2), 3)]
bad = lambda e: abs(e) > 30
def q_pass(e, u, g):
    return sum(q for r, q in meter if abs(e + (r - 4) * u) <= 30 - g)
def joint(u, g, want_bad=None, retest=False):
    total = F(0)
    for e, pe in spread:
        if want_bad is not None and bad(e) != want_bad: continue
        qp = q_pass(e, u, g)
        total += pe * (1 - (1 - qp) ** 3 if retest else qp)
    return total
out = sum(q for e, q in spread if bad(e))
check(b, "#prob not in_spec", out, name="production test: share out of spec")
import math
normal = 2 * (1 - 0.5 * (1 + math.erf(2 / math.sqrt(2))))
results.append((abs(float(out) - normal) < 1e-3, "  ...close to the normal figure 2(1 - Phi(2)) = 4.55%", f"{normal:.6f}"))
check(b, "claim false_accept_z540", *interval([(pi, joint(u, 0, True)) for pi, u in units]))
check(b, "#prob in_spec and not passes(r1, 0)", *interval([(pi, sum(pe for e, pe in spread if not bad(e)) - joint(u, 0, False)) for pi, u in units]))
check(b, "claim shipped_under_1000_ppm", *interval([(pi, joint(u, 0, True) / joint(u, 0)) for pi, u in units]))
check(b, "claim retest_under_1000_ppm", *interval([(pi, joint(u, 0, True, True) / joint(u, 0, None, True)) for pi, u in units]))
check(b, "claim guard_6_under_1000_ppm", *interval([(pi, joint(u, 6, True) / joint(u, 6)) for pi, u in units]))
check(b, "#prob in_spec and not passes(r1, 6)", *interval([(pi, sum(pe for e, pe in spread if not bad(e)) - joint(u, 6, False)) for pi, u in units]))
check(b, "theorem guard_8_ships_only_good", *interval([(pi, 1 - joint(u, 8, True)) for pi, u in units]))
results.append((all(joint(u, 12, True) == 0 for _, u in units), "production test: a 12 mV guard band never ships a bad part", "0"))
check(b, "#prob in_spec and not passes(r1, 12)", *interval([(pi, sum(pe for e, pe in spread if not bad(e)) - joint(u, 12, False)) for pi, u in units]))

# ---- learned rates -----------------------------------------------------------
# A client gives up after `budget` attempts. The first fails with probability t, and each retry
# with f = s + (1 - s) t, so it succeeds with 1 - t f^(budget - 1), which falls as t or s rises.
# The worst and best values over each possibility level are then at the ends of the ranges.
# The likelihood's cuts are found here by bisection in floating point, independently of Haze.
b = blocks("examples/Gallery/learned_rates.hz")
def lik_cut(k, n, a):
    if a == 0: return (0.0, 1.0)
    ll = lambda p: (k * math.log(p) if k else 0) + ((n - k) * math.log(1 - p) if k < n else 0)
    top, ph = ll(k / n), k / n
    def solve(lo, hi, rising):
        for _ in range(200):
            m = (lo + hi) / 2
            if (ll(m) < top + math.log(a)) == rising: lo = m
            else: hi = m
        return (lo + hi) / 2
    return (solve(0.0, ph, True) if k else 0.0, solve(ph, 1.0, False) if k < n else 1.0)
def tri_cut(a, m, c, al): return (a + al * (m - a), c - al * (c - m))
done = lambda t, s, budget: 1 - t * (s + (1 - s) * t) ** (budget - 1)
levels = sorted({j / 10 for j in range(1, 11)} | {1e-6, 1e-4, 1e-3, 1e-2})
for budget, name in ((3, "three_attempts"), (5, "five_attempts")):
    bel = pl = 0.0
    for l, n in zip(levels, [0.0] + levels[:-1]):
        (t0, t1), (s0, s1) = lik_cut(12, 4000, n), tri_cut(0.1, 0.3, 0.6, n)
        bel += (l - n) * done(t1, s1, budget)
        pl += (l - n) * done(t0, s0, budget)
    check(b, f"claim {name}", bel, pl, name=f"learned rates: belief and plausibility with {budget} attempts")
    core = [l.split(":")[-1] for l in b.get(f"claim {name}", []) if "at the most possible values" in l]
    results.append((any(abs(x - done(0.003, 0.3, budget)) <= 6e-7 for c in core for x in nums(c)),
                    f"learned rates: {budget} attempts at the most possible rates", f"{done(0.003, 0.3, budget):.6f}"))
results.append(("theorem accepted" in "\n".join(b.get("theorem within_budget", [])), "learned rates: the budget is never exceeded", "1"))

passed = sum(r[0] for r in results)
for ok, name, exp in results:
    print("PASS" if ok else "FAIL", name, "|", exp)
print(f"{passed}/{len(results)} checks passed")
sys.exit(0 if passed == len(results) else 1)
