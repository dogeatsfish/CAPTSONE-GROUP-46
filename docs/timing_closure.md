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
