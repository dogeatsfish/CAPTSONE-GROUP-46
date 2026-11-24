# Calibration from L1

What ticket #23 can honestly measure from the data we have, what it has to assume
instead, and the shapes `calibration.json` could take.

**Audience:** software team — whoever picks up ticket #23.
**Date:** 2026-11-20.
**Status:** idea — nothing is built and nothing is agreed. This is a proposal to
argue with, not a design to implement.

---

## The one-paragraph version

Ticket #23 would produce one file, `sw/data_pipeline/data/calibration.json` (new),
from one script, `sw/data_pipeline/src/calibrate.py` (new). The file holds the
numbers that make the synthetic market look like a real one: how often quotes
change, how wide the
spread sits, how much size rests at the touch, how fast the mid moves, how far
from the mid limit orders land, how often they are cancelled. Some of those we can
measure from the TAQ sample in the repo. Most of them we cannot, because L1 shows
only the best bid and offer — so they come from published stylised facts and are
**assumptions wearing a number**. The whole design problem is keeping those two
kinds of value apart without making the file painful to read.

It matters now because #23 has no dependencies and sits at the head of the build
order (`#23 → #11 fair value → #12 background flow → #13 market maker → …`). The
background-flow participant in #12 draws its distance-from-mid, its cancel rate and
its order size straight out of this file. Whatever shape we pick, every agent
ticket downstream inherits it.

---

## What the sample actually is

Before choosing anything, it is worth being precise about
`sw/data_pipeline/data/taq_millisecond_quotes_sample.csv`, because two of the
ticket's assumptions do not survive contact with it.

| | |
|---|---|
| Rows | 20,000 |
| Ticker | `C` — Citigroup, trading around $3.55 |
| Date | 2009-02-13 |
| Span | 04:12:37 → 09:32:29 |
| Venue codes | **nine**: `T` 6479, `Z` 5789, `P` 4099, `I` 2230, `N` 1137, `W` 165, `B` 97, `C` 3, `D` 1 |
| Rows before 09:30 | 7,371, spread thinly over ~5h17m (~0.4 quotes/s) |
| Rows at or after 09:30 | 12,629 — all inside a **149-second** window |
| Spread in that window | 1c × 8,257 · 2c × 3,729 · 3c × 110 · wider than 5c × 460 |
| Touch size | median 100 lots, mean 139, max 1,993 |
| Raw bid range | **0.0001 → 11.93**, on a $3.55 stock |

Three consequences:

**There is no intraday profile in this file.** The ticket asks for one, but 63% of
the rows sit in a 149-second burst at the open and the rest is thin pre-market.
What we can see is a single regime transition — pre-open to open — not a U-shape.
Fitting a curve to 149 seconds would produce the most misleading number in the
file.

**This is a consolidated tape, not a book.** Nine venue codes are interleaved. The
~85 quotes/s aggregate is the rate of the *tape*; the busiest single venue runs at
about 31/s, `T` at 22/s. A simulation with one or two exchanges wants the per-venue
figure. Anything that does not group by `exchange` is quietly measuring the wrong
process — and `CSVL1Reader` in `sw/data_pipeline/src/cmd_L1_to_L3.py` currently
discards the `exchange` column altogether.

**Cleaning is a stage, not a detail.** A bid of $0.0001 and an ask of $21.02 on a
$3.55 stock are stub and indicative quotes, not trading interest. Left in, they
dominate every volatility and spread estimate. There are also 551 consecutive
duplicate quotes. The ticket does not mention cleaning at all, and it is the
largest correctness risk in the work.

> **Why this section comes first:** every design choice below is downstream of the
> fact that we have 149 seconds of one crisis-era penny stock across nine venues.
> A calibration built from it can be honest or it can be impressive. Not both.

---

## One file, two jobs

`calibration.json` has to be two things at once, and they pull in opposite
directions:

| As a measurement report | As a config file |
|---|---|
| Wants provenance, sample size, the filter applied, caveats | Wants stable keys and terse values |
| Read by a human deciding whether to trust a number | Read by a loader that just wants the number |
| Grows richer over time | Wants to never change shape |

The ticket's phrase "marked as assumptions" is the first instinct. A C++ loader
that just wants a float is the second. The question the rest of this doc answers is
how to serve both without the file becoming either a liability or a lie.

---

## Possible shapes for the file

### A. Two top-level sections

```
measured: { spread: …, touch_size: … }
assumed:  { cancel_ratio: …, depth: … }
```

The obvious first reach, and genuinely the easiest to read — you can see at a
glance what is real. The problem is that provenance determines *location*. The day
an L3 sample arrives and we can finally measure the cancel ratio, its key moves
from `assumed.cancel_ratio` to `measured.cancel_ratio`, and every consumer that
read the old path breaks. That promotion is the exact scenario the ticket asks us
to support ("optional second reader for a free L3 sample later").

### B. Flat registry, provenance as an attribute

Stable dotted paths; every leaf is a small record rather than a bare number, and
each record says where its value came from. Promotion flips one field and leaves
the key alone, so consumers never notice. A vocabulary of four is probably enough:
measured, assumed, derived, and **measurement attempted and rejected** — that last
one matters more than it sounds, because with 149 seconds of session several
estimators *should* refuse to produce a number, and "we tried, here is why it
failed" is worth recording so nobody redoes the work.

Costs: more verbose, and the loader has to reach one level deeper for every value.

### C. Terse config plus a provenance sidecar

Two files — clean values in one, the evidence in the other. Consumers stay simple
and the report can be as rich as we like. The risk is the ordinary one with
parallel files: they drift, and the sidecar is the one that rots.

| | A. Two sections | B. Flat registry | C. Sidecar |
|---|---|---|---|
| Readable at a glance | best | fair | good |
| Survives promotion to L3 | **no** | yes | yes |
| Loader complexity | lowest | medium | low |
| Can drift out of sync | n/a | n/a | **yes** |

> **Leaning: B.** Promotion without breaking consumers is the one property the
> ticket explicitly asks for, and it is the only one of the three criteria that is
> expensive to retrofit. Verbosity is a cosmetic cost; a key that moves is a
> breaking change.

Two things fall out of B if we take it. Values are easier to reuse when they are
**dimensionless** — spread in ticks, size in lots, rates per second — because a
calibration denominated in dollars bakes "C at $3.55" into every consumer, while
ticks and lots transplant to a sim symbol at any price. And distributions want a
**single encoding** regardless of provenance: if a measured histogram and an
assumed power law have the same shape in the file, promoting one to the other
changes data and not code.

---

## Where the defaults live

The published-stylised-facts numbers have to live somewhere. Three places:

- **Constants in `calibrate.py`.** Convenient, and wrong — it makes a parameter
  change a code change, reviewed as a code diff, by whoever can edit Python rather
  than whoever knows the literature.
- **A committed, hand-authored `defaults.json`** beside the generated file.
- **Inlined into the generated output**, with no separate source.

> **Leaning: the separate file.** A table of literature values with citations is
> *data*; it should read as a data diff in review. It also keeps `calibrate.py` a
> pure merge of two inputs, so promotion is one code path rather than "delete the
> constant, add an estimator". Most of all it preserves a clean invariant: **one
> file is generated and never edited, the other is edited and never generated.**
> The moment defaults live inside the generated file, someone hand-tweaks the
> generated file and reproducibility quietly dies.

---

## Pipeline shape and boundaries

`calibrate.py` runs rarely — its output is committed — so it can afford to be
simple and explicit. Five stages:

| Stage | Does |
|---|---|
| Read | pull ticks through a reader; no CSV parsing of its own |
| Clean | drop stub and indicative quotes, drop consecutive duplicates, count every rejection |
| Segment | split by venue and by session phase |
| Estimate | pure functions, ticks in, one parameter record out |
| Assemble | load defaults, overlay measurements, validate, write |

The rejection counts from the cleaning stage are not debug output — they are the
audit trail, and they belong in the file next to the numbers they shaped.

Each estimator should carry its own minimum-sample rule and return *rejected*
rather than a number when the rule is not met. That is what keeps a thin sample
from silently producing a confident-looking figure, and it is what makes the
estimator set extensible later.

What it should **not** do: parse CSV itself; hardcode a default; get imported by
the FastAPI service at request time (it is an offline build step whose *output* is
the artifact); or have its output hand-edited. Worth saying so in the file header.

---

## Readers and the L3 seam

`sw/data_pipeline/src/cmd_L1_to_L3.py` already has the right seam: an
`L1DataReader` ABC with a `read_ticks()` generator, a concrete `CSVL1Reader`, and a
`DatabaseL1Reader` stub. Reuse it rather than writing a second reader. It needs one
additive change — stop dropping `exchange` — which is safe because
`L1ToMBOConverter` ignores extra dict keys.

For the eventual L3 sample, the question is subclass or sibling. L3 carries order
ids, explicit cancels and depth beyond the touch: concepts with no L1 shape at all.

> **Leaning: a sibling ABC**, not a subclass. Subclassing would force the L1 reader
> to fake fields it cannot possibly know. Two reader families, two estimator
> families, writing the same parameter keys — and a merge that prefers the better
> provenance. That merge rule *is* the promotion mechanism, and it should live in
> exactly one place.

---

## What L1 supports, and what it cannot

Over this specific sample:

| Parameter | Status |
|---|---|
| Quote-update rate | Measured — but per venue and per session phase, never the tape aggregate |
| Spread distribution | Measured after cleaning; degenerate — one tick ~69% of the time |
| Touch size distribution | Measured; the strongest estimate in the file |
| Touch size imbalance | Measured |
| Quote lifetime at the touch | Measured |
| Mid volatility | Measured only after cleaning, and thin — the busiest venue shows just 155 mid changes in 4,680 updates |
| Intraday profile | **Not measurable.** One regime transition, not a profile |
| Cancel ratio | Assumed — but see below |
| Add/cancel/execute mix | Assumed; the file contains no trades at all |
| Distance-from-mid of limit orders | Assumed; L1 is blind off the touch |
| Depth beyond the touch | Assumed |
| Trade rate and trade size | Assumed; nothing in the file |

One refinement worth floating. "L1 cannot show the cancel ratio" is true of the
book as a whole, but L1 *does* bound how fast liquidity at the touch turns over —
how long a given best price and size survives is directly observable. So the
assumed cancel ratio could ship with a measured consistency check beside it:
*assumed from literature; implied touch turnover in this sample is X/s, consistent
or not*. That turns a blind assumption into a bounded one for almost no work.

The caveats belong **inside the artifact**, not only in this doc, because the file
will outlive the conversation: one day, one ticker, February 2009 mid-crisis, a
sub-$5 price so the tick is ~28 bp and the spread is pinned at the minimum, nine
venue codes from a consolidated tape, 149 seconds of regular session — and that
window is the least typical moment of the trading day — and quotes only, so the
entire execution side of the model is literature.

---

## Getting it into C++

The file is produced in Python and consumed by a C++ participant. Three ways
across:

| Option | Cost |
|---|---|
| Vendor a JSON parser into the engine | ~25k lines of header into a `Makefile` that lists every source by hand, and a second place in the project that must agree about JSON |
| Codegen a C++ header from the JSON | Type-safe and fast, but makes calibration a **compile-time** dependency — tuning a parameter means rebuilding the engine |
| Python owns all JSON; C++ receives a resolved, typed config | One more thing to bind by hand |

> **Leaning: the third.** `LatencyProfile`, `FeeSchedule` and `Order` already cross
> this boundary in `sw/engine/bindings/src/bindings.cpp`; a resolved config object
> is the same move, and the engine keeps its property of having no parser in it.
> The honest cost: the pure-C++ `online_run` CLI could no longer bootstrap itself
> from a scenario file — it would need driving from Python, or a separate export
> step writing something `fread` can take, the trick the MBO stream already uses.
> Worth paying only when a C++-only scenario run is actually needed.

One trap to flag while we are here, because it bites whoever writes #12:
`sw/engine/simcore/include/scheduler.h` warns that `std::mt19937_64` is portable
across platforms but `std::uniform_real_distribution` and friends are **not** —
each standard library implements them differently. Any agent that samples a
calibrated distribution through `std::*_distribution` gives up cross-platform
reproducibility, which is the engine's headline property. Sampling from a tabulated
CDF off raw `rng()()` bits avoids it, and conveniently that is the same encoding
that lets measured and assumed distributions share a shape.

---

## What this will not give us

In the spirit of the architecture doc's known simplifications — these are limits to
state out loud, not problems to solve:

- **The microstructure shape is one stock on one morning.** Rescaling to ticks and
  lots makes it portable, not general.
- **The execution side is entirely literature.** No trades in the sample means the
  add/cancel/execute mix, trade sizes and trade rate are assumptions with error bars
  nobody has measured.
- **No depth.** Everything past the touch is invented, and the background-flow
  participant will be building a book shape we chose rather than one we observed.
- **A 2009 crisis regime at a 28 bp tick** is not a neutral baseline. Spreads pinned
  at one tick 69% of the time is a property of *this* name at *this* price, and a
  sim symbol at $100 will behave differently for reasons that have nothing to do
  with the agents.
- **Nothing here is validated.** Whether the resulting market looks real is ticket
  #24's job, and until it exists the calibration is plausible rather than checked.

---

## Open questions

| Question | Leaning |
|---|---|
| numpy/pandas, or stdlib? | **Stdlib.** This is counting, sorting and one-pass moments over 20k rows, run about once. If the team wants array tools for wider analysis, add them in a `data_pipeline`-specific requirements file — never in `sw/service/requirements.txt`, which is the deployment surface |
| Which L3 source, and is it in scope? | **Build the seam, implement no reader.** LOBSTER's free sample over Databento if it happens — full-day L3 for a few names, no account needed. #23 must not block on it |
| Dimensionless or dollar-denominated? | **Ticks, lots and per-second.** It means telling the report's readers "the shape is C-in-Feb-2009, rescaled", which is honest; dollar values hide the same limitation |
| What do we do about the intraday profile? | **Redefine it** as a two-phase multiplier with one measured entry (open burst vs pre-open) and the rest assumed — or drop it to assumed entirely. Fitting a curve to 149 seconds would be worse than admitting we cannot see it. This one changes the ticket text, so it needs a decision rather than a default |
| Does cleaning get its own ticket? | Probably not — but it is unscoped work inside a 2-day estimate, and the estimate should move if we take it seriously |
