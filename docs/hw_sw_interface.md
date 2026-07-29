# HW / SW Interface Contract

**Status: DRAFT — items marked OPEN need a decision from both teams.**

This document exists because the hardware datapath and the software data pipeline
were built to assumptions that have never been written down side by side. Every
statement below about the software side was verified against the files in `sw/`
and against `sw/data_pipeline/data/synthetic_mbo_stream.csv` as it exists today,
not inferred from the design report.

The consumer of this contract is the CSV → ITCH bridge (`sim/csv_to_itch.py`),
which has to turn the software team's MBO stream into wire-format packets the
hardware can actually parse.

---

## What the software side actually produces

`sw/data_pipeline/src/cmd_L1_to_L3.py` converts an L1 quote feed into an MBO
event stream. Measured properties of the current output:

| Property | Value |
|---|---|
| Rows | 61,348 events + header |
| Columns | `timestamp, message_type, order_id, side, price, size` |
| Message types present | `A` and `C` only |
| Max concurrent live orders | **2** (one bid, one ask) |
| Distinct prices | 491 |
| Price range | 0.0001 … 301000.0 |
| Events with price < 1 | 310 |
| Events with price > 100 | 26 |

The 2-order ceiling is structural, not a property of this particular file:
`_process_side()` cancels the existing order before adding a replacement, so
exactly one order per side is ever live.

---

## 1. Symbol identity — **OPEN**

**The CSV has no symbol column.** The whole software feed is one unnamed
instrument.

The hardware expects otherwise. `cut_through_parser.sv` takes `symbol_id` from
the low byte of the ITCH **Stock Locate** field, and `order_book_array.sv`
maintains `NUM_ASSETS = 5` independent books. `alpha_engine_core.sv` maps the
asset index to an ASCII ticker for the outbound OUCH message
(`0→AAPL, 1→MSFT, 2→AMZN, 3→GOOG, 4→TSLA`).

Options:

- **(a)** Add a `symbol` column to the pipeline output and assign locates
  0–4 from it. Correct long-term, requires SW pipeline work.
- **(b)** Bridge assigns locate 0 to everything. The design then only ever
  exercises one of five books, and four fifths of the order book is dead in
  every replay test.
- **(c)** Bridge round-robins events across locates 0–4 to exercise all five
  books. Produces stimulus that is realistic *for the hardware* but no longer
  corresponds to a real market.

**The bridge currently implements (c)**, with `--symbols` to select, because the
purpose of the replay test is to exercise hardware. This is a test-harness
choice, not a decision about the product. **Someone needs to pick (a) or (b) for
the real system.**

---

## 2. Message type mapping — decided

| CSV | ITCH | Reasoning |
|---|---|---|
| `A` | `A` Add Order (36 B) | Direct. |
| `C` | `D` Order Delete (19 B) | The CSV's `C` carries the order's **full original size** — it is a complete removal, which is ITCH Delete. |

**Do not map `C` to `X` (Order Cancel).** `X` is a *partial* cancel carrying the
number of shares removed. Mapping `C→X` happens to produce the right answer with
this feed, because `rem = shares - cancel_shares` lands on zero and the parser
emits `MSG_DELETE` anyway — but that is an accident of `C` always cancelling the
whole order. The moment the pipeline emits a partial cancel, `C→X` silently
becomes correct and `C→D` silently becomes wrong. The mapping must be driven by
the semantics, not by which one currently passes.

`E` (Executed), `X` (Cancel) and `U` (Replace) are implemented in the RTL parser
and covered by its unit bench, but **are not reachable from the software feed**.

---

## 3. Numeric scaling — **OPEN**

Software uses `double` for price and size (`sw/shared/include/common.h`).
Hardware uses `logic [31:0]`, unsigned, for both.

OUCH 5.0 specifies **4 implied decimal places** for its price field, and
`outbound_tx_generator.sv` zero-extends the internal 32-bit price into the
8-byte OUCH field. That fixes the natural scale factor:

```
price_hw = round(price_sw * 10^4)
size_hw  = round(size_sw)
```

Headroom check against the observed data:

| | Value | uint32 |
|---|---|---|
| Smallest price (0.0001) | 1 | fine |
| Largest price (301000.0) | 3,010,000,000 | fits, **1.43× margin** |

This works, but 1.43× is not comfortable, and it only holds because the feed
happens to top out at $301k. **Someone needs to either confirm 10⁴ and bound the
price range, or move to a smaller scale factor.** Note that `PRICE_W` is a
`ct_pkg` parameter shared by every block, so changing it is not a local edit.

Size scaling is unstated anywhere. The CSV sizes are whole numbers in this file
(`15.0`, `10.0`), so `round()` is lossless today, but nothing enforces that.

---

## 4. Book depth is never exercised — informational

With at most 2 live orders, the software feed can only ever populate **level 0**
of one side of one book.

The hardware maintains `NUM_LEVELS = 16` levels per side, with sorted insertion,
tail eviction and shift-up-on-delete. **None of that logic is reachable from the
software feed.** It is covered instead by
`tb/order_book/order_book_crv_tb.sv`, which drives it with constrained-random
stimulus (177,988 checks per 2,000-transaction run, verified across five seeds
at 20,000 transactions each).

This is worth stating explicitly in the report: replaying real market data
through the chip is a good end-to-end test and a bad depth test. The two are
complementary, not redundant.

---

## 5. The two order books are different models — informational

They are not intended to match and should not be compared directly:

- `sw/match/src/orderbook.cpp` is a **matching engine**. It crosses trades when
  prices cross and maintains a trade log.
- `rtl/order_book/order_book_array.sv` is a **market-data book**. It aggregates
  price levels and never matches anything.

The only meaningful cross-check between them is the **L1 state** (best bid/ask
price and quantity), which both maintain. That is what the replay test compares.

---

## 6. The two strategies are different algorithms — informational

- `sw/simulation/src/user_strategy.cpp` — fair-value arbitrage. Crosses the
  spread when `best_ask < fair_value - 0.50` or `best_bid > fair_value + 0.50`.
- `rtl/alpha_engine/alpha_engine_core.sv` — EMA mean reversion on the mid price,
  with a configurable threshold.

Both consume the same `{best_bid, best_ask}` input, so either could be ported to
the other side. But **the software simulation is not a golden model for the
hardware alpha engine as it stands**, and nobody should expect their order
streams to agree. If the report claims software/hardware co-verification of the
strategy, one of the two has to be reimplemented to match.

---

## Summary of what needs deciding

| # | Item | Owner | Blocking? |
|---|---|---|---|
| 1 | Symbol column / locate assignment | SW pipeline + HW | Yes — real system cannot be multi-asset without it |
| 3 | Confirm 10⁴ price scale and bound the price range | Both | Yes — silent overflow risk above $429k |
| 3b | Define size scaling and whether fractional sizes are legal | SW | No — lossless today |
| 6 | Whether strategy co-verification is claimed in the report | Both | No — but affects what the report can say |

Items 2, 4 and 5 are decided or informational and need no action.
