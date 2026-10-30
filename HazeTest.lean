/-
Copyright (c) 2026 Ritabrata Maiti. All rights reserved.
Released under the PolyForm Noncommercial License 1.0.0 as described in the file LICENSE.md.
Authors: Ritabrata Maiti
-/
import Haze.Frontend

/-!
# Golden Tests

Every `.hz` file in `tests/` and `examples/` is checked, and its output is compared with the
`.expected` file next to it. Run the tests with `lake test`. After an intended change in
output, regenerate the expected files with `lake exe hazetest --update`.
-/

def normalize (s : String) : String :=
  (s.replace "\r\n" "\n").trimAscii.toString

def main (args : List String) : IO UInt32 := do
  let update := args.contains "--update"
  let mut failed := 0
  let mut total := 0
  for dir in ["tests", "examples"] do
    let files ← System.FilePath.walkDir dir
    let files := (files.filter (·.extension == some "hz")).qsort (·.toString < ·.toString)
    for f in files do
      total := total + 1
      let src ← IO.FS.readFile f
      let name := f.toString.replace "\\" "/"
      let (out, _) := Haze.Frontend.run name src
      let expFile := f.withExtension "expected"
      if update then
        IO.FS.writeFile expFile (out ++ "\n")
        IO.println s!"updated {expFile}"
        continue
      if !(← expFile.pathExists) then
        IO.println s!"FAIL {name}: missing {expFile} (run `lake exe hazetest --update`)"
        failed := failed + 1
        continue
      let expected ← IO.FS.readFile expFile
      if normalize out == normalize expected then
        IO.println s!"ok   {name}"
      else
        failed := failed + 1
        IO.println s!"FAIL {name}"
        let a := (normalize expected).splitOn "\n"
        let b := (normalize out).splitOn "\n"
        for i in [0:max a.length b.length] do
          let x := a.getD i "<eof>"
          let y := b.getD i "<eof>"
          if x != y then
            IO.println s!"  line {i+1}:\n    expected: {x}\n    actual:   {y}"
            break
  unless update do IO.println s!"{total - failed}/{total} golden tests passed"
  return if failed == 0 then 0 else 1
