# Pin Constraint Verification — `commontrader_pins.xdc`

Audit of `vivado/constraints/commontrader_pins.xdc` against the **Alinx
AX7A035B/AX7A200B User Manual** and against the actual device database for
`xc7a200tfbg484-2`. Scope: are the Ethernet pin LOCs right, and is the I/O
standard right? Performed after the telemetry ports were removed from
`commontrader_top`.

**Verdict: the pins and the I/O standard were already correct.** No LOC changed.
Two real problems were found and fixed alongside (stale constraints, TX slew).

---

## Sources of truth

| What | Source |
|---|---|
| Board net → FPGA pin | AX7A035B/AX7A200B User Manual §3.2 (Ethernet, p.37–38), §3.13 (keys, p.55), §3.14 (LEDs, p.56), §2.3 (clock, p.14) |
| Bank VCCO voltages | Same manual, §2.10 Power Supply (p.32–33) |
| Bank membership, clock capability, pin function | Vivado 2025.2 `get_package_pins` on `xc7a200tfbg484-2` |
| What the tool actually applied | `vivado/CAPSTONE.runs/impl_1/commontrader_top_io_placed.rpt` |

The manual covers both the AX7A035B and the AX7A200B — the two share the same
carrier board and the same 484-ball core-board footprint, so the carrier pin
mapping is identical. The manual's Ethernet section is written against the
KSZ9031RNX variant; our board is the JL2121, but the **pin mapping is the carrier
board's and is the same**. Only PHY-internal behaviour (strapping, MDIO register
map) differs — see `board_bringup_issues.md` §5.

---

## 1. Ethernet pins — all 12 match, no change

| Manual net | FPGA pin | XDC port | Bank |
|---|---|---|---|
| ETH_TXCK | P15 | `rgmii_tx_clk` | 14 |
| ETH_TXD0 | N14 | `rgmii_txd[0]` | 14 |
| ETH_TXD1 | P16 | `rgmii_txd[1]` | 14 |
| ETH_TXD2 | R17 | `rgmii_txd[2]` | 14 |
| ETH_TXD3 | R16 | `rgmii_txd[3]` | 14 |
| ETH_TXCTL | N17 | `rgmii_tx_ctl` | 14 |
| ETH_RXCK | V18 | `rgmii_rx_clk` | 14 |
| ETH_RXD0 | P19 | `rgmii_rxd[0]` | 14 |
| ETH_RXD1 | U18 | `rgmii_rxd[1]` | 14 |
| ETH_RXD2 | U17 | `rgmii_rxd[2]` | 14 |
| ETH_RXD3 | P17 | `rgmii_rxd[3]` | 14 |
| ETH_RXCTL | R19 | `rgmii_rx_ctl` | 14 |
| ETH_RESET | R14 | `eth_phy_rst_n` | 14 |
| ETH_MDC | N13 | *(not wired)* | 14 |
| ETH_MDIO | P14 | *(not wired)* | 14 |

Non-Ethernet pins in the file, also confirmed:

| Manual net | FPGA pin | XDC port | Bank | Polarity |
|---|---|---|---|---|
| RESET key | F15 | `sys_rst_n` | 16 | active-low, idles high |
| KEY1 | L19 | `hw_kill_switch_n` | 15 | active-low, idles high |
| LED1..LED4 | L13 M13 K14 K13 | *(not wired)* | 15 | active-low (0 = lit) |

Manual §3.13, verbatim: *"When the key is pressed, the IO input voltage of the
FPGA is low. When no key is pressed, the IO input voltage of the FPGA is high."*
This is what `hw_kill_switch_n`'s active-low convention and the RTL inversion are
built on — confirmed correct.

---

## 2. `LVCMOS33` is the correct I/O standard

Manual §2.10 power distribution table:

| Rail | Supplies |
|---|---|
| +1.0 V | FPGA core voltage |
| +1.8 V | FPGA auxiliary (TPS74801) |
| **+3.3 V** | **VCCIO of BANK0, BANK13, BANK14**, QSPI flash, clock crystal |
| **VCCIO (+3.3 V, SPX3819M5-3-3 LDO)** | **FPGA BANK15, BANK16** |
| +1.5 V | DDR3, **BANK34 and BANK35** |
| VREF/VTT (+0.75 V) | DDR3 termination |
| MGTAVCC 1.0 V / MGTAVTT 1.2 V | GTP transceiver BANK216 |

Every pin constrained in the file lands in **bank 14, 15 or 16 — all 3.3 V**, so
`LVCMOS33` is right on all of them. Confirmed against the tool's own view in
`commontrader_top_io_placed.rpt` (every port `LVCMOS33`, banks 14/15/16).

The one rule to remember: **banks 34/35 are 1.5 V.** Anything ever constrained
there needs an SSTL15-family standard, never `LVCMOS33`.

`CFGBVS VCCO` / `CONFIG_VOLTAGE 3.3` are also correct — bank 0 is on the +3.3 V
rail per the same table.

---

## 3. V18 is clock-capable — open question now closed

`rgmii_rx_clk` is the only clock in the design (the MMCM derives `core_clk` from
it), so V18 had to reach a BUFG. Queried from the device database:

```
V18  bank=14  IS_CLK_CAPABLE=1  site=IOB_X0Y122  func=IO_L14P_T2_SRCC_14
```

It is an **SRCC** pin in bank 14 — it reaches a BUFG and can drive the MMCM.
Every RGMII data pin is in the same bank and clock region (IOB_X0Y101..X0Y140),
so a BUFIO/BUFR capture scheme also stays available if the BUFG path ever becomes
a problem. This resolves item 6 in `board_bringup_issues.md`.

Full query results for every pin in the file:

```
V18  bank=14 clk_cap=1 site=IOB_X0Y122 func=IO_L14P_T2_SRCC_14
F15  bank=16 clk_cap=0 site=IOB_X0Y249 func=IO_0_16
R14  bank=14 clk_cap=0 site=IOB_X0Y111 func=IO_L19N_T3_A09_D25_VREF_14
P19  bank=14 clk_cap=0 site=IOB_X0Y140 func=IO_L5P_T0_D06_14
U18  bank=14 clk_cap=0 site=IOB_X0Y113 func=IO_L18N_T2_A11_D27_14
U17  bank=14 clk_cap=0 site=IOB_X0Y114 func=IO_L18P_T2_A12_D28_14
P17  bank=14 clk_cap=0 site=IOB_X0Y107 func=IO_L21N_T3_DQS_A06_D22_14
R19  bank=14 clk_cap=0 site=IOB_X0Y139 func=IO_L5N_T0_D07_14
P15  bank=14 clk_cap=0 site=IOB_X0Y106 func=IO_L22P_T3_A05_D21_14
N14  bank=14 clk_cap=0 site=IOB_X0Y103 func=IO_L23N_T3_A02_D18_14
P16  bank=14 clk_cap=0 site=IOB_X0Y102 func=IO_L24P_T3_A01_D17_14
R17  bank=14 clk_cap=0 site=IOB_X0Y101 func=IO_L24N_T3_A00_D16_14
R16  bank=14 clk_cap=0 site=IOB_X0Y105 func=IO_L22N_T3_A04_D20_14
N17  bank=14 clk_cap=0 site=IOB_X0Y108 func=IO_L21P_T3_DQS_14
L19  bank=15 clk_cap=1 site=IOB_X0Y172 func=IO_L14P_T2_SRCC_15
L13  bank=15 clk_cap=0 site=IOB_X0Y159 func=IO_L20N_T3_A19_15   (LED1)
M13  bank=15 clk_cap=0 site=IOB_X0Y160 func=IO_L20P_T3_A20_15   (LED2)
K14  bank=15 clk_cap=0 site=IOB_X0Y161 func=IO_L19N_T3_A21_VREF_15 (LED3)
K13  bank=15 clk_cap=0 site=IOB_X0Y162 func=IO_L19P_T3_A22_15   (LED4)
R4   bank=34 clk_cap=1 site=IOB_X1Y124 func=IO_L13P_T2_MRCC_34  (SYS_CLK_P)
T4   bank=34 clk_cap=1 site=IOB_X1Y123 func=IO_L13N_T2_MRCC_34  (SYS_CLK_N)
```

Several pins carry secondary functions (`A00-A12/D16-D28` config, `DQS`, `VREF`).
None of these conflict: they are only special during parallel configuration or
when a VREF-requiring standard is used in the bank, and `LVCMOS33` needs no VREF.

---

## 4. Problems found and fixed

### 4.1 Stale telemetry constraints (was breaking every run)

`order_drop_count`, `tx_fifo_overflow` and `ts_wrapped` were removed from the
`commontrader_top` port list (they are internal signals observed through an ILA),
but the XDC still constrained them. Every implementation run logged:

```
WARNING:  [Vivado 12-584] No ports matched 'tx_fifo_overflow'.   [commontrader_pins.xdc:83]
CRITICAL: [Common 17-55]  'set_property' expects at least one object. [commontrader_pins.xdc:83]
WARNING:  [Vivado 12-584] No ports matched 'ts_wrapped'.         [commontrader_pins.xdc:84]
CRITICAL: [Common 17-55]  'set_property' expects at least one object. [commontrader_pins.xdc:84]
WARNING:  [Vivado 12-584] No ports matched 'order_drop_count[*]'.[commontrader_pins.xdc:92]
CRITICAL: [Common 17-55]  'set_property' expects at least one object. [commontrader_pins.xdc:92]
```

**Fixed:** the three `set_property` lines are gone. The LED pinout and the
active-low note are kept as a comment so the mapping is not lost if telemetry
returns as ports.

### 4.2 RGMII TX slew rate (the one electrical change)

`commontrader_top_io_placed.rpt` showed all six TX pins at Vivado's default for
an LVCMOS33 output: **`DRIVE 12`, `SLEW SLOW`**. A slow-slew 3.3 V edge is far
too soft for RGMII's 4 ns unit interval (125 MHz DDR, 250 Mb/s per lane) — it
consumes most of the eye the PHY has to sample.

**Fixed:** `SLEW FAST DRIVE 12` added to `rgmii_tx_clk`, `rgmii_txd[3:0]` and
`rgmii_tx_ctl`. `DRIVE 12` is unchanged in value but now stated explicitly so it
reads as a decision rather than a default.

```tcl
set_property -dict {PACKAGE_PIN P15 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports rgmii_tx_clk]
```

RX pins need nothing — inputs have no slew/drive.

---

## 5. `sys_clk`

`sys_clk` is still a top-level port but is unused by the datapath. It **survives
synthesis** (present in `synth_1/commontrader_top.dcp`, defaulted to `LVCMOS18`
with no LOC) and is **trimmed by `opt_design`** — absent from
`commontrader_top_io_placed.rpt`. So it needs no LOC today, but it stays
DRC-clean only because `opt_design` drops it.

It cannot be given a LOC as written: the board's system clock is a **200 MHz
differential pair** (SYS_CLK_P **R4** / SYS_CLK_N **T4**, MRCC in **bank 34**),
which does not map to a single-ended port — and bank 34 is the 1.5 V DDR3 bank,
so wiring it up later means an `IBUFGDS` with `DIFF_SSTL15`, never `LVCMOS33`.

**Durable fix:** delete the port from `commontrader_top`.

---

## 6. Outstanding follow-up

**`vivado/constraints/bitstream_drc_waivers.xdc` is now dead weight.** Its UCIO-1
waiver exists solely for `order_drop_count`, which is no longer a port. It was
left in place rather than silently changing bitstream DRC behaviour, but it
should be deleted — as it stands it downgrades UCIO-1 for *any* unconstrained
port, masking a check worth having. Removing it is safe: all 15 real ports have a
LOC, and `sys_clk` is trimmed before the bitstream DRC runs.

---

## How this was verified

1. `get_package_pins` on `xc7a200tfbg484-2` for every pin in the file — bank,
   `IS_CLK_CAPABLE`, site, `PIN_FUNC`.
2. Manual §3.2/§3.13/§3.14/§2.3/§2.10 read for the net→pin tables and the bank
   voltage table.
3. `impl_1/commontrader_top_io_placed.rpt` read for what the tool actually
   applied (standard, bank, drive, slew per pin).
4. After editing: the file was re-read against `synth_1/commontrader_top.dcp`
   with `read_xdc` — **parses clean, zero warnings**, all 15 ports on the
   expected pins and banks with `SLEW FAST` applied to the six TX pins.

```
eth_phy_rst_n      OUT  loc=R14  bank=14  std=LVCMOS33  slew=SLOW  drive=12
hw_kill_switch_n   IN   loc=L19  bank=15  std=LVCMOS33
rgmii_rx_clk       IN   loc=V18  bank=14  std=LVCMOS33
rgmii_rx_ctl       IN   loc=R19  bank=14  std=LVCMOS33
rgmii_rxd[0]       IN   loc=P19  bank=14  std=LVCMOS33
rgmii_rxd[1]       IN   loc=U18  bank=14  std=LVCMOS33
rgmii_rxd[2]       IN   loc=U17  bank=14  std=LVCMOS33
rgmii_rxd[3]       IN   loc=P17  bank=14  std=LVCMOS33
rgmii_tx_clk       OUT  loc=P15  bank=14  std=LVCMOS33  slew=FAST  drive=12
rgmii_tx_ctl       OUT  loc=N17  bank=14  std=LVCMOS33  slew=FAST  drive=12
rgmii_txd[0]       OUT  loc=N14  bank=14  std=LVCMOS33  slew=FAST  drive=12
rgmii_txd[1]       OUT  loc=P16  bank=14  std=LVCMOS33  slew=FAST  drive=12
rgmii_txd[2]       OUT  loc=R17  bank=14  std=LVCMOS33  slew=FAST  drive=12
rgmii_txd[3]       OUT  loc=R16  bank=14  std=LVCMOS33  slew=FAST  drive=12
sys_clk            IN   loc=     bank=    std=LVCMOS18   <- trimmed by opt_design
sys_rst_n          IN   loc=F15  bank=16  std=LVCMOS33
```

---

## Note on the implementation run

The implementation run that was in flight during this audit reached
`phys_opt_design` and then stopped — its state files cleared when the constraint
file changed. Implementation has to be relaunched, which is needed anyway to pick
up `SLEW FAST` (the in-flight run had read the old constraints).
