# Calibration from a month of Massive L1 data

An update to [calibration.md](calibration.md). It replaces the 20k-row TAQ sample with
5 trading days to one month of quotes **and trades** for one stock from a Massive
(formerly Polygon) subscription. It also covers how the bots get their parameters and
how exchanges are modelled.

**Audience:** software team — whoever picks up ticket #23, and the agent tickets 11–18.
**Date:** 2026-11-24.
**Status:** idea, with two decisions made (one stock of mid liquidity, quotes and trades;
the single-market-first exchange model below). Everything else is open to argument.

---

## The one-paragraph version

A fetch script pulls quotes and trades for one stock of mid liquidity from Massive into a
**gitignored** raw folder. That's a lot of data at fine time resolution, and it never gets
committed. `calibrate.py` turns it into the committed `calibration.json`, the base
config for the simulated market. Each bot reads that base and multiplies a few
personality knobs by its own scale factors, so no two bots behave the same while the
market as a whole still matches what we measured. On exchanges, we calibrate **one
market** from consolidated data now. Later (ticket #21) venues become small profiles
(flow share, fees, tick, speed bump) that share one fair value. That's the only venue
model this data can support.

---

## What a month of Massive data changes

Most of what calibration.md had to leave as assumptions came from the sample being 149 s,
quotes only. A month of quotes and trades fixes most of that, but not all of it:

| Parameter | TAQ sample | Massive, 1 month |
|---|---|---|
| Intraday profile (U-shape) | not measurable | **measured**: per-minute buckets averaged over ~20 days |
| Trade rate, trade size | assumed | **measured** from the trades endpoint |
| Buy/sell aggressor mix | assumed | **measured**: trade price against the prevailing quote midpoint (tick rule as fallback) |
| Spread, touch size, quote rate | measured but thin | measured, with confidence intervals across days |
| Mid volatility | measured but thin | measured, per session phase |
| Overnight gaps, day-to-day variation | none | measured; feeds #11's multi-day fair value |
| Cancel ratio, depth beyond the touch, distance from mid | assumed | **still assumed**: L1 can't see them |
| Per-venue books | n/a | **not available** (see below) |

The cancel ratio can still get the bounded check calibration.md suggests: how long the
best price and size survive is visible in L1, and that limits how fast the touch can turn
over.

The last row matters most. Massive's quotes are the **consolidated NBBO**, the best bid
and offer across all exchanges. Each quote says which exchange holds the best bid/ask, and
each trade says which exchange printed it, but nothing shows the book at any single
exchange. Separate per-exchange books would mean direct exchange feeds, which cost far
more.

---

## Exchanges: one market now, venue profiles later

### Now: the sim exchange is the whole market

The engine has a single venue (`exchange_ = 0` in `simcore/include/scheduler.h`). Treat
that one exchange as the whole US market and calibrate it from the consolidated NBBO and
every trade. That's consistent: consolidated data for a venue that represents
everything. calibration.md's warning that the tape aggregate "measures the wrong process"
applies only once the sim has more than one venue. It doesn't apply here.

This step needs no engine change.

### At #21: a venue is a profile, not a book

When multi-venue lands, each exchange is a small `VenueProfile` in the scenario file
(#20):

| Field | Source |
|---|---|
| `flow_share` | **measured**: share of trade prints by exchange code, cross-checked against how often each exchange sets the NBBO |
| `maker_rebate`, `taker_fee` | public fee schedules (assumed, cited) |
| `tick_size` | config |
| `speed_bump_ns` | config (the IEX-style 350 µs ticket) |
| latency tiers | per-participant, per-venue (the latency ticket) |

Background flow sends each order to a venue drawn by `flow_share`. Every venue shares the
**one fair value** from #11, so prices drift apart between venues only because of
latency, fees and flow imbalance. That's the behaviour the arb bot (#18) and the
smart-routing lessons (5–6) are built to teach.

Suggested starting set for those lessons: **three generic venues**, each based on what
the data shows:

- a maker-taker venue holding the largest flow share
- an inverted-fee venue (pays takers, charges makers)
- a speed-bump venue

Config uses generic names (`venue_a`, …). Real exchange codes appear only in the
calibration report, as evidence for the shares.

> **Why this model:** it's the only one the data supports, it's the venue model #21
> already describes, and the first step needs nothing from the engine.

---

## Bots: base config × personal scale

Every bot starts from `calibration.json` and multiplies its own knobs by factors drawn
when it's created. Four rules keep that from breaking the calibration:

1. **Draw from `Scheduler::rng()()` raw bits**, e.g. a log-normal around 1.0 with
   σ ≈ 0.2 built by hand. Not through `std::*_distribution`, which differs between
   standard libraries (see the note in `scheduler.h`). Same seed, same bots, on every
   platform.
2. **Renormalise the totals.** If ten background bots each scale their arrival rate, the
   market's total rate drifts away from the measured one. Draw the factors, then rescale
   so Σ(per-bot rate) equals the calibrated rate. Do the same for volume share.
3. **Scale personality, not the market.** Good candidates: aggressiveness (share of
   market vs limit orders), distance-from-mid quantile, cancel patience, order size.
   Spread, tick size and fair-value volatility belong to the market and stay unscaled.
4. **Record the drawn factors** in the run's output, so a run can be explained later
   ("bot 7 was 1.4× as aggressive").

---

## Pipeline

| Step | Where | Notes |
|---|---|---|
| Fetch | `sw/data_pipeline/src/fetch_massive.py` (new) | one ticker, a date range, quotes and trades; key from the `MASSIVE_API_KEY` env var, never in the repo; resumable one day at a time |
| Store raw | `sw/data_pipeline/raw/<TICKER>/<date>/{quotes,trades}.parquet` | add `sw/data_pipeline/raw/` to `.gitignore` **before** the first fetch |
| Read | `MassiveL1Reader` and a trades reader beside `CSVL1Reader` in `cmd_L1_to_L3.py` | keeps `exchange`; `CSVL1Reader` should stop dropping it too |
| Clean | `calibrate.py` (new) | drop stub quotes, crossed and locked quotes, and duplicates; drop trades with irregular condition codes; count every rejection |
| Segment | `calibrate.py` | by session phase: pre-market, open, regular, close, after hours |
| Estimate | `calibrate.py` | pure functions, each with its own minimum sample size; below it, the result is `rejected`, not a number |
| Output | `sw/data_pipeline/data/calibration.json` (committed) | flat registry with a provenance flag on every value (calibration.md option B); ticks, lots and per-second units; distributions as tabulated CDFs |

### Choosing the stock

Pick a mid-liquidity name at $20–100 with a spread usually wider than one tick. Very
liquid names (AAPL/SPY class) sit at one tick almost all the time, which leaves the spread
distribution with nothing to measure, and they produce gigabytes per week.

### Dependencies

A month of quotes is tens of millions of rows, which reverses calibration.md's "stdlib"
leaning. Use pandas and pyarrow, listed in a `data_pipeline`-only
`requirements.txt`. Keep them out of `sw/service/requirements.txt`, which is what gets
deployed.

---

## What this still won't give us

- **One stock in one month.** Ticks and lots make the numbers portable, not general.
- **Nothing past the touch.** Depth, distance-from-mid and the cancel ratio are still
  literature values. LOBSTER or Databento L3 data could fill them later through the
  sibling-reader seam in calibration.md.
- **No per-venue books.** Venues differ only in flow share, fees and latency. Their
  book shapes come from the same calibration.
- **Validation is #24's job.** Until it checks the sim's spread, trade rate and intraday
  shape against the measured distributions, the calibration is still unchecked.

---

## How to check it

- After a fetch, `git status` shows no raw files.
- Two runs of `calibrate.py` on the same raw data give a byte-identical
  `calibration.json`.
- Mean spread, trades per day and per-venue trade share in the report match a separate
  pandas query on the raw data.
- Running on a single day returns `rejected` for the intraday profile instead of a
  number.
