/-
Copyright (c) 2026 Ritabrata Maiti. All rights reserved.
Released under the PolyForm Noncommercial License 1.0.0 as described in the file LICENSE.md.
Authors: Ritabrata Maiti
-/
import Haze.Core
import Haze.Syntax

/-!
# Elaborator

The elaborator translates syntax trees into kernel terms, in the role of `Lean.Elab`. It
resolves names to de Bruijn indices, inserts coercions and performs type-directed
translation. Like Lean's elaborator it is not trusted: the kernel checks everything it
produces again.

The type-directed rules specific to Haze are:

* `if c then a else b` is an ordinary conditional when `c : Bool`. When `c : Deg` it becomes
  the stochastic conditional `Expr.choose`, which takes `a` with probability `c`.
* `and`, `or`, `not` and `implies` are Boolean on `Bool`. As soon as a `Deg` is involved they
  use the connectives of the active `Logic`, with `Bool` embedded as the degrees 0 and 1.
* A `Deg` can be used where a `Num` is expected. A number can be used where a `Deg` is
  expected if it lies between 0 and 1.

## Main Definitions

* `Haze.Elab.elabExpr`: elaborates an expression and infers its type.
* `Haze.Elab.elabDecl`: elaborates a top-level declaration.
-/

namespace Haze.Elab
open Haze.Syntax

/--
The elaboration context: the environment, the local variables (innermost first) and the state
variables of the enclosing system, if any.
-/
structure Scope where
  env : Env
  locals : List (String × Ty) := []
  sysVars : Array (String × Ty) := #[]
  inSystem : Bool := false
  /-- The signature of the function being defined, which recursive calls refer to. -/
  selfFun : Option (String × List Ty × Ty) := none
  pos : Pos := {}

/-- The elaboration monad. Errors carry the source position of the innermost enclosing term. -/
abbrev ElabM := ReaderT Scope (Except (Pos × String))

def err (msg : String) : ElabM α := do throw ((← read).pos, msg)

def withPos (p : Pos) (x : ElabM α) : ElabM α := withReader (fun s => { s with pos := p }) x

def withLocal (n : String) (t : Ty) (x : ElabM α) : ElabM α :=
  withReader (fun s => { s with locals := (n, t) :: s.locals }) x

/-- Resolves a type name: `Bool`, `Num`, `Deg` or a declared enumeration type. -/
def resolveTy (n : String) : ElabM Ty := do
  match n with
  | "Bool" => pure .bool
  | "Num" => pure .num
  | "Deg" => pure .deg
  | _ => if (← read).env.enums.contains n then pure (.enum n) else err s!"unknown type {n}"

/-- Resolves a grade annotation such as `prob+fuzzy`. -/
def resolveGrade (gs : List String) : ElabM Grade :=
  gs.foldlM (init := Grade.crisp) fun g n => match n with
    | "crisp" => pure g
    | "prob" => pure (g.join .probG)
    | "fuzzy" => pure (g.join .fuzzyG)
    | "partial" => pure (g.join .divergeG)
    | _ => err s!"unknown grade {n} (expected crisp, prob, fuzzy or partial)"

/--
Coerces `e` from type `from_` to type `to`.

`Bool` embeds into `Deg` as the degrees 0 and 1, and `Deg` embeds into `Num`. A `Num` used as a
`Deg` is checked to lie between 0 and 1, statically for literals and at runtime otherwise.
-/
def coerce (e : Expr) (from_ to : Ty) : ElabM Expr := do
  if from_ == to then return e
  match from_, to, e with
  | .bool, .deg, .lit (.bool b) => pure (.lit (.deg (if b then 1 else 0)))
  | .bool, .deg, _ => pure (.prim .degOfBool [e])
  | .deg, .num, .lit (.deg q) => pure (.lit (.num q))
  | .deg, .num, _ => pure (.prim .numOfDeg [e])
  | .num, .deg, .lit (.num q) =>
    if 0 ≤ q && q ≤ 1 then pure (.lit (.deg q)) else err s!"{fmtQ q} is not a degree in [0,1]"
  | .num, .deg, _ => pure (.prim .degOfNum [e])
  | .bool, .num, _ => err "expected a number, got a Bool"
  | _, _, _ => err s!"type mismatch: expected {to}, got {from_}"

/-- The least common type of two branches, in the order `Bool`, `Deg`, `Num`. -/
def unify (a b : Ty) : ElabM Ty := do
  if a == b then return a
  match a, b with
  | .bool, .deg | .deg, .bool => pure .deg
  | .num, .deg | .deg, .num => pure .num
  | _, _ => err s!"branches have incompatible types {a} and {b}"

/-- Evaluates a constant numeric expression, such as a categorical weight or a membership. -/
partial def constQ : SExpr → Option Rat
  | .num q => some q
  | .atPos _ e => constQ e
  | .un "-" a => (constQ a).map (- ·)
  | .bin "+" a b => do pure ((← constQ a) + (← constQ b))
  | .bin "-" a b => do pure ((← constQ a) - (← constQ b))
  | .bin "*" a b => do pure ((← constQ a) * (← constQ b))
  | .bin "/" a b => do let d ← constQ b; if d == 0 then none else pure ((← constQ a) / d)
  | _ => none

def logicOf : ElabM Logic := return (← read).env.logic

mutual
/-- Elaborates `e` and coerces the result to type `t`. -/
partial def elabAs (e : SExpr) (t : Ty) : ElabM Expr := do
  let (x, tx) ← elabExpr e
  coerce x tx t

partial def elabNum (e : SExpr) : ElabM Expr := elabAs e .num

partial def elabArgs (f : String) (args : List SExpr) (ps : List Ty) : ElabM (List Expr) := do
  unless args.length == ps.length do
    err s!"{f} expects {ps.length} argument(s), got {args.length}"
  (args.zip ps).mapM fun (a, t) => elabAs a t

partial def elabTruth (a b : SExpr) (boolOp : Prim) (degOp : Logic → Prim) : ElabM (Expr × Ty) := do
  let (x, tx) ← elabExpr a
  let (y, ty) ← elabExpr b
  if tx == .bool && ty == .bool then return (.prim boolOp [x, y], .bool)
  let x ← coerce x tx .deg
  let y ← coerce y ty .deg
  return (.prim (degOp (← logicOf)) [x, y], .deg)

/--
Elaborates an expression, returning the kernel term and its type.

A condition of type `Deg` turns `if` into the stochastic conditional `Expr.choose`, and connectives
on degrees use the active `Logic`.
-/
partial def elabExpr : SExpr → ElabM (Expr × Ty)
  | .atPos p e => withPos p (elabExpr e)
  | .num q => pure (.lit (.num q), .num)
  | .bool b => pure (.lit (.bool b), .bool)
  | .ident n => do
    let s ← read
    if let some i := s.locals.findIdx? (·.1 == n) then
      return (.bvar i, s.locals[i]!.2)
    if s.inSystem then
      if let some i := s.sysVars.findIdx? (·.1 == n) then
        return (.svar i, s.sysVars[i]!.2)
      if n == "crashed" then return (.crashed, .bool)
    if let some g := s.env.global? n then return (.gvar n, g.ty)
    if let some (ty, i) := s.env.ctors[n]? then return (.lit (.tag ty i), .enum ty)
    if s.env.funs.contains n then err s!"function {n} must be applied to arguments"
    if n == "crashed" then err "`crashed` is only available inside a system or a system property"
    err s!"unknown identifier {n}"
  | .call f args => elabCall f args
  | .un "-" a => return (.prim .neg [← elabNum a], .num)
  | .un "not" a => do
    let (x, tx) ← elabExpr a
    if tx == .bool then return (.prim .bnot [x], .bool)
    return (.prim .tnot [← coerce x tx .deg], .deg)
  | .un op _ => err s!"unknown unary operator {op}"
  | .bin op a b => do
    match op with
    | "+" => return (.prim .add [← elabNum a, ← elabNum b], .num)
    | "-" => return (.prim .sub [← elabNum a, ← elabNum b], .num)
    | "*" => return (.prim .mul [← elabNum a, ← elabNum b], .num)
    | "/" => return (.prim .div [← elabNum a, ← elabNum b], .num)
    | "<" => return (.prim .lt [← elabNum a, ← elabNum b], .bool)
    | "<=" => return (.prim .le [← elabNum a, ← elabNum b], .bool)
    | ">" => return (.prim .lt [← elabNum b, ← elabNum a], .bool)
    | ">=" => return (.prim .le [← elabNum b, ← elabNum a], .bool)
    | "==" | "!=" =>
      let (x, tx) ← elabExpr a
      let (y, ty) ← elabExpr b
      let (x, y) ← if tx == ty then pure (x, y) else
        match tx, ty with
        | .num, .deg | .deg, .num | .deg, .deg => pure (← coerce x tx .num, ← coerce y ty .num)
        | _, _ => err s!"cannot compare {tx} with {ty}"
      return (.prim (if op == "==" then .eq else .ne) [x, y], .bool)
    | "and" => elabTruth a b .band .tand
    | "or" => elabTruth a b .bor .tor
    | "implies" =>
      let (x, tx) ← elabExpr a
      let (y, ty) ← elabExpr b
      if tx == .bool && ty == .bool then return (.prim .bor [.prim .bnot [x], y], .bool)
      let x ← coerce x tx .deg
      let y ← coerce y ty .deg
      return (.prim (.tor (← logicOf)) [.prim .tnot [x], y], .deg)
    | _ => err s!"unknown operator {op}"
  | .is x hedges f => do
    let s ← read
    let some fi := s.env.funs[f]? | err s!"unknown fuzzy set {f}"
    let [(_, pt)] := fi.params | err s!"fuzzy set {f} must take exactly one argument"
    unless fi.ret == .deg do err s!"fuzzy set {f} must return Deg"
    let mut e : Expr := .call f [← elabAs x pt]
    for h in hedges.reverse do
      e := if h == "very" then .prim .very [e] else .prim .tnot [e]
    return (e, .deg)
  | .ite c t e => do
    let (cx, ct) ← elabExpr c
    let (tx, tt) ← elabExpr t
    let (ex, et) ← elabExpr e
    let ty ← unify tt et
    let tx ← coerce tx tt ty
    let ex ← coerce ex et ty
    match ct with
    | .bool => return (.ite cx tx ex, ty)
    | .deg => return (.choose cx tx ex, ty)
    | _ => err s!"condition must be Bool or Deg (stochastic), got {ct}"
  | .cat alts => do
    if alts.isEmpty then err "empty distribution"
    let vs ← alts.mapM fun (v, _) => elabExpr v
    let some (_, t0) := vs.head? | err "empty distribution"
    let ty ← vs.foldlM (fun acc (_, t) => unify acc t) t0
    let mut out := #[]
    for ((x, tx), (_, w)) in vs.zip alts do
      let some q := constQ w | err "distribution weights must be constant numbers"
      out := out.push (← coerce x tx ty, q)
    return (.cat out.toList, ty)
  | .letE n v b => do
    let (vx, vt) ← elabExpr v
    let (bx, bt) ← withLocal n vt (elabExpr b)
    return (.letE vx bx, bt)
  | .quant all n lo hi body => do
    let lo ← elabNum lo
    let hi ← elabNum hi
    let (bx, bt) ← withLocal n .num (elabExpr body)
    match bt with
    | .bool => return (.quant all false n lo hi bx, .bool)
    | .deg => return (.quant all true n lo hi bx, .deg)
    | _ => err s!"quantifier body must be Bool or Deg, got {bt}"
  | .matchE s arms => do
    let (sx, st) ← elabExpr s
    let .enum en := st | err s!"match expects an enum, got {st}"
    let env := (← read).env
    let mut out := #[]
    let mut dflt := none
    let mut ty : Option Ty := none
    for (c, b) in arms do
      let (bx, bt) ← elabExpr b
      ty ← match ty with | none => pure (some bt) | some t => some <$> unify t bt
      if c == "_" then dflt := some (bx, bt)
      else
        let some (ety, i) := env.ctors[c]? | err s!"unknown constructor {c}"
        unless ety == en do err s!"constructor {c} does not belong to {en}"
        out := out.push (i, bx, bt)
    let some resTy := ty | err "empty match"
    let arms ← out.toList.mapM fun (i, bx, bt) => do pure (i, ← coerce bx bt resTy)
    let dfltE ← dflt.mapM fun (bx, bt) => coerce bx bt resTy
    return (.matchE sx arms dfltE, resTy)

/-- Elaborates a call to a built-in primitive or to a declared function. -/
partial def elabCall (f : String) (args : List SExpr) : ElabM (Expr × Ty) := do
  match f, args with
  | "flip", _ | "bernoulli", _ => return (.rand .bernoulli (← elabArgs f args [.deg]), .bool)
  | "uniform", _ => return (.rand .uniform (← elabArgs f args [.num, .num]), .num)
  | "binomial", _ => return (.rand .binomial (← elabArgs f args [.num, .deg]), .num)
  | "tri", _ => return (.prim .tri (← elabArgs f args [.num, .num, .num, .num]), .deg)
  | "trap", _ => return (.prim .trap (← elabArgs f args [.num, .num, .num, .num, .num]), .deg)
  | "ramp_up", _ => return (.prim .rampUp (← elabArgs f args [.num, .num, .num]), .deg)
  | "ramp_down", _ => return (.prim .rampDown (← elabArgs f args [.num, .num, .num]), .deg)
  | "abs", _ => return (.prim .abs (← elabArgs f args [.num]), .num)
  | "floor", _ => return (.prim .floor (← elabArgs f args [.num]), .num)
  | "min", _ => return (.prim .min (← elabArgs f args [.num, .num]), .num)
  | "max", _ => return (.prim .max (← elabArgs f args [.num, .num]), .num)
  | "deg", [a] => return (← elabAs a .deg, .deg)
  | "num", [a] => return (← elabAs a .num, .num)
  | _, _ =>
    let s ← read
    if let some fi := s.env.funs[f]? then
      return (.call f (← elabArgs f args (fi.params.map (·.2))), fi.ret)
    if let some (n, ps, r) := s.selfFun then
      if n == f then return (.call f (← elabArgs f args ps), r)
    err s!"unknown function {f}"
end

/-! ## Statements -/

def varIndex (n : String) : ElabM (Nat × Ty) := do
  let s ← read
  if s.locals.any (·.1 == n) then err s!"cannot assign to local {n}; only state variables are mutable"
  match s.sysVars.findIdx? (·.1 == n) with
  | some i => pure (i, s.sysVars[i]!.2)
  | none => err s!"unknown state variable {n}"

def seqS : Stmt → Stmt → Stmt
  | .skip, b => b
  | a, .skip => a
  | a, b => .seq a b

mutual
/--
Elaborates a block of statements. A `let` statement binds a local variable for the rest of the
block.
-/
partial def elabBlock : List SStmt → ElabM Stmt
  | [] => pure .skip
  | s :: rest => do
    match s with
    | .atPos p (.letS n v) => withPos p do
      let (vx, vt) ← elabExpr v
      return .letS vx (← withLocal n vt (elabBlock rest))
    | _ => return seqS (← elabStmt s) (← elabBlock rest)

partial def elabStmt : SStmt → ElabM Stmt
  | .atPos p s => withPos p (elabStmt s)
  | .skip => pure .skip
  | .assign n e => do
    let (i, t) ← varIndex n
    return .assign i (← elabAs e t)
  | .assert e => return .assert (← elabAs e .bool)
  | .letS _ _ => err "internal: let outside block"
  | .ite c t e => do
    let (cx, ct) ← elabExpr c
    let t ← elabBlock t
    let e ← elabBlock e
    match ct with
    | .bool => return .ite cx t e
    | .deg => return .choose cx t e
    | _ => err s!"condition must be Bool or Deg (stochastic), got {ct}"
  | .matchS s arms => do
    let (sx, st) ← elabExpr s
    let .enum en := st | err s!"match expects an enum, got {st}"
    let env := (← read).env
    let mut out := #[]
    let mut dflt := Stmt.skip
    for (c, b) in arms do
      let bx ← elabBlock b
      if c == "_" then dflt := bx
      else
        let some (ety, i) := env.ctors[c]? | err s!"unknown constructor {c}"
        unless ety == en do err s!"constructor {c} does not belong to {en}"
        out := out.push (i, bx)
    return .matchS sx out.toList dflt
end

/-! ## Declarations -/

/--
Elaborates a property. If the property names a system, the system's state variables are in scope.
-/
def elabProp (p : SProp) : ElabM (PropSpec × Ty) := do
  match p.sys with
  | none =>
    let (b, t) ← elabExpr p.body
    return ({ sys := none, mode := p.mode, body := b }, t)
  | some s =>
    let some si := (← read).env.systems[s]? | err s!"unknown system {s}"
    let (b, t) ← withReader (fun sc => { sc with sysVars := si.vars, inSystem := true }) (elabExpr p.body)
    return ({ sys := some s, mode := p.mode, body := b }, t)

def elabLiteral (e : SExpr) (ty : Ty) : ElabM Value := do
  match ← elabAs e ty with
  | .lit v => pure v
  | _ =>
    match constQ e, ty with
    | some q, .num => pure (.num q)
    | some q, .deg => pure (.deg q)
    | _, _ => err "fuzzy parameter support must consist of literals"

/-- Checks whether a term calls the function `n`. Functions that call themselves are recursive. -/
partial def callsSelf (n : String) : Expr → Bool
  | .call f args => f == n || args.any (callsSelf n)
  | .prim _ args | .rand _ args => args.any (callsSelf n)
  | .ite a b c | .choose a b c => callsSelf n a || callsSelf n b || callsSelf n c
  | .cat alts => alts.any (callsSelf n ·.1)
  | .letE a b => callsSelf n a || callsSelf n b
  | .quant _ _ _ a b c => callsSelf n a || callsSelf n b || callsSelf n c
  | .matchE s arms d => callsSelf n s || arms.any (callsSelf n ·.2) || (d.map (callsSelf n)).getD false
  | _ => false

/--
Elaborates a top-level declaration into a kernel declaration. `Haze.Kernel.addDecl` checks the
result again.
-/
def elabDecl : SDecl → ElabM Decl
  | .logic l => match l with
    | "godel" | "zadeh" => pure (.logic .godel)
    | "product" => pure (.logic .product)
    | "lukasiewicz" => pure (.logic .lukasiewicz)
    | _ => err s!"unknown logic {l} (expected godel, product or lukasiewicz)"
  | .enumD n cs => pure (.enumD n cs.toArray)
  | .param n ty sup => do
    let ty ← resolveTy ty
    let sup ← sup.mapM fun (v, m) => do
      let some q := constQ m | err "memberships must be constant numbers"
      pure (← elabLiteral v ty, q)
    pure (.param n ty sup)
  | .input n ty e => do
    let ty ← resolveTy ty
    pure (.node n ty (← elabAs e ty) true none)
  | .defD n none ret g body => do
    let ty ← resolveTy ret
    let g ← g.mapM resolveGrade
    pure (.node n ty (← elabAs body ty) false g)
  | .defD n (some ps) ret g body => do
    let ty ← resolveTy ret
    let g ← g.mapM resolveGrade
    let ps ← ps.mapM fun (x, t) => do pure (x, ← resolveTy t)
    let sig := (n, ps.map (·.2), ty)
    let body ← withReader (fun s => { s with
        locals := ps.reverse ++ s.locals, selfFun := some sig }) (elabAs body ty)
    pure (.fn { name := n, params := ps, ret := ty, body, recursive := callsSelf n body } g)
  | .observe e => return .observe (← elabAs e .bool)
  | .system n vars step => do
    let vs ← vars.mapM fun (x, t, e) => do
      let t ← resolveTy t
      pure (x, t, ← elabAs e t)
    let sysVars := (vs.map fun (x, t, _) => (x, t)).toArray
    let step ← withReader (fun s => { s with sysVars, inSystem := true }) (elabBlock step)
    pure (.system { name := n, vars := sysVars, init := (vs.map (·.2.2)).toArray, step })
  | .claim isThm n p bound => do
    let (spec, t) ← elabProp p
    unless t == .bool || t == .deg do err s!"a claim must be Bool or Deg, got {t}"
    let b ← match bound with
      | none => pure Bound.none
      | some (op, e) =>
        let some q := constQ e | err "probability bound must be a constant"
        pure (if op == ">=" then Bound.ge q else Bound.le q)
    pure (.claim n isThm spec b)
  | .query c p => do
    let (spec, _) ← elabProp p
    let k := match c with
      | "#check" => QueryKind.check | "#eval" => .eval | "#prob" => .prob
      | "#expect" => .expect | _ => .outcomes
    pure (.query k spec)
  | .print n => pure (.print n)

end Haze.Elab
