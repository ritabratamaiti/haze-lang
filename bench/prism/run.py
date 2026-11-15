"""
Runs the models in bench/prism/models with Haze, PRISM and Storm, and compares their answers and
times. Linux only; this is how the numbers in docs/Benchmarks.md were produced.

    python3 run.py HAZE PRISM_DIR [--storm CONTAINER] [--repeat N] [--timeout S]

HAZE is the haze binary, PRISM_DIR an unpacked PRISM release (its prism-examples folder has the
original models), and CONTAINER a running container of the movesrwth/storm image, used with
`docker exec`, with the work directory mounted at /work. Each tool runs N times (default 3) and the fastest wall-clock time is kept, so the
times include starting the JVM or the process. Writes results.json next to this file.
"""
import argparse, json, pathlib, re, subprocess, time
from fractions import Fraction

HERE = pathlib.Path(__file__).resolve().parent
ap = argparse.ArgumentParser()
ap.add_argument("haze"); ap.add_argument("prism_dir")
ap.add_argument("--storm"); ap.add_argument("--repeat", type=int, default=3); ap.add_argument("--timeout", type=int, default=600)
ap.add_argument("--only")
ap.add_argument("--workdir", default=str(pathlib.Path.home() / "hazebench" / "work"),
                help="where the PRISM model copies go; mount it at /work in the Storm container")
a = ap.parse_args()
cases = json.loads((HERE / "models" / "cases.json").read_text())
prism = str(pathlib.Path(a.prism_dir) / "bin" / "prism")
examples = pathlib.Path(a.prism_dir) / "prism-examples"
work = pathlib.Path(a.workdir)
work.mkdir(parents=True, exist_ok=True)


def timed(cmd):
    best, out = None, None
    for _ in range(a.repeat):
        t = time.perf_counter()
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=a.timeout)
        except subprocess.TimeoutExpired:
            if cmd[0] == "docker":   # the process inside the container outlives `docker exec`
                subprocess.run(["docker", "exec", cmd[2], "pkill", "-f", "storm"], capture_output=True)
            return None, "timeout"
        dt = time.perf_counter() - t
        best = dt if best is None else min(best, dt)
        out = r.stdout + r.stderr
        if dt > 60: break          # one run is enough for slow cases
    return best, out


def num(s):
    s = s.strip()
    if "/" in s or re.fullmatch(r"-?\d+", s): return Fraction(s)
    return float(s)


def haze_values(out, rounds):
    vals = []
    for line in out.splitlines():
        if not line.startswith("{"): continue
        r = json.loads(line)
        if r.get("kind") == "prob": vals.append((Fraction(r["belief"]), Fraction(r["plausibility"])))
        elif r.get("kind") == "expect":
            b = r["branches"][0]
            lo, hi = Fraction(b["lower"]), Fraction(b["upper"])
            if rounds: lo, hi = lo / rounds, hi / rounds
            vals.append((lo, hi))
    return vals


def prism_model(c):
    """A copy of the PRISM model, with Herman's `init true` block removed so that it starts with
    every variable at 0, the same state as the Haze model."""
    src = (examples / c["prism"]).read_text()
    src = re.sub(r"init\s+true\s+endinit", "", src)
    p = work / pathlib.Path(c["prism"]).name
    p.write_text(src)
    return p, src


def strip_filter(prop):
    m = re.fullmatch(r"filter\(state, (.*), [^,]*\)", prop)
    return m.group(1) if m else prop


results = []
for c in cases:
    if a.only and a.only not in c["haze"]: continue
    model, src = prism_model(c)
    consts = ",".join(kv for kv in c["consts"].split(",") if kv and re.search(rf"const\s+\w+\s+{kv.split('=')[0]}\b", src))
    props = [strip_filter(p) for _, p in c["props"]]
    pf = work / (model.stem + ".props"); pf.write_text("\n".join(props) + "\n")
    row = {"model": c["model"], "size": c["size"], "props": [n for n, _ in c["props"]]}

    t, out = timed([a.haze, "--json", str(HERE / "models" / c["haze"])])
    row["haze"] = {"time": t, "values": [[str(lo), str(hi)] for lo, hi in haze_values(out, c.get("round"))] if t else None}
    m = re.findall(r"(\d+) (?:reachable states|states/step)", out or "")
    row["haze"]["states"] = max(map(int, m)) if m else None

    for key, extra in (("prism", []), ("prism_exact", ["-exact"])):
        cmd = [prism, str(model), str(pf)] + (["-const", consts] if consts else []) + extra
        t, out = timed(cmd)
        vals = re.findall(r"^Result: (\S+)", out or "", re.M)
        st = re.search(r"^States:\s+(\d+)", out or "", re.M)
        row[key] = {"time": t, "values": vals if t else None, "states": int(st.group(1)) if st else None}
        if t and len(vals) != len(props): row[key]["error"] = (out or "")[-600:]

    if a.storm:
        for key, extra in (("storm", []), ("storm_exact", ["--exact"])):
            cmd = ["docker", "exec", a.storm, "storm", "--prism", f"/work/{model.name}", "--prop", ";".join(props)]
            cmd += (["--constants", consts] if consts else []) + extra
            t, out = timed(cmd)
            vals = re.findall(r"^Result \(for initial states\): (\S+)", out or "", re.M)
            st = re.search(r"^States:\s+(\d+)", out or "", re.M)
            row[key] = {"time": t, "values": vals if t else None, "states": int(st.group(1)) if st else None}
            if t and len(vals) != len(props): row[key]["error"] = (out or "")[-600:]
    results.append(row)
    print(json.dumps(row), flush=True)

(HERE / "results.json").write_text(json.dumps(results, indent=1) + "\n")
