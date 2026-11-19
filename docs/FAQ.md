# FAQ

## Is Haze ready to use?

Haze is at version 0.1. The checker is tested against hand-computed results, independent
calculations, and PRISM and Storm on PRISM's own example models. The language may still change
between versions, and the release notes say when a change breaks existing models. Haze fits well
when you're checking a design or a protocol, before or alongside writing the code.

## Should I use Haze or PRISM?

They answer different questions. Haze checks discrete-time models of software with exact
answers, rates given as ranges or learned from counts with certified belief and plausibility,
counterexamples for every failed bound, and tests ranked by probability. PRISM and Storm cover
more kinds of model, such as Markov decision processes and continuous time, and richer temporal
logics, with symbolic engines for very large state spaces. [How Haze compares](Comparison.md)
goes through the differences.

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

It proves the model correct, for the model's sizes and horizons and for every value of its
parameters. If the model says three replicas and six steps, the theorem says nothing about four
replicas or seven steps. Whether the model matches the code is a separate question, and
[Testing real code](../examples/Conformance/README.md) shows one way to check it.

The checker itself isn't formally verified. Its foundations are partly proved in Lean, and its
results are tested ([Trust and testing](Design.md#trust-and-testing)).

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

Haze enumerates states explicitly. It keeps at most 2 million configurations per step, explores
100,000 states for a property without a bound unless you set `explore`, and checks every
combination of fuzzy parameter values. The models in the repository have up to about a thousand
states per step. [Limits](Language-Reference.md#limits) has the details.

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
