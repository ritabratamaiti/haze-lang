---
title: Why one $50 bet beats fifty $1 bets at roulette
date: 2026-11-25
author: Ritabrata Maiti
summary: To turn $50 into $100 betting on red at American roulette, $1 bets get there 0.51% of the time and a single $50 bet 47.4% of the time. When you only roughly know your edge, the $1 plan swings between 12% and 73% while the single bet barely moves.
image: blog/images/bold-play-card.png
---
# Why one $50 bet beats fifty $1 bets at roulette

Say you have $50, you need $100 by tonight, and the only way to get it is to bet on red at an
American roulette wheel, which comes up on 18 of its 38 pockets. Bet $1 at a time until you have
$100 or nothing, and you get to $100 with probability 0.51%. Put all $50 on one spin and you get
there with probability 9/19, or 47.4%. The wheel and the odds per spin are the same, and the second
plan works about 92 times as often.

This is an old result. Lester Dubins and Leonard Savage proved in *How to Gamble If You Must*
(1965) that when every bet is slightly against you, bold play, which bets everything you have or
just enough to reach the goal, gives the best chance of reaching it. It came to mind this week
because of [Gambling for Goals](https://www.nber.org/papers/w36010), a new NBER working paper by
Costas Arkolakis, Spencer Y. Kwon, Dominic Russel, Claire Shi and Hyunjoo Yang that
[Marginal Revolution highlighted](https://marginalrevolution.com/marginalrevolution/2026/11/gambling-for-goals.html)
on November 24. Using a survey and linked Korean credit, telecom and card records, the authors find
that people who put more weight on hard-to-reach goals, such as owning a home, take more financial
risk. The arithmetic below says nothing about whether that's wise. It shows how much the size of
each bet matters once you need a fixed amount and every bet favors the house, and it shows
something a single number can't: what happens to the answer when you only roughly know the odds.

## The numbers

The chance of reaching $100 from $50 by betting on red, for different stakes:

| Stake per spin | American wheel (18/38) | European wheel (18/37) |
|---|---|---|
| $1 | 0.51% | 6.3% |
| $5 | 25.9% | 36.8% |
| $10 | 37.1% (59049/159049) | 43.3% |
| $25 | 44.8% (81/181) | 47.3% (324/685) |
| $50, once | 47.4% (9/19) | 48.6% (18/37) |

Every entry is exact before rounding. The bigger the stake, the better the chance, all the way up to
betting everything.

## Why the small bets lose

On average the house keeps 2/38 of every dollar bet on red, about 5.3 cents. Betting $1 at a time
from $50, a session lasts 940 spins on average before it reaches $0 or $100. About $940 crosses the
table, and the expected loss is 2/38 of that: $49.49 of your $50. One $50 bet puts $50 across the
table, for an expected loss of $2.63. Both plans lose money on average, and the one that bets less
in total keeps more of its chance.

The same arithmetic runs the other way when each bet favors you. Then many small bets give your
edge hundreds of spins to work, and they are the better plan. In a fair game the plan doesn't
matter: from $30, every strategy reaches $100 with probability exactly 3/10.

## Checking it in Haze

[Haze](https://haze-lang.pages.dev) is a small language for modeling systems with random steps and
checking what they guarantee. Here are the two plans, flat betting with a fixed stake and bold play:

```haze
system Flat(p : Num, stake : Num, start : Num) {
  var money : Num := start
  step {
    if money > 0 and money < 100 {
      money := money + (if flip(p) then stake else -stake)
    }
  }
}

system Bold(p : Num, start : Num) {
  var money : Num := start
  step {
    if money > 0 and money < 100 {
      let stake := min(money, 100 - money)
      money := money + (if flip(p) then stake else -stake)
    }
  }
}

-- Red at American roulette: 18 of the 38 pockets.
#prob Flat(18/38, 1, 50) |= eventually money == 100
#prob Flat(18/38, 10, 50) |= eventually money == 100
#prob Bold(18/38, 50) |= eventually money == 100
#expect Flat(18/38, 1, 50) |= steps until money == 0 or money == 100
#prob Bold(18/38, 30) |= eventually money == 100
```

`eventually` with no bound asks about runs of any length. Haze finds every amount of money the
player can reach and solves the equations for the chance of getting to $100, so the answers are
exact rather than averages from a long simulation:

```
#prob Flat(18/38, 1, 50) |= eventually money == 100
  probability ≈0.005127
#prob Flat(18/38, 10, 50) |= eventually money == 100
  probability ≈0.371263
#prob Bold(18/38, 50) |= eventually money == 100
  probability 0.473684 (=9/19)
#expect Flat(18/38, 1, 50) |= steps until money == 0 or money == 100
  expected steps ≈940.258035
#prob Bold(18/38, 30) |= eventually money == 100
  probability ≈0.2675
```

The last query shows why an exact solver helps. From $30, bold play bets $30. If it wins, it has
$60 and bets $40, and from there it can go around the loop $60, $20, $40, $80, $60 any number of
times before it wins or loses. Haze solves the loop exactly: 26.75%, against 0.06% for $1 bets from
the same $30. I also checked every number in this post with exact fractions in Python, using the
closed form for fixed stakes and a linear solve for bold play.

<figure>
<img src="https://haze-lang.pages.dev/blog/images/bold-play-curve.png" alt="Chance of reaching $100 at American roulette against starting money. Bold play stays just below the fair-game diagonal. $1 bets stay near zero until about $70 and then rise steeply. At $50, bold play gives 47.4% and $1 bets 0.51%.">
<figcaption>Figure 1. The chance of reaching $100 from each starting amount, betting on red at American roulette. Bold play stays within a few points of a fair game. $1 bets stay under 5% unless you start with more than about $70.</figcaption>
</figure>

## A curve with no slope

Figure 1 makes bold play look like a slightly lowered straight line. It's stranger than that. As a
function of the starting amount, its chance of success is continuous and increasing, yet in any
unfair game its derivative is zero almost everywhere. Patrick Billingsley called it
[the singular function of bold play](https://www.jstor.org/stable/27852139) (*American Scientist*
71, 1983).

The binary digits of your money, as a fraction of the goal, explain it. Below half the goal, bold
play doubles your money or loses it all. Above half, it either reaches the goal or falls back to
twice your money minus the goal. Either way, a bet you survive doubles the fraction and drops its
first binary digit, so every digit is one spin: a 0 is a spin you must win to keep going, and a 1 is
a spin that ends the game in your favor if you win it. In a fair game the chance of success works
out to the binary fraction itself, the diagonal in figure 1. When the wheel favors the house, the
weight of each digit depends on the digits before it, and the gap to the diagonal picks up a dent at
every binary scale.

<figure>
<img src="https://haze-lang.pages.dev/blog/images/bold-play-shortfall.png" alt="Percentage points by which bold play falls short of a fair game, against starting money. The curve is an arch with notches at $50, $25 and $75, smaller notches between them, and a maximum of about 3.6 points near $67.">
<figcaption>Figure 2. How far bold play falls short of a fair game at American roulette, in percentage points, computed from the binary expansion at 4,097 starting amounts and matching the exact solution at whole dollars. The notches repeat at every power of two. The largest gap, 3.57 points, is near two thirds of the goal, whose binary digits alternate 1, 0, 1, 0.</figcaption>
</figure>

## When you don't know your edge

Roulette comes with known odds. Most bets don't. A card counter at blackjack, someone betting on a
sports line they think is off, or anyone betting on their own judgment has an edge they can only
estimate. In Haze you can say that directly with a fuzzy parameter: you list the values you
consider possible and how plausible each one is, and Haze answers every question for all of them.

```haze
system Flat(p : Num, stake : Num, start : Num) {
  var money : Num := start
  step {
    if money > 0 and money < 100 {
      money := money + (if flip(p) then stake else -stake)
    }
  }
}

system Bold(p : Num, start : Num) {
  var money : Num := start
  step {
    if money > 0 and money < 100 {
      let stake := min(money, 100 - money)
      money := money + (if flip(p) then stake else -stake)
    }
  }
}

-- You win most plausibly 49% of the time, possibly 49.5% or 50%, and just possibly 50.5%.
param win : Num ~= {0.49: 1, 0.495: 0.7, 0.5: 0.4, 0.505: 0.2}

#prob Flat(win, 1, 50) |= eventually money == 100
#prob Bold(win, 50) |= eventually money == 100
```

```
#prob Flat(win, 1, 50) |= eventually money == 100
  belief ≈0.119175 · plausibility ≈0.362646
  by fuzzy parameter (π = possibility):
    win = 0.49   π 1       ≈0.119175
    win = 0.495  π 0.7     ≈0.268935
    win = 0.5    π 0.4     0.5
    win = 0.505  π 0.2     ≈0.731065
#prob Bold(win, 50) |= eventually money == 100
  belief 0.49 · plausibility 0.4965
  by fuzzy parameter (π = possibility):
    win = 0.49   π 1       0.49
    win = 0.495  π 0.7     0.495
    win = 0.5    π 0.4     0.5
    win = 0.505  π 0.2     0.505
```

The answer is a pair instead of one number. Belief is how strongly what you said guarantees the
outcome, and plausibility is how strongly it allows it. They are the belief and plausibility of
Dempster-Shafer theory, and [the docs](https://haze-lang.pages.dev/docs/fuzzy/) show how Haze
computes them. The table underneath is the part to look at. With $1 stakes, the chance of doubling
runs from 11.9% at the edge you consider most likely to 73.1% at the hopeful one. Bold play stays
between 49% and 50.5%.

Written as requirements, the difference is plain:

```haze
claim flat_doubles : Flat(win, 1, 50) |= eventually money == 100 with prob >= 0.4
claim bold_doubles : Bold(win, 50) |= eventually money == 100 with prob >= 0.4
```

```
claim flat_doubles
  belief ≈0.119175 · plausibility ≈0.362646 · graded
  bound fails: belief ≈0.119175 < 0.4
  counterexample at step 50 (path mass ≈2.39061e-15, never reached on this path):
    parameters: win = 0.49
    state: p = 0.49, stake = 1, money = 0
claim bold_doubles
  belief 0.49 · plausibility 0.4965 · graded
  bound holds: belief ≥ 0.4
```

Haze rejects the first claim and shows what breaks it: at win = 0.49, the edge you thought most
likely, a run of 50 straight losses ends at $0 without ever reaching $100. The second claim holds
for every value you listed.

Small stakes magnify whatever edge you have, in both directions. If your edge is real, $1 bets
double your money 73% of the time, against 50.5% for one big bet. If it isn't, they do it 12% of the
time, against 49%. Which plan is better depends on how sure you are of the edge, and a model that
takes one guessed number for it would hide exactly that.

## What the model leaves out

- Spins are independent, and the wheel pays what its odds say.
- Only even-money bets are modeled. Roulette also offers longer-odds bets, which change the
  analysis.
- There's no table limit. Casinos cap bets; with a $25 maximum, $25 bets reach $100 from $50 44.8%
  of the time.
- Money moves in whole dollars, there is a single target, and there is no time limit, although $1
  bets need 940 spins on average.
- Every plan here loses money on average. The question is the chance of reaching a target, not how
  to make money, and none of this is advice to gamble.

## Running the model

Both complete code blocks above open in the [playground](https://haze-lang.pages.dev/play/), where
you can change the stake, the wheel or the edge. The fuzzy one takes several seconds in the browser,
because it solves four 101-state chains in exact fractions. The
[full model](https://github.com/ritabratamaiti/haze-lang/blob/main/examples/Gallery/bold_play.hz),
with the European wheel, the fair-game check and both claims, is in the
[gallery](https://haze-lang.pages.dev/gallery/).

Haze is written in Lean 4 and runs in the browser. It was built for questions like these about
retries, timeouts and circuit breakers, and the first posts on this blog use it on
[32 resilience libraries](https://haze-lang.pages.dev/blog/checking-32-libraries/).
