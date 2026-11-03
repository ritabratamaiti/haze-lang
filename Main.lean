/-
Copyright (c) 2026 Ritabrata Maiti. All rights reserved.
Released under the PolyForm Noncommercial License 1.0.0 as described in the file LICENSE.md.
Authors: Ritabrata Maiti
-/
import Haze.Frontend

/-!
# Command-Line Interface

`haze [--fuel N] [--json] FILE.hz...` checks Haze source files and prints their messages, or one
JSON record per message with `--json`. The exit status is 1 if any declaration was rejected and 2
if the arguments are invalid.
-/

/-- The help text of the command-line interface. -/
def usage : String :=
  "usage: haze [--fuel N] [--json] FILE.hz...\n" ++
  "Checks Haze programs: graded types, exact probabilities, fuzzy [belief, plausibility].\n" ++
  "  --fuel N  bound on nested function calls (default 1000)\n" ++
  "  --json    print one JSON record per message"

def main (args : List String) : IO UInt32 := do
  let mut opts : Haze.Frontend.Options := {}
  let mut files := #[]
  let mut json := false
  let mut rest := args
  while !rest.isEmpty do
    match rest with
    | "--fuel" :: n :: tl =>
      let some k := n.toNat? | IO.eprintln "--fuel expects a number"; return 2
      opts := { opts with fuel := k }; rest := tl
    | "--json" :: tl => json := true; rest := tl
    | ("-h" :: _) | ("--help" :: _) => IO.println usage; return 0
    | f :: tl => files := files.push f; rest := tl
    | [] => pure ()
  if files.isEmpty then IO.eprintln usage; return 2
  let mut errors := 0
  for f in files do
    let src ← IO.FS.readFile f
    let (out, n) := if json then Haze.Frontend.runJson f src opts else Haze.Frontend.run f src opts
    unless out.isEmpty do IO.println out
    errors := errors + n
  return if errors == 0 then 0 else 1
