import Haze.Frontend

def usage : String :=
  "usage: haze [--fuel N] FILE.hz...\n" ++
  "Checks Haze programs: graded types, exact probabilities, fuzzy [belief, plausibility]."

def main (args : List String) : IO UInt32 := do
  let mut opts : Haze.Frontend.Options := {}
  let mut files := #[]
  let mut rest := args
  while !rest.isEmpty do
    match rest with
    | "--fuel" :: n :: tl =>
      let some k := n.toNat? | IO.eprintln "--fuel expects a number"; return 2
      opts := { opts with fuel := k }; rest := tl
    | ("-h" :: _) | ("--help" :: _) => IO.println usage; return 0
    | f :: tl => files := files.push f; rest := tl
    | [] => pure ()
  if files.isEmpty then IO.eprintln usage; return 2
  let mut errors := 0
  for f in files do
    let src ← IO.FS.readFile f
    let (out, n) := Haze.Frontend.run f src opts
    unless out.isEmpty do IO.println out
    errors := errors + n
  return if errors == 0 then 0 else 1
