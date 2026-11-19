/-
Copyright (c) 2026 Ritabrata Maiti. All rights reserved.
Released under the Functional Source License 1.1 (FSL-1.1-ALv2) as described in the file LICENSE.md.
Authors: Ritabrata Maiti
-/
import Haze.Core

/-!
# Kernel Type Checker

The kernel type checker checks every elaborated declaration again, independently of the
elaborator, before the declaration enters the environment. It plays the role of Lean's C++ kernel
(reached through `Lean.Environment.addDecl`). Unlike Lean's kernel, it computes a graded
judgment `Γ ⊢ e : T @ g`, and it rejects a declaration whose grade exceeds the grade written in
its annotation, such as `@ prob`.

## Main Definitions

* `Haze.Kernel.infer`: infers the type and grade of a term.
* `Haze.Kernel.checkFun`: infers the latent grade of a possibly recursive function.
* `Haze.Kernel.addDecl`: checks a declaration and adds it to the environment.
-/

namespace Haze.Kernel

/--
The checking monad of the kernel. An error is the message explaining why a declaration was
rejected.
-/
abbrev CheckM := Except String

/--
The typing context: the environment, the types of the local variables (innermost first) and the
state variables of the enclosing system.
-/
structure TCtx where
  env : Env
  locals : List Ty := []
  sysVars : Array (String × Ty) := #[]
  inSystem : Bool := false
  /--
  The grade of the state variables: `crisp` inside the step of a system, and the grade of the
  whole system in a property about it.
  -/
  svarGrade : Grade := .crisp

/--
Computes the type of a literal value. Rejects degrees outside the interval from 0 to 1 and
constructors that the environment doesn't define.
-/
def typeOfValue (env : Env) : Value → CheckM Ty
  | .bool _ => pure .bool
  | .num _ => pure .num
  | .deg q => if 0 ≤ q && q ≤ 1 then pure .deg else throw s!"kernel: degree {fmtQ q} outside [0,1]"
  | .tag ty i => match env.enums[ty]? with
    | some cs => if i < cs.size then pure (.enum ty) else throw s!"kernel: bad constructor index for {ty}"
    | none => throw s!"kernel: unknown enum {ty}"
  | .ival .. => throw "kernel: an interval is not a literal"

/--
The parameter types and result type of a primitive. Equality and inequality accept two arguments
of any one type, so they have no fixed signature and return `none`.
-/
def primSig : Prim → Option (List Ty × Ty)
  | .add | .sub | .mul | .div | .min | .max => some ([.num, .num], .num)
  | .neg | .abs | .floor => some ([.num], .num)
  | .lt | .le => some ([.num, .num], .bool)
  | .band | .bor => some ([.bool, .bool], .bool)
  | .bnot => some ([.bool], .bool)
  | .tand _ | .tor _ => some ([.deg, .deg], .deg)
  | .tnot | .very => some ([.deg], .deg)
  | .degOfBool => some ([.bool], .deg)
  | .numOfDeg => some ([.deg], .num)
  | .degOfNum => some ([.num], .deg)
  | .tri => some ([.num, .num, .num, .num], .deg)
  | .trap => some ([.num, .num, .num, .num, .num], .deg)
  | .rampUp | .rampDown => some ([.num, .num, .num], .deg)
  | .eq | .ne => none

def expectTy (what : String) (expected actual : Ty) : CheckM Unit :=
  unless expected == actual do
    throw s!"kernel: type mismatch in {what}: expected {expected}, got {actual}"

/--
Infers the type and grade of a term, that is, the graded judgment `Γ ⊢ e : T @ g`.

The grade of a term joins the grades of its parts. Stochastic conditionals, random primitives and
categorical choices add `prob`, a global variable contributes its own grade (`fuzzy` for a fuzzy
parameter), and a call adds the latent grade of the function.
-/
partial def infer (c : TCtx) : Expr → CheckM (Ty × Grade)
  | .lit v => return (← typeOfValue c.env v, .crisp)
  | .bvar i => match c.locals[i]? with
    | some t => pure (t, .crisp)
    | none => throw s!"kernel: loose bound variable #{i}"
  | .gvar n => match c.env.global? n with
    | some g => pure (g.ty, g.grade)
    | none => throw s!"kernel: unknown global {n}"
  | .svar i =>
    if !c.inSystem then throw "kernel: state variable outside a system" else
    match c.sysVars[i]? with
    | some (_, t) => pure (t, c.svarGrade)
    | none => throw s!"kernel: bad state variable #{i}"
  | .crashed =>
    if c.inSystem then pure (.bool, c.svarGrade) else throw "kernel: `crashed` outside a system"
  | .prim op args => do
    let rs ← args.mapM (infer c)
    let g := Grade.joinAll (rs.map (·.2))
    match op with
    | .eq | .ne =>
      match rs with
      | [(a, _), (b, _)] => expectTy "equality" a b; pure (.bool, g)
      | _ => throw "kernel: arity mismatch for equality"
    | _ =>
      let some (ps, r) := primSig op | throw "kernel: unknown primitive"
      unless ps.length == rs.length do throw s!"kernel: arity mismatch for {repr op}"
      for (p, (a, _)) in ps.zip rs do expectTy s!"argument of {repr op}" p a
      pure (r, g)
  | .call f args => do
    let some fi := c.env.funs[f]? | throw s!"kernel: unknown function {f}"
    unless fi.params.length == args.length do throw s!"kernel: arity mismatch calling {f}"
    let rs ← args.mapM (infer c)
    for ((_, p), (a, _)) in fi.params.zip rs do expectTy s!"argument of {f}" p a
    pure (fi.ret, (Grade.joinAll (rs.map (·.2))).join fi.latent)
  | .ite cnd t e => do
    let (tc, gc) ← infer c cnd
    expectTy "if-condition" .bool tc
    let (tt, gt) ← infer c t
    let (te, ge) ← infer c e
    expectTy "if-branches" tt te
    pure (tt, Grade.joinAll [gc, gt, ge])
  | .choose p t e => do
    let (tp, gp) ← infer c p
    expectTy "stochastic condition" .deg tp
    let (tt, gt) ← infer c t
    let (te, ge) ← infer c e
    expectTy "stochastic branches" tt te
    pure (tt, Grade.joinAll [gp, gt, ge, .probG])
  | .rand r args => do
    let rs ← args.mapM (infer c)
    let (ps, ret) : List Ty × Ty := match r with
      | .bernoulli => ([.deg], .bool)
      | .uniform => ([.num, .num], .num)
      | .binomial => ([.num, .deg], .num)
    unless ps.length == rs.length do throw "kernel: arity mismatch for random primitive"
    for (p, (a, _)) in ps.zip rs do expectTy "random primitive argument" p a
    pure (ret, (Grade.joinAll (rs.map (·.2))).join .probG)
  | .cat alts => do
    let some (e0, _) := alts.head? | throw "kernel: empty categorical distribution"
    let (t0, _) ← infer c e0
    let mut g := Grade.probG
    let mut total : Rat := 0
    for (e, w) in alts do
      let (t, ge) ← infer c e
      expectTy "categorical alternatives" t0 t
      if w < 0 then throw s!"kernel: negative weight {fmtQ w}"
      total := total + w
      g := g.join ge
    unless total == 1 do throw s!"kernel: categorical weights sum to {fmtQ total}, not 1"
    pure (t0, g)
  | .catW alts => do
    let some (e0, _) := alts.head? | throw "kernel: empty categorical distribution"
    let (t0, _) ← infer c e0
    let mut g := Grade.probG
    for (e, w) in alts do
      let (t, ge) ← infer c e
      expectTy "categorical alternatives" t0 t
      let (tw, gw) ← infer c w
      expectTy "categorical weight" .num tw
      g := g.join ge |>.join gw
    pure (t0, g)
  | .letE v b => do
    let (tv, gv) ← infer c v
    let (tb, gb) ← infer { c with locals := tv :: c.locals } b
    pure (tb, gv.join gb)
  | .quant _ isDeg _ lo hi body => do
    let (tl, gl) ← infer c lo
    let (th, gh) ← infer c hi
    expectTy "quantifier bound" .num tl
    expectTy "quantifier bound" .num th
    let (tb, gb) ← infer { c with locals := .num :: c.locals } body
    expectTy "quantifier body" (if isDeg then .deg else .bool) tb
    pure (tb, Grade.joinAll [gl, gh, gb])
  | .matchE s arms dflt => do
    let (ts, gs) ← infer c s
    let .enum en := ts | throw s!"kernel: match on non-enum type {ts}"
    let some cs := c.env.enums[en]? | throw s!"kernel: unknown enum {en}"
    let idxs := arms.map (·.1)
    if idxs.any (· ≥ cs.size) then throw "kernel: bad constructor in match"
    if idxs.eraseDups.length != idxs.length then throw "kernel: duplicate match arm"
    if dflt.isNone && idxs.length != cs.size then throw "kernel: non-exhaustive match"
    let bodies := arms.map (·.2) ++ dflt.toList
    let some b0 := bodies.head? | throw "kernel: empty match"
    let (t0, _) ← infer c b0
    let mut g := gs
    for b in bodies do
      let (t, gb) ← infer c b
      expectTy "match arms" t0 t
      g := g.join gb
    pure (t0, g)

/-- Checks a statement of a system step and returns its grade. -/
partial def checkStmt (c : TCtx) : Stmt → CheckM Grade
  | .skip => pure .crisp
  | .assign i e => do
    let some (n, t) := c.sysVars[i]? | throw s!"kernel: bad state variable #{i}"
    let (te, g) ← infer c e
    expectTy s!"assignment to {n}" t te
    pure g
  | .seq a b => return (← checkStmt c a).join (← checkStmt c b)
  | .ite cnd t e => do
    let (tc, gc) ← infer c cnd
    expectTy "if-condition" .bool tc
    return Grade.joinAll [gc, ← checkStmt c t, ← checkStmt c e]
  | .choose p t e => do
    let (tp, gp) ← infer c p
    expectTy "stochastic condition" .deg tp
    return Grade.joinAll [gp, ← checkStmt c t, ← checkStmt c e, .probG]
  | .matchS s arms dflt => do
    let (ts, gs) ← infer c s
    let .enum en := ts | throw s!"kernel: match on non-enum type {ts}"
    let some cs := c.env.enums[en]? | throw s!"kernel: unknown enum {en}"
    let idxs := arms.map (·.1)
    if idxs.any (· ≥ cs.size) then throw "kernel: bad constructor in match"
    if idxs.eraseDups.length != idxs.length then throw "kernel: duplicate match arm"
    let mut g := gs.join (← checkStmt c dflt)
    for (_, b) in arms do g := g.join (← checkStmt c b)
    pure g
  | .letS v body _ => do
    let (tv, gv) ← infer c v
    return gv.join (← checkStmt { c with locals := tv :: c.locals } body)
  | .assert cnd => do
    let (tc, g) ← infer c cnd
    expectTy "assert" .bool tc
    pure g

/--
Rejects a declaration that has a declared grade unless its inferred grade is less than or equal
to the declared one.
-/
def checkDeclared (what : String) (declared : Option Grade) (actual : Grade) : CheckM Unit :=
  match declared with
  | some d => unless actual.le d do
      throw s!"kernel: grade mismatch for {what}: declared @{d} but the term is @{actual}"
  | none => pure ()

/-- The indices of the state variables that a statement can assign to. -/
partial def assignedVars : Stmt → List Nat
  | .assign i _ => [i]
  | .seq a b | .ite _ a b | .choose _ a b => assignedVars a ++ assignedVars b
  | .matchS _ arms d => (arms.flatMap fun (_, b) => assignedVars b) ++ assignedVars d
  | .letS _ b _ => assignedVars b
  | .skip | .assert _ => []

/-- The largest horizon `k` accepted in a temporal property. -/
def maxHorizon : Nat := 100000

/--
Checks a property and returns its type and grade. A property with a nonzero horizon must name a
system. If `allowNum` is `false`, the property must have type `Bool` or `Deg`.
-/
def checkSpec (env : Env) (spec : PropSpec) (allowNum : Bool) : CheckM (Ty × Grade) := do
  let k := match spec.mode with | .after k | .always k | .eventually k => k | _ => 0
  if k > maxHorizon then throw s!"kernel: horizon {k} exceeds {maxHorizon}"
  let c ← match spec.sys with
    | none =>
      if k != 0 || spec.mode.unbounded then throw "kernel: temporal operators need a system (`S |= ...`)"
      pure { env : TCtx }
    | some s =>
      let some si := env.systems[s]? | throw s!"kernel: unknown system {s}"
      pure { env, sysVars := si.vars, inSystem := true, svarGrade := si.grade : TCtx }
  -- the arguments of a parameterized system are ordinary terms, and their grades count too
  let mut gArgs := Grade.crisp
  match spec.sys.bind (env.systems[·]?) with
  | some si =>
    unless spec.args.length == si.params do
      throw s!"kernel: system {si.name} takes {si.params} parameter(s), got {spec.args.length}"
    for (a, (n, ty)) in spec.args.zip (si.vars.toList.take si.params) do
      let (ta, ga) ← infer { env } a
      expectTy s!"parameter {n}" ty ta
      gArgs := gArgs.join ga
  | none => unless spec.args.isEmpty do throw "kernel: arguments given without a system"
  let (t, g) ← infer c spec.body
  let mut g := g.join gArgs
  -- a conditional property compares two probabilities at the same step
  if let some cond := spec.given then
    match spec.mode with
    | .after _ => pure ()
    | _ => throw "kernel: `given` is only supported with after[k] or without a modality"
    let (tc, gc) ← infer c cond
    expectTy "condition after `given`" .bool tc
    g := g.join gc
  match spec.mode with
  | .after _ => pure ()
  | .stepsUntil =>
    unless t == .bool do throw s!"kernel: `steps until` needs a Bool property, got {t}"
    -- the result is a number of steps, not a degree of truth
    unless allowNum do throw "kernel: `steps until` gives a number of steps; use it with #expect"
  | _ => unless t == .bool || t == .deg do throw s!"kernel: temporal property must be Bool or Deg, got {t}"
  unless allowNum || t == .bool || t == .deg do throw s!"kernel: claims must be Bool or Deg, got {t}"
  pure (t, g)

/--
Checks a function and infers its latent grade, the grade that each call adds.

The body of a recursive function calls the function itself, so its grade depends on the latent
grade being computed. The kernel therefore takes the least fixed point of grade inference, which
exists and is reached after a few iterations because grades form a finite lattice.
-/
def checkFun (env : Env) (f : FunInfo) (declared : Option Grade) : CheckM FunInfo := do
  let base := if f.recursive then Grade.divergeG else .crisp
  let mut g := base
  for _ in [0:5] do
    let env' := { env with funs := env.funs.insert f.name { f with latent := g } }
    let c : TCtx := { env := env', locals := (f.params.map (·.2)).reverse }
    let (t, gb) ← infer c f.body
    expectTy s!"body of {f.name}" f.ret t
    let g' := gb.join base
    if g' == g then
      checkDeclared s!"function {f.name}" declared g
      return { f with latent := g }
    g := g.join g'
  throw "kernel: grade inference did not converge"

/--
Checks a declaration and adds it to the environment. This is the entry point of the kernel.
Observations, claims and queries are checked but leave the environment unchanged; the front end
adds a claim itself once the model checker has accepted it.
-/
def addDecl (env : Env) : Decl → CheckM Env
  | .logic l => pure { env with logic := l }
  | .explore _ => pure env
  | .enumD n cs => do
    if env.contains n then throw s!"kernel: {n} already declared"
    if cs.isEmpty then throw "kernel: empty enum"
    let mut env := { env with enums := env.enums.insert n cs }
    for h : i in [0:cs.size] do
      let cn := cs[i]
      if env.contains cn then throw s!"kernel: {cn} already declared"
      env := { env with ctors := env.ctors.insert cn (n, i) }
    pure env
  | .param n ty support => do
    if env.contains n then throw s!"kernel: {n} already declared"
    if support.isEmpty then throw "kernel: fuzzy parameter with empty support"
    for (v, m) in support do
      expectTy s!"support of {n}" ty (← typeOfValue env v)
      unless 0 ≤ m && m ≤ 1 do throw s!"kernel: membership {fmtQ m} outside [0,1]"
    let vs := support.map (·.1)
    if vs.eraseDups.length != vs.length then throw s!"kernel: duplicate support value in {n}"
    unless support.any (·.2 == 1) do
      throw s!"kernel: fuzzy parameter {n} is not normal (no value has membership 1)"
    pure (env.addGlobal { name := n, ty, grade := .fuzzyG, kind := .param support })
  | .cparam n shape => do
    if env.contains n then throw s!"kernel: {n} already declared"
    match shape with
    | .trap a b c d =>
      unless a ≤ b && b ≤ c && c ≤ d do
        throw s!"kernel: the corners of {n} must be in increasing order"
    | .likelihood k t =>
      unless k ≤ t && 0 < t do
        throw s!"kernel: likelihood of {n} needs 0 < trials and failures ≤ trials"
    pure (env.addGlobal { name := n, ty := .num, grade := .fuzzyG, kind := .cparam shape })
  | .levels n => do
    unless 0 < n && n ≤ 1000 do throw "kernel: levels must be between 1 and 1000"
    pure env
  | .node n ty val isInput declared => do
    if env.contains n then throw s!"kernel: {n} already declared"
    let (t, g) ← infer { env } val
    expectTy s!"definition of {n}" ty t
    checkDeclared n declared g
    pure (env.addGlobal { name := n, ty, grade := g, kind := .node val isInput })
  | .fn f declared => do
    if env.contains f.name then throw s!"kernel: {f.name} already declared"
    let f ← checkFun env f declared
    pure { env with funs := env.funs.insert f.name f }
  | .observe cnd => do
    let (t, _) ← infer { env } cnd
    expectTy "observe" .bool t
    pure env
  | .system s => do
    if env.contains s.name then throw s!"kernel: {s.name} already declared"
    unless s.vars.size == s.init.size && s.params ≤ s.vars.size do throw "kernel: malformed system"
    -- initial values may refer to the parameters, but not to other state variables
    let paramCtx : TCtx := { env, sysVars := s.vars.extract 0 s.params, inSystem := true }
    let mut g := Grade.crisp
    for h : i in [0:s.vars.size] do
      let (n, t) := s.vars[i]
      let some e := s.init[i]? | throw "kernel: malformed system"
      let (te, ge) ← infer (if i < s.params then { env } else paramCtx) e
      expectTy s!"initial value of {n}" t te
      g := g.join ge
    -- parameters are fixed for the whole run
    for i in assignedVars s.step do
      if i < s.params then
        throw s!"kernel: the step of {s.name} assigns to its parameter {(s.vars[i]?.map (·.1)).getD "?"}"
    g := g.join (← checkStmt { env, sysVars := s.vars, inSystem := true } s.step)
    pure { env with systems := env.systems.insert s.name { s with grade := g } }
  | .claim n _ spec bound => do
    if env.contains n then throw s!"kernel: {n} already declared"
    let _ ← checkSpec env spec false
    match bound with
    | .ge q | .le q => unless 0 ≤ q && q ≤ 1 do throw s!"kernel: probability bound {fmtQ q} outside [0,1]"
    | .none => pure ()
    pure env
  | .query k spec => do
    if let .tests _ := k then
      if spec.sys.isNone then throw "kernel: #tests needs a system (`S |= ...`)"
      if spec.mode.unbounded then throw "kernel: #tests needs a bounded property, such as always[k]"
      if spec.given.isSome then throw "kernel: #tests doesn't support `given`"
    let numOk := match k with | .prob | .tests _ => false | _ => true
    let _ ← checkSpec env spec numOk
    pure env
  | .print _ => pure env

end Haze.Kernel
