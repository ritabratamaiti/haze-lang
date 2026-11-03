"""
Times the models in bench/ with the haze binary. Build with `lake build` first, then run

    python scripts/bench.py [--repeat N] [haze-binary]

Each model is run N times (default 3) and the fastest time is reported.
"""
import os, pathlib, subprocess, sys, time

ROOT = pathlib.Path(__file__).resolve().parent.parent
args = sys.argv[1:]
repeat = 3
if args[:1] == ["--repeat"]:
    repeat = int(args[1]); args = args[2:]
haze = args[0] if args else str(ROOT / ".lake" / "build" / "bin" / ("haze.exe" if os.name == "nt" else "haze"))
for f in sorted((ROOT / "bench").glob("*.hz")):
    best = None
    for _ in range(repeat):
        t = time.perf_counter()
        subprocess.run([haze, str(f)], capture_output=True)
        dt = time.perf_counter() - t
        best = dt if best is None else min(best, dt)
    print(f"{f.name:20} {best:8.2f} s")
