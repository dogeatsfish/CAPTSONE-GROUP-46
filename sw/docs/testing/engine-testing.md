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
| `test-python` | builds the module, then runs `../service/tests/test_bindings.py` |
| `run` | builds + runs `online_run` on `FILE` at pacing `SCALE`, broadcasting to `ITCH_ADDR` |
| `flash` | sends ITCH packets at the board so its LED flashes — a visual link check |
| `bench` | measures the engine's own fan-out cost in wall-clock time |
| `rebuild` | clean, then build from scratch |
| `clean` | removes all build artifacts |

Overridable variables: `FILE` (the MBO book), `SCALE` (pacing — `1.0` is real
time, `0` disables it), `ITCH_ADDR` / `ITCH_PORT` / `OUCH_PORT` (default to
loopback on 50001), `CXX`, `CXXFLAGS`.

Headers are tracked as prerequisites, so editing one rebuilds everything that
includes it. You shouldn't need `make clean` as a habit; `make rebuild` is
there for the cases where a scratch build is genuinely right, like changing
`CXXFLAGS`.

---

## The unit tests

```bash
make test          # all four C++ binaries, stops at the first failure
make test-python   # the Python binding tests, in sw/service/tests/
```

The binding tests live with the service rather than the engine because the
service is what consumes `engine_sim`; `make test-python` builds the module
and then runs them from there.

Each binary prints one `ok <name>` line per check group and a final
`PASSED (0 failed checks)`. There is no test framework: each file defines its
own `CHECK` macro that prints the failing line and bumps a counter, and `main`
exits non-zero if anything failed.

| Binary | Source | Covers |
|---|---|---|
| `test_orderbook` | `tests/src/test_orderbook.cpp` | matching, resting, price/time priority, L1 and L2 depth, market orders, partial cancel (`reduce`), `replace` and its loss of priority, rejects, queue position, snapshot/restore |
| `test_account` | `tests/src/test_account.cpp` | position and average-entry math, realized vs unrealized PnL, taker fee and maker rebate, open-order tracking, fill history |
| `test_scheduler` | `tests/src/test_scheduler.cpp` | time ordering, same-time tie-break, the no-time-travel guarantee, inbox routing, `run_until`, periodic snapshots, seek-from-snapshot, determinism |
| `test_participant` | `tests/src/test_participant.cpp` | callbacks at zero latency, both latency legs, fill-notification delay, the "faster participant wins the race" property, tier presets, market orders, order management, fees, timers, queue-position queries, unregistered participants |
| `sw/service/tests/test_bindings.py` | — | the Python surface: direct `OrderBook` use, stepping the scheduler, a `Participant` subclass written in Python, latency presets, snapshots, determinism, `OfflineSimulation` options |

Test binaries are gitignored (`sw/engine/test_*`) and removed by `make clean`.

### Writing a new one

1. Add `tests/src/test_<thing>.cpp` with its own `CHECK` macro — copy the
   top of an existing one.
2. Add `test_<thing>` to `TEST_TARGETS` in the Makefile and give it a rule —
   copy the nearest existing one. `SCHED_SRCS` is the source list anything
   scheduler-level needs to link, and `ALL_HDRS` covers the headers.
3. `make test` picks it up, and so does CI.

---

## Running the engine by hand

`online_run` (built from `tools/online_run.cpp`) replays a market-data book over
real ITCH/OUCH sockets. It takes positional arguments only:

```bash
./online_run [mbo_file] [time_scale] [itch_port] [ouch_port] [itch_addr]
```

Anything you leave off keeps its `OnlineConfig` default
(`runner/include/online_config.h`). Through the Makefile:

```bash
make run                                      # loopback, 1000x speed
make run FILE=../data_pipeline/data/flood_book.bin SCALE=0
make run SCALE=1.0 ITCH_ADDR=192.168.0.1      # real time, at the board
```

> **This is a replay, not a test.** `online_run` doesn't enable the local
> strategy, so it streams market data and stands up the sockets but produces
> no trades on its own — nothing is sending orders in. Trades come from a real
> board, or from the FastAPI service's loopback path, which does set
> `enable_local_strategy`. For pass/fail checking, use `make test`.

### Datasets

`data_pipeline/data/` holds the committed books:

| File | What it is |
|---|---|
| `synthetic_mbo_stream.bin` | the full ~5.3h stream, ~61k records |
| `tiny_book.bin` | 10 orders, about a second |
| `flood_book.bin` | 5000 orders, dense — what CI's loopback run replays |
| `market_ladder.bin` | a rising bid ladder, 100 orders |

`data_pipeline/src/gen_market_ladder.py` and `gen_test_datasets.py` regenerate
the last three if you need variants. Record format is `struct "<QcQcdd"` —
timestamp, message type, order id, side, price, size — 34 bytes, asserted at
compile time in `shared/include/feed.h`.

## Measuring the engine's own speed

`make bench` answers a different question from the latency model. `in_ns` and
`out_ns` are bookkeeping — adding a number to a timestamp costs nothing. What
would bound a real system is the engine's **wall-clock** overhead: heap
push/pop, building the L2 snapshot, dispatching callbacks, updating accounts.

```bash
make bench                      # 1, 2, 4 ... 256 participants
make bench BENCH_TRIALS=20000   # more samples per point
```

It times, per trade, from the moment the order hits the book to the moment the
last participant's callback returns, and reports percentiles rather than a mean
because the tail is what bites.

Representative output (Apple Silicon, `-O2`, 3000 trades per point):

| participants | steps | p50 | p99 | per recipient |
|---|---|---|---|---|
| 1 | 3 | 1.75 µs | 3.5 µs | — |
| 16 | 33 | 3.3 µs | 4.6 µs | 206 ns |
| 64 | 129 | 10.2 µs | 11.7 µs | 159 ns |
| 256 | 513 | 47.5 µs | 54.8 µs | 186 ns |

Two things fall out of that:

- **There is a fixed cost of roughly 1.5 µs per trade** regardless of audience
  — the match itself, plus one `get_l2_state` and the `shared_ptr` snapshot
  that every book update shares.
- **Each additional listener costs about 160–190 ns**, which is one heap push,
  one pop, a `BookEvent` copy and a virtual call.

So if every participant were on a genuinely sub-microsecond link, **the engine
would be the bottleneck, not the network**: at 64 participants nobody can hear
about a trade in under ~10 µs of real time, whatever their `LatencyProfile`
says. That gap doesn't affect correctness — simulated time is independent of
wall-clock time, and results stay deterministic — but it caps how fast a live
or real-time-paced run could go.

`steps` is `2N + 1`: one `BookAction`, then a `Trade` and a book update for
each participant. If that number ever changes, the routing changed.

Not in CI — wall-clock timing on a shared runner is noise.

## Checking a change didn't move the numbers

The offline simulation is deterministic, so the quickest way to confirm a change
didn't alter behaviour is to compare its output before and after. This is a
manual diff, not an automated test:

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
6. a loopback `online_run` end-to-end run, grepping for `Simulation finished successfully`
   — the only check that exercises the real socket path (ITCH framing, UDP
   send, the OUCH listener thread); everything above it runs in-process

Warnings don't fail the build. To make them fail locally:

```bash
make test CXXFLAGS="-std=c++17 -O2 -Wall -Wextra -Werror"
```
