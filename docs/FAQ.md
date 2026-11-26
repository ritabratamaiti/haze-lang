# FAQ

## Is Haze ready to use?

You can run a model in the [browser](https://haze-lang.pages.dev/play/), check it in
[CI](CI.md) and replay its generated tests against an implementation. The
[conformance example](../examples/Conformance/README.md) does all the checking locally with
a Python client and the `haze` binary. Version 0.1 is experimental: pin the release used in
CI because the language may change. The browser has an editor; this release does not ship an
IDE extension.

The continuous fuzzy parameter forms `tri`, `trap` and `likelihood` in this checkout are
development features, not part of v0.1.0. Build the branch with `lake build haze` and run its
checker with `lake exe haze FILE.hz`.

## Should I use Haze or PRISM?

In Haze, the [three-send example](https://haze-lang.pages.dev/play/?example=rough-numbers)
checks a 99.99% delivery target without assuming the loss rate is known exactly. It reports
the probability at each candidate rate, checks the belief bound and shows a failure at 5%
loss. This branch can also [check all the rates in a range](Fuzzy-Parameters.md#checking-a-delivery-target)
when the estimate is continuous. Haze expresses the protocol in discrete steps. PRISM and
Storm also analyze models with continuous time or nondeterministic choices and support
reward properties. The [comparison](Comparison.md#prism-and-storm) covers these differences
and links the results for models checked with all three tools.

## Why fuzzy parameters and not a prior distribution?

A prior turns your uncertainty about a rate into more randomness, and the answer becomes a
single probability that mixes the two. Sometimes that's what you want, and Haze can do it: make
the rate an `input` with a distribution. Each world then draws one rate, and the random values
that depend on it use that rate.

```haze
input loss : Num ~ {0.01: 0.3, 0.02: 0.5, 0.05: 0.2}
input lost : Bool ~ flip(loss)
#prob lost
```

A fuzzy parameter keeps the two kinds of uncertainty apart. You don't have to invent
probabilities for a rate you've only estimated, and the answer shows how much of it depends on
the estimate: a wide gap between belief and plausibility means the estimate matters, and the
table shows which values are responsible. [Fuzzy parameters](Fuzzy-Parameters.md) has more.

## Does a Haze theorem prove my system correct?

An accepted theorem establishes the stated property for the model and its parameter values.
If the model has three replicas and the property says `always[6]`, the result covers those
replicas through step six. With `always` and no bound, the property covers runs of any length
for that same model. [Testing real code](../examples/Conformance/README.md) checks the
separate question of whether an implementation behaves like the model.

Lean proofs cover parts of the checker's foundations, including the grade lattice and fuzzy
connectives. The checker as a whole is not formally verified.
[Trust and testing](Design.md#trust-and-testing) describes the evidence.

## Why exact fractions?

A requirement like "at least 0.999" should be checked against the true probability, not against
a floating-point approximation of it, which can round a 0.9989999 to 0.999. Exact fractions also
make results reproducible, and they can be checked by hand.

The cost is speed when the numbers get large. Most models check in a second or two, but a model
with many steps of binomial arithmetic, such as the chip yield example in the gallery, takes
several seconds natively and much longer in the browser.

## What does "unknown" mean in a result?

Some outcomes can't be computed within Haze's limits: a recursive function that runs out of fuel,
or a state beyond the exploration limit of a property without a bound. Haze doesn't guess them.
It counts them as unknown, which widens the result into an interval that contains the true
value. Raising `--fuel` or `explore` narrows the interval when the unknown part is unlikely.

## How large can a model be?

For a bounded property, the limit is 2 million distinct configurations per step after Haze
merges equal configurations and drops state that cannot affect the answer. Unbounded properties
explore up to 100,000 states by default. Set `explore N` to change that budget; if it is
exhausted, the result accounts for unexplored behavior as unknown. The output reports
`states/step` or `reachable states` for the property you checked.
[Limits](Language-Reference.md#limits) lists the other bounds.

## Does the playground send my code to a server?

No. The playground runs a WebAssembly build of Haze in your browser, made from the same Lean code
as the `haze` command. The website is static, and your code only leaves the page if you copy a
share link, which holds the code in the link itself.

## Why is it written in Lean?

Lean is both a programming language and a proof assistant. Haze uses it for the first, with exact
rational arithmetic, native code, and a WebAssembly build; and for the second, to prove some of
its foundations. Its design also follows Lean's: an elaborator that doesn't need to be trusted,
and a small kernel that checks everything again. [Design and semantics](Design.md#starting-from-lean)
explains how the parts correspond.

## Can I use Haze at work?

Yes. Haze is released under the [Functional Source License](https://github.com/ritabratamaiti/haze-lang/blob/main/LICENSE.md)
(FSL-1.1-ALv2). You can use, modify and share it for any purpose, including inside a company and
in commercial work, except offering Haze, or a product built on it with the same functionality,
as a competing commercial product or service. Each release becomes available under the Apache
License 2.0 two years after it's published.

The FSL isn't an open-source license by the Open Source Initiative's definition, because of that
one restriction. For a license that covers other uses, email ritabratamaiti@gmail.com.

## How can I contribute?

Bug reports, examples and fixes are welcome. [CONTRIBUTING.md](https://github.com/ritabratamaiti/haze-lang/blob/main/CONTRIBUTING.md)
describes how to build and test Haze, and asks contributors to sign a contributor license
agreement.
