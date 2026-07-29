# Synthesis → Implementation → Bitstream

Build runbook for **CommonTrader** (`commontrader_top`) on the **Alinx AX7A200B**
(`XC7A200T-2FBG484I`, Artix-7, −2, 1.0 V). Companion to
[`README.md`](README.md) (simulation) and
[`../docs/board_bringup_issues.md`](../docs/board_bringup_issues.md) (what to
watch on real hardware).

Constraints used: [`constraints/commontrader_timing.xdc`](constraints/commontrader_timing.xdc)
(clocks + CDC) and [`constraints/commontrader_pins.xdc`](constraints/commontrader_pins.xdc)
(pins + RGMII I/O).

---

## 0. Pre-flight (once, before Run Synthesis)

| # | Do | Why |
|---|----|-----|
| 1 | **Add both XDC files** to `constrs_1` (Add Sources → constraints). | Timing is meaningless / unplaceable without them. |
| 2 | **Confirm the part is `xc7a200tfbg484-2`** (Settings → General → Project device). Not `-1L`. | `-1L` is the 0.9 V part → wrong timing models (bring-up issue #4). |
| 3 | **Enable the `SYNTHESIS` define** — *the step everyone forgets.* | Without it you synthesize the behavioural MMCM/IDDR/ODDR stubs and get no real clock. |
| 4 | **Set the top to `commontrader_top`.** | Otherwise a bench or the wrong module is synthesized. |

Tcl for 3 and 4:
```tcl
set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} -value {-verilog_define SYNTHESIS} -objects [get_runs synth_1]
set_property top commontrader_top [current_fileset]
update_compile_order -fileset sources_1
```
(GUI for 3: Settings → Synthesis → add `-verilog_define SYNTHESIS` to the
synth_design **More Options** field.)

---

## 1. Synthesis

**Run Synthesis** → **Open Synthesized Design**, then:

```tcl
report_clocks              ;# must show rgmii_rx_clk (8 ns) AND a ~250 MHz MMCM clock (4 ns)
report_cdc                 ;# the big one — every crossing should be "Safe"
report_clock_interaction   ;# the 125/250 crossing should show as async groups, not unsafe
report_utilization         ;# LUT/FF/BRAM/DSP — well under 80% (NF-3)
```

- **Search the synth log for `latch`** → must be **0** (the rx_mac fix). Any
  inferred latch is a bug.
- **Only one clock in `report_clocks`** → the SYNTHESIS define isn't on, or the
  MMCM didn't infer. Re-do pre-flight #3.
- **`report_cdc` shows Unsafe / Unknown / Critical** → a crossing isn't
  constrained. With `ASYNC_REG` + the async clock groups it should be Safe; if
  not, confirm the timing XDC loaded and that its second clock-group reference
  resolved (there's a note at that line in the file).

---

## 2. Implementation

**Run Implementation** → **Open Implemented Design**, then the one gate that
matters (**NF-4**):

```tcl
report_timing_summary
```

Pass criteria:
- **WNS ≥ 0** (setup) and **WHS ≥ 0** (hold)
- **TNS = 0, THS = 0** (no violating paths), **0 failing endpoints**

**If WNS < 0 at 250 MHz** — expected difficulty on a −2 Artix. Likely critical
path: the order-book level shift or the risk-gateway DSP multiply. Fixes, in
order: pipeline the offending path → try an impl strategy
(`Performance_ExplorePostRoutePhysOpt`) → last resort, lower the core clock.
**Iterate implementation, not synthesis.**

Re-run `report_utilization` here for the accurate post-route numbers.

---

## 3. Bitstream

One thing to handle first: the **telemetry outputs**
(`order_drop_count[15:0]`, `tx_fifo_overflow`, `ts_wrapped`) have no pins — the
pins file recommends an **ILA**. Choose one:

- **Recommended:** add an **ILA** probing those plus key RGMII/AXIS signals.
  Resolves the unconstrained-output DRC *and* gives on-chip visibility for
  bring-up.
- **Quick smoke build:** downgrade the unconstrained-I/O DRC so the bitstream
  generates:
  ```tcl
  set_property SEVERITY {Warning} [get_drc_checks UCIO-1]
  ```

Then **Generate Bitstream** → produces the `.bit`.

---

## 4. Program and bring up

**Hardware Manager** → connect (JTAG) → **Program Device**. Then check, in order:

1. PHY link comes up at **gigabit** (bring-up issue #3 — 100M breaks the MMCM).
2. RX clock is present (MMCM locked).
3. Watch the pipeline on the ILA.

---

## Reading the results — cheat sheet

| Report | Good | Bad → meaning |
|---|---|---|
| synth log `latch` | 0 | >0 → inferred-latch bug |
| `report_clocks` | 125 MHz + ~250 MHz | one clock → SYNTHESIS off / MMCM missing |
| `report_cdc` | all **Safe** | Unsafe/Unknown → CDC unconstrained |
| `report_utilization` | < 80 % each | >80 % → NF-3 fail, no room for user logic |
| `report_timing_summary` | **WNS ≥ 0, WHS ≥ 0, 0 failing** | WNS < 0 → 250 MHz not met, pipeline the critical path |

---

## Known caveats for this build

- **RGMII I/O timing is commented out** in `commontrader_pins.xdc` (needs the
  JL2121 datasheet numbers). The design builds and times the *internal* logic
  fine, but the RGMII interface itself is unverified — fill in the
  `set_input_delay` / `set_output_delay` before trusting real network traffic.
- **If the MMCM fails to place** complaining about its clock input, V18 isn't
  clock-capable (bring-up issue #6) — you'd need a BUFR/BUFG hop or different
  RXC routing.
- The sim suite is fully green, so anything that surfaces here is
  **timing / placement / board-integration**, which
  [`../docs/board_bringup_issues.md`](../docs/board_bringup_issues.md) already
  maps out.
