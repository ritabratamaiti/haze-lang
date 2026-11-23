---
title: A Bloom filter that can't reach the error rate you ask for
date: 2026-11-23
order: 2
author: Ritabrata Maiti
summary: The partitioned filter in the npm package bloom-filters derives every slice's bit from the same two hashes. Two strings that share those hashes share all their bits, which puts a floor of about 0.5/n under the false positive rate, whatever rate you ask for.
---
# A Bloom filter that can't reach the error rate you ask for

You size a Bloom filter by saying how many items it will hold and how often you can tolerate a
false "yes". [bloom-filters](https://github.com/Callidon/bloom-filters), a JavaScript library
of probabilistic data structures, does the sizing for you in `PartitionedBloomFilter.create(n, errorRate)`. It
picks the right sizes, but below an error rate of about `0.5 / n` the filter stops getting better,
however small a rate you ask for. With 1,000 items and a requested rate of 1 in 10,000, I measured
6.4 in 10,000. It's reported as
[bloom-filters#133](https://github.com/Callidon/bloom-filters/issues/133).

## How the filter is laid out

A partitioned filter splits its bits into `k` equal slices of `m` bits, where
`k = ceil(log2(1 / errorRate))`. Adding an item sets one bit in every slice, and a lookup answers
"present" when all `k` of its bits are set. For 1,000 items at 1 in 10,000, `create` picks 14
slices of 1,370 bits. If each slice chose its bit independently, an item that was never added
would find all 14 of its bits set with probability `(1 - (1 - 1/m)^n)^k`, about 1.01 in 10,000.
That's the rate `create` is designed around.

Hashing every item 14 times is slow, so the package hashes it twice, to `a` and `b`, and derives
slice `i`'s bit as

```
(a + i*b + c(i)) mod m
```

where `c(i)` depends only on `i`
([`getIndexes`](https://github.com/Callidon/bloom-filters/blob/e2882ef1a3e00a18cd202e118bc6a1b9475f0000/src/hashing.ts#L45-L60)).
Deriving many hashes from two is a well-known shortcut, and the package's classic `BloomFilter`
uses it too, across all `k * m` bits at once. Applied slice by slice, it has a catch: if a new
item's `a` and `b` equal a stored item's `a` and `b` modulo `m`, the two items get the same bit in
every slice, since `c(i)` is the same for both. That happens with probability `1/m^2` for each
stored item, and it doesn't shrink as `k` grows.

## Checking it in Haze

The code uses `a` and `b` only modulo `m`, so for a model it's enough to know the two residues of
each item, each uniform between 0 and `m - 1`. Here is one stored item and one lookup, with
`m = 6` and `k = 4`:

```haze
def m : Num := 6
def k : Num := 4
def mod_m(x : Num) : Num := x - m * floor(x / m)
def c(i : Num) : Num := floor((i * i * i - i) / 6)
def index(a : Num, b : Num, i : Num) : Num := mod_m(a + i * b + c(i))

-- One stored key and one query that was never added, each with its two hash residues.
input a1 : Num ~ uniform(0, m - 1)
input b1 : Num ~ uniform(0, m - 1)
input qa : Num ~ uniform(0, m - 1)
input qb : Num ~ uniform(0, m - 1)

def same_bit_everywhere : Bool := forall i in 0..k - 1, index(qa, qb, i) == index(a1, b1, i)

theorem only_when_both_hashes_match : same_bit_everywhere == (qa == a1 and qb == b1)
claim as_rare_as_independent_slices : same_bit_everywhere with prob <= 1/1296
```

```
theorem only_when_both_hashes_match
  probability 1 · holds with certainty
claim as_rare_as_independent_slices
  probability 0.027778 (=1/36)
  bound fails: plausibility 0.027778 (=1/36) > ≈7.71605e-4 (=1/1296)
```

The theorem says the lookup matches the stored item in all four slices exactly when both hash
residues match; the first two slices already pin that down. So the chance is 1/36, where four
independent slices would give 1/1296. The
[complete model](https://github.com/ritabratamaiti/haze-lang/blob/main/examples/Found/bloom_filters.hz)
holds two items, computes the filter's actual false positive rate (73/1296, where the textbook
formula gives 0.0087) and includes the fix: with a separate hash for each slice, the same check
passes.

## A pair of strings

If a match on two residues is enough, pairs of colliding strings should be easy to find. They
are. On bloom-filters 3.0.4:

```js
const { PartitionedBloomFilter } = require('bloom-filters')
const f = PartitionedBloomFilter.create(1000, 0.0001) // 14 slices of 1370 bits
f.add('user-2476')
console.log(f.has('user-2825')) // true
```

`'user-2476'` and `'user-2825'` set the same 14 bits. With independent slices, the chance of that
would be `(1/1370)^14`. Counting up through `'user-0'`, `'user-1'` and so on, 1,000 such pairs turn
up within about 61,000 strings.

## Measured rates

Each stored item adds about `1/m^2` of false positives, so `n` items add about `n / m^2`. With the
slice sizes `create` chooses, that comes to roughly `ln(2)^2 / n`, or `0.48 / n`, and a requested
rate below that can't be met. Measured on 3.0.4, with 4 to 40 million lookups per row:

| items | requested | measured | predicted |
|---|---|---|---|
| 100 | 0.001 | 0.00621 | 0.00622 |
| 1,000 | 0.01 | 0.0107 | 0.0105 |
| 1,000 | 0.001 | 0.00151 | 0.00149 |
| 1,000 | 0.0001 | 0.000642 | 0.000643 |
| 10,000 | 0.00001 | 0.0000628 | 0.0000608 |
| 100,000 | 0.0001 | 0.000111 | 0.000106 |

"Predicted" uses the package's index formula with random hashes. It agrees with the measurements
to within their confidence intervals, while the textbook rate is far off in the first five rows.
When the requested rate is well above `0.5 / n`, as with 1% or with 100,000 items, the effect is
small, which may be why nobody had reported it. `ScalableBloomFilter` grows by adding partitioned
filters, so it has the same floor.

## Fixing it

Either give every slice its own hash, for example by hashing with a different seed per slice, at
the cost of `k` hashes per item, or keep the two hashes and have `create` enlarge `m` when the
requested rate is below `0.5 / n`. The model can check whichever is chosen.

## Running the model

The model is in the Haze repository. With [Haze installed](https://haze-lang.pages.dev/docs/installation/):

```
git clone https://github.com/ritabratamaiti/haze-lang
haze haze-lang/examples/Found/bloom_filters.hz
```

You can also paste the short version above into the [playground](https://haze-lang.pages.dev/play/). This is
one of seven findings described in
[Checking 32 resilience libraries against their own docs](https://haze-lang.pages.dev/blog/checking-32-libraries/).
