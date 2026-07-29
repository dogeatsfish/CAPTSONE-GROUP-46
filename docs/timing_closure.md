# Timing Closure Analysis — first synthesis/implementation run

Analysis of the first full build (Vivado 2025.2, `xc7a200tfbg484-2`), from
`vivado/report_*.txt`. **Result: everything is healthy except one thing — the
Order Book's single-cycle search/ToB-update cone, which misses 250 MHz by ~3×.**

---

## Scorecard

| Check | Result | Verdict |
|---|---|---|
| Clocks (`report_clocks`) | `rgmii_rx_clk` 8 ns + auto-derived `core_clk_unbuf` 4 ns (MMCM ×2) | ✅ SYNTHESIS define + MMCM worked |
| CDC (`report_cdc`) | 0 Unsafe, 0 missing-ASYNC_REG on the FIFO crossings; "Critical/User Ignored" rows are the *declared* async groups (expected) | ✅ |
| 125 MHz domain | WNS **+2.020 ns**, 0 failing | ✅ whole PHY side closes |
| Utilization | LUT 5.35 %, FF 4.77 %, BRAM ~1 %, DSP 0.5 % | ✅ NF-3 with huge margin |
| Hold / pulse width | WHS +0.060 ns, WPWS +0.870 ns, 0 failing | ✅ |
| **250 MHz domain** | **WNS −6.691 ns, TNS −100 222 ns, 27 087 failing endpoints** | ❌ the one real problem |

Two XDC Critical Warnings (`Common 17-55`, timing.xdc lines 63–64) were the
`rx_error_meta/sync` ASYNC_REG constraints matching nothing — those flops are
**pruned** because the Risk Gateway's `viol_crc` is stubbed (L3). Fixed with
`-quiet` + a comment; the constraint re-arms when viol_crc is wired. They had
zero effect on the timing result.

---

## The critical path (why WNS = −6.691 ns)

```
Source:       u_order_book/book_reg[2][1][5][quantity][1]/C     (a BOOK LEVEL register)
Destination:  u_order_book/tob_reg[2][0][price][15]/CE          (a ToB register clock-enable)
Data path:    10.224 ns   (logic 3.408 / route 6.817)
Logic levels: 19  (CARRY4×11, LUT6×6, LUT5, LUT4)
Required:     ~3.5 ns  (4 ns period − uncertainty/setup)
```

Reading it:

1. **The book lives in registers, not BRAM.** `book_reg[asset][side][level]…`
   — all 5×2×16×64 = 10 240 bits are flops (hence 12.8 k registers, ~1 % BRAM).
   That in itself is fine at this size; the problem is what feeds them.
2. **The search + ToB-update decision is one giant combinational cone.** The
   path walks from a *level-5 quantity bit* through the level-compare /
   hit-select logic (`book[…]_i_44 → _i_23 → tob[…]_i_25 → _i_12 → _i_6`) into
   an 11-deep **CARRY4 chain** (32-bit compare rippling) and finally gates the
   ToB register's **clock-enable**. 19 logic levels ≈ 10.2 ns — a ~3.3 ns
   budget allows roughly 5–6. The cone is ~3× too deep, matching WNS.
3. **27 k failing endpoints is fan-out, not 27 k problems.** Every book/ToB
   bit sits behind the same cone, so one structural fix collapses nearly all of
   them. Current achievable core clock ≈ 1/(4 + 6.69) ns ≈ **93 MHz**.

Root cause vs the design intent: the FSM already splits work into
DECODE → SEARCH → SHIFT → WRITE_COMMIT, but **SEARCH resolves all 16 levels ×
32-bit price/quantity comparisons plus the hit/insert priority-encode in a
single 4 ns cycle**, and the ToB commit re-derives compare results the same way.
That was fine in simulation; on a −2 Artix it is ~3 cycles of real logic.

---

## Fix plan (in order of yield)

1. **Pipeline SEARCH over 2–3 cycles** (the structural fix).
   Stage A: fire all 16 per-level 32-bit comparators, **register** the 16
   hit/greater bits. Stage B: priority-encode the registered bits into
   `hit_idx`/insert position, register it. (Optionally split compare into
   upper/lower half-words for a stage C.) SHIFT/WRITE_COMMIT then consume a
   *registered* index — the CARRY4 wall disappears from every downstream path.
2. **Register the ToB-update decision.** Compute "does level 0 change / new ToB
   value" in WRITE_COMMIT into a staging register; commit to `tob_reg` one cycle
   later (new TOB_COMMIT state or a valid flag). Removes the compare→CE path.
3. **Re-check the budget** — it absorbs this easily: `t_update` grows from 19
   to ~22–23 cycles, still ≪ the 168-cycle minimum packet gap (13 % of budget vs
   11 %). No back-pressure risk; `tob_updated`/FS-7 timing shifts by 1–2 cycles
   (the benches measure, they don't hardcode — re-run to confirm).
4. **Not worth trying instead of the above:** impl strategies / phys-opt
   (recovers ~0.5–1 ns, not 6.7), retiming (can't split a CE cone effectively),
   or lowering the core clock (250 MHz is the design's headline spec).

After the RTL change: re-run synthesis → `report_timing_summary`. Expect the
worst path to move elsewhere (likely risk-gateway DSP or alpha compare) with
WNS in low negative hundreds of ps at worst — then strategies/phys-opt are the
right tool.

---

## Sequencing

1. ✅ XDC `-quiet` fix (done — silences the two Critical Warnings).
2. Pipeline the Order Book (items 1–2) + re-run the full sim regression
   (`./sim/run_all_tb.sh --sim xsim`) — the reference model comparisons are
   latency-insensitive, but T-numbered directed checks may need cycle-count
   updates.
3. Re-synthesize/implement, re-check `report_timing_summary`.
4. Then bitstream + ILA per `vivado/synthesis_implementation.md`.

---

# Round 2 — second implementation run and the three remaining fixes

The order-book pipeline (see `order_book_pipelining.md`) fixed the round-1
path: WNS improved **−6.691 → −4.701 ns** and the `book_reg → tob_reg/CE` cone
vanished from the report (`report_timing_summary2.txt`). The XDC `-quiet` fix
also cleared both synthesis Critical Warnings. What remained, and what was
changed for round 3:

## Scorecard (run 2)

| Group | Result | Meaning |
|---|---|---|
| 125 MHz domain | WNS +2.152 ns, 0 failing | ✅ still closes |
| Hold / pulse width | WHS +0.083 ns, 0 failing | ✅ |
| **250 MHz setup** | **WNS −4.701 ns, 24 175 failing endpoints** | ❌ new worst path: Alpha EMA |
| **`async_default` (recovery)** | **WNS −3.111 ns, 3 719 failing endpoints** | ❌ reset-release net fanout |

## Fix 1 — Alpha Engine pipelined 2 → 4 stages (`alpha_engine_core.sv`)

Worst path was `book_busy_reg → … → ema_avg_reg[1][33]/D`: 17 logic levels,
CARRY4×10, 8.57 ns. One cycle contained: strobe qualification
(`tob_updated && !book_busy`), the asset priority-select (its `sel_idx` net fans
to 190 loads), the 5:1 ToB muxes, then **three chained 34-bit adders**
(`mid = (bid+ask)>>1`, `delta = mid − avg`, `avg += delta >>> k`).

Now four stages, each at most two chained adders fed from local registers:
S0 select/capture (pure mux) → S1 mid + delta (the only 2-adder stage; spread
pre-terms `mid_x ∓ spread_avg` computed in parallel so the spread delta becomes
a single subtract) → S2 EMA write-back + signal select → S3 threshold compare,
order pack, spread write-back. Arithmetic is bit-identical (operations were
staged, not altered; the spread refactor is exact modular-arithmetic
associativity, no shifts distributed).

Consequences: order issues **4 cycles** after `tob_updated` — the full FS-7
budget, still compliant (was 2). Accumulator read→write-back spans 2–3 cycles,
hazard-free because same-book strobes are ≥ 7 cycles apart. Latency telemetry
grows by 2 ticks (8 ns); the integration bench bounds-checks it, no change
needed. `alpha_engine_core_tb` A7 updated: valid at T+4, silent T+1…T+3.

## Fix 2 — reset-release fanout (`clk_rst_gen.sv`)

The recovery failures were **one flop (`core_rst_n_reg`) driving ~13 600
async-clear pins** — 5.94 ns of route on the worst arc
(`→ u_tx_gen/byte_idx_reg/CLR`; "tx_gen slow" was really the reset net, the
farthest load). Both reset synchronisers now drive through an internal register
marked `(* max_fanout = 256 *)`, so synthesis replicates the final flop
(replicas keep async-assert) into ~50 short regional nets. No behavioral
change; sim-invisible.

## Fix 3 — order-book control fanout (`order_book_array.sv`)

Most of the 24 k failing endpoints were the broad fan of book control registers
(`tgt_asset`, `tgt_side`, `hit_idx`, `shift_idx`, `state`) steering the
write-enables and data muxes of all ~10 k book-level flops. Each is now marked
`(* max_fanout = 512 *)` for the same replication treatment.

## Verification after the three fixes

Full 12-bench xsim regression: **173 410 checks, 0 failures** (alpha bench
gained 2 checks from the extended A7 latency probe).

## Expected in run 3

- Alpha cone and recovery group should close or come within phys-opt reach.
- If a residue remains, likely candidates in order: order-book SHIFT read mux
  (160:1 → register), risk-gateway DSP product (check the multiplier absorbed
  its `product_s2/s3` regs as MREG/PREG), parser field-extract steering. Try
  strategy `Performance_ExplorePostRoutePhysOpt` before touching RTL again.

---

# Round 3 — the order book comes back, and the real root cause

Run 3 (`report_timing_summary3.txt`) confirmed the Alpha and reset fixes worked —
WNS improved **−4.701 → −3.138 ns** — but the order book returned as the worst
offender, and the report finally made the *root* cause unambiguous.

## Scorecard (run 3)

| Group | Result | Meaning |
|---|---|---|
| 125 MHz domain | WNS +1.723 ns, 0 failing | ✅ still closes |
| Hold / pulse width | WHS +0.059 ns, 0 failing | ✅ |
| **250 MHz setup** | **WNS −3.138 ns, 23 193 failing endpoints** | ❌ order-book search |
| **`async_default` (recovery)** | **WNS −2.308 ns, 1 880 failing endpoints** | ❌ `hit_idx` self-preset |

Both remaining failures traced to the order book, and **both were route-bound,
not logic-bound** — the signature that pipelining logic depth cannot fix:

**Setup path (−3.138 ns).** `tgt_asset_reg[1] → book[tgt_asset][tgt_side][*] mux
→ price compare → cmp_insert_reg[4]`. Only 8 logic levels, but **78 % of the
7.08 ns is route**: `tgt_asset[1]` alone fans out to **452 loads** across 1.8 ns
of wire. The comparators in `SEARCH_CMP` were reading the `book` array directly,
and `book` is `NUM_ASSETS × 2 × NUM_LEVELS` (~10 k) flip-flops **scattered across
the die**. Muxing a slice out of it is inherently long-wire.

**Recovery path (−2.308 ns).** `hit_idx_reg[2]` (fanout 162, **3.65 ns on one
net**) feeding **its own async preset**. This was self-inflicted: the round-2
`(* max_fanout = 512 *)` on `hit_idx`/`tgt_asset` — registers with *no* reset —
let Vivado replicate them as `FDPE`/`FDCE` cells with **logic-driven set/reset
pins** (the `_P`/`_C`/`_LDC` cells, the 17 “LUT drives async reset” warnings, and
the `no_clock` check entries). That converts a normal data net into a
recovery/removal arc, and the net still spanned the die.

## The real root cause

The whole `book` lives in flip-flops (the module header still advertises a
BRAM/FF *hybrid*, but the depth is currently all FFs). **Every** search, shift,
compare, and write muxes across that die-spanning array, steered by control nets
(`tgt_asset`, `hit_idx`, `shift_idx`) that therefore fan out to hundreds of
loads. Rounds 1–2 pipelined the *logic* inside those cones; they could not
shorten the *wires*. Utilisation is only ~5 % LUT / ~5 % FF, so the die is
sparse and those wires are long — a classic scattered-array routing wall.

## Fix — local working slice ("load-modify-store") in `order_book_array.sv`

Instead of operating on the scattered `book`, a transaction now:

1. **LOAD** (replaces the old `DECODE`): copy `book[tgt_asset][tgt_side][*]` into
   a compact local array `sel[NUM_LEVELS]`. One die-spanning **mux** per level,
   nothing behind it.
2. **SEARCH_CMP / SEARCH_ENC / SHIFT / WRITE_COMMIT**: all read and write `sel`,
   never `book`. `sel` is 16 fixed entries the placer keeps together, so these
   cones are now short and local. The comparators, the level shift, and the
   aggregate-add all move off the die-spanning array.
3. **STORE** (replaces the old `TOB_COMMIT`): write the final `sel` back to
   `book[tgt_asset][tgt_side][*]` (one die-spanning **demux** — local data, CE
   gated by asset/side match, no arithmetic) and commit the ToB atomically.

The **only** two die-spanning steps left are the LOAD mux and the STORE demux,
both single-level and arithmetic-free. `hit_idx`/`shift_idx` now address only the
16-entry `sel`, so their fanout collapses from ~160 to ~16 — the `max_fanout`
attributes on them (and the async-reset artifacts they caused) are **removed**,
and the recovery failures go with them. `tgt_asset`/`tgt_side` keep `max_fanout`
(they still steer LOAD/STORE); `state` keeps it too.

Two supporting changes:
- The transaction control registers (`tgt_asset`, `tgt_side`, `hit_idx`,
  `hit_exact`, `hit_valid`) are now **reset** in the async-reset branch, so they
  infer clean `FDCE` flops (async-clear from the already-replicated `core_rst_n`)
  instead of the no-reset flops Vivado was free to build with logic-driven
  set/reset.

**Behaviour is identical.** State count is unchanged (LOAD↔DECODE, STORE↔
TOB_COMMIT), every cycle latency is unchanged (worst case still
`NUM_LEVELS + 5 = 21`), the ToB/`tob_updated`/`book_busy` timing is bit-for-bit
the same, and the final `book` contents are the same — the data simply lives in
`sel` between LOAD and STORE. `book` now also updates **atomically** at STORE
rather than being torn mid-shift, which is strictly cleaner for any depth read
that races a busy book. No testbench change is required.

## Expected in run 4

- The −3.138 ns setup cone (search comparators) and the −2.308 ns recovery cone
  (`hit_idx` self-preset) should both be gone: the search now reads local flops,
  and `hit_idx` is a plain resettable flop addressing 16 entries.
- New worst path, if any, is most likely the LOAD mux or the STORE demux
  (`tgt_asset` steering ~160 book flops) — but those are single logic levels, so
  even route-heavy they have ~3 ns of slack budget. If a residue remains there,
  `max_fanout` on `tgt_asset` plus `Performance_ExplorePostRoutePhysOpt` should
  close it without further RTL surgery. The longer-term structural option (only
  if needed) is to move the book depth into real BRAM as the header envisaged.

---

# Round 4 — the last two order-book paths

Run 4 (`report_timing_summary4.txt`) confirmed round 3 worked — WNS improved
**−3.138 → −1.862 ns**, the search comparators and the `hit_idx` self-preset are
gone. Both remaining failures were still inside `u_order_book`, and both were
the patterns this doc predicted but had not yet fully addressed.

## Scorecard (run 4)

| Group | Result | Meaning |
|---|---|---|
| 125 MHz domain | WNS +2.743 ns, 0 failing | ✅ still closes |
| Hold / pulse width | WHS +0.054 ns, 0 failing | ✅ |
| **250 MHz setup** | **WNS −1.862 ns, 12 805 failing endpoints** | ❌ STORE ToB compare |
| **`async_default` (recovery)** | **WNS −1.086 ns, 10 450 failing endpoints** | ❌ book async-reset net |

**Setup path (−1.862 ns).** `tob_reg[3][0][quantity][5] → …i_215/i_170/i_124 →
6×CARRY4 → tob_ts[3][15]_i_1 → tob_ts_reg[3][6]/CE`. 11 logic levels. This is
`STORE`'s `commit_tob != tob[tgt_asset][tgt_side]`: a 64-bit inequality that both
muxes the die-spanning ToB cache **and** gates the ToB/timestamp clock-enables,
all in one cycle. Exactly the "register the ToB-update decision" item from
round 1 that was only ever half-done (the *candidate* was registered; the
*compare* was not).

**Recovery path (−1.086 ns).** `core_rst_n_q → LUT1 → book_reg[…]/CLR`, **fanout
13 059, 88 % route, 3.58 ns on the worst net**. The whole `book`/`tob`/`tob_ts`
(~11 k flops) is async-reset, so reset *release* is a recovery arc on one
die-spanning 13 k-load net. `phys_opt` re-placed the driver (log: TNS −3165 →
−2806) but a single net to 13 k loads cannot be made short.

## Fix 1 — split the ToB-changed compare into `STORE_CMP` (`order_book_array.sv`)

`WRITE_COMMIT` now hands off to a new `STORE_CMP` state whose only job is
`tob_changed <= (commit_tob != orig_tob)`. `orig_tob` is the top of book snapshotted
at `LOAD` (`book[tgt][side][0]`, which the ToB cache mirrors — so the compare is
identical to the old `commit_tob != tob[tgt][side]`, but against a **local** flop
instead of the die-spanning cache). `STORE` is then a flag-gated write with no
wide compare in its cone. The compare is now reg → 64-bit compare → flag-reg over
local operands, ending at one flop instead of 16 clock-enables. +1 cycle
(worst-case update 21 → 22, still ≪ 168).

## Fix 2 — synchronous reset for the book (`order_book_array.sv`)

The module's main `always_ff` is now clocked-only; reset is a registered,
`(* max_fanout = 256 *)`-replicated `core_rst_sync`. A synchronous reset is never
a recovery/removal arc, and replication turns the 13 k-load clear into ~40 short
local nets. Reset still zeroes the entire book/ToB — behaviour is identical apart
from taking effect on the clock edge (and one cycle after assertion). As a
bonus, every book flop is now FDRE, so the round-2 self-preset FDPE class cannot
recur, and the DPIR async-driver methodology warnings for the book clear.

## Verification (must re-run before trusting these)

- `./sim/run_all_tb.sh --sim xsim` — behaviour is bit-identical except: (a) the
  book/ToB commit is **+1 cycle** later per update (any T-numbered directed check
  that hardcodes the order-book latency needs +1), and (b) reset now takes effect
  synchronously, one cycle after `core_rst_n` — benches that assert reset for a
  single cycle mid-stream and expect an immediate clear need review (most hold
  reset for many cycles, so this is a non-issue).
- Then re-synthesize/implement → `report_timing_summary5.txt`.

## Expected in run 5

- Setup: the compare becomes a local reg→compare→reg path (~6 CARRY4, short
  routes) with the full ~3.5 ns budget — should close.
- Recovery: the `async_default` book group disappears (no async CLR on the book).
- If any residue remains it should be phys-opt reach; try
  `Performance_ExplorePostRoutePhysOpt`. The next structural lever, only if a
  real path survives, is still moving book depth into BRAM.

---

# Round 5 — order book closes, WNS moves to the risk gateway

Run 5 (`report_timing_summary5.txt`) confirmed **both round-4 order-book fixes
worked** — the order book no longer appears in any failing path, and the
recovery group collapsed from −1.086 ns / 10 450 endpoints to −0.570 ns / 239
endpoints. WNS regressed numerically (−1.862 → −2.190 ns) only because it
un-masked a pre-existing risk-gateway path.

## Scorecard (run 5)

| Group | Result | Meaning |
|---|---|---|
| 125 MHz domain | WNS +2.662 ns, 0 failing | ✅ |
| **250 MHz setup** | **WNS −2.190 ns, 13 768 failing** | ❌ risk-gateway compare |
| **`async_default` (recovery)** | **WNS −0.570 ns, 239 failing** | ❌ tx_gen/alpha async reset |

Note the setup **endpoint total jumped 33 951 → 45 863** while async_default
dropped 13 059 → 1 148: converting the ~11.9 k book flops from async-CLR
(recovery endpoints) to sync-R (setup endpoints) *moved* them between groups —
those book R-pins are now-counted-and-**met**, not failing.

## The `report_failing30.txt` breakdown — three separable problems

| Cluster | Slack | Path |
|---|---|---|
| risk gateway (4+ paths) | −2.190 | `product_s3 → 64-bit compare → token-bucket → token_bucket_reg/R` |
| **order book SHIFT (~20 paths, the bulk)** | −1.48 … −1.36 | `hit_idx (fo=158) / shift_idx / tgt_type / hit_qty → sel_reg/D,CE` |
| tx_gen (2 paths) | −1.389 | `ip_ident → r_ip_csum`, 13×CARRY4 |

So the order book was **not** fully closed — the SHIFT/WRITE_COMMIT control nets
on the 1024-flop `sel` array are the largest failing cluster (route-bound, 82 %).

## Fixes for run 6

1. **Risk — register the max-value compare** (`pre_trade_risk_gateway.sv`).
   `viol_max_value` is now registered off `product_s2` (dropping the `product_s3`
   delay reg) rather than a combinational compare off `product_s3`. Same latency
   and pipeline alignment (product_s2 is valid one cycle before viol_max_value,
   exactly as product_s3 was); the compare gets its own cycle and the token
   bucket reads a single flag.
2. **Order book — re-replicate the SHIFT control nets** (`order_book_array.sv`).
   `(* max_fanout *)` restored on `hit_idx` (32), `shift_idx` (32), `tgt_type`
   (64). Round 3 removed these believing the local slice dropped their fanout to
   ~16 (it is 158) and because they created async self-preset FDPE artifacts —
   the latter no longer applies now the module is synchronous-reset (FDRE).
3. **tx_gen — constant-fold the IP checksum** (`outbound_tx_generator.sv`). The
   nine sequential accumulator adds became one variable add + folds by
   pre-summing the eight constant header words into `IP_CSUM_CONST`. Bit-
   identical; collapses 13×CARRY4 to a shallow cone.

## Expected / open for run 7

- Risk and tx_gen paths should close outright.
- The order-book SHIFT paths were route-bound at −1.4; replication + phys_opt
  should recover most of it, but **may not fully close** — these are variable-
  indexed array read/write cones and replication only shortens the control nets.
  If a residue remains, the decisive fix is a **single-cycle parallel shift**:
  replace the N-cycle `sel[dst_i] <= sel[src_i]` (variable indices, big muxes)
  with `for k: sel[k] <= mask(k,hit_idx) ? neighbor : sel[k]` — each element
  reads a FIXED neighbor gated by a per-element threshold of hit_idx. That
  removes the variable indexing entirely AND cuts SHIFT from ~16 cycles to 1
  (worst-case update 22 → ~7). It changes cycle-latency, so it needs the
  directed benches updated and a full regression — do it deliberately, not blind.
- Recovery (−0.570) is now `u_tx_gen`/`u_alpha` async reset (one net, fo≈1897).
  Same class as the order-book recovery; convert those two modules to sync reset
  if phys_opt does not absorb it.

---

# Round 6 — order book improves, WNS moves to the parser BRAM read

Run 6 (`report_timing_summary6.txt`): WNS −2.128 ns (from −2.190). The order-book
`max_fanout` fix worked — it dropped out of the top failing paths. Risk and
tx_gen fixes held. Two things surfaced:

- **New WNS (−2.128) is the parser** ref-table BRAM read-modify-write:
  `ref_table_reg/CLKBWRCLK → DOBDO (2.125 ns clock-to-out) → 32-bit shares
  subtract + valid decode → ref_wdata_reg`, 6.0 ns in one cycle. A *registered*
  BRAM read already eats ~2.1 ns before any logic.
- **Recovery worsened −0.570 → −0.874**: now `u_alpha` / top-level `kill_meta`
  async-reset CLR pins. This will keep drifting until the remaining core-domain
  modules stop being async-reset (same story as the book).

## Fix applied — parser BRAM read pipeline (`cut_through_parser.sv`)

Added a fabric register `ref_rdata_q` (new `R_WAIT2` state) between the BRAM
output and R_EMIT1's arithmetic, so the `shares` subtract starts from a fast flop
instead of the 2.1 ns DOBDO pin. +1 resolve cycle (still ≪ the 21-cycle message
gap); parser output latency grows by 1 (telemetry benches bound-check, re-run).

## `report_failing30_1.txt` breakdown — two clusters ARE the whole top 30

| Cluster | Slack | Count | Cause |
|---|---|---|---|
| parser BRAM read → `upd`/`ref_wdata` | −2.128 … −1.884 | 3 | fixed above (`ref_rdata_q`) |
| **order-book `core_rst_sync_rep → book_reg/R`** | −1.776 … −1.695 | **~24 of 30** | the book's synchronous reset — 0 logic levels, pure long-route to the scattered ~11k flops |

The `max_fanout` fix DID work — the SHIFT paths dropped out of the top 30
entirely. The book is back as WNS-driver, but now purely because of its **reset
net**: replicating `core_rst_sync` to ~40 copies still leaves each reaching ~256
flops scattered across a 5%-utilised die. A reset to 11k scattered flops is
long-route whether it is async (recovery, round 4) or sync (setup, round 6).

## Fix applied — book/tob/tob_ts to GSR init, no runtime reset (`order_book_array.sv`)

The market-data arrays now carry `= '{default:'0}` declaration initialisers
(→ flop INIT → GSR clears them at configuration) and are **removed from the
runtime reset branch**. That deletes the whole `core_rst_sync → book_reg/R`
class. The control/FSM path and `sel` keep the sync reset (~1.3k flops, routes
fine). Behavioural change: a *runtime* `core_rst_n` no longer wipes the
accumulated book (it restarts the control path and rebuilds from the feed);
book+tob+tob_ts are dropped together so the "tob mirrors book[0]" invariant
holds. Both order-book benches reset only at t=0 (verified), where GSR init gives
the same all-zero state, so T1 (ToB==0) still passes.

## Expected / open for run 7

- Parser (−2.128) and the book reset cluster (−1.78) should both be gone.
- Next setup WNS is whatever sat just below −1.695 (not visible in the top 30) —
  most likely the order-book SHIFT residue after `max_fanout`, or alpha. If a
  real SHIFT residue remains, the single-cycle **parallel shift** is the decisive
  fix (Round 5 note) — needs bench cycle-count updates.
- Recovery (−0.874, `async_default`) is still `u_alpha`/`tx_gen`/top async reset.
  NOTE: do NOT naively sync-reset those — alpha's reset fans to ~1.9k scattered
  flops and would fail SETUP the same way the book just did. The right tool is
  the same GSR-init treatment for their large datapath arrays, or a scoped
  false_path on the reset release. Decide per-module from the next breakdown.

## Datapath preview (`report_datapath40.txt`, reset endpoints filtered out)

Filtering the endpoints to `REF_PIN_NAME == D || CE` (drops the ~10k `book_reg/R`
reset paths) exposed the real datapath tier that will drive run 7's WNS:

| Cluster | Slack | Detail | Status |
|---|---|---|---|
| parser BRAM read → `upd`/`ref_wdata` | −2.128 … −1.36 (~25) | one cycle BRAM-out + arith | fixed (`ref_rdata_q`) |
| order-book SHIFT `state → sel_reg/D` | −1.548 … −1.427 | 1 logic level, **91 % route** (placement) | pending |
| tx_gen `ip_ident → r_ip_csum` | −1.476 … −1.363 | 13×CARRY4 (fold chain) | **re-fixed**, see below |
| alpha `s2_sig → order_tuser/CE, trade/CE` | −1.407 … −1.364 | 9 levels, 4×CARRY4 | pending |

## Fix — tx_gen checksum PIPELINE (`outbound_tx_generator.sv`), replacing the round-5 attempt

The round-5 constant-fold did nothing to the depth: the 13×CARRY4 is the base add
plus the two *dependent* carry folds, not the (already-folded) constant adds.
Since `ip_ident` changes only once per packet, the checksum is now precomputed
continuously in a 2-stage pipeline (`ip_csum_raw` → `ip_csum_pre`) and latched at
accept. Bit-identical output; the deep cone is gone.

## Remaining after parser + book-reset + tx_gen (the "last RTL round")

1. **Order-book SHIFT** `state → sel_reg/D`, −1.548, **91 % route, 1 logic level**
   — this is *placement*, not logic, so its exact slack will move in run 7's new
   placement. Options: the single-cycle **parallel shift** (removes muxing +
   shortens latency, needs bench updates), or a **Pblock** floorplanning
   `u_order_book` into a compact region (no RTL/bench change). Best judged on run 7.
2. **Alpha** `s2_sig → …/CE`, −1.407, 9 levels — logic-bound (deterministic), the
   S3 threshold-compare/order-pack cone; pipeline one more stage. Needs the file
   read carefully (alpha is already 4 stages; adding one shifts FS-7 latency).

---

# Round 7 — the big drop; WNS is the alpha engine

Run 7 (`report_timing_summary7.txt`) with parser + book-GSR-init + tx_gen fixes:

| | run 6 | run 7 |
|---|---|---|
| WNS | −2.128 | **−1.107** |
| TNS | −7963 | −975 |
| Failing endpoints | 15653 | 4476 |
| `async_default` recovery | −0.874 | **+0.263 (MET)** |

The book GSR-init drained the recovery group entirely, and freeing the ~11k reset
endpoints also let the placer shorten the order-book SHIFT paths — they dropped
out of the failing list (no parallel shift needed, placement fixed it). Parser
and tx_gen closed. WNS is now a single clean path:

```
u_alpha/s2_sig_reg[5] → LUT2 → 4×CARRY4 (s2_sig </> ±THR) → LUT3/LUT6×3 (issue/qty) → trade/CE
```

## Fix — rebalance the alpha S2/S3 boundary (`alpha_engine_core.sv`)

FS-7 caps the engine at 4 cycles, so no stage can be added. Instead the threshold
compare (`do_buy = sig < -THR`, `do_sell = sig > THR`) moved from S3 back into S2,
registered as `s2_do_buy`/`s2_do_sell`. Its operands are S1 registers and S2 had
slack, so the ~4-CARRY4 compare is free there; S3 keeps only the shallow LUT
issue/qty logic and the trade write. `s2_sig` itself is no longer read (only the
decision bits are used downstream) so it was removed. Bit-identical behaviour,
latency and FS-7 budget unchanged.

## Expected / strategy for run 8

- Alpha's −1.107 path should close.
- Whatever's next is below −1.107 (order-book SHIFT residue or assorted small
  cones). TNS −975 over 4476 endpoints ≈ −0.22 ns average — this is the last
  mile. **Switch the impl run to a Performance strategy** now
  (`Performance_ExplorePostRoutePhysOpt`, or `Performance_Explore`) — with the
  worst RTL cones gone, phys-opt/router effort can recover the remaining few
  hundred ps that the default strategy leaves on the table.

---

# Round 8 — alpha closes, and the order-book SHIFT finally goes parallel

Run 8 (`report_timing_summary8.txt`, alpha fix + `Performance_ExplorePostRoutePhysOpt`):
WNS **−1.107 → −0.748**. Alpha closed; the Performance place/route recovered a bit
more (though its post-route phys_opt warned WNS was still beyond its −0.5 ns sweet
spot — correct: structural residue remained). Recovery stays MET (+0.384).

New WNS is the perennial order-book SHIFT, now isolated and unambiguous:
```
u_order_book/hit_idx_reg[1]_rep__2 → u_order_book/sel_reg[7][price][0]/D
4.779 ns, logic 1.085 / route 3.694 (77% route), 4 logic levels
```
`max_fanout` + placement had walked it from −1.48 → −0.748, but the **structure**
— a variable-index 16:1 `sel[src_i]` read mux steered by hit_idx — is what was
left. Pure routing, not logic.

## Fix — single-cycle parallel shift (`order_book_array.sv`)

Replaced the multi-cycle `sel[dst_i] <= sel[src_i]` slide (variable indices → the
16:1 mux) with a **fixed-neighbour** shift: on a remove each level takes
`sel[k+1]`, on an insert `sel[k-1]`, gated by a per-level compare of the constant
`k` against `hit_idx`. Fixed neighbours let the placer keep each 64-bit lane as a
local chain, so the long mux net is gone. Non-blocking assignment reads the old
slice, so doing all levels at once is bit-identical to the old tail-to-head
ordering — the final book is the same. Bonus: the slide collapses from NUM_LEVELS
cycles to 1 (worst-case update 22 → 7). Dead `shift_idx` counter removed.

**No bench change needed** (verified): `order_book_array_tb.send()` waits a fixed
30 cycles (≥ old 21 and new 7), and the `book_busy` check is an upper bound
(`<= NUM_LEVELS+5`), which a shorter slide only satisfies more easily. The crv
bench compares final state against a latency-insensitive reference model.

## Expected / strategy for run 9

- The −0.748 SHIFT path should close (route now local).
- Remaining is the ~−0.2-avg tail (TNS −785 / 4232 endpoints). With the last
  structural cone gone and WNS heading into phys-opt's range (> −0.5),
  `Performance_ExplorePostRoutePhysOpt` should now actually earn its keep and
  close the rest — this time its phys_opt pass won't hit the −0.5 bail-out.
- If a stubborn few remain, a fresh filtered `report_datapath40` pinpoints them.

---

# Round 9 — the last cone

Run 9 (`report_timing_summary9.txt`, parallel shift + `Performance_ExplorePostRoutePhysOpt`):

| | run 8 | run 9 |
|---|---|---|
| WNS | −0.748 | **−0.274** |
| TNS | −785.4 | **−15.6** |
| Failing endpoints | 4232 | **224** |
| Recovery / hold / pulse width | MET | **MET** (+0.584 / +0.059 / +0.728) |

The parallel shift did exactly what it was meant to: the whole `hit_idx`/`shift_idx`/
`sel→sel` cluster is gone, TNS collapsed 50×, and the remaining 224 endpoints
average just −0.07 ns. **Full sim regression passed** on the accumulated changes.

Last cone, and note it is now LOGIC-bound (53 % logic), not routing:
```
u_order_book/hit_exact_reg → u_order_book/sel_reg[7][quantity][31]/D
4.197 ns, 11 levels, 8×CARRY4
```

## Fix — take `hit_exact` out of the aggregate-add carry chain

`WRITE_COMMIT` had `if (hit_exact) qty = hit_qty + tgt_qty;`. Synthesis implemented
that by steering the **adder input** with `hit_exact`, so the entire 32-bit carry
chain propagated *behind* it. The gating now happens in SHIFT's pre-read instead —
`hit_qty <= hit_exact ? sel[hit_idx].quantity : '0` (a plain mux there) — leaving
WRITE_COMMIT with an unconditional register+register add. Exact, because hit_qty is
zero whenever `!hit_exact`:

| case | hit_qty | WRITE_COMMIT result |
|---|---|---|
| ADD, hit_exact | existing level qty | aggregate = hit_qty + tgt_qty ✅ |
| ADD, !hit_exact (insert) | 0 | tgt_qty ✅ |
| MODIFY / DELETE | unused | unchanged ✅ |

## `report_failing40.txt` — the tail is NOT all order book

Checking the assumption paid off. The 40 worst paths:

| Cluster | Slack | Count | logic/route | phys-opt reach? |
|---|---|---|---|---|
| `order_book/hit_exact → sel/D` | −0.274…−0.122 | ~20 | 50 % logic | fixed above |
| `parser/p_shares → upd[quantity]/D` | −0.260…−0.121 | 5 | 65 % route | likely |
| `risk/product_s2 → viol_max_value/D` | −0.205 | 1 | **65 % logic, 12×CARRY4** | **no** |
| `risk` DSP `CLK → *_psdsp/D` | −0.186…−0.122 | 3 | **84 % logic** (3.375 ns DSP clk→out) | maybe (0.6 ns route) |
| `risk/token_bucket → /R` | −0.155 | 4 | 64 % route | likely |
| `parser/wire_msg_len → /CE` | −0.136…−0.132 | 7 | 58 % logic | marginal |
| `order_book/cmp_insert → hit_exact/D` | −0.149 | 1 | 75 % route | likely |

## Second fix — split the risk max-value compare (`pre_trade_risk_gateway.sv`)

The `viol_max_value` compare introduced in Round 5 is a full **64-bit** magnitude
compare (~12 CARRY4) — logic-bound, so no amount of phys-opt touches it.
`MAX_ORDER_VAL` is an `int` and always fits the low 32 bits, so any set bit in
`product_s2[63:32]` already means "over cap". The check is now an OR-reduce of the
upper half in parallel with a 32-bit compare of the lower half — bit-identical for
unsigned operands, ~4 CARRY4 shallower.

## Expected for run 10, and the likely survivor

Route-bound clusters (parser p_shares, token_bucket, cmp_insert) are now in
phys-opt's range and should close. The one to watch is the **risk DSP clk→out**
path: 3.375 ns of that 4.014 ns is the DSP48's own CLK→P propagation, which is
inherent — only its 0.639 ns of route is recoverable, so phys-opt has to place the
capture flop essentially adjacent to the DSP. If it survives, the real fix is to
give the 32×32 multiply an **MREG stage** (`product_m <= price_s1*quantity_s1;
product_s2 <= product_m;`), which is also what the outstanding DPOP/DPIP DRC
warnings have been asking for — but that adds a cycle and needs the whole risk
pipeline (`viol_max_qty`, `tvalid`, `trade`) extended by one to stay aligned.
Deferred until we see whether it actually survives.

Re-run the regression first — the directed T6 check ("add at existing top price →
aggregate") exercises `hit_qty` directly, and the risk bench covers the max-value
cap, so both folds are covered.

---

# Rounds 10–11 — placement variance, and the token-bucket root cause

| run | WNS | WNS location | change under test |
|---|---|---|---|
| 9 | −0.274 | order_book `hit_exact` | (best so far) |
| 10 | −0.414 | risk `viol_max_value → token_bucket/R` | round-9 RTL fixes |
| 11 | −0.490 | risk `token_bucket → token_bucket/R` | synth settings bundle |

**Round 9's two fixes both landed** — the order-book `hit_exact` cluster (~20
paths) and the `product_s2 → viol_max_value` compare are gone from the failing
list. What surfaced instead was the token bucket, three runs running.

## Synthesis settings experiment — negative result

Tried `-flatten_hierarchy none -resource_sharing off -no_lc -no_srlextract`
(rationale: ~5 % utilisation, so trade area for speed). Confirmed applied in
`synth_1/commontrader_top.tcl`. **Did not help** (−0.414 → −0.490, within
run-to-run variance). Worth reverting to defaults to reduce variables.

Note the `Netlist 29-101` warning about `order_book_array` having "a large number
of primitives" **persists regardless of the flatten setting** — `order_book_array`
is a leaf module with no submodules, so hierarchy preservation cannot subdivide
it. The warning is not evidence that the setting was ignored.

## Root cause — 32-bit arithmetic on a 5-bit counter (`pre_trade_risk_gateway.sv`)

The token bucket was not placement bad luck. It was declared:

```systemverilog
automatic integer next_bucket = token_bucket + tokens_to_add - tokens_to_sub;
```

`integer` is **32-bit signed**, but `token_bucket` is a **5-bit** counter (0…16).
Synthesis therefore built a 32-bit add/subtract *and* 32-bit saturation compares —
which is why a trivial token counter kept appearing as a 4× CARRY4 cone (WNS in
runs 5, 10 and 11). Now sized to the actual range (−1 … RATE_TOKENS+2, 7 bits
signed); arithmetic and saturation behaviour unchanged. The sibling
`(token_bucket + tokens_to_add) == 0` had the same unsized-literal widening and is
now `== '0`.

**Lesson for the rest of the codebase:** `integer`/unsized literals in RTL silently
create 32-bit datapaths. Worth grepping for other uses before the next build.

---

# Round 12 — we have hit the placement noise floor

| run | WNS | WNS owner | what changed |
|---|---|---|---|
| 9 | **−0.274** | order_book `hit_exact` | (best) |
| 10 | −0.414 | risk `viol_max_value` | + round-9 RTL fixes |
| 11 | −0.490 | risk `token_bucket` | synth settings bundle (reverted since) |
| 12 | −0.624 | parser `wire_msg_len` | + token-bucket fix, clean defaults |

Every fix landed — each cluster disappeared from the failing list the run after it
was made, and the token-bucket fix removed that cone for good. **The RTL today is
strictly better than at run 9** (since then: `hit_exact` out of a carry chain, the
64-bit max-value compare split, 32-bit arithmetic on a 5-bit counter sized down).

## The decisive measurement

The parser `wire_msg_len` path **was −0.136 ns in run 9 and −0.624 ns in run 12
with its RTL completely unchanged** — a **0.49 ns swing from placement alone**.

Our remaining gap is ~0.27 ns. **Variance (≈0.5 ns) now exceeds the gap.** That is
why fixing each WNS keeps promoting a *worse* one: we are no longer measuring
logic depth, we are sampling placement luck. Further single-path RTL surgery is
not a converging process.

Achieved period across runs: 4.27–4.62 ns → the design currently closes somewhere
around **216–234 MHz**, against a 250 MHz (4.0 ns) target.

## Fix still applied — parser end-of-message test

`FIELD_EXTRACT` evaluated `wire_msg_len - 16'd1` inline, putting a 16-bit subtract
(5×CARRY4) in front of a clock-enable. Now precomputed as `wire_msg_len_m1` in the
shallow `MSG_LEN` state; the hot path is a plain equality compare. Real fix, worth
keeping — but it is not what closes the design.

## The three honest options from here

1. **Sample the variance — placer directive / seed sweep.** Highest expected value.
   The RTL is better than the run that hit −0.274, so a favourable placement should
   land closer to zero. Try `place_design -directive` alternatives
   (`ExtraTimingOpt`, `ExtraPostPlacementOpt`, `ExtraNetDelay_high`) as separate
   impl runs and keep the best checkpoint. Costs build time only — no RTL risk.
2. **Reduce the variance — floorplan.** Pblock `u_order_book` (and possibly
   `u_risk`) into compact regions so intra-module routes stop being a lottery.
   Zero functional risk; needs region sizing and a couple of iterations.
3. **Re-examine the 250 MHz target.** The design closes ~230 MHz. If the spec can
   flex, this ends immediately. This is a team/advisor decision, not an
   engineering-only one — noted here because it is a legitimate option, not
   because it is recommended over 1 and 2.

**Recommendation:** stop single-path RTL chasing. Do (1), and (2) if (1) is not
enough. Keep run 9's checkpoint as the reference baseline.

---

# Round 13 — best result, and the last high-fanout control net

Run 13 (default synthesis + `Performance_ExplorePostRoutePhysOpt`):

| | run 12 | **run 13** |
|---|---|---|
| WNS | −0.624 | **−0.118** |
| TNS | −42.8 | **−4.44** |
| Failing endpoints | 319 | **86** |

`Design State : Physopt postRoute` — fully routed, real delays. Clock still
4.000 ns / 250 MHz, endpoint count consistent with prior runs (nothing dropped
from analysis), and hold (+0.060), pulse width (+0.728), recovery (+0.586) and
the 125 MHz domain (+2.553) are all MET. **From −6.691 → −0.118 ns.**

## Fix — replicate `tgt_price` (`order_book_array.sv`)

WNS was `tgt_price_reg[0] → cmp_exact_reg[12]/D`, 5 logic levels but **63 % route**.
`SEARCH_CMP` uses `tgt_price` in BOTH comparators of EVERY level
(`lvl.price == tgt_price` and `tgt_price >/< lvl.price`) — ~32 comparator
instances spread across the whole `sel` array. `tgt_price` was **the only latched
transaction field still without `max_fanout`**; `tgt_asset`, `tgt_side`,
`tgt_type` and `hit_idx` all have it, and `hit_idx` is exactly the net whose
replication took it from −1.48 ns to closing. Now `(* max_fanout = 16 *)`.

This is a **synthesis attribute — no functional change, no regression required.**
It also reduces *variance*, not just this run's WNS: shorter control routes make
the design less sensitive to placement luck, which has been the dominant effect
since round 9.

## `report_failing40_3` + congestion — the last 40 paths are fanout reach

All 40 remaining paths sit between −0.118 and −0.058 ns, and ~80 % are
**route-dominated on high-fanout control nets**:

| Cluster | Slack | Count | Profile |
|---|---|---|---|
| `tgt_price → cmp_exact/cmp_insert` | −0.118…−0.088 | ~6 | 63–72 % route |
| `state_reg[0] → book_reg/CE` | −0.095…−0.060 | ~10 | **83 % route, 2 levels** |
| `state_reg[2]_rep → sel` | −0.101…−0.065 | 4 | **80 % route, 1 level** |
| `hit_idx → sel/CE` | −0.117…−0.091 | 3 | 80 % route |
| `tgt_type → sel/CE` | −0.088…−0.058 | 3 | 80 % route |
| `tgt_qty → sel[quantity]` | −0.117…−0.077 | 3 | 56 % *logic*, 7×CARRY4 (aggregate add) |
| `risk/product_s2 → viol_max_value` | −0.116 | 1 | 60 % *logic*, 11×CARRY4 |
| `parser` / `tx_gen` misc | −0.109…−0.067 | 6 | 60–79 % route |

**Congestion report: "No congestion windows are found above level 5", router
congestion table empty.** Two consequences: (a) the `AltSpreadLogic` theory is
dead — there is nothing to relieve; (b) a 3.3 ns route on a *two-logic-level* path
with zero congestion is not a detour, it is a net physically reaching ~1024 book
flops. That is fanout **reach**, and replication is the correct and safe lever
(90 % of the die is free).

`max_fanout` values were therefore too loose and are tightened:
`state` 512→64, `tgt_type` 64→32, `hit_idx` 32→16, `tgt_price` (new) 16.
All attributes — no functional change, no regression needed.

## Both remaining logic-bound cones closed pre-emptively

Logic-bound cones do not respond to placement, so they resurface as the
route-bound ones are fixed. Both were closed in the same pass rather than waiting
for them to become the WNS again.

**1. Risk max-value compare (−0.116, 11×CARRY4).** The round-9 split removed the
upper 32 bits but left a full 32-bit compare on the low half. The split point is
now derived from the parameter — `MOV_BITS = $clog2(MAX_ORDER_VAL+1)` (20 for the
1e6 default) — because `2**MOV_BITS > MAX_ORDER_VAL` by construction, so any set
bit at or above `MOV_BITS` already exceeds the cap. Leaves an OR-reduce in
parallel with a ~20-bit compare (~5 CARRY4). Bit-identical for unsigned operands;
guarded against a zero cap so the slice can never be null.

**2. Order-book aggregate add (−0.117, 7×CARRY4, 11 levels).** An exact-price ADD
needs `sel[hit_idx].quantity + tgt_qty`, and doing it in WRITE_COMMIT put a 32-bit
add *in front of* the `sel` write demux. The per-level sums are now precomputed in
**SEARCH_CMP** — where `hit_idx` is not yet known, which is precisely what makes it
work: no mux ahead of the adder, both operands are registers, so it is a clean
reg→add→reg cycle. WRITE_COMMIT is left with a mux over registered sums, and
`hit_exact` selects between two *registered* values (one LUT level, not a carry
chain). Costs 16 adders + 512 flops — free at ~5 % utilisation.

Equivalence (an exact-price ADD never shifts, so `sel` is unchanged between
SEARCH_CMP and WRITE_COMMIT — the only case that reads `agg_qty`):

| case | needs_shift | agg_qty used | result |
|---|---|---|---|
| ADD, hit_exact | false | yes | `sel[hit_idx].qty + tgt_qty` ✅ |
| ADD, !hit_exact | true | no | `tgt_qty` ✅ |
| MODIFY | false | no | `tgt_qty` ✅ |
| DELETE | true | no | nothing written ✅ |

**Regression required** — the order-book change is functional (T6 "add at existing
top price → aggregate" covers it directly), and the risk change touches a risk
control even though it is behaviourally identical.

---

# DRC — critical/blocking items for the bitstream

**Applied — see [DRC_fix.md](DRC_fix.md) for the full write-up.** None of these
gate timing, but the pin-planning ones **block `write_bitstream`**. All share the
round-4 root cause (async reset on a hard-block register) except the last.

1. **REQP-1839 / REQP-1840 (40 criticals) — parser BRAM address regs.**
   `u_parser/ref_table` (RAMB18/36) has address pins (`ADDRARDADDR`,
   `ADDRBWRADDR`) driven by `ref_waddr`/`p_ref` registers that carry an async
   reset — Vivado warns this can corrupt RAM contents on reset assertion. Fix:
   make the address-generating registers in `cut_through_parser.sv` (the
   `posedge core_clk or negedge core_rst_n` block at ~L419: `ref_waddr`, `p_ref`
   and their replicas) **synchronous-reset**, same conversion as the book.

2. **DPOR (34) + DPOP (6) + DPIP (5) — risk-gateway DSPs.**
   `u_risk/product_s2*` DSP output registers have an async reset, which blocks
   Vivado from pulling them into the DSP48 as MREG/PREG (log: "No candidate cells
   for DSP register optimization"). Fix: sync-reset the `product_s2`/pipeline
   registers in `pre_trade_risk_gateway.sv`; optionally add the suggested extra
   MREG/PREG stage. Improves DSP timing and power; not currently critical-path.

3. **CFGBVS-1 / NSTD-1 / UCIO-1 (pin planning) — will fail bitstream.**
   - `CFGBVS`/`CONFIG_VOLTAGE` unset → add to the pins XDC:
     `set_property CFGBVS VCCO [current_design]` and
     `set_property CONFIG_VOLTAGE 3.3 [current_design]` (match the board bank-0 rail).
   - `order_drop_count[15:0]` (top-level output) has no `LOC`/`IOSTANDARD`. Either
     assign real pins + IOSTANDARD in the XDC, or — if it is debug-only telemetry —
     drop it from the top-level ports and observe it via ILA instead.

---

# Round 14 — Parser arithmetic split & Order Book fanout distribution

After previous rounds, remaining bottleneck paths surfaced in `cut_through_parser.sv` and `order_book_array.sv`:

## Fix 1 — Parser compare & subtract pipeline split (`cut_through_parser.sv`)
- **Problem:** `R_WAIT2` evaluated `ref_rdata.shares > p_shares` and `ref_rdata.shares - p_shares` in a single cycle starting directly from the BRAM output (`ref_rdata`), creating a 15-logic-level cone (-0.388 ns WNS on `ref_rdata_reg[shares][2] → rem_q_reg[29]`).
- **Fix:** Introduced state `R_WAIT3` into `res_state_e`. In `R_WAIT2`, `ref_rdata_q <= ref_rdata`, `rem_q_diff <= ref_rdata.shares - p_shares`, and `rem_q_is_greater <= (ref_rdata.shares > p_shares)`. In `R_WAIT3`, `rem_q <= rem_q_is_greater ? rem_q_diff : '0`.
- **Result:** Splits the 32-bit compare and subtract across two clock cycles, reducing logic levels from 15 to 8.

## Fix 2 — Order Book `hit_idx` fanout pipeline stage (`order_book_array.sv`)
- **Problem:** Priority encoder outputs directly drove `hit_idx` replicated registers, causing long routing delays from the priority encoder logic to scattered destination registers across the die.
- **Fix:** Added `SEARCH_DIST` state to `book_state_e` (expanded enum `book_state_e` from `logic [2:0]` to `logic [3:0]` to accommodate 9 total states). `SEARCH_ENC` writes to central un-replicated registers (`hit_idx_central`, `hit_exact_central`, `hit_valid_central`), and `SEARCH_DIST` copies them to the `max_fanout` replicated registers (`hit_idx`, `hit_exact`, `hit_valid`).
- **Result:** Decouples priority encoder logic from the die-spanning distribution routing phase.

---

# Round 15 — Risk Gateway TNS recovery & Order Book MUX control replication

## Fix 1 — Risk Gateway `viol_max_value` pipeline alignment & TNS fix (`pre_trade_risk_gateway.sv`)
- **Problem:** `viol_max_value` evaluated off `product[3]` in an `always_ff` block, introducing an extra cycle of latency relative to `tvalid[3]` (failing `risk_gateway_tb` Tests 3, 5C, 5D). A temporary combinational fix directly off `product[3]` caused a 5-level combinational cascade into `refund_pulse → tokens_to_add → token_bucket_reg`, exploding TNS (-0.373 ns on `token_bucket_reg`).
- **Fix:** Re-registered `viol_max_value` off `product[2]` instead of `product[3]`.
- **Result:** Keeps `viol_max_value` as a registered flop (breaking the long combinational path into the token bucket and restoring TNS), while making it valid on cycle 4 so it aligns perfectly with `tvalid[3]` on cycle 5 for egress validation.

## Fix 2 — Order Book `tgt_side` control net replication (`order_book_array.sv`)
- **Problem:** `sel_reg[14][price] → cmp_insert_reg[14]` was failing at -0.380 ns with 67% routing delay. `tgt_side` lacked tight fanout replication (`max_fanout = 512`), forcing all level selection MUXes (`tgt_side == SIDE_BID ? > : <`) to cluster near a single driver.
- **Fix:** Applied `(* max_fanout = 8 *)` to `tgt_side` in `order_book_array.sv`.
- **Result:** Allows Vivado to replicate `tgt_side` locally across the array, placing the level selection MUXes next to their respective `sel_reg` slices and eliminating routing bottleneck.

## Verification
- **Full xsim regression passed:** 173,423 checks across 12 testbenches with **0 failures**.

---

# Round 16 — WNS moves back to order book and tx_gen

Run 16 (`report_failing40.txt` from user observation):
The last round's fixes to `pre_trade_risk_gateway` worsened WNS slightly to -0.213 ns, shifting the critical paths back to the order book and tx_gen blocks.

| Group | Slack | Cause |
|---|---|---|
| `order_book_array` | -0.213 ns | `agg_qty` / `hit_idx` 16:1 mux logic feeding `sel` demux |
| `outbound_tx_generator` | -0.203 ns | `ip_csum_pre` double carry chain (17-bit add + 16-bit add) |

## Fix 1 — Flatten `WRITE_COMMIT` mux (`order_book_array.sv`)
`WRITE_COMMIT` previously read `agg_qty[hit_idx]` which forced a 16:1 multiplexer right before a write demux (`sel[hit_idx] <= ...`).
Since `agg_qty` is already computed for ALL levels in `SEARCH_CMP`, this was refactored to loop over `NUM_LEVELS` and conditionally read its OWN `agg_qty[k]` when `k == hit_idx`. This decouples the levels and eliminates the massive logic cone. Also updated `commit_tob` to statically read `agg_qty[0]` when `hit_idx == '0`.

## Fix 2 — Pipeline IPv4 checksum (`outbound_tx_generator.sv`)
The IP checksum pre-calculation was taking 1 cycle to do two sequential carry chains. Pipelined into 3 stages instead of 2. `ip_ident` only updates once per packet (which is at least 77 cycles apart), giving the pipeline more than enough time to settle without affecting throughput or latency.

---

# Round 17 — Fixing Parser BRAM Read, Order Book Routing, and Risk Gateway DSP

Run 17 (based on `report_failing40.txt` and DRC reports):
The critical paths remaining were deeply structural, highlighting route-dominated comparisons and sub-optimal DSP primitive packing.

| Group | Slack | Cause |
|---|---|---|
| `cut_through_parser` | -0.421 ns | 32-bit `shares` subtract executed in the same cycle as the `ref_table` BRAM read. |
| `order_book_array` | -0.161 ns | 32-bit `quantity != 0` OR-reduce spanned the array, feeding `cmp_exact` and causing 77% route delay. |
| `pre_trade_risk_gateway` | DRC DPIP/DPOP | `product_s2` multiplier lacked an explicit `MREG` pipeline stage, blocking DSP48 optimization. |

## Fix 1 — Parser BRAM Read Pipeline (`cut_through_parser.sv`)
The FSM previously evaluated `rem_q_diff` starting directly from the `ref_rdata` BRAM output pin, violating the 4.0ns period because the BRAM clock-to-out takes ~2.125ns.
**Fix**: Introduced `R_WAIT4` to properly pipeline the subtract. `R_WAIT2` now only captures `ref_rdata_q <= ref_rdata`. `R_WAIT3` computes `rem_q_diff` starting from the fast fabric register `ref_rdata_q`. `R_WAIT4` drives the final multiplexer.

## Fix 2 — Order Book Pre-Compare Stage (`order_book_array.sv`)
The `SEARCH_CMP` comparisons (`cmp_exact_next` and `cmp_insert_next`) relied on a wide 32-bit OR-reduce check for `lvl.quantity != '0'`, causing massive routing delay across the wide `sel` array.
**Fix**: Added a `SEARCH_PRE_CMP` state to the FSM before `SEARCH_CMP`. This state evaluates `sel_valid` (quantity != 0) and local price comparisons (`==`, `>`, `<`) into per-level registers. `SEARCH_CMP` then operates entirely on these local boolean flags, completely isolating the heavy routing from the critical path.

## Fix 3 — Risk Gateway DSP MREG Inference (`pre_trade_risk_gateway.sv`)
The Vivado DRC tool reported DPIP / DPOP warnings because the `price * quantity` pipeline was missing an explicit MREG intermediate pipeline stage, preventing the registers from packing inside the DSP48 primitive.
**Fix**: Added `product_m` to the DSP pipeline as the explicit MREG stage (`product_m <= price_s1 * quantity_s1; product[1] <= product_m;`). Also updated the `viol_max_value` check to read directly from `product[1]`, ensuring no change to the overall egress latency.

## Verification
- Expected to close WNS across all modules as all three major structural anomalies have been fully partitioned.

---

# Round 18 — three clock-enable cones own all 40 failing paths

Run 18 (`vivado/report_failing40.txt`, 2026-07-28 16:21, `Design State: Physopt
postRoute` — fully routed, real delays).

**A note on the record.** Rounds 14–17 were written up without scorecards or run
numbers, so there is no recorded WNS between run 13 (−0.118 ns) and this run
(−0.127 ns). The two numbers are close, but they are **not** a measured trend —
several RTL changes landed in between (parser `R_WAIT3`/`R_WAIT4`, `SEARCH_DIST`,
`SEARCH_PRE_CMP`, risk DSP `MREG`, `tgt_side` replication) whose individual
effect was never captured. Treat run 18 as a fresh measurement, not as
"run 13 plus 9 ps".

## Scorecard (run 18)

| | value |
|---|---|
| WNS | **−0.127 ns** |
| Failing paths in report | 40 (report capped at 40) |
| Path group | **`core_clk_unbuf` — all 40** |
| Endpoints | `/CE` on 39, `/D` on 1 |
| Logic vs route | 17–22 % logic, **78–83 % route** |

The report was checked for I/O involvement and there is none: **zero** paths
touch an `OBUF` or any `rgmii_*` pin, and the `set_output_delay` constraints in
`commontrader_pins.xdc` are still commented out, so no output paths are being
analysed at all. Pin properties (`IOSTANDARD`/`SLEW`/`DRIVE`) do not enter this
result. There is also no debug hub in the design (`BSCANE2: 0 used`), so JTAG /
ILA insertion is not a factor either.

## The 40 paths are three cones, not 40 problems

| Cone | Slack | Count | Path |
|---|---|---|---|
| **alpha** `s2_ask_qty → trade_reg[*]/CE` | −0.123 … −0.098 | **30** | 4 LUT levels → fanout-71 enable net |
| **order book** `tgt_type → sel_reg[*][*]/CE` | −0.102 … | **8** | LUT2 → LUT4 → LUT6 → LUT6, via a **fanout-977** net |
| **order book** `upd[symbol_id] → tgt_price_reg[9]_rep/D` | **−0.127** (WNS) | 1 | LUT5 → LUT5 → fanout-72 → LUT4 |

All three are the same shape: a small combinational decision computed *in front
of* a wide clock-enable, so a cheap function pays a wide net's routing cost. In
every case the inputs were already registers, one stage earlier.

## Fix 1 — alpha engine: don't compute `qty != 0` through the min (30 paths)

```
s2_ask_qty_reg[11] → trade[quantity][6]_i_8 → _i_2
                   → trade[timestamp][15]_i_4 → _i_1 → trade[0] (fo=71) → trade_reg/CE
```

S3 gated the trade register's clock enables on `(do_buy || do_sell) && qty != 0`,
where `qty = min(avail, LOT_SIZE)` and `avail` is a 32-bit mux of the two ToB
quantities. That dragged the avail mux *and* the LOT_SIZE min into the enable
cone — four LUT levels to answer a yes/no question.

The chain is unnecessary. **`LOT_SIZE` is a non-zero constant, so
`min(avail, LOT_SIZE) != 0` ⟺ `avail != 0`** — the min cannot turn a non-zero
value into zero, nor a zero into non-zero. The zero test therefore moves one
stage earlier onto the raw S1 quantities (`s2_ask_nz`, `s2_bid_nz`), and S3
becomes a single LUT over four S2 registers:

```systemverilog
issue = do_buy ? s2_ask_nz : (do_sell && s2_bid_nz);
```

Written as a **mux, not an OR**, so it reproduces the `avail` mux's `do_buy`
priority exactly — identical for every input combination, including the
impossible-while-`THRESHOLD > 0` case of both decisions asserting at once. The
qty arithmetic stays in S3, where it now only feeds `trade.quantity`'s D input,
which has slack. FS-7 latency, stage count and arithmetic are unchanged.

## Fix 2 — order book: register the shift-kind decode (8 paths)

```
tgt_type_reg[1] → LUT2 (is_removal, fo=977) → LUT4 (needs_shift)
                → LUT6 → LUT6 → sel_reg[*][*]/CE
```

`is_removal` and `needs_shift` were **combinational** off `tgt_type`/`hit_exact`
and sat directly in front of every `sel` write-enable — and `is_removal` reached
**977 loads**. Both are pure functions of registers that are stable from
`SEARCH_ENC` onward, so they are now computed once in **`SEARCH_DIST`** — the
stage round 14 added purely to fan registers out, which has slack to spare — and
consumed as flops in `SHIFT`.

`hit_exact_central` is used rather than the replicated `hit_exact` because
`SEARCH_DIST` is precisely the cycle that copies one into the other, so the two
are equal by construction during `SHIFT`. Both carry `(* max_fanout = 64 *)`,
matching `state`, since they gate the same flops.

## Fix 3 — order book: the symbol check off the `tgt_*` capture enable (WNS)

```
upd_reg[symbol_id][5] → LUT5 → LUT5 → state1 (fo=72) → LUT4 → tgt_price_reg[9]_rep/D
```

`IDLE` gated the `tgt_*` **capture** on `s_axis_tvalid && upd.symbol_id < NUM_ASSETS`.
`symbol_id < 5` is an 8-bit compare that cannot fold into one LUT6, so it is two
levels however it is written — and it was landing in front of every replica of
`tgt_price`, `tgt_qty`, `tgt_asset`, `tgt_side`, `tgt_type` and `tgt_ts`.

The fix is to keep it **off the wide enable** rather than to make it shallower.
Capture is now gated on `s_axis_tvalid` alone (one level); only the **state move**
carries the range check:

```systemverilog
if (s_axis_tvalid) begin
  tgt_asset <= upd.symbol_id[ASSET_IDX_W-1:0];
  ...
  if (upd.symbol_id < SYMBOL_W'(NUM_ASSETS)) state <= LOAD;
end
```

Latching a rejected update is harmless: the FSM stays in `IDLE`, nothing reads
`tgt_*` in `IDLE`, and the next accepted update overwrites every field. The
discard still happens **here**, in the block that owns the array — an
out-of-range locate never reaches `LOAD` and so never indexes `book`.

## Verification

Full 12-bench xsim regression: **173 410 checks, 0 failures.**

| bench | checks | | bench | checks |
|---|---|---|---|---|
| cdc_fifo | 19 | | order_book_crv | 173 019 |
| rx_mac | 20 | | alpha_engine | 34 |
| tx_mac | 36 | | risk_gateway | 26 |
| parser | 57 | | tx_gen | 32 |
| order_book | 45 | | integration / replay / crv | 58 / 55 / 9 |

Net functional change is 14 lines across two files; no state was added, no
latency changed, and no bench needed updating.

## Expected in run 19

- All three reported cones should clear — each is now register → 1–2 LUT → flop.
- **What surfaces next is the open question.** The 40 paths were clustered in a
  29 ps band (−0.127 … −0.098), which usually means a dense population sitting
  just under zero that the `-slack_lesser_than 0 -max_paths 40` cap hides. The
  design may land near zero rather than comfortably positive.
- If a residue remains, re-report with a **higher `-max_paths`** (200+) before
  changing anything — with WNS this small, knowing whether it is 5 paths or 500
  decides between one more RTL fix and a placement/floorplan approach. Round 12's
  finding still stands: placement variance was measured at ≈0.5 ns, which is
  larger than the current gap.

---

# Round 19 — the write-enable decode, and the whole failure set for the first time

Run 19 (`vivado/report_failing500.txt`, 2026-07-28 20:50, `Physopt postRoute`),
reported with `-max_paths 500` — so for the first time **this is every failing
path, not a truncated view.**

## Scorecard (run 19)

| | run 18 (capped at 40) | **run 19 (complete)** |
|---|---|---|
| WNS | −0.127 | **−0.173** |
| Failing paths | ≥ 40, unknown | **240** |
| TNS over reported paths | unknown | **−13.7 ns** |
| Median failing slack | — | **−0.046 ns** |
| Paths better than −50 ps | — | **121 of 240** |
| Location | alpha + order book | **`u_order_book` — all 240** |

Read this honestly in both directions. **WNS got 46 ps worse.** But run 18's
report was capped at 40 paths, so its total was never measured — the two runs
were taken with different instruments and their path counts cannot be compared.
What *can* be checked is whether round 18's fixes landed, and they did: all three
of its cones (`s2_ask_qty → trade_reg/CE`, `tgt_type → sel_reg/CE`,
`upd[symbol_id] → tgt_price_reg/D`) are **absent** from the 240. The alpha
engine, parser, risk gateway, tx_gen and both MACs contribute **zero** failing
paths. What is left is one module and, underneath it, essentially one idea.

## All 240 paths are the write-enable decode

| Cluster | Slack | Count | Endpoint |
|---|---|---|---|
| `state` / `tgt_side` / `tgt_asset` → `book_reg[*]/CE` | −0.17 … −0.00 | **194** | the STORE demux |
| `state` / `hit_idx` → `sel_reg[*]/CE` | −0.173 … | **35** | the `sel` write enables |
| `state_rep` → `state_rep/D` | −0.128 … −0.007 | 5 | FSM replica-to-replica |
| `cmp_exact` → `state_reg/D` | −0.102, −0.007 | 2 | priority cascade in next-state |
| `book_reg` / `tgt_asset` → `sel_reg/D` | −0.061 … −0.010 | 3 | the LOAD mux |
| `upd[symbol_id]` → `state_reg/D` | −0.021 | 1 | round-18's relocated compare |

229 of 240 are **clock enables**, and the shape is identical in both clusters: a
small decode computed *in front of* a net that has to reach a whole array.

```
tgt_side_rep__120/Q (fo=32)
  → LUT6  book[1][1][1][quantity][31]_i_2  (fo=38)
  → LUT4  book[3][1][1][quantity][31]_i_1  (fo=832)   ← 84 % route
  → book_reg[3][1][2][price][11]/CE
```

This is also the answer to the placement question. `book[tgt_asset][tgt_side][l]
<= sel[l]` sitting inside the FSM's `STORE` arm gives **every one of the ~10 k
book flops** a clock enable of `(state == STORE) && (a == tgt_asset) && (s ==
tgt_side)`. That decode net has no natural home — it must touch the entire array
— so the placer smears the logic across clock regions trying to serve it. The
uneven spread is a symptom of this cone, not an independent problem.

## Fix 1 — registered one-hot book write-enable (194 paths)

A new `store_we[a][s]` one-hot register is raised in **STORE_CMP**, and the book
write-back **moves out of the FSM** into its own `always_ff` gated by nothing
else:

```systemverilog
always_ff @(posedge core_clk) begin
  for (a) for (s) if (store_we[a][s])
    for (l) book[a][s][l] <= sel[l];
end
```

Every book flop's clock enable is now **one register bit with zero logic levels**.
The decode still happens — it just happens a cycle earlier, in STORE_CMP, which
does nothing but a 64-bit compare and has slack to spare. Crucially each
`store_we` bit drives **one contiguous asset/side slice** (16 × 64 = 1024 flops)
instead of a net spanning the array, so `max_fanout` replicas are physically
local to what they enable. That is what should also pull the placement back
together.

Timing and data are unchanged: `store_we` is a one-cycle strobe (self-clearing
alongside `tob_updated`), so the write lands in exactly the cycle the old `STORE`
arm did, and `sel` is stable from WRITE_COMMIT onward. The new block has **no
reset** — the book is GSR-initialised, and adding one would recreate the
round-4/6 reset-net failure on 10 k flops.

## Fix 2 — per-level registered `sel` enables (35 paths)

`sh_en[k]` and `wc_en[k]` are computed in **SEARCH_DIST** — the stage round 14
added purely to fan registers out — from `hit_idx_central` and `tgt_type`, a full
cycle before either write. SHIFT and WRITE_COMMIT then read a flop per level
instead of rebuilding `k` vs `hit_idx` inside the enable cone.

The payoff is exact: a `sel` clock enable is now
`{state[3:0], sh_en[k], wc_en[k]}` — **six inputs, one LUT6, one logic level**,
down from three.

The data muxes are untouched (SHIFT still reads a fixed neighbour). Two
equivalences worth recording:

- **`sh_en` reproduces all three SHIFT arms**: `!needs_shift` → all zero;
  removal → `k >= hit_idx` plus the always-vacated tail level `N-1`; insert →
  `k >= 1 && k > hit_idx`.
- **`wc_en` is set only for ADD and MODIFY.** This matters: `msg_type_e` has a
  **fourth** value, `MSG_RSVD`, which the old `unique case (tgt_type)` dropped
  through its `default: ;`. Testing `tgt_type != MSG_DELETE` would have silently
  started writing on MSG_RSVD. The quantity mux folds the two live arms exactly:
  `(ADD && hit_exact) ? agg_qty[k] : tgt_qty`.

## Fix 3 — priority cascade out of the next-state cone (2 paths)

`SEARCH_ENC` branched on the **combinational** `srch_valid`, putting the 16-level
priority cascade over `cmp_exact`/`cmp_insert` directly into the FSM's next-state
logic (4 logic levels — the deepest cone left outside the enable clusters).
`srch_valid` is already being registered into `hit_valid_central` on that same
edge, so the transition is now unconditional and the drop decision moves to
SEARCH_DIST where it reads a flop.

**Cost:** a *rejected* update (price outside the depth window on a full book)
takes one extra cycle to return to IDLE and holds `book_busy` one cycle longer.
Accepted transactions are unchanged at 7 cycles; the benches bound `book_busy` by
`NUM_LEVELS + 5 = 21` against an observed maximum of 8.

## Deliberately not touched (9 paths)

| Paths | Why left alone |
|---|---|
| 5 × `state_rep → state_rep/D` | A **replication artifact.** `state` currently carries ~11 k loads (mostly book CEs) so `max_fanout = 64` builds ~17 replicas, and each replica's next-state cone reads another replica. Fix 1 removes the book CEs from `state` entirely, so the load count — and with it the replica count — should collapse on its own. Changing `max_fanout` in the same pass would confound the measurement. |
| 3 × `book_reg`/`tgt_asset → sel_reg/D` | The LOAD mux, the one remaining die-spanning **read**. At −0.061 … −0.010 with the enable clusters gone, this is placement reach, not depth. |
| 1 × `upd[symbol_id] → state_reg/D` | Round 18's relocated compare, at −0.021. An 8-bit compare cannot fold below two LUT levels; removing it entirely needs a pipeline stage in the accept path, which is not worth it for 21 ps. |

## Verification

**Not run** — at the engineer's request, all simulation and implementation is
being handled outside this document. The full 12-bench regression
(`./sim/run_all_tb.sh --sim xsim`, 173 410 checks) must pass before these results
are trusted. Highest-value coverage for this round:

- `order_book` **T6** (add at an existing top price → aggregate) exercises
  `wc_en` + `agg_qty` directly.
- `order_book` **T10** (fill 16 levels then insert a new top) exercises `sh_en`
  across a full-book shift, including the tail-vacate case.
- `order_book_crv` (173 019 checks) compares final book state against a
  latency-insensitive reference model — it covers the Fix 3 reject-path timing
  change, which no directed test targets.
- The `book_busy` upper-bound check bounds Fix 3's extra reject cycle.

## Expected in run 20

- The two enable clusters (229 of 240 paths) should clear outright: zero logic
  levels on the book CEs, one LUT6 on the `sel` CEs.
- The 5 `state` replica paths should follow indirectly as `state`'s fanout
  collapses.
- **If WNS is still negative**, the remaining candidates are the LOAD mux and
  placement. At that point the lever is no longer RTL — it is a Pblock around
  `u_order_book`, which round 12 already identified and which the placement
  spread argues for independently.
