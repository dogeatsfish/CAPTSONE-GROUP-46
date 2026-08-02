# Software Documentation

Documentation for the software side of the project (the trading engine,
data pipeline, and host-side tooling under `sw/`).

## Contents

- _(add software design notes, protocol references, and build/run guides here)_

## Development environment (Dev Container)

A ready-to-use Linux C++ toolchain is provided as a VS Code Dev Container so the
POSIX-only engine (`<sys/socket.h>`, etc.) compiles and debugs natively on
Windows/macOS via Docker. It lives at [`sw/.devcontainer/`](../.devcontainer)
and **must stay there** — VS Code only auto-detects `.devcontainer/` at the root
of the folder you open, and this one is configured to open the whole `sw/`
workspace. To use it: open the `sw/` folder in VS Code and choose
**"Reopen in Container"**.

- `Dockerfile` — Ubuntu 24.04 base with pinned GCC 13, CMake, Ninja, GDB,
  Valgrind, and Python/pybind11.
- `devcontainer.json` — extensions, IntelliSense/CMake paths, and the
  `SYS_PTRACE` capability needed for GDB/Valgrind.

## Guides

- [Building and running the engine](build-and-test.md) — every Makefile target,
  overridable variables, how to run each test, and the macOS vs Linux
  difference for the Python module.
- [Engine tests](testing.md) — what each test covers (`stress_orderbook`,
  `test_online`, `socket_test`, `gen_market_ladder.py`) and its specific cases.

## Related documents

- [Host ↔ FPGA link setup and connection test](../../docs/connection-test.md) —
  how to wire the host to the board, configure the NIC, and verify the link.
  Uses the helper scripts in [`setup/`](../../setup).

## Quick reference

- **Build the engine:** `make -C sw/engine` (native CLI + `online_run`)
- **Run the real-time engine:** `make -C sw/engine run-online`
- **Wire protocols:** see `sw/engine/simulation/include/protocol.h` (ITCH in,
  OUCH out; byte layouts mirror the FPGA RTL).
- **Online networking config:** `OnlineSimulation::Config` in
  `sw/engine/simulation/include/online_simulation.h` (ports, addresses, and the
  UDP/TCP OUCH transport toggle).
