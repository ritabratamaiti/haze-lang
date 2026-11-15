"""
Writes Haze translations of PRISM's DTMC examples, and the PRISM properties that match them.

    python bench/prism/gen.py

The models go to bench/prism/models, with cases.json listing each model's PRISM counterpart and
properties. run.py runs both tools and compares them.
"""
import json, pathlib

out = pathlib.Path(__file__).resolve().parent / "models"
out.mkdir(exist_ok=True)
cases = []


def dice():
    hz = """-- Knuth and Yao's die: a fair six-sided die from fair coin flips (PRISM: simple/dice/dice.pm)
system Die {
  var s : Num := 0
  var d : Num := 0
  step {
    if s == 0 { if flip(0.5) { s := 1 } else { s := 2 } }
    else if s == 1 { if flip(0.5) { s := 3 } else { s := 4 } }
    else if s == 2 { if flip(0.5) { s := 5 } else { s := 6 } }
    else if s == 3 { if flip(0.5) { s := 1 } else { s := 7; d := 1 } }
    else if s == 4 { s := 7; if flip(0.5) { d := 2 } else { d := 3 } }
    else if s == 5 { s := 7; if flip(0.5) { d := 4 } else { d := 5 } }
    else if s == 6 { if flip(0.5) { s := 2 } else { s := 7; d := 6 } }
  }
}

#prob Die |= eventually s == 7 and d == 6
#expect Die |= steps until s == 7
"""
    (out / "dice.hz").write_text(hz)
    cases.append({"model": "Knuth-Yao die", "size": "", "haze": "dice.hz",
                  "prism": "simple/dice/dice.pm", "consts": "x=1",
                  "props": [["probability of a 6", "P=? [ F s=7 & d=6 ]"],
                            ["expected coin flips", "R{\"coin_flips\"}=? [ F s=7 ]"]]})


def herman(n, K):
    left = {i: (i - 1 if i > 1 else n) for i in range(1, n + 1)}   # process i reads its left neighbor
    tokens = " + ".join(f"tok(x{i}, x{left[i]})" for i in range(1, n + 1))
    lines = [f"-- Herman's self-stabilizing ring with {n} processes (PRISM: dtmcs/herman/herman{n}.pm),",
             "-- starting with every process holding a token",
             "def tok(a : Bool, b : Bool) : Num := if a == b then 1 else 0",
             "",
             "system Herman {"] + [f"  var x{i} : Bool := false" for i in range(1, n + 1)] + ["  step {"]
    lines += [f"    let o{i} := x{i}" for i in range(1, n + 1)]
    lines += [f"    if o{i} == o{left[i]} {{ x{i} := flip(0.5) }} else {{ x{i} := o{left[i]} }}" for i in range(1, n + 1)]
    lines += ["  }", "}", "",
              "explore 2000000",
              f"#prob Herman |= eventually[{K}] {tokens} == 1",
              f"#expect Herman |= steps until {tokens} == 1", ""]
    name = f"herman{n}.hz"
    (out / name).write_text("\n".join(lines))
    start = "&".join(f"x{i}=0" for i in range(1, n + 1))
    cases.append({"model": "Herman", "size": f"N = {n}", "haze": name,
                  "prism": f"dtmcs/herman/herman{n}.pm", "consts": "k=0,K=0",
                  "props": [[f"stable within {K} steps", f"filter(state, P=? [ F<={K} \"stable\" ], {start})"],
                            ["expected steps to stabilize", f"filter(state, R{{\"steps\"}}=? [ F \"stable\" ], {start})"]]})


def leader(n, k):
    ps = range(1, n + 1)
    nxt = {i: (i + 1 if i < n else 1) for i in ps}           # process i reads process i+1
    lines = [f"-- Itai and Rodeh's synchronous leader election, {n} processes choosing from {k} values",
             f"-- (PRISM: dtmcs/leader_sync/leader{n}_{k}.pm), step for step: each round is a pick,",
             f"-- {n - 1} reads and a decision",
             "enum Phase = Pick | Read | Decide | Elected",
             "",
             "system Leader {",
             "  var phase : Phase := Pick",
             "  var c : Num := 1"]
    for i in ps:
        lines += [f"  var u{i} : Bool := false", f"  var v{i} : Num := 0", f"  var p{i} : Num := 0"]
    lines += ["  step {", "    match phase {", "      Pick => {"]
    for i in ps:
        lines += [f"        let r{i} := uniform(0, {k - 1})", f"        p{i} := r{i}", f"        v{i} := r{i}", f"        u{i} := true"]
    lines += ["        phase := Read", "      }", "      Read => {"]
    for i in ps:
        lines += [f"        let ou{i} := u{i}", f"        let ov{i} := v{i}"]
    lines += [f"        if c < {n - 1} {{"]
    for i in ps:
        lines += [f"          u{i} := ou{i} and p{i} != ov{nxt[i]}",
                  f"          v{i} := ov{nxt[i]}",
                  f"          if not ou{i} {{ p{i} := 0 }}"]
    lines += ["          c := c + 1", "        } else {"]
    for i in ps:
        lines += [f"          u{i} := ou{i} and p{i} != ov{nxt[i]}", f"          v{i} := 0", f"          if ou{i} {{ p{i} := 0 }}"]
    lines += ["          phase := Decide", "        }", "      }", "      Decide => {"]
    anyu = " or ".join(f"u{i}" for i in ps)
    lines += [f"        if {anyu} {{ phase := Elected }} else {{ phase := Pick; c := 1 }}"]
    for i in ps:
        lines += [f"        u{i} := false", f"        v{i} := 0", f"        p{i} := 0"]
    lines += ["      }", "      _ => skip", "    }", "  }", "}", "",
              f"#prob Leader |= eventually[{n + 1}] phase == Elected",
              "#expect Leader |= steps until phase == Elected", ""]
    name = f"leader{n}_{k}.hz"
    (out / name).write_text("\n".join(lines))
    cases.append({"model": "Leader election", "size": f"N = {n}, K = {k}", "haze": name, "round": n + 1,
                  "prism": f"dtmcs/leader_sync/leader{n}_{k}.pm", "consts": "L=1",
                  "props": [["leader in the first round", f"P=? [ F<={n + 1} \"elected\" ]"],
                            ["expected rounds", "R{\"num_rounds\"}=? [ F \"elected\" ]"]]})


dice()
for n in (3, 5, 7, 9):
    herman(n, 10)
for n, k in ((3, 2), (3, 4), (4, 2), (4, 4), (5, 2), (5, 4), (6, 2), (6, 4)):
    leader(n, k)
(out / "cases.json").write_text(json.dumps(cases, indent=1) + "\n")
print(f"{len(cases)} models in {out}")
