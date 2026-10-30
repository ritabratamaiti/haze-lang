# Haze

Haze is a small verification language for software whose outcomes vary. Packets get
lost, upstreams fail, and some parameters are only known vaguely ("loss is around 2%").
A Haze program models the system as a transition system. Its claims and theorems are
checked exactly, and every answer comes back as a `[belief, plausibility]` interval
rather than a single true/false.

The architecture comes from Lean 4 (parser → elaborator → core `Expr` → trusted kernel
→ environment), and Haze is implemented in Lean. The kernel is new: its typing judgement is
graded by uncertainty, and its core calculus has stochastic conditionals, random choice
and system state built in. [docs/DESIGN.md](docs/DESIGN.md) covers how Lean is built and
what Haze changes.

```haze
param loss : Num ~= {0.01: 0.6, 0.02: 1, 0.05: 0.5, 0.1: 0.2}   -- fuzzy: "around 2%"

system Naive {
  var phase : Phase := Sending
  var charges : Num := 0
  ...
  step { ... if flip(loss) { phase := Waiting } else { charges := charges + 1 ... } ... }
}

claim   delivered        : Naive |= eventually[6] phase == Done with prob >= 0.99
theorem single_charge    : Naive |= always[6] charges <= 1
```

```
payments_retry.hz:85:1: info: claim delivered
  belief ≈0.998319 · plausibility ≈0.99997 — graded
  bound holds: belief ≥ 0.99
  by fuzzy parameter (π = possibility):
    loss = 0.01  π 0.6     ≈0.999992
    loss = 0.02  π 1       ≈0.999938
    loss = 0.05  π 0.5     ≈0.999073
    loss = 0.1   π 0.2     0.993141
payments_retry.hz:88:1: error: theorem naive_single_charge
  belief ≈0.955681 · plausibility ≈0.986011 — graded
  theorem rejected: belief is ≈0.955681, not 1
  counterexample at step 3 (path mass ≈0.000098, degree 0):
    parameters: loss = 0.01
    state: phase = Waiting, attempts = 2, charges = 2, acked = false, latency = 1000
```

The idempotent version of the same protocol is accepted as a theorem for every admissible
loss rate. See [examples/payments_retry.hz](examples/payments_retry.hz).

## Build and run

Requires [elan](https://github.com/leanprover/elan); the toolchain is pinned in `lean-toolchain`.

```sh
lake build                         # library, proofs (Haze/Theory.lean) and the `haze` CLI
lake exe haze examples/quorum_replication.hz
lake exe haze --fuel 5000 FILE.hz  # recursion-depth bound before outcomes become "unknown"
lake test                          # golden tests over tests/ and examples/
lake exe hazetest --update         # regenerate *.expected after an intended change
```

`haze` exits with status 1 if any declaration was rejected.

## Language tour

| Construct | Meaning |
|---|---|
| `enum Phase = A \| B \| C` | finite type |
| `param p : Num ~= {v: μ, …}` | **fuzzy input**: a possibility distribution (must be normal: some μ = 1) |
| `input x : T ~ e` | **probabilistic input**: a random node, sampled once per world |
| `def x : T := e` / `def f(a : T) : U := e` | random node / function (functions re-sample on every call, may recurse) |
| `def x : T @crisp := e` | grade annotation, enforced by the kernel |
| `observe e` | Bayesian conditioning of all worlds on a Boolean |
| `system S { var v : T := e … step { … } }` | transition system; statements `:=`, `if`, `match`, `let`, `assert`, `skip` |
| `claim c : φ [with prob >= q \| <= q]` | graded claim; with a bound it is rejected if the bound fails |
| `theorem t : φ` | must hold with belief 1 (every path, every admissible parameter) |
| `S \|= always[k] φ`, `eventually[k] φ`, `after[k] φ` | bounded temporal properties of a system |
| `#check`, `#eval`, `#prob`, `#expect`, `#outcomes`, `#print` | queries |

Types are `Bool`, `Num` (exact rationals), `Deg` (fuzzy truth degree in [0,1]) and enums.
Expressions include arithmetic, comparisons, `and/or/not/implies`, `if/then/else`,
`let … in`, `match`, bounded `forall/exists x in a..b, φ`, categorical `{v: w, …}`,
`flip(p)`, `uniform(a, b)`, `binomial(n, p)`, membership functions `tri`, `trap`,
`ramp_up`, `ramp_down`, and fuzzy sets with hedges: `x is very warm`, `x is not hot`.

**Stochastic conditionals.** The meaning of `if` depends on the condition's type:

* `if c then a else b` with `c : Bool` is an ordinary conditional (even when `c` is random);
* with `c : Deg` it is a **stochastic conditional**: take `a` with probability equal to the
  degree. `if temp is hot then … else …` therefore turns fuzzy inputs into randomness.

The same rule applies to `if` statements in system steps.

**Logics.** `logic godel | product | lukasiewicz` selects the t-norm used by `and`/`or`
on degrees from that point on (Bool is embedded as 0/1).

## What the answers mean

* Probabilistic uncertainty only: belief = plausibility = the **exact** probability
  (rational arithmetic, no sampling).
* Fuzzy parameters: the interval is the necessity/possibility pair of possibility theory,
  computed over α-cuts. Mixed with probability it is a Dempster–Shafer belief/plausibility.
* Recursion that runs out of fuel produces formally *unknown* outcomes. These widen the
  interval instead of being guessed.
* `#outcomes` lists the formal outcome for each state of the inputs, and failed theorems
  report a counterexample state (plus the falsifying bindings for `forall`s).

Details and rules: [docs/DESIGN.md](docs/DESIGN.md).

## Examples

| File | What it verifies |
|---|---|
| [payments_retry.hz](examples/payments_retry.hz) | retries + lost responses ⇒ double charges; idempotency keys fix it; fuzzy latency SLA |
| [quorum_replication.hz](examples/quorum_replication.hz) | R + W > N gives read-your-writes (theorem); R = 1 gives stale reads (counterexample + risk) |
| [circuit_breaker.hz](examples/circuit_breaker.hz) | breaker invariants as theorems; trip time, recovery and load shedding under a "flaky" upstream |
| [canary_rollout.hz](examples/canary_rollout.hz) | does a bad build reach 100%? exposure under a vague defect rate |
| [incident_triage.hz](examples/incident_triage.hz) | Bayesian root-cause posterior from alerts and an on-call paging rule |

## Layout

```
Haze/Core.lean          core AST (Expr, Stmt), grades, values, declarations, environment
Haze/Syntax.lean        lexer, concrete syntax, parser
Haze/Elab.lean          elaborator: names → de Bruijn, coercions, type-directed desugaring
Haze/Kernel/Check.lean  trusted type-and-grade checker, addDecl
Haze/Kernel/Eval.lean   exact distribution monad, evaluator, statement execution
Haze/Kernel/Verify.lean worlds, observe, fuzzy α-cut integration, bounded model checking
Haze/Frontend.lean      declaration-by-declaration driver and reports
Haze/Theory.lean        Lean proofs about kernel components (grade lattice, t-norm laws)
Main.lean, HazeTest.lean  CLI and golden-test driver
```

## Limits

Verification is exact and bounded: horizons are finite, quantifiers range over integer
intervals, and state spaces are enumerated (with merging and relevance projection), so very
large or continuous models are out of scope. Fuzzy parameters must have finite supports.
The Lean proofs cover the grade lattice and the fuzzy connectives. The model checker as a
whole is tested, not formally verified.

## License

Haze is source-available under the [PolyForm Noncommercial License 1.0.0](LICENSE.md):
free for personal, research, educational and other non-commercial use. For commercial
use, contact the author.

Required Notice: Copyright (c) 2026 Ritabrata Maiti
