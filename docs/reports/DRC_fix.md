# DRC Cleanup — run 4 report (`vivado/report_DRC.txt`)

Companion to [timing_closure.md](timing_closure.md). The timing doc's Round 4
covers the two order-book *timing* paths; this file covers the *DRC* warnings
cleared alongside them so a bitstream can be built. All 90 violations fell into
four groups, three of which share one root cause: **an asynchronous reset on a
register that a hard block (BRAM / DSP48) cannot accept.**

| DRC | Count | Block | Root cause | Fix |
|---|---|---|---|---|
| REQP-1839 / REQP-1840 | 40 | `u_parser` ref_table BRAM | async-reset regs drive BRAM address pins | sync reset |
| DPOR-1 / DPOP-1,2 / DPIP-1 | 45 | `u_risk` DSP48 | async-reset regs can't merge into DSP | sync reset |
| CFGBVS-1 | 1 | device | config bank voltage unset | XDC property |
| NSTD-1 / UCIO-1 | 2 | `order_drop_count` port | 16-bit debug bus, no pins | IOSTANDARD + UCIO waiver |

The order book's own async-reset **recovery** failure (13 k-load clear net) is
the same class and was fixed in the same sweep — see Round 4 in the timing doc.

---

## 1. Parser — REQP-1839 / REQP-1840 (40 criticals)

**Symptom.** `u_parser/ref_table_reg[0][price]` (RAMB36) and `[0][side]`
(RAMB18) have address pins (`ADDRARDADDR`, `ADDRBWRADDR`) driven by
`ref_waddr` / `ref_raddr` / `p_ref` registers that carry an asynchronous reset.
Vivado warns this can **corrupt RAM contents** on reset assertion (a BRAM
address must not glitch async) and it is not covered by default STA.

**Fix.** [cut_through_parser.sv](../rtl/parser/cut_through_parser.sv) — both
`always_ff` blocks (the ingest FSM and the resolve/emit pipeline) changed from
`@(posedge core_clk or negedge core_rst_n)` to `@(posedge core_clk)`; the
`if (!core_rst_n)` reset bodies are unchanged, so the reset is now synchronous.
The `ref_table` inference block already had no reset (it is the BRAM itself).

---

## 2. Risk gateway — DPOR-1 / DPOP-1,2 / DPIP-1 (45 warnings)

**Symptom.** The `u_risk` max-value multiply
(`product_s2 <= price_s1 * quantity_s1; product_s3 <= product_s2;`) uses DSP48s,
but the pipeline registers have an async reset. DSP48 registers are
**synchronous-reset only**, so Vivado could not pull `price_s1`/`quantity_s1`
(AREG/BREG), `product_s2` (MREG) or `product_s3` (PREG) into the DSP — leaving
`MREG=0, PREG=0` and un-pipelined inputs (the DPOP/DPIP warnings) and blocking
DSP register merge entirely (log: *"No candidate cells for DSP register
optimization found"*).

**Fix.** [pre_trade_risk_gateway.sv](../rtl/risk_gateway/pre_trade_risk_gateway.sv)
— every `always_ff` converted from `@(posedge clk_250mhz or negedge rst_n)` to
`@(posedge clk_250mhz)` (synchronous reset). The whole module was converted, not
just `Max_Value`, for one consistent reset style and to clear the DPIR
async-driver methodology warnings too. With sync reset the tool can absorb the
entire multiply into the DSP48 — fixes the DRC and improves DSP timing/power.

---

## 3. Device config — CFGBVS-1 (1, blocks bitstream)

`CFGBVS` / `CONFIG_VOLTAGE` were unset. Added to
[commontrader_pins.xdc](../vivado/constraints/commontrader_pins.xdc):

```tcl
set_property CFGBVS VCCO        [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
```

Bank 0 on the AX7A200B is 3.3 V. **Verify against the board manual power table.**

---

## 4. `order_drop_count` — NSTD-1 / UCIO-1 (2, block bitstream)

`order_drop_count[15:0]` is a 16-bit telemetry bus that is deliberately **not a
board pin** (only 2 LEDs are free; it is meant for an ILA / status register — see
the port comment in `commontrader_top` and the note in the pins XDC). It is a
top-level port because three top-level testbenches observe it, so it cannot
simply be deleted.

- **NSTD-1** (default IOSTANDARD): resolved by assigning an IOSTANDARD (no LOC)
  in the pins XDC: `set_property IOSTANDARD LVCMOS33 [get_ports {order_drop_count[*]}]`.
- **UCIO-1** (no LOC): waived in
  [bitstream_drc_waivers.xdc](../vivado/constraints/bitstream_drc_waivers.xdc)
  (`set_property SEVERITY {Warning} [get_drc_checks UCIO-1]`) so the tool
  auto-places these debug outputs and `write_bitstream` completes.

**This waiver is interim.** The permanent fix is to observe `order_drop_count`
through an ILA/debug hub (`mark_debug`) rather than a physical port, or to assign
real expansion-header LOCs from the AX7A200B manual. Add
`bitstream_drc_waivers.xdc` to `constrs_1` (or as a `write_bitstream` tcl.pre
hook) — keep it separate so the waiver stays visible.

---

## Verification / sequencing

1. **Regression** (`./sim/run_all_tb.sh --sim xsim`). The reset conversions are
   behaviourally moot for any bench that holds reset across ≥1 clock edge (all of
   them) — reset now takes effect on the edge instead of asynchronously. No
   functional logic changed in the parser or risk gateway. (The order-book +1
   cycle latency note is in the timing doc, not here.)
2. **Re-synthesize / implement.** Confirm in the new reports:
   - REQP-1839/1840 gone from `report_drc`.
   - The risk multiply now shows DSP with MREG/PREG absorbed (`report_utilization`
     DSP count unchanged, but check the DSP is fully registered / DPOP-DPIP gone).
   - `report_methodology` DPIR async-driver count drops sharply.
3. **Bitstream** (when ready): with the config property + waiver in `constrs_1`,
   CFGBVS-1 / NSTD-1 / UCIO-1 no longer block `write_bitstream`.
