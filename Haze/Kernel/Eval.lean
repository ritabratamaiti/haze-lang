/-
Exact semantics of Haze kernel terms.

`M α` is an exact finite sub-distribution over `Res α` (a value or `stuck` = out of fuel),
in an error monad for genuine runtime faults. All weights are exact rationals.
-/
import Haze.Kernel.Check

namespace Haze.Kernel
open Std

structure M (α : Type) where
  run : Except String (List (Res α × Rat))

namespace M
def pure (a : α) : M α := ⟨.ok [(.ok a, 1)]⟩

def bind (m : M α) (f : α → M β) : M β := ⟨do
  let xs ← m.run
  let mut out : Array (Res β × Rat) := #[]
  for (r, w) in xs do
    match r with
    | .stuck => out := out.push (.stuck, w)
    | .ok a =>
      let ys ← (f a).run
      for (s, v) in ys do
        if w * v != 0 then out := out.push (s, w * v)
  return out.toList⟩

instance : Monad M where
  pure := M.pure
  bind := M.bind

def fail (msg : String) : M α := ⟨.error msg⟩
def stuck : M α := ⟨.ok [(.stuck, 1)]⟩

def ofList (xs : List (α × Rat)) : M α :=
  ⟨.ok (xs.filterMap fun (a, w) => if w == 0 then none else some (.ok a, w))⟩

/-- Merge equal outcomes (keeps first-occurrence order, so output is deterministic). -/
def compactList [BEq α] [Hashable α] (xs : List (α × Rat)) : List (α × Rat) := Id.run do
  let mut ix : HashMap α Nat := {}
  let mut out : Array (α × Rat) := #[]
  for (a, w) in xs do
    match ix[a]? with
    | some i => out := out.modify i fun (b, v) => (b, v + w)
    | none => ix := ix.insert a out.size; out := out.push (a, w)
  return (out.filter (·.2 != 0)).toList

def compact [DecidableEq α] [Hashable α] (m : M α) : M α := ⟨return compactList (← m.run)⟩
end M

structure ECtx where
  env : Env
  world : Array (Res Value) := #[]
  vars : Array Value := #[]
  crashed : Bool := false
  locals : List Value := []
  fuel : Nat

def asNum : Value → M Rat
  | .num q => pure q
  | v => M.fail s!"runtime: expected a number, got {repr v}"

def asDeg : Value → M Rat
  | .deg q => pure q
  | v => M.fail s!"runtime: expected a degree, got {repr v}"

def asBool : Value → M Bool
  | .bool b => pure b
  | v => M.fail s!"runtime: expected a Bool, got {repr v}"

def asInt (q : Rat) : M Int :=
  if isInt q then pure q.num else M.fail s!"runtime: expected an integer, got {fmtQ q}"

def clamp01 (q : Rat) : Rat := qmax 0 (qmin 1 q)

def tand : Logic → Rat → Rat → Rat
  | .godel, a, b => qmin a b
  | .product, a, b => a * b
  | .lukasiewicz, a, b => qmax 0 (a + b - 1)

def tor : Logic → Rat → Rat → Rat
  | .godel, a, b => qmax a b
  | .product, a, b => a + b - a * b
  | .lukasiewicz, a, b => qmin 1 (a + b)

def tri (x a b c : Rat) : Rat :=
  if x < a then 0 else if x < b then (x - a) / (b - a)
  else if x == b then 1 else if x < c then (c - x) / (c - b) else 0

def trap (x a b c d : Rat) : Rat :=
  if x < a then 0 else if x < b then (x - a) / (b - a)
  else if x ≤ c then 1 else if x < d then (d - x) / (d - c) else 0

def rampUp (x a b : Rat) : Rat :=
  if x ≤ a then 0 else if b ≤ x then 1 else (x - a) / (b - a)

def evalPrim (op : Prim) (vs : List Value) : M Value := do
  match op, vs with
  | .eq, [a, b] => pure (.bool (a == b))
  | .ne, [a, b] => pure (.bool (a != b))
  | .add, [a, b] => return .num ((← asNum a) + (← asNum b))
  | .sub, [a, b] => return .num ((← asNum a) - (← asNum b))
  | .mul, [a, b] => return .num ((← asNum a) * (← asNum b))
  | .div, [a, b] =>
    let d ← asNum b
    if d == 0 then M.fail "runtime: division by zero" else return .num ((← asNum a) / d)
  | .min, [a, b] => return .num (qmin (← asNum a) (← asNum b))
  | .max, [a, b] => return .num (qmax (← asNum a) (← asNum b))
  | .neg, [a] => return .num (-(← asNum a))
  | .abs, [a] => let q ← asNum a; return .num (if q < 0 then -q else q)
  | .floor, [a] => return .num ((← asNum a).floor : Rat)
  | .lt, [a, b] => return .bool ((← asNum a) < (← asNum b))
  | .le, [a, b] => return .bool ((← asNum a) ≤ (← asNum b))
  | .band, [a, b] => return .bool ((← asBool a) && (← asBool b))
  | .bor, [a, b] => return .bool ((← asBool a) || (← asBool b))
  | .bnot, [a] => return .bool (!(← asBool a))
  | .tand l, [a, b] => return .deg (tand l (← asDeg a) (← asDeg b))
  | .tor l, [a, b] => return .deg (tor l (← asDeg a) (← asDeg b))
  | .tnot, [a] => return .deg (1 - (← asDeg a))
  | .very, [a] => let q ← asDeg a; return .deg (q * q)
  | .degOfBool, [a] => return .deg (if ← asBool a then 1 else 0)
  | .numOfDeg, [a] => return .num (← asDeg a)
  | .degOfNum, [a] =>
    let q ← asNum a
    if 0 ≤ q && q ≤ 1 then pure (.deg q) else M.fail s!"runtime: {fmtQ q} is not a degree in [0,1]"
  | .tri, [x, a, b, c] =>
    return .deg (clamp01 (tri (← asNum x) (← asNum a) (← asNum b) (← asNum c)))
  | .trap, [x, a, b, c, d] =>
    return .deg (clamp01 (trap (← asNum x) (← asNum a) (← asNum b) (← asNum c) (← asNum d)))
  | .rampUp, [x, a, b] => return .deg (clamp01 (rampUp (← asNum x) (← asNum a) (← asNum b)))
  | .rampDown, [x, a, b] => return .deg (1 - clamp01 (rampUp (← asNum x) (← asNum a) (← asNum b)))
  | _, _ => M.fail s!"runtime: bad primitive application {repr op}"

def choose (n k : Nat) : Nat := Id.run do
  let mut r := 1
  for i in [0:k] do r := r * (n - i) / (i + 1)
  return r

def maxSupport : Nat := 100000

def evalRand (r : RandPrim) (vs : List Value) : M Value := do
  match r, vs with
  | .bernoulli, [p] =>
    let q ← asDeg p
    M.ofList [(.bool true, q), (.bool false, 1 - q)]
  | .uniform, [a, b] =>
    let lo ← asInt (← asNum a)
    let hi ← asInt (← asNum b)
    if hi < lo then M.fail s!"runtime: uniform({lo}, {hi}) is empty" else
    let n := (hi - lo + 1).toNat
    if n > maxSupport then M.fail s!"runtime: uniform support {n} too large" else
    M.ofList ((List.range n).map fun (i : Nat) => (.num ((lo + (i : Int) : Int) : Rat), (1 : Rat) / n))
  | .binomial, [n, p] =>
    let n ← asInt (← asNum n)
    let q ← asDeg p
    if n < 0 || n > 10000 then M.fail s!"runtime: binomial n={n} out of range" else
    let n := n.toNat
    M.ofList ((List.range (n + 1)).map fun (k : Nat) =>
      (.num (k : Rat), (choose n k : Rat) * q ^ k * (1 - q) ^ (n - k)))
  | _, _ => M.fail "runtime: bad random primitive application"

mutual
partial def evalArgs (c : ECtx) : List Expr → M (List Value)
  | [] => pure []
  | e :: es => do
    let v ← eval c e
    let vs ← evalArgs c es
    pure (v :: vs)

partial def eval (c : ECtx) : Expr → M Value
  | .lit v => pure v
  | .bvar i => match c.locals[i]? with
    | some v => pure v
    | none => M.fail s!"runtime: loose bound variable #{i}"
  | .gvar n => match c.env.globalIx[n]? >>= (c.world[·]?) with
    | some (.ok v) => pure v
    | some .stuck => M.stuck
    | none => M.fail s!"runtime: global {n} has no value in this world"
  | .svar i => match c.vars[i]? with
    | some v => pure v
    | none => M.fail s!"runtime: bad state variable #{i}"
  | .crashed => pure (.bool c.crashed)
  | .prim op args => M.compact do evalPrim op (← evalArgs c args)
  | .call f args => do
    let some fi := c.env.funs[f]? | M.fail s!"runtime: unknown function {f}"
    let vs ← evalArgs c args
    if c.fuel == 0 then M.stuck else
    M.compact (eval { c with locals := vs.reverse, fuel := c.fuel - 1 } fi.body)
  | .ite cnd t e => do
    if ← asBool (← eval c cnd) then eval c t else eval c e
  | .choose p t e => do
    let q ← asDeg (← eval c p)
    let b ← M.ofList [(true, q), (false, 1 - q)]
    if b then eval c t else eval c e
  | .rand r args => M.compact do evalRand r (← evalArgs c args)
  | .cat alts => M.compact do
    let i ← M.ofList (alts.mapIdx fun i (_, w) => (i, w))
    match alts[i]? with
    | some (e, _) => eval c e
    | none => M.fail "runtime: bad categorical index"
  | .letE v b => do
    let x ← eval c v
    eval { c with locals := x :: c.locals } b
  | .quant all isDeg _ lo hi body => M.compact do
    let a ← asInt (← asNum (← eval c lo))
    let b ← asInt (← asNum (← eval c hi))
    let n := (b - a + 1).toNat
    if n > maxSupport then M.fail s!"runtime: quantifier range of {n} values too large" else
    -- the unit of the aggregation (vacuous truth for ∀, falsity for ∃)
    let unit : Value := if isDeg then .deg (if all then 1 else 0) else .bool all
    let mut acc : M Value := pure unit
    for i in [0:n] do
      let x : Value := .num ((a + i : Int) : Rat)
      acc := M.compact do
        let prev ← acc
        -- short-circuit once the aggregate is absorbing
        if prev == (if isDeg then .deg (if all then 0 else 1) else .bool (!all)) then pure prev else
        let v ← eval { c with locals := x :: c.locals } body
        match prev, v with
        | .bool p, .bool q => pure (.bool (if all then p && q else p || q))
        | .deg p, .deg q => pure (.deg (if all then qmin p q else qmax p q))
        | _, _ => M.fail "runtime: ill-typed quantifier body"
    acc
  | .matchE s arms dflt => do
    match ← eval c s with
    | .tag _ i => match arms.find? (·.1 == i) with
      | some (_, b) => eval c b
      | none => match dflt with
        | some d => eval c d
        | none => M.fail "runtime: non-exhaustive match"
    | v => M.fail s!"runtime: match on non-enum value {repr v}"
end

/-- Mutable part of a system configuration. -/
structure SState where
  vars : Array Value
  crashed : Bool := false
  deriving DecidableEq, Hashable, Inhabited

/-- Execute one statement of a system step. A failed `assert` crashes the system:
the rest of the step is skipped and the crashed configuration is absorbing. -/
partial def exec (c : ECtx) (locals : List Value) (s : SState) (st : Stmt) : M SState :=
  if s.crashed then pure s else
  let ce : ECtx := { c with vars := s.vars, crashed := false, locals }
  match st with
  | .skip => pure s
  | .assign i e => do
    let v ← eval ce e
    pure { s with vars := s.vars.set! i v }
  | .seq a b => do
    let s' ← M.compact (exec c locals s a)
    exec c locals s' b
  | .ite cnd t e => do
    if ← asBool (← eval ce cnd) then exec c locals s t else exec c locals s e
  | .choose p t e => do
    let q ← asDeg (← eval ce p)
    let b ← M.ofList [(true, q), (false, 1 - q)]
    if b then exec c locals s t else exec c locals s e
  | .matchS scrut arms dflt => do
    match ← eval ce scrut with
    | .tag _ i => match arms.find? (·.1 == i) with
      | some (_, b) => exec c locals s b
      | none => exec c locals s dflt
    | v => M.fail s!"runtime: match on non-enum value {repr v}"
  | .letS v body => do
    let x ← eval ce v
    exec c (x :: locals) s body
  | .assert cnd => do
    if ← asBool (← eval ce cnd) then pure s else pure { s with crashed := true }

end Haze.Kernel
