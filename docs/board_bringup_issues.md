# Board Bring-Up Issues — CommonTrader on the Alinx AX7A200B

Cross-check of the **RTL** against the **AX7A200B User Manual (REV 1.0)** and the
**Detailed Design Report (Group 46)**. This lists everything that must be fixed
or watched before the design runs on real hardware, which items were fixed
directly in the RTL/TB, and which need action *outside* this repo (Vivado
project settings, the design report, board verification, operational).

Target board: **Alinx AX7A200B**, FPGA **`XC7A200T-2FBG484I`** (Artix-7, speed
grade **-2**, industrial, **1.0 V** core). Ethernet: **JL2121-N040I** GPHY over
RGMII, strapped for **RGMII-ID** (2 ns internal delay both directions).

---

## Summary

| # | Finding | Severity | Status |
|---|---------|----------|--------|
| 1 | **PHY reset (ETH_RESET / R14) had no RTL port** — PHY never leaves reset, no RX clock, board looks dead | 🔴 blocker | ✅ **Fixed in RTL** |
| 2 | **`hw_kill_switch` polarity** — board key idles HIGH; the active-high RTL signal made the kill *permanently asserted* | 🟠 | ✅ **Fixed in RTL/TB** |
| 3 | **1000M-only clocking** — the sole clock is the PHY's 125 MHz RX clock; a 100M/10M link breaks the MMCM | 🔴 must-know | ⚠️ **External (operational)** |
| 4 | **Wrong Vivado part** — report/compiler use `xc7a200tifbg484-1L` (speed -1, **0.9 V**); silicon is `-2` / **1.0 V** | 🟠 | ⚠️ **External (project setting)** |
| 5 | **PHY part name** — report says *Realtek RTL8211*; board is *JL2121-N040I* | 🟠 | ⚠️ **External (report + verify)** |
| 6 | **Verify V18 (ETH_RXCK) is clock-capable** — it feeds the MMCM | 🟠 | ⚠️ **External (verification)** |
| 7 | **LED polarity split** — carrier LEDs active-LOW, core-board LED active-HIGH | 🟡 | ⚠️ **External (wiring)** |
| 8 | **CRC residue in report** — report says `0xC704DD7B` (non-reflected); as-built is `0xDEBB20E3` | 🟡 | ⚠️ **External (report)** |
| 9 | **Block classifications** — report marks TX MAC + both CDC FIFOs as (ND) vendor; they are custom (D) | 🟡 | ⚠️ **External (report)** |
| 10 | **RGMII-ID strapping** — 2 ns delay both ways → no FPGA IDELAY/ODELAY needed | 🟢 good | ℹ️ informational |
| 11 | **GTP 6.6 Gb/s, DDR3, SFP, HDMI, PCIe** — all unused by CommonTrader | 🟢 n/a | ℹ️ informational |

---

## Fixed in RTL / TB

### 1. Ethernet PHY reset (blocker)

**Problem.** `commontrader_top` had no port to drive the JL2121's `ETH_RESET`
(R14, active-low). The PHY holds its RGMII RX clock in reset until released — and
that RX clock is the **only** clock in the design (the MMCM in `clk_rst_gen`
derives the 250 MHz `core_clk` from it). With no port, the PHY never leaves reset
and nothing on the FPGA has a clock.

**Fix.** Added an active-low output `eth_phy_rst_n` to `commontrader_top`, driven
from the async board reset:

```systemverilog
output logic eth_phy_rst_n,          // to JL2121 ETH_RESET (R14)
...
assign eth_phy_rst_n = sys_rst_n;    // released when the board reset deasserts
```

**Why driven from `sys_rst_n` and not a proper timed pulse.** There is a
chicken-and-egg: the PHY must be out of reset to produce the RX clock, but that
RX clock is what every on-chip clock is derived from — so *no on-chip clock
exists* to sequence a timed reset. Driving it straight from the async board reset
releases the PHY as soon as the board reset deasserts and relies on the PHY's own
power-on reset at power-up. A robust timed power-on reset would need an
independent free-running oscillator (the board's 200 MHz crystal on R4/T4, via
`IBUFGDS` + a counter) — deferred; this is sufficient for bring-up.

**Files.** `rtl/top/commontrader_top.sv` (new port + assign),
`vivado/constraints/commontrader_pins.xdc` (R14 constraint).

### 2. `hw_kill_switch` polarity

**Problem.** The AX7A200B user keys idle **HIGH** (pull-up) and go **LOW** when
pressed. The RTL treated `hw_kill_switch` as **active-high** (high = kill), so an
un-pressed key (idle high) would assert the kill **permanently** — the outbound
path would be dead on the real board.

**Fix.** Renamed the top-level port to **`hw_kill_switch_n`** (active-low,
matching the board key *and* the codebase's existing `_n` convention:
`sys_rst_n`, `core_rst_n`, `phy_rst_n`) and inverted it once into the internal
active-high convention the Risk Gateway expects:

```systemverilog
input logic hw_kill_switch_n,             // active-low pin (board key idles high)
...
kill_meta <= ~hw_kill_switch_n;           // -> active-high kill, unchanged downstream
```

The `pre_trade_risk_gateway` keeps its internal active-high `hw_kill_switch`
input — only the board-facing top port and its inversion changed.

**Files.** `rtl/top/commontrader_top.sv`, `vivado/constraints/commontrader_pins.xdc`
(L19), `vivado/constraints/commontrader_timing.xdc` (`set_false_path`), and the
three top-level benches `tb/top/commontrader_top_tb.sv`,
`commontrader_crv_tb.sv`, `commontrader_replay_tb.sv` (renamed the signal and
flipped the drive: idle = `1'b1` = no kill; the `top_tb` T10 test now drives
`1'b0` to assert the kill).

**Verified.** `integration` (58 checks, incl. T10 `kill switch suppressed the
order`), `replay` (55), `integration_crv` (9) — all pass.

---

## Requires external action (not RTL)

### 3. 1000M-only clocking (🔴 must-know)

The design is **entirely PHY-clocked** and hardwired to a 125 MHz RGMII clock.
The MMCM is fixed for a 125 MHz input; if the auto-negotiating JL2121 links at
**100M** the RX clock drops to 25 MHz, the MMCM VCO would be 25 × 8 = 200 MHz —
below the 600 MHz minimum — and it **never locks → dead design**. **Action:**
ensure a **gigabit** link partner during bring-up. (A speed-independent design
would need a fixed board-crystal clock and multi-rate handling — out of scope.)

### 4. Wrong Vivado target part (🟠)

The report's Compiler section targets **`xc7a200tifbg484-1L`** — speed grade
**-1** and low-voltage **0.9 V**. The actual silicon is **`XC7A200T-2FBG484I`** —
speed **-2**, **1.0 V** VCCINT (manual power table). The `L`/0.9 V mismatch means
Vivado applies the wrong voltage timing models. **Action:** set the Vivado part
to **`xc7a200tfbg484-2`**. The DFX pblock/utilization figures were computed on
-1L and will shift.

### 5. PHY part name (🟠)

The report's block diagram says the PHY is **Realtek RTL8211**; the AX7A200B
manual (§3.2) says it is a **JL2121-N040I**. Both are RGMII gigabit PHYs, but
MDIO register maps, reset timing, and strapping differ. All constraints in this
repo already use the *actual* JL2121 behavior. **Action:** correct the report,
and re-verify any RTL8211-specific assumption against the JL2121 (only relevant
if MDIO management is ever added).

### 6. Verify V18 is clock-capable (🟠)

`rgmii_rx_clk` (V18) feeds the MMCM, so V18 must be a clock-capable (MRCC/SRCC)
pin. The manual doesn't give the full pin name; Alinx route RGMII RXC to a CC
pin, so it should be fine. **Action:** confirm in the pin report if the MMCM
refuses to place.

### 7. LED polarity split (🟡)

Carrier-board LEDs (L13/M13, where the pins file suggests routing
`tx_fifo_overflow` / `ts_wrapped`) are **active-LOW** (0 = lit); the core-board
LED (W5) is **active-HIGH**. The status outputs are active-high, so on a carrier
LED they light on the *good* state. **Action:** invert at the LED assignment if
you want "lit == asserted", or (recommended) route telemetry to an ILA instead.

### 8. CRC residue in report (🟡)

The report (§3.1.1) states the valid-frame CRC residue is `0xC704DD7B` — the
*non-reflected* value. The MAC is built with the reflected IEEE-802.3 CRC, whose
residue is `0xDEBB20E3` (already documented in `tx_mac_core.sv`; tests pass).
**Action:** correct the residue value in the report.

### 9. Block classifications in report (🟡)

The report marks **TX MAC Core** and **both CDC FIFOs** as **(ND)** (vendor IP),
but all three are **custom** (which is what lets the design satisfy NF-2
free-tier). **Action:** reclassify them as (D) in the report.

---

## Informational (no action)

- **10. RGMII-ID strapping (good).** JL2121 adds 2 ns delay on both TX and RX
  (manual Table 3-2-1), so the FPGA needs no IDELAY/ODELAY — RX captured with an
  IDDR directly, TX clock forwarded edge-aligned with an ODDR.
- **11. Unused peripherals.** GTP transceivers (6.6 Gb/s), DDR3, SFP, HDMI, PCIe
  are all unused by CommonTrader — no pin/resource conflicts.

---

## What still lines up (spec ↔ RTL ↔ board)

250 MHz core from the MMCM (125→250); trade struct (144-bit), parser output
(91-bit), Order Reference Table (1024 × 74-bit), 5 assets × 16 levels, timestamp
(16-bit @ 250 MHz = 4 ns ≤ FS-5's 5 ns), 672 ns / 168-cycle packet budget,
cut-through latencies (176 ns RX, 160 ns parser, 308 ns TX), the intentional
1000 orders/s rate limit, and the NF-3 resource margins — all consistent.
