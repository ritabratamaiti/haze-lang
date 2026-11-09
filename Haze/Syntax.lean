/-
Copyright (c) 2026 Ritabrata Maiti. All rights reserved.
Released under the Functional Source License 1.1 (FSL-1.1-ALv2) as described in the file LICENSE.md.
Authors: Ritabrata Maiti
-/
import Haze.Core

/-!
# Concrete Syntax

This file contains the lexer, the concrete syntax trees and the recursive-descent parser for Haze
source files. Together they play the role of `Lean.Parser` and `Lean.Syntax`, except that the
grammar is fixed rather than extensible.

## Main Definitions

* `Haze.Syntax.lex`: splits a source file into tokens.
* `Haze.Syntax.SExpr`, `Haze.Syntax.SStmt`, `Haze.Syntax.SDecl`: the syntax trees of
  expressions, statements and declarations.
* `Haze.Syntax.program`: parses a complete source file.
-/

namespace Haze.Syntax

/-- A position in a source file. Lines and columns start at 1. -/
structure Pos where
  line : Nat := 1
  col : Nat := 1
  deriving Inhabited, Repr

instance : ToString Pos := ⟨fun p => s!"{p.line}:{p.col}"⟩

/--
The kinds of token. Keywords are lexed as identifiers and recognized by the parser, and commands
such as `#eval` are lexed as symbols.
-/
inductive Tok where
  | ident (s : String)
  | num (q : Rat)
  | sym (s : String)
  | eof
  deriving Inhabited, Repr, BEq

/-- A token, with its source position and the range of character indices that it covers. -/
structure Token where
  tok : Tok
  pos : Pos
  start : Nat
  stop : Nat
  deriving Inhabited

/-- Reserved words, which can't be used as identifiers. -/
def keywords : List String :=
  ["logic", "enum", "param", "input", "def", "observe", "system", "var", "step", "claim",
   "theorem", "with", "prob", "if", "then", "else", "let", "in", "forall", "exists", "match",
   "and", "or", "not", "implies", "is", "very", "true", "false", "assert", "skip",
   "always", "eventually", "after", "given"]

/--
The symbols that the lexer recognizes. Multi-character symbols come first, so the lexer always
takes the longest match.
-/
def symbols : List String :=
  [":=", "~=", "|=", "==", "!=", "<=", ">=", "=>", "->", "..",
   "(", ")", "{", "}", "[", "]", ",", ":", ";", "|", "@", "<", ">", "+", "-", "*", "/", "~", "_", "="]

/-- Maps a Unicode symbol to its ASCII spelling, such as `≤` to `<=` and `≈` to `~=`. -/
def unicodeAlias : Char → Option String
  | '≈' => some "~=" | '≤' => some "<=" | '≥' => some ">=" | '≠' => some "!="
  | '⊨' => some "|=" | '→' => some "->" | '⇒' => some "=>" | _ => none

def isIdStart (c : Char) : Bool := c.isAlpha
def isIdChar (c : Char) : Bool := c.isAlphanum || c == '_' || c == '\''

/--
Splits a source file into tokens. Line comments start with `--`, and block comments are written
`/- … -/`. On failure, returns the position and message of the first lexical error.
-/
def lex (src : String) : Except (Pos × String) (Array Token) := Id.run do
  let cs := src.toList.toArray
  let n := cs.size
  let mut i := 0
  let mut line := 1
  let mut col := 1
  let mut out : Array Token := #[]
  let charAt (j : Nat) : Char := cs.getD j '\x00'
  -- `for` needs a bound. Every iteration consumes at least one character, so `n + 1`
  -- iterations are enough.
  for _ in [0:n+1] do
    if i ≥ n then break
    let c := charAt i
    if c == '\n' then
      i := i + 1; line := line + 1; col := 1; continue
    if c.isWhitespace then
      i := i + 1; col := col + 1; continue
    -- Skip comments.
    if c == '-' && charAt (i+1) == '-' then
      while i < n && charAt i != '\n' do i := i + 1
      continue
    if c == '/' && charAt (i+1) == '-' then
      let p : Pos := { line, col }
      i := i + 2; col := col + 2
      let mut closed := false
      while i < n do
        if charAt i == '-' && charAt (i+1) == '/' then
          i := i + 2; col := col + 2; closed := true; break
        if charAt i == '\n' then line := line + 1; col := 1 else col := col + 1
        i := i + 1
      if !closed then return .error (p, "unterminated comment")
      continue
    let pos : Pos := { line, col }
    let start := i
    if isIdStart c then
      let mut j := i
      while j < n && isIdChar (charAt j) do j := j + 1
      let s := String.ofList (cs.extract i j).toList
      out := out.push { tok := .ident s, pos, start, stop := j }
      col := col + (j - i); i := j; continue
    if c == '#' then
      let mut j := i + 1
      while j < n && isIdChar (charAt j) do j := j + 1
      let s := String.ofList (cs.extract i j).toList
      out := out.push { tok := .sym s, pos, start, stop := j }
      col := col + (j - i); i := j; continue
    if c.isDigit then
      let mut j := i
      let mut v : Nat := 0
      while j < n && (charAt j).isDigit do
        v := v * 10 + ((charAt j).toNat - '0'.toNat); j := j + 1
      let mut q : Rat := v
      if charAt j == '.' && (charAt (j+1)).isDigit then
        j := j + 1
        let mut scale : Nat := 1
        let mut frac : Nat := 0
        while j < n && (charAt j).isDigit do
          frac := frac * 10 + ((charAt j).toNat - '0'.toNat); scale := scale * 10; j := j + 1
        q := q + (frac : Rat) / (scale : Rat)
      out := out.push { tok := .num q, pos, start, stop := j }
      col := col + (j - i); i := j; continue
    match unicodeAlias c with
    | some s =>
      out := out.push { tok := .sym s, pos, start, stop := i + 1 }
      i := i + 1; col := col + 1; continue
    | none => pure ()
    let mut matched := false
    for s in symbols do
      let k := s.length
      if String.ofList (cs.extract i (i + k)).toList == s then
        out := out.push { tok := .sym s, pos, start, stop := i + k }
        i := i + k; col := col + k; matched := true; break
    if !matched then return .error (pos, s!"unexpected character '{c}'")
  out := out.push { tok := .eof, pos := { line, col }, start := n, stop := n }
  return .ok out

/-! ## Concrete syntax -/

/--
Expressions as written in the source, before names are resolved and types are checked. The
parser wraps subexpressions in `atPos` to record their source positions for error messages.
-/
inductive SExpr where
  | num (q : Rat)
  | bool (b : Bool)
  | ident (n : String)
  | call (f : String) (args : List SExpr)
  | bin (op : String) (a b : SExpr)
  | un (op : String) (a : SExpr)
  | is (x : SExpr) (hedges : List String) (f : String)
  | ite (c t e : SExpr)
  | cat (alts : List (SExpr × SExpr))
  | letE (n : String) (v b : SExpr)
  | quant (all : Bool) (n : String) (lo hi body : SExpr)
  | matchE (s : SExpr) (arms : List (String × SExpr))
  | atPos (p : Pos) (e : SExpr)
  deriving Inhabited, Repr

/-- Statements as written in the source. -/
inductive SStmt where
  | assign (n : String) (e : SExpr)
  | ite (c : SExpr) (t e : List SStmt)
  | matchS (s : SExpr) (arms : List (String × List SStmt))
  | letS (n : String) (v : SExpr)
  | assert (e : SExpr)
  | skip
  | atPos (p : Pos) (s : SStmt)
  deriving Inhabited, Repr

/--
A property as written in the source: a term, optionally preceded by `S |=` and a temporal modality
to evaluate it on the states of the system `S`.
-/
structure SProp where
  sys : Option String := none
  /-- The arguments of a parameterized system, as in `S(a, b) |= φ`. -/
  args : List SExpr := []
  /-- The condition after `given`, if any. -/
  given : Option SExpr := none
  mode : Temporal := .after 0
  body : SExpr
  deriving Inhabited, Repr

/-- Top-level declarations and commands as written in the source. -/
inductive SDecl where
  | logic (l : String)
  /-- `explore N`: the number of states explored for an unbounded property. -/
  | explore (n : Nat)
  | enumD (n : String) (ctors : List String)
  | param (n : String) (ty : String) (support : List (SExpr × SExpr))
  | input (n : String) (ty : String) (e : SExpr)
  | defD (n : String) (params : Option (List (String × String))) (ret : String)
      (grade : Option (List String)) (body : SExpr)
  | observe (e : SExpr)
  | system (n : String) (params : List (String × String)) (vars : List (String × String × SExpr))
      (step : List SStmt)
  | claim (isThm : Bool) (n : String) (p : SProp) (bound : Option (String × SExpr))
  | query (cmd : String) (p : SProp)
  | print (n : String)
  deriving Inhabited, Repr

/-- A parsed declaration, with its position and its source text, which messages quote. -/
structure DeclStx where
  decl : SDecl
  pos : Pos
  text : String
  deriving Inhabited

/-! ## Parser -/

structure PState where
  toks : Array Token
  i : Nat := 0

/--
The parser monad. It tracks the position in the token array and reports errors at a source
position.
-/
abbrev P := StateT PState (Except (Pos × String))

def peekTok : P Token := do let s ← get; pure (s.toks[s.i]?.getD s.toks.back!)
def peekAt (k : Nat) : P Tok := do let s ← get; pure ((s.toks[s.i + k]?.map (·.tok)).getD .eof)
def advance : P Unit := modify fun s => { s with i := s.i + 1 }
def curPos : P Pos := return (← peekTok).pos

def failAt (msg : String) : P α := do throw ((← curPos), msg)

def describe : Tok → String
  | .ident s => s!"'{s}'" | .num q => s!"number {fmtQ q}" | .sym s => s!"'{s}'" | .eof => "end of input"

def isSym (s : String) : P Bool := return (← peekTok).tok == .sym s
def isKw (s : String) : P Bool := return (← peekTok).tok == .ident s

def expectSym (s : String) : P Unit := do
  if ← isSym s then advance else failAt s!"expected '{s}', found {describe (← peekTok).tok}"

def expectKw (s : String) : P Unit := do
  if ← isKw s then advance else failAt s!"expected '{s}', found {describe (← peekTok).tok}"

def ident : P String := do
  match (← peekTok).tok with
  | .ident s =>
    if keywords.contains s then failAt s!"expected an identifier, found keyword '{s}'"
    advance; pure s
  | t => failAt s!"expected an identifier, found {describe t}"

def number : P Rat := do
  match (← peekTok).tok with
  | .num q => advance; pure q
  | t => failAt s!"expected a number, found {describe t}"

/--
Parses items separated by `sep` up to `close`, allowing a trailing separator. Doesn't consume
`close`.
-/
def sepBy (p : P α) (sep : String) (close : String) : P (List α) := do
  let mut out := #[]
  if ← isSym close then return []
  repeat
    out := out.push (← p)
    if ← isSym sep then
      advance
      if ← isSym close then break
    else
      break
  return out.toList

/--
Parses items up to `close`, with optional `sep` separators between them. Doesn't consume `close`.
-/
def itemsUntil (p : P α) (sep close : String) : P (List α) := do
  let mut out := #[]
  while !(← isSym close) do
    if (← peekTok).tok == .eof then failAt s!"expected '{close}'"
    out := out.push (← p)
    while ← isSym sep do advance
  return out.toList

def withPos (p : P SExpr) : P SExpr := do
  let pos ← curPos
  return .atPos pos (← p)

mutual
/--
Parses an expression.

The precedence levels, from loosest to tightest, are `if`, `let` and the quantifiers; `implies`;
`or`; `and`; `not`; comparisons and `is`; `+` and `-`; `*` and `/`; unary `-`; and atoms.
-/
partial def expr : P SExpr := withPos do
  if ← isKw "if" then
    advance
    let c ← expr; expectKw "then"
    let t ← expr; expectKw "else"
    let e ← expr
    return .ite c t e
  if ← isKw "let" then
    advance
    let n ← ident; expectSym ":="
    let v ← expr; expectKw "in"
    return .letE n v (← expr)
  if (← isKw "forall") || (← isKw "exists") then
    let all ← isKw "forall"
    advance
    let n ← ident; expectKw "in"
    let lo ← addE; expectSym ".."
    let hi ← addE; expectSym ","
    return .quant all n lo hi (← expr)
  implies

partial def implies : P SExpr := withPos do
  let a ← orE
  if (← isKw "implies") || (← isSym "->") then
    advance
    return .bin "implies" a (← implies)
  return a

partial def orE : P SExpr := withPos do
  let mut a ← andE
  while ← isKw "or" do
    advance; a := .bin "or" a (← andE)
  return a

partial def andE : P SExpr := withPos do
  let mut a ← notE
  while ← isKw "and" do
    advance; a := .bin "and" a (← notE)
  return a

partial def notE : P SExpr := withPos do
  if ← isKw "not" then
    advance; return .un "not" (← notE)
  cmpE

partial def cmpE : P SExpr := withPos do
  let a ← addE
  for op in ["==", "!=", "<=", ">=", "<", ">"] do
    if ← isSym op then
      advance; return .bin op a (← addE)
  if ← isKw "is" then
    advance
    let mut hedges := #[]
    while (← isKw "very") || (← isKw "not") do
      hedges := hedges.push (if ← isKw "very" then "very" else "not"); advance
    return .is a hedges.toList (← ident)
  return a

partial def addE : P SExpr := withPos do
  let mut a ← mulE
  repeat
    if ← isSym "+" then advance; a := .bin "+" a (← mulE)
    else if ← isSym "-" then advance; a := .bin "-" a (← mulE)
    else break
  return a

partial def mulE : P SExpr := withPos do
  let mut a ← unaryE
  repeat
    if ← isSym "*" then advance; a := .bin "*" a (← unaryE)
    else if ← isSym "/" then advance; a := .bin "/" a (← unaryE)
    else break
  return a

partial def unaryE : P SExpr := withPos do
  if ← isSym "-" then advance; return .un "-" (← unaryE)
  atom

partial def matchArmName : P String := do
  if ← isSym "_" then advance; pure "_" else ident

partial def atom : P SExpr := withPos do
  let t ← peekTok
  match t.tok with
  | .num q => advance; pure (.num q)
  | .ident "true" => advance; pure (.bool true)
  | .ident "false" => advance; pure (.bool false)
  | .ident "if" | .ident "let" | .ident "forall" | .ident "exists" => expr
  | .ident "match" =>
    advance
    let s ← expr
    expectSym "{"
    let arms ← itemsUntil (do let n ← matchArmName; expectSym "=>"; let e ← expr; pure (n, e)) "," "}"
    expectSym "}"
    pure (.matchE s arms)
  | .ident _ =>
    let n ← ident
    if ← isSym "(" then
      advance
      let args ← sepBy expr "," ")"
      expectSym ")"
      pure (.call n args)
    else pure (.ident n)
  | .sym "(" => advance; let e ← expr; expectSym ")"; pure e
  | .sym "{" =>
    advance
    let alts ← sepBy (do let v ← expr; expectSym ":"; let w ← expr; pure (v, w)) "," "}"
    expectSym "}"
    pure (.cat alts)
  | tok => failAt s!"expected an expression, found {describe tok}"
end

mutual
/-- Parses a block of statements in braces. Semicolons between statements are optional. -/
partial def block : P (List SStmt) := do
  expectSym "{"
  let mut out := #[]
  while !(← isSym "}") do
    if (← peekTok).tok == .eof then failAt "unterminated block"
    out := out.push (← stmt)
    while ← isSym ";" do advance
  expectSym "}"
  return out.toList

partial def stmt : P SStmt := do
  let pos ← curPos
  let s ← do
    if ← isKw "skip" then advance; pure SStmt.skip
    else if ← isKw "assert" then advance; pure (.assert (← expr))
    else if ← isKw "let" then
      advance
      let n ← ident; expectSym ":="
      pure (.letS n (← expr))
    else if ← isKw "if" then ifStmt
    else if ← isKw "match" then
      advance
      let s ← expr
      expectSym "{"
      let arms ← itemsUntil (do
        let n ← matchArmName; expectSym "=>"
        let b ← if ← isSym "{" then block else do pure [← stmt]
        pure (n, b)) "," "}"
      expectSym "}"
      pure (.matchS s arms)
    else
      let n ← ident
      expectSym ":="
      pure (.assign n (← expr))
  return .atPos pos s

partial def ifStmt : P SStmt := do
  expectKw "if"
  let c ← expr
  if ← isKw "then" then advance
  let t ← block
  if ← isKw "else" then
    advance
    if ← isKw "if" then
      let pos ← curPos
      return .ite c t [.atPos pos (← ifStmt)]
    return .ite c t (← block)
  return .ite c t []
end

def typeName : P String := ident

/--
If the tokens ahead are `S(…) |=`, returns the number of tokens up to and including the closing
parenthesis. Used to tell a property about a parameterized system from a function call.
-/
def systemArgsAhead : P (Option Nat) := do
  unless (← peekAt 1) == .sym "(" do return none
  let mut depth := 0
  let mut k := 1
  for _ in [0:10000] do
    match ← peekAt k with
    | .sym "(" => depth := depth + 1
    | .sym ")" =>
      depth := depth - 1
      if depth == 0 then
        return if (← peekAt (k + 1)) == .sym "|=" then some k else none
    | .eof => return none
    | _ => pure ()
    k := k + 1
  return none

def givenClause : P (Option SExpr) := do
  if ← isKw "given" then advance; return some (← expr)
  return none

/--
Parses an optional temporal modality: `after[k]`, `always[k]`, `eventually[k]`, `always` and
`eventually` without a bound, or `steps until`. Without one, the property is about step 0.
-/
def temporalMode : P Temporal := do
  let bound : P (Option Nat) := do
    if ← isSym "[" then
      advance; let k ← number; expectSym "]"; pure (some k.num.toNat)
    else pure none
  if ← isKw "always" then
    advance; return match ← bound with | some k => .always k | none => .alwaysInf
  else if ← isKw "eventually" then
    advance; return match ← bound with | some k => .eventually k | none => .eventuallyInf
  else if ← isKw "after" then
    advance; expectSym "["; let k ← number; expectSym "]"; return .after k.num.toNat
  else if (← peekTok).tok == .ident "steps" && (← peekAt 1) == .ident "until" then
    advance; advance; return .stepsUntil
  else return .after 0

def prop : P SProp := do
  let parseMode := temporalMode
  if let .ident s := (← peekTok).tok then
    if (← systemArgsAhead).isSome then
      advance; advance
      let args ← sepBy expr "," ")"
      expectSym ")"; expectSym "|="
      let mode ← parseMode
      let body ← expr
      return { sys := some s, args, mode, body, given := ← givenClause }
  match (← peekTok).tok, (← peekAt 1) with
  | .ident s, .sym "|=" =>
    advance; advance
    let mode ← temporalMode
    let body ← expr
    pure { sys := some s, mode, body, given := ← givenClause }
  | _, _ =>
    let body ← expr
    pure { body, given := ← givenClause }

def grade : P (List String) := do
  let mut gs := #[← ident]
  while ← isSym "+" do advance; gs := gs.push (← ident)
  return gs.toList

/-- Parses one top-level declaration or command. -/
def decl : P SDecl := do
  let t ← peekTok
  match t.tok with
  | .ident "logic" => advance; pure (.logic (← ident))
  | .ident "explore" =>
    -- a setting only at the start of a declaration, so `explore` can still be used as a name
    advance; let n ← number
    unless n.den == 1 && n.num > 0 do failAt "explore expects a positive whole number of states"
    pure (.explore n.num.toNat)
  | .ident "enum" =>
    advance
    let n ← ident; expectSym "="
    let mut cs := #[← ident]
    while ← isSym "|" do advance; cs := cs.push (← ident)
    pure (.enumD n cs.toList)
  | .ident "param" =>
    advance
    let n ← ident; expectSym ":"
    let ty ← typeName; expectSym "~="
    expectSym "{"
    let sup ← sepBy (do let v ← expr; expectSym ":"; let m ← expr; pure (v, m)) "," "}"
    expectSym "}"
    pure (.param n ty sup)
  | .ident "input" =>
    advance
    let n ← ident; expectSym ":"
    let ty ← typeName; expectSym "~"
    pure (.input n ty (← expr))
  | .ident "def" =>
    advance
    let n ← ident
    let params ← if ← isSym "(" then do
        advance
        let ps ← sepBy (do let x ← ident; expectSym ":"; let t ← typeName; pure (x, t)) "," ")"
        expectSym ")"
        pure (some ps)
      else pure none
    expectSym ":"
    let ret ← typeName
    let g ← if ← isSym "@" then do advance; pure (some (← grade)) else pure none
    expectSym ":="
    pure (.defD n params ret g (← expr))
  | .ident "observe" => advance; pure (.observe (← expr))
  | .ident "system" =>
    advance
    let n ← ident
    let params ← if ← isSym "(" then do
        advance
        let ps ← sepBy (do let x ← ident; expectSym ":"; let t ← typeName; pure (x, t)) "," ")"
        expectSym ")"
        pure ps
      else pure []
    expectSym "{"
    let mut vars := #[]
    while ← isKw "var" do
      advance
      let x ← ident; expectSym ":"
      let ty ← typeName; expectSym ":="
      vars := vars.push (x, ty, ← expr)
      while ← isSym ";" do advance
    expectKw "step"
    let body ← block
    expectSym "}"
    pure (.system n params vars.toList body)
  | .ident "claim" | .ident "theorem" =>
    let isThm := t.tok == .ident "theorem"
    advance
    let n ← ident; expectSym ":"
    let p ← prop
    let bound ← if ← isKw "with" then do
        advance; expectKw "prob"
        let op ← if ← isSym ">=" then pure ">=" else if ← isSym "<=" then pure "<=" else failAt "expected '>=' or '<='"
        advance
        pure (some (op, ← expr))
      else pure none
    pure (.claim isThm n p bound)
  | .sym "#print" => advance; pure (.print (← ident))
  | .sym c =>
    if ["#check", "#eval", "#prob", "#expect", "#outcomes"].contains c then
      advance; pure (.query c (← prop))
    else if c == "#tests" then
      -- `#tests[n]` lists the n most likely runs; plain `#tests` lists 10
      advance
      let n ← if ← isSym "[" then do
          advance; let k ← number; expectSym "]"
          unless k.den == 1 && k.num > 0 do failAt "#tests[n] needs a positive whole number"
          pure k.num.toNat
        else pure 10
      pure (.query s!"#tests {n}" (← prop))
    else failAt s!"unknown command {c}"
  | tok => failAt s!"expected a declaration, found {describe tok}"

/-- Parses a complete source file into its declarations, each with its position and source text. -/
def program (src : String) : Except (Pos × String) (Array DeclStx) := do
  let toks ← lex src
  let chars := src.toList.toArray
  let go : P (Array DeclStx) := do
    let mut out := #[]
    while (← peekTok).tok != .eof do
      let t0 ← peekTok
      let d ← decl
      let s ← get
      let stop := (s.toks[s.i - 1]?.map (·.stop)).getD t0.stop
      let text := String.ofList (chars.extract t0.start stop).toList
      out := out.push { decl := d, pos := t0.pos, text }
    return out
  return (← go.run { toks }).1

end Haze.Syntax
