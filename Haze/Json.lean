/-
Copyright (c) 2026 Ritabrata Maiti. All rights reserved.
Released under the PolyForm Noncommercial License 1.0.0 as described in the file LICENSE.md.
Authors: Ritabrata Maiti
-/
import Haze.Core

/-!
# JSON Output

This file defines a minimal JSON representation. `haze --json` uses it to report results in a form
that other programs can read. Rational numbers are written as strings such as `"2/3"`, so they stay
exact.
-/

namespace Haze

/-- JSON values. A number is stored as its textual representation, which is rendered unchanged. -/
inductive Json where
  | null
  | bool (b : Bool)
  | num (s : String)
  | str (s : String)
  | arr (xs : List Json)
  | obj (fields : List (String × Json))
  deriving Inhabited

namespace Json

/-- Escapes a string for use inside a JSON string literal. -/
def escape (s : String) : String :=
  s.foldl (init := "") fun acc c =>
    acc ++ match c with
      | '"' => "\\\""
      | '\\' => "\\\\"
      | '\n' => "\\n"
      | '\r' => "\\r"
      | '\t' => "\\t"
      | c => if c.toNat < 0x20 then
          let h := String.ofList (Nat.toDigits 16 c.toNat)
          "\\u" ++ String.ofList (List.replicate (4 - h.length) '0') ++ h
        else c.toString

/-- Renders a JSON value on a single line. -/
partial def render : Json → String
  | .null => "null"
  | .bool b => toString b
  | .num s => s
  | .str s => "\"" ++ escape s ++ "\""
  | .arr xs => "[" ++ ",".intercalate (xs.map render) ++ "]"
  | .obj fs => "{" ++ ",".intercalate (fs.map fun (k, v) => "\"" ++ escape k ++ "\":" ++ render v) ++ "}"

/-- Encodes an exact rational number as a JSON string such as `"2/3"` or `"5"`. -/
def rat (q : Rat) : Json :=
  .str (if q.den == 1 then toString q.num else s!"{q.num}/{q.den}")

/-- Encodes a natural number as a JSON number. -/
def nat (n : Nat) : Json := .num (toString n)

/--
Encodes a Haze value. Booleans become JSON Booleans, numbers and degrees become exact rationals,
and an enumeration value becomes the name of its constructor.
-/
def value (env : Env) : Value → Json
  | .bool b => .bool b
  | .num q | .deg q => rat q
  | .tag ty i => .str (env.ctorName ty i)

/-- Encodes an assignment of values to names as a JSON object. -/
def assignment (env : Env) (a : List (String × Value)) : Json :=
  .obj (a.map fun (n, v) => (n, value env v))

end Json
end Haze
