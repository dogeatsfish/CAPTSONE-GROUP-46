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
| `sim/` | Simulation harness — see [`sim/README.md`](sim/README.md) for the verification flow |
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

## Branching and Pull Requests

`main` is protected — you can't push to it directly. All work goes through a branch and a pull request.

**1. Start from the latest `main`:**
```bash
git checkout main
git pull
```

**2. Make your branch:**
```bash
git checkout -b yourname/what-youre-doing
```

**3. Work, and commit as you go:**
```bash
git add .
git commit -m "What you did"
```

**4. Push:**
```bash
git push -u origin yourname/what-youre-doing
```

**5. Open the PR** — click the link the push prints, or use the banner on GitHub. Wait for the green CI check and one approval, then **Merge** and **Delete branch**.

**6. Clean up:**
```bash
git checkout main
git pull
```

### Notes
- Keep branches and PRs small and short-lived.
- `rtl/common/ct_pkg.sv` and `rtl/top/commontrader_top.sv` are shared by everyone — flag any changes to them in your PR description.
- Stuck? Ask in the group chat before running anything with `--force` in it.