/-
Copyright (c) 2026 Ritabrata Maiti. All rights reserved.
Released under the Functional Source License 1.1 (FSL-1.1-ALv2) as described in the file LICENSE.md.
Authors: Ritabrata Maiti
-/
import Haze.Frontend
import Haze.Agent

/-!
# Command-Line Interface

`haze [--fuel N] [--states N] [--json] FILE.hz...` checks Haze source files and prints their messages, or one
JSON record per message with `--json`. The exit status is 1 if any declaration was rejected and 2
if the arguments are invalid or a file can't be read. `haze agent …` sets up coding agents to use
Haze (see `Haze.Agent`).
-/

/-- The version of Haze, which `haze --version` prints. -/
def version : String := "0.1.0"

/-- The help text of the command-line interface. -/
def usage : String :=
  "usage: haze [--fuel N] [--states N] [--json] FILE.hz...\n" ++
  "       haze agent install|uninstall|status|links|hook ...\n" ++
  "       haze --version\n" ++
  "Checks Haze programs: graded types, exact probabilities, fuzzy [belief, plausibility].\n" ++
  "  --fuel N    bound on nested function calls (default 1000)\n" ++
  "  --states N  states explored for an unbounded property (default 100000)\n" ++
  "  --json      print one JSON record per message"

def main (args : List String) : IO UInt32 := do
  if let "agent" :: rest := args then return ← Haze.Agent.main rest version
  let mut opts : Haze.Frontend.Options := {}
  let mut files := #[]
  let mut json := false
  let mut rest := args
  while !rest.isEmpty do
    match rest with
    | "--fuel" :: n :: tl =>
      let some k := n.toNat? | IO.eprintln "--fuel expects a number"; return 2
      opts := { opts with fuel := k }; rest := tl
    | "--states" :: n :: tl =>
      let some k := n.toNat? | IO.eprintln "--states expects a number"; return 2
      opts := { opts with states := k }; rest := tl
    | "--json" :: tl => json := true; rest := tl
    | ("-h" :: _) | ("--help" :: _) => IO.println usage; return 0
    | ("-V" :: _) | ("--version" :: _) => IO.println s!"haze {version}"; return 0
    | f :: tl =>
      if f.startsWith "-" && f != "-" then
        IO.eprintln s!"haze: unknown option {f}\n{usage}"; return 2
      files := files.push f; rest := tl
    | [] => pure ()
  if files.isEmpty then IO.eprintln usage; return 2
  let mut errors := 0
  for f in files do
    let src ← match ← (IO.FS.readFile f).toBaseIO with
      | .ok src => pure src
      | .error e => IO.eprintln s!"haze: can't read {f}: {e}"; return 2
    let (out, n) := if json then Haze.Frontend.runJson f src opts else Haze.Frontend.run f src opts
    unless out.isEmpty do IO.println out
    errors := errors + n
  return if errors == 0 then 0 else 1
