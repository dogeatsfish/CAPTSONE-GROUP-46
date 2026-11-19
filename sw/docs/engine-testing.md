# Engine Testing

How to build the engine and run its tests. Everything here is software-only —
no FPGA, no browser. For the full-stack and hardware path see
[system-testing.md](system-testing.md).

All commands run from `sw/engine`:

```bash
cd sw/engine
```

---

## Prerequisites

| Platform | Toolchain | Online/hardware support |
|---|---|---|
| **Linux** | `g++` | full |
| **macOS** | `g++` (an Apple Clang alias) — `xcode-select --install` | full |
| **Windows** | MSYS2/MinGW-w64, or WSL2 | WSL2: full. Native: offline only, built with `-DCT_NO_ONLINE_SIM` |

The Python module additionally needs Python 3 with `pybind11`
(`pip install pybind11`). The Makefile builds against whatever `python3`
resolves to on `PATH`.

> Native Windows is the odd one out because the `pymodule` branch of the
> Makefile still excludes `online_simulation.cpp`. `network/include/socket_compat.h`
> now wraps the Winsock/POSIX differences, so that exclusion may no longer be
> necessary — it just hasn't been tested on a Windows box. See `TODO.md`.

---

## Makefile targets

| Target | What it does |
|---|---|
| `all` (default) | builds the real-time CLI `online_run` |
| `pymodule` | builds the importable Python extension `engine_sim*.so` |
| `test` | builds + runs all four C++ unit-test binaries |
| `test-python` | builds the module, then runs `tests/test_bindings.py` |
| `run` | builds + runs `online_run` on `FILE` at pacing `SCALE` |
| `smoke-test` | generates the short book, then replays it over loopback |
| `hardware-test` | streams the MBO feed at the real board (see [system-testing.md](system-testing.md)) |
| `clean` | removes all build artifacts |

Overridable variables: `FILE`, `SCALE`, `PY` (interpreter used to generate test
books, default `../service/.venv/bin/python`), `SMOKE_CONFIG`,
`HARDWARE_CONFIG`, `CXX`, `CXXFLAGS`.

---

## The unit tests

```bash
make test          # all four, stops at the first failure
make test-python   # the Python binding tests
```

Each binary prints one `ok <name>` line per check group and a final
`PASSED (0 failed checks)`. They use the tiny assertion harness in
`tests/include/test.h` — no external framework.

| Binary | Source | Covers |
|---|---|---|
| `test_orderbook` | `tests/src/test_orderbook.cpp` | matching, resting, price/time priority, L1 and L2 depth, market orders, partial cancel (`reduce`), `replace` and its loss of priority, rejects, queue position, snapshot/restore |
| `test_account` | `tests/src/test_account.cpp` | position and average-entry math, realized vs unrealized PnL, taker fee and maker rebate, open-order tracking, fill history |
| `test_scheduler` | `tests/src/test_scheduler.cpp` | time ordering, same-time tie-break, the no-time-travel guarantee, inbox routing, `run_until`, periodic snapshots, seek-from-snapshot, determinism |
| `test_participant` | `tests/src/test_participant.cpp` | callbacks at zero latency, both latency legs, fill-notification delay, the "faster participant wins the race" property, tier presets, market orders, order management, fees, timers, queue-position queries, unregistered participants |
| `tests/test_bindings.py` | — | the Python surface: direct `OrderBook` use, stepping the scheduler, a `Participant` subclass written in Python, latency presets, snapshots, determinism, `OfflineSimulation` options |

Test binaries are gitignored (`sw/engine/test_*`) and removed by `make clean`.

### Writing a new one

1. Add `tests/src/test_<thing>.cpp`, including `test.h`.
2. Add `test_<thing>` to `TEST_TARGETS` in the Makefile and give it a rule —
   copy the nearest existing one. `SCHED_SRCS` is the source list anything
   scheduler-level needs to link.
3. `make test` picks it up, and so does CI.

---

## Replay scenarios

These are **runnable scenarios**, not pass/fail tests: you watch the banner,
the replay, and the final trade/PnL summary. They drive `online_run` (built
from `tests/src/test.cpp`) against an `.ini` under `tests/config/`.

```bash
./online_run <config.ini>                   # config mode
./online_run <mbo_file> <time_scale> [itch_port] [ouch_port] [itch_addr]
```

| Config | Target | Address | Data | Pacing |
|---|---|---|---|---|
| `smoke_test.ini` | `make smoke-test` | loopback | `smoke_book.bin` (10 orders) | `1.0` |
| `socket_test.ini` | `make run FILE=tests/config/socket_test.ini` | loopback | `synthetic_mbo_stream.bin` | `0.001` |
| `flood_test.ini` | `make run FILE=tests/config/flood_test.ini` | loopback | `flood_book.bin` (5000 orders) | `0` (burst) |
| `hardware_test.ini` | `make hardware-test` | `192.168.0.1` | `synthetic_mbo_stream.bin` | `1.0` |

Keys read from the `.ini`: `[network] itch_address / itch_port / ouch_port`,
`[data] market_book`, `[timing] time_scale`. Anything absent falls back to the
`OnlineConfig` default in `simulation/include/online_config.h`.

> **Loopback scenarios produce no trades.** `online_run` doesn't enable the
> local strategy, so it replays market data and stands up the sockets but
> nothing sends orders in. Trades come from a real board, or from the FastAPI
> service's loopback path (which *does* set `enable_local_strategy`).

### Generated books

`synthetic_mbo_stream.bin` is committed. The others are generated into
`data_pipeline/data/`:

```bash
python3 data_pipeline/src/gen_market_ladder.py   # -> market_ladder.bin
python3 data_pipeline/src/gen_test_datasets.py   # -> smoke_book.bin, flood_book.bin
```

`make smoke-test` runs the second one for you. Record format is
`struct "<QcQcdd"` — timestamp, message type, order id, side, price, size — 34
bytes, asserted at compile time in `offline_simulation.h`.

---

## Checking a change didn't move the numbers

The offline simulation is deterministic, so the quickest regression check is to
compare its output before and after:

```bash
make pymodule
python3 -c "
import engine_sim
r = engine_sim.OfflineSimulation('../data_pipeline/data/synthetic_mbo_stream.bin').run()
print(r.total_trades, len(r.pnl_curve))
"
```

Current baseline on `synthetic_mbo_stream.bin`: **1164 trades, 19193 PnL
samples**. With the Retail latency preset: **1239 trades**, realized ≈ 8373.91.

If those move and you didn't expect them to, something changed in the matching,
the routing or the account math. If they move and you *did* expect it, update
the numbers here in the same commit.

---

## CI

`.github/workflows/software-ci.yml` runs on every PR touching `sw/`. The
`engine` job runs on **ubuntu-latest and macos-latest**:

1. `make` — build the CLI
2. `make test` — the four C++ binaries
3. `make pymodule` — build the extension
4. `make test-python` — the binding tests
5. an offline simulation through Python, asserting the PnL curve isn't empty
6. a loopback `online_run` smoke test, grepping for `Simulation finished successfully`

Warnings don't fail the build. To make them fail locally:

```bash
make test CXXFLAGS="-std=c++17 -O2 -Wall -Wextra -Werror"
```
