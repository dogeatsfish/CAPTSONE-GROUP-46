# Building and Running the Engine

All commands run from `sw/engine` (where the `Makefile` lives):

```bash
cd sw/engine
```

## Prerequisites

| Platform | C++ toolchain | Notes |
|----------|---------------|-------|
| **Linux / Dev Container** | `g++` (GCC 13 in the container) | Everything works out of the box. |
| **macOS** | `g++` → Apple Clang via Xcode CLT | `xcode-select --install`. `g++` is a Clang alias here. |

The Python module and the online tests additionally need Python 3 with
`pybind11`. Inside the [Dev Container](README.md) these are preinstalled.

## Makefile targets at a glance

| Target         | What it does                                                        |
|----------------|---------------------------------------------------------------------|
| `all` (default)| Builds `simulation_run` and `online_run`.                           |
| `simulation_run` | Builds the offline (batch) CLI binary.                            |
| `run`          | Builds + runs the offline CLI on `FILE`.                            |
| `online`       | Builds the real-time CLI binary `online_run`.                       |
| `run-online`   | Builds + runs `online_run` on `FILE` at pacing `SCALE`.             |
| `pymodule`     | Builds the importable Python extension `engine_sim*.so`.            |
| `stress-book`  | Builds + runs the OrderBook stress/correctness harness.             |
| `test-online`  | Generates a market book, then builds + runs the end-to-end online test. |
| `socket-test`  | Generates a market book, then builds + runs the OUCH socket test.   |
| `flood-test`   | Generates a dense market book, then stress-tests the engine with a burst of ITCH messages. |
| `hw-smoke-test`| Builds `online_run` and streams a short book at the real FPGA (`docs/connection-test.md`). |
| `fpga-test`    | Builds the FPGA hardware harness `fpga_test` (does not run it).      |
| `run-fpga-test`| Builds + runs the FPGA harness against the real board.              |
| `clean`        | Removes all build artifacts.                                        |

## Overridable variables

Pass these on the command line as `make <target> VAR=value`:

- `FILE` — MBO data file for `run` / `run-online`
  (default `../data_pipeline/data/synthetic_mbo_stream.bin`).
- `SCALE` — wall-clock pacing for `run-online`
  (default `0.001` = 1000× faster; `1.0` = real time; `0` = no pacing).
- `PY` — Python interpreter for the online tests
  (default `../service/.venv/bin/python`).
- `FPGA_FILE` / `FPGA_SCALE` — MBO stream and pacing for `run-fpga-test`
  (defaults `../data_pipeline/data/synthetic_mbo_stream.bin` and `1.0`).
- `CXX` / `CXXFLAGS` — compiler and flags.

## Running each part

### Offline (batch) simulation

```bash
make run                                   # default data file
make run FILE=../data_pipeline/data/synthetic_mbo_stream.bin
```

### Online (real-time) engine

```bash
make run-online                            # SCALE=0.001 (fast)
make run-online SCALE=1.0                  # true real time (for hardware)
```

Or call the binary directly for full control over networking args (see
`main_online.cpp`):

```bash
./online_run ../data_pipeline/data/synthetic_mbo_stream.bin 1.0 50001 50001 192.168.0.1 udp
#            [mbo_file]                                    [scale][itchP][ouchP][itch_addr][transport]
```

### The tests

```bash
make stress-book       # pure C++ OrderBook stress + correctness, no Python/network
make test-online       # end-to-end: ITCH replay + OUCH connect/send/receive
make socket-test       # OUCH socket client vs a rising bid ladder
make flood-test        # same, but against a dense 5000-order book (stress)
```

`test-online`, `socket-test`, and `flood-test` are the same binary
(`tests/src/socket_test.cpp`) pointed at three different `tests/config/*.ini`
files -- which orders it sends, expected trade counts, and whether it also
verifies the ITCH broadcast are config, not separate source files. All three
first generate their market book (via `$(PY)`), then compile and run. If your
Python isn't at the default venv path, override it:

```bash
make test-online PY=python3
make socket-test PY=/path/to/venv/bin/python
```

Each reads its socket addresses/ports/transport, dataset path, and test
scenario (orders to send, expected trade counts, ITCH verification) from a
`tests/config/*.ini` file instead of hardcoded values in the `.cpp` —
override with e.g. `TEST_ONLINE_CONFIG=path/to/other.ini` or
`SOCKET_TEST_CONFIG=...`. See `tests/config/test_online.ini` or the header
comment in `tests/src/socket_test.cpp` for the full key list.

> **Transport note:** `socket_test.cpp`'s OUCH client (`connect_ouch`) only
> speaks **TCP**, while the engine's default OUCH transport is now **UDP** —
> that's why its `.ini` files pin `ouch_transport = tcp`. Pointing one of
> these configs at `udp` fails fast with a clear error instead of hanging.
> See `sw/engine/simulation/include/online_simulation.h`.

### Hardware smoke test

```bash
make hw-smoke-test
```

Builds `online_run` and streams a short 10-order book at the real FPGA
(`tests/config/hardware_smoke.ini`: UDP, `192.168.0.1:50001`). This assumes
the host↔FPGA link is already set up — see `docs/connection-test.md`, which
this is the quick/checked-in version of step 4's manual command.

Same override pattern as `test-online`/`socket-test`: point it at a different
`.ini` with `HW_SMOKE_CONFIG=...` instead of editing the Makefile.

## Building the Python module — macOS vs Linux

This is the one target that differs by platform. The `pymodule` recipe uses the
macOS/Clang linker flag `-undefined dynamic_lookup`, which lets undefined Python
symbols resolve at load time:

```make
$(CXX) $(CXXFLAGS) -shared -fPIC -undefined dynamic_lookup \
    $(INCLUDES) $(PY_INCLUDES) $(PY_SRCS) -o $(PY_TARGET)
```

### macOS

Works as written:

```bash
make pymodule
```

### Linux

`-undefined dynamic_lookup` is **not** a valid GCC/ld flag on Linux and the
`make pymodule` target will fail there. Linux Python extensions don't need it,
so build the module manually without that flag:

```bash
g++ -std=c++17 -O2 -Wall -Wextra -shared -fPIC \
    -Ishared/include -Imatch/include -Isimulation/include \
    $(python3 -m pybind11 --includes) \
    bindings/src/bindings.cpp \
    simulation/src/offline_simulation.cpp \
    simulation/src/online_simulation.cpp \
    simulation/src/protocol.cpp \
    simulation/src/user_strategy.cpp \
    match/src/orderbook.cpp \
    -o engine_sim$(python3-config --extension-suffix)
```

Then import it:

```bash
python3 -c "import engine_sim; print(engine_sim.OuchTransport.UDP)"
```

## Cleaning up

```bash
make clean
```
