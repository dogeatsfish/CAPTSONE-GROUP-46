# CommonTrader

FPGA-based high-frequency trading teaching platform.
ECE 498A/B Capstone — Group 2026.46
Target: AMD Artix-7 XC7A200T (Alinx AX7A200B)

## Repository Structure

| Path | Contents |
|---|---|
| `rtl/` | SystemVerilog sources, one directory per subsystem |
| `rtl/common/` | Shared interface definitions and parameters |
| `tb/` | Testbenches (mirrors `rtl/`) |
| `sim/` | Verilator scripts and simulation harness |
| `vivado/` | Tcl build scripts and XDC constraints |
| `sw/` | Market simulation, matching engine, FastAPI backend, React UI |
| `docs/` | Design documents and reference material |

## Important

**Do not commit Vivado project files.** The project is regenerated from the Tcl
scripts in `vivado/`. Only sources, constraints, and build scripts are tracked.

## Getting Started

```bash
git clone <repo-url>
cd commontrader
```

Lint the RTL locally before pushing:

```bash
verilator --lint-only -Wall -Irtl/common rtl/**/*.sv
```

## Subsystem Owners

| Subsystem | Owner |
|---|---|
| RX MAC Core | |
| Cut-through Stream Parser | |
| Order Book Array | |
| Alpha Engine Core | |
| Pre-Trade Risk Gateway | |
| Outbound TX Generator | |
| Market Simulation | |
| Matching Engine | |
| FastAPI Backend | |
| UI | |

## Branching

- `main` is always buildable and is protected.
- Branch off `main`: `name/short-description`
- Open a PR, get one approval, merge, delete the branch.
- Keep branches short-lived.
