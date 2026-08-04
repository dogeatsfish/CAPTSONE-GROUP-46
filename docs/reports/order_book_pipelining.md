# Order Book Pipelining — 250 MHz timing closure change

RTL change made to fix the first implementation run's timing failure
(**WNS −6.691 ns**, 27 087 failing endpoints, all in the 250 MHz `core_clk`
domain — see [`timing_closure.md`](timing_closure.md) for the run analysis).

**One-line summary:** the Order Book's SEARCH and COMMIT stages each did a full
cycle's worth of muxing *and* comparison *and* selection in a single 4 ns
cycle; each is now split into two shallow pipeline stages. Cost: **+2 cycles
per book update** (19 → 21 worst case, against a 168-cycle budget). No
interface, protocol, or storage change.

---

## Why (the critical path, from `vivado/report_timing_summary.txt`)

```
Source:       u_order_book/book_reg[2][1][5][quantity][1]/C
Destination:  u_order_book/tob_reg[2][0][price][15]/CE
Data path:    10.224 ns  (budget ≈ 3.5 ns)  —  19 logic levels, CARRY4×11
```

Two single-cycle cones caused it:

1. **SEARCH** resolved, in one cycle: a 10:1 asset/side mux over the whole book
   array (5 assets × 2 sides × 64 b/level), then **16 parallel 32-bit price
   comparators**, then a **serial 16-level priority cascade** — the encode
   couldn't start until the slowest comparator finished.
2. **WRITE_COMMIT** resolved, in one cycle: a variable-indexed read of the hit
   level (a 160:1 × 64-bit mux), a 32-bit aggregate add, the ToB candidate
   selection, and a **64-bit "did the top change" compare gating the ToB
   registers' clock-enables** (the CARRY4×11 chain in the report).

Fine in simulation; ~3× too deep for a −2 Artix-7 at 250 MHz.

---

## What changed — `rtl/order_book/order_book_array.sv`

### FSM: 5 states → 7

```
before:  IDLE → DECODE → SEARCH     → SHIFT → WRITE_COMMIT              → IDLE
after:   IDLE → DECODE → SEARCH_CMP → SEARCH_ENC
                                    → SHIFT → WRITE_COMMIT → TOB_COMMIT → IDLE
```

### 1. SEARCH split: `SEARCH_CMP` + `SEARCH_ENC`

- **`SEARCH_CMP`** computes, per level, two bits — `cmp_exact[l]` (occupied,
  price matches) and `cmp_insert[l]` (empty, or worse-priced) — and **registers
  the two 16-bit vectors**. This stage contains the asset/side mux and all 16
  comparators, and nothing else.
- **`SEARCH_ENC`** priority-encodes the *registered* vectors into
  `hit_idx / hit_exact / hit_valid` (identical semantics to the old serial
  scan: lowest index wins; exact and insert are mutually exclusive per level).
  The invalid-search drop-out (price worse than the whole tracked window on a
  full book) moved from SEARCH to here, unchanged in behavior.

The comparator bank and the priority cascade are now in different cycles, so
neither cone contains the other.

### 2. COMMIT split: `WRITE_COMMIT` + `TOB_COMMIT`

- **New register `hit_qty`** — in SHIFT's pass-through cycle (taken exactly
  when an aggregate-add can occur: modify, or add-into-existing-level), the hit
  level's quantity is pre-read into a flop. The aggregate add in WRITE_COMMIT
  (`hit_qty + tgt_qty`) now starts from a register instead of a 160:1
  variable-index mux.
- **`WRITE_COMMIT`** still writes the affected level, but instead of also
  comparing-and-committing the ToB, it **registers the ToB candidate** into new
  register `commit_tob` (the written level if `hit_idx == 0` on add/modify,
  else `book[asset][side][0]`, which is final by this point for deletes).
- **New state `TOB_COMMIT`** does the 64-bit `commit_tob != tob[...]` compare
  and commits the ToB registers / `tob_ts` / `tob_updated` pulse atomically,
  then clears `book_busy` and returns to IDLE.

The level-mux/adder and the wide compare + clock-enable fan-out are now two
shallow cycles instead of one 19-level one.

---

## What did NOT change

- **Interfaces:** every port of `order_book_array` is identical. No change to
  the parser, Alpha Engine, or top level.
- **Semantics:** same updates, same ordering rules, same aggregate behavior,
  same ToB atomicity, same `tob_updated`-only-on-real-change rule, same
  invalid-locate and out-of-window drops. `tob_updated` still never overlaps
  `book_busy` (busy clears on the same edge the pulse is set — CRV invariant I3
  still holds).
- **Storage:** the book stays in registers (10 240 bits ≈ 4 % of the device's
  FFs — fine); no BRAM migration was needed for timing.

## Cost

- **+2 cycles per book update**: worst case 19 → **21** cycles
  (1 decode + 2 search + 16 shift + 2 commit), i.e. 12.5 % of the 168-cycle
  minimum packet gap (was 11.3 %). `s_axis_tready` still never de-asserts.
- `tob_updated` (and therefore the Alpha Engine's reaction) fires 2 cycles
  later per update. All benches measure rather than hardcode this, except the
  explicit bound below.
- ~35 extra flops (`cmp_exact/insert` 32, `hit_qty` 32, `commit_tob` 64, one
  wider state encoding) — noise at 4.77 % FF utilization.

## Testbench change

`tb/order_book/order_book_array_tb.sv` — the T10 bound updated from the old
worst case to the new one: `book_busy worst-case <= 21 cyc`
(`busy_max <= NUM_LEVELS + 5`, was `+ 3`), plus the matching comments. No other
bench encodes the update latency.

## Verification

Full 12-bench xsim regression re-run after the change — see the summary table
in the commit / chat log; the expectation is identical pass counts with only
the T10 bound line changed.

## Expected timing outcome

The two deep cones are gone; the deepest remaining order-book paths are the
SHIFT's 160:1 read mux → register and the 16-comparator bank → register, both
of which fit a 4 ns cycle with routing margin. If the next run still misses,
it should be by picoseconds-to-low-hundreds-of-ps elsewhere (risk-gateway DSP,
alpha compare) — that is phys-opt / strategy territory, not restructuring.
