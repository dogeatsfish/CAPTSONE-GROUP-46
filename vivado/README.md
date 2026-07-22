# Running Simulations in Vivado

CommonTrader's testbenches run on Vivado's **`xsim`** simulator, verified on
**Vivado 2025.2**. There are two ways to drive it — pick by what you need:

| You want… | Use | Speed |
|---|---|---|
| Pass/fail regression | command-line scripts (`sim/*.sh`) | fast, scriptable |
| Interactive waveforms in the IDE | Vivado project + the Tcl helpers here | slower, GUI |

Both use the *same* `xvlog → xelab → xsim` on the *same* sources; the GUI just
adds the Project Manager and a waveform viewer on top.

## Prerequisites

- AMD/Xilinx **Vivado 2025.2** with `xvlog` / `xelab` / `xsim` on `PATH`
  (run from the Vivado shell, or `source settings64.sh` first). -> `C:\AMDDesignTools\2025.2\Vivado\settings64.sh` is where mine was located
- Only for the `replay` bench — generate its stimulus once:
  `python sim/csv_to_itch.py --events 400 --out sim/replay`

---

## Option A — command line (recommended for regression)

No project needed. From the repo root:

```bash
./sim/run_xsim.sh order_book                 # one bench
./sim/run_xsim.sh order_book_crv +SEED=42    # one bench, with a plusarg
./sim/run_xsim.sh order_book --gui           # build, then open the xsim waveform GUI
./sim/run_all_tb.sh --sim xsim               # all 12 benches, pass/fail table
./sim/regression_crv.sh                      # both CRV benches across seeds 1..20
```

All 12 benches pass this way (**173,400 checks, 0 failures** in the default-seed
run). See `sim/README.md` for the bench list and the full plusarg table.

---

## Option B — Vivado GUI project flow

Vivado's Project Manager runs **one testbench per "simulation set."** That is why
the default `sim_1` only ever elaborates a single file. Two Tcl helpers make the
whole bench suite usable from the GUI.

> In the **Tcl Console**, `source` needs the *full* path, and the `{ }` braces
> matter — they keep the space in `…/UW Programming/…` from breaking the path.

### 1. One-time — create a simulation set per bench

With the CAPSTONE project open:

```tcl
source {<project-root>/vivado/create_sim_sets.tcl}
```

Creates `sim_cdc_fifo`, `sim_order_book`, `sim_replay`, … one per bench (read from
`sim/benches.sh`), each with the correct top module. Switch between them with the
dropdown at the top of the **Sources** panel. Non-destructive and re-runnable.

### 2. Each session — run a bench with the helper

```tcl
source {<project-root>/vivado/run_bench.tcl}

run_bench sim_order_book                            ;# run to $finish
run_bench sim_order_book_crv {SEED=42 NTXN=50000}   ;# with plusargs
run_bench sim_replay                                ;# data files handled for you
run_bench sim_order_book_crv {SEED=7} 20us          ;# bounded 20 us run
run_all_bench                                       ;# every bench + pass/fail table
```

`run_bench <simset> {plusargs} {runtime}` configures the set and launches it.
`run_all_bench` is the project-flow equivalent of `run_all_tb.sh`.

### Why the helpers exist — Vivado 2025.2 quirks they hide

- **The default run stops at 1000 ns.** The helper sets
  `xsim.simulate.runtime = -all` so the bench runs to `$finish`. (This persists on
  the set, so the GUI **Run Behavioral Simulation** button honours it afterward.)
- **Plusargs** go in as `-testplusarg NAME=value` — the helper builds them.
- **`replay`'s data files.** The project runs xsim from a deep build dir, so the
  bench's relative `sim/replay_*.hex` paths won't resolve. `run_bench` auto-supplies
  the correct paths back to `sim/`.

Doing it by hand instead of the helper:

```tcl
set fs [get_filesets sim_order_book_crv]
set_property -name {xsim.simulate.runtime}           -value {-all}                 -objects $fs
set_property -name {xsim.simulate.xsim.more_options} -value {-testplusarg SEED=42} -objects $fs
launch_simulation -simset $fs
```

---

## Files in this folder

| File | Purpose |
|---|---|
| `create_sim_sets.tcl` | one-time: build one simulation set per bench |
| `run_bench.tcl` | `run_bench` / `run_all_bench` — run a bench (or all) to `$finish`, with plusargs |
| `CAPSTONE.xpr` | the Vivado project |
| `constraints/` | timing / pin constraints |

Full bench list, plusarg reference, and SystemVerilog portability rules:
**`sim/README.md`**.
