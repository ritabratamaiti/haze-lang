/-
The Haze kernel type checker (analogue of Lean's `kernel/type_checker.cpp`).

It re-checks every elaborated declaration independently of the elaborator, computing the
graded judgement `Γ ⊢ e : T @ g`. The elaborator is untrusted; only declarations accepted
here enter the environment.
-/
import Haze.Core

namespace Haze.Kernel

abbrev CheckM := Except String

structure TCtx where
  env : Env
  locals : List Ty := []
  sysVars : Array (String × Ty) := #[]
  inSystem : Bool := false
  /-- grade of state variables: crisp while checking a step, the system grade in claims -/
  svarGrade : Grade := .crisp

def typeOfValue (env : Env) : Value → CheckM Ty
  | .bool _ => pure .bool
  | .num _ => pure .num
  | .deg q => if 0 ≤ q && q ≤ 1 then pure .deg else throw s!"kernel: degree {fmtQ q} outside [0,1]"
  | .tag ty i => match env.enums[ty]? with
    | some cs => if i < cs.size then pure (.enum ty) else throw s!"kernel: bad constructor index for {ty}"
    | none => throw s!"kernel: unknown enum {ty}"

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
  | .letS v body => do
    let (tv, gv) ← infer c v
    return gv.join (← checkStmt { c with locals := tv :: c.locals } body)
  | .assert cnd => do
    let (tc, g) ← infer c cnd
    expectTy "assert" .bool tc
    pure g

def checkDeclared (what : String) (declared : Option Grade) (actual : Grade) : CheckM Unit :=
  match declared with
  | some d => unless actual.le d do
      throw s!"kernel: grade mismatch for {what}: declared @{d} but the term is @{actual}"
  | none => pure ()

def maxHorizon : Nat := 100000

def checkSpec (env : Env) (spec : PropSpec) (allowNum : Bool) : CheckM (Ty × Grade) := do
  let k := match spec.mode with | .after k | .always k | .eventually k => k
  if k > maxHorizon then throw s!"kernel: horizon {k} exceeds {maxHorizon}"
  let c ← match spec.sys with
    | none =>
      if k != 0 then throw "kernel: temporal operators need a system (`S |= ...`)"
      pure { env : TCtx }
    | some s =>
      let some si := env.systems[s]? | throw s!"kernel: unknown system {s}"
      pure { env, sysVars := si.vars, inSystem := true, svarGrade := si.grade : TCtx }
  let (t, g) ← infer c spec.body
  match spec.mode with
  | .after _ => pure ()
  | _ => unless t == .bool || t == .deg do throw s!"kernel: temporal property must be Bool or Deg, got {t}"
  unless allowNum || t == .bool || t == .deg do throw s!"kernel: claims must be Bool or Deg, got {t}"
  pure (t, g)

/-- Check a function, computing its latent grade as the least fixed point over the
finite grade lattice (needed for recursion). -/
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

/-- Kernel entry point: check a declaration and add it to the environment
(analogue of `Lean.Environment.addDecl`). Queries are checked but not added. -/
def addDecl (env : Env) : Decl → CheckM Env
  | .logic l => pure { env with logic := l }
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
    unless s.vars.size == s.init.size do throw "kernel: malformed system"
    let mut g := Grade.crisp
    for h : i in [0:s.vars.size] do
      let (n, t) := s.vars[i]
      let some e := s.init[i]? | throw "kernel: malformed system"
      let (te, ge) ← infer { env } e
      expectTy s!"initial value of {n}" t te
      g := g.join ge
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
    let _ ← checkSpec env spec (k != .prob)
    pure env
  | .print _ => pure env

end Haze.Kernel
