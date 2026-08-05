# Engine Tests / Scenarios

The engine's test surface is a single real-time CLI, **`online_run`** (built
from `sw/engine/tests/src/test.cpp`), driven by config files under
`sw/engine/tests/config/`. Each config replays a market-data book through the
`OnlineSimulation` over a chosen transport/address. These are **runnable
scenarios** -- you watch the banner, the replay, and the final trade/PnL
summary (and, for the hardware run, OUCH activity from the board) -- rather
than self-checking pass/fail unit tests.

> The earlier assertion-based C++ harnesses (`stress_orderbook.cpp`,
> `socket_test.cpp`, `fpga_test.cpp`) have been removed. Order-entry now comes
> from a real client (the FPGA over OUCH) or the FastAPI service's loopback
> path, not a bundled test client. See `git log` if you need the old harnesses.

For how to build (and the `PY=` override), see
[build-and-test.md](build-and-test.md).

---

## How it works

`test.cpp` is the entry point for the `online_run` binary. It takes either a
config file or positional args:

```bash
./online_run <config.ini>                 # config mode (first arg ends in .ini)
./online_run [mbo_file] [time_scale]       # positional mode
```

In config mode it parses the `.ini` with `TestConfig`
(`tests/include/test.h`, a tiny INI decoder). Only these keys are read; any
value not present falls back to its `OnlineConfig` default
(`simulation/include/online_config.h`):

| Section | Key | Meaning |
|---|---|---|
| `[network]` | `itch_address` | ITCH market-data destination (`127.0.0.1` loopback vs `192.168.0.1` FPGA) |
| `[network]` | `itch_port` / `ouch_port` | UDP/TCP ports |
| `[network]` | `ouch_transport` | `udp` (default, matches FPGA) or `tcp` |
| `[data]` | `market_book` | packed MBO `.bin` to replay |
| `[timing]` | `time_scale` | `1.0` real time, smaller = faster, `0` = no pacing |

> **Trades on loopback.** `online_run` does **not** run the local strategy
> (`enable_local_strategy`/`auto_fill` aren't config keys and stay off), so the
> loopback scenarios below replay market data and stand up the ITCH/OUCH
> sockets but produce **no trades** on their own -- nothing is sending orders
> in. Trades come from a real board (the `hardware` scenario) or from the
> FastAPI service's loopback path (which enables the local strategy). See
> [run-dashboard.md](run-dashboard.md).

---

## Scenarios (`tests/config/`)

| Config | make target | Address | Data | Pacing |
|---|---|---|---|---|
| `socket_test.ini` | `make run FILE=tests/config/socket_test.ini` | loopback `127.0.0.1` | `synthetic_mbo_stream.bin` (full MBO) | `0.001` |
| `smoke_test.ini` | `make smoke-test` | loopback `127.0.0.1` | `smoke_book.bin` (10 orders) | `1.0` |
| `flood_test.ini` | `make run FILE=tests/config/flood_test.ini` | loopback `127.0.0.1` | `flood_book.bin` (5000 orders) | `0` (burst) |
| `hardware_test.ini` | `make hardware-test` | `192.168.0.1` (FPGA) | `synthetic_mbo_stream.bin` (full MBO) | `1.0` |

- **`socket_test`** — loopback replay of the full ~5.3h MBO stream, compressed
  to a few seconds (`time_scale = 0.001`). Confirms the engine reads and
  replays the real dataset end to end.
- **`smoke_test`** — quick (~1s) loopback replay of the short generated
  `smoke_book`. `make smoke-test` generates the book first.
- **`flood_test`** — the dense generated `flood_book` replayed with no pacing,
  bursting market data as fast as possible (stress). `make smoke-test` also
  generates `flood_book`.
- **`hardware_test`** — streams the MBO feed at the real board over
  `192.168.0.1:50001` in real time; the board sends OUCH orders back, which the
  engine matches and reports in the final trade/PnL summary. Requires the
  host↔FPGA link up (see below).

---

## Market-data generators (`data_pipeline/src/`)

The books live in `data_pipeline/data/`. `synthetic_mbo_stream.bin` is
committed; the ladder/smoke/flood books are generated:

- **`gen_market_ladder.py`** — `EventGenerator` builds a linearly-interpolated
  price ladder of `'A'` (Add) events and serialises it (`struct "<QcQcdd"`:
  timestamp, msg type, order id, side, price, size). Run directly, it writes
  `market_ladder.bin` (a rising bid ladder, 100 orders 100.00→104.95, 50 ms
  apart).
- **`gen_test_datasets.py`** — reuses that generator to produce
  `smoke_book.bin` (10 orders, ~1s) and `flood_book.bin` (5000 orders, dense).
  `make smoke-test` runs it automatically.

```bash
python3 data_pipeline/src/gen_market_ladder.py    # -> data_pipeline/data/market_ladder.bin
python3 data_pipeline/src/gen_test_datasets.py    # -> smoke_book.bin + flood_book.bin
```

---

## Running

```bash
cd sw/engine

make run                                    # defaults: full MBO stream, time_scale 0.001
make run FILE=tests/config/socket_test.ini  # any config
make smoke-test                             # generate books + loopback smoke run
make hardware-test                          # stream at the real board (needs the link up)
```

Override `PY=` if your Python 3 isn't at the Makefile's default venv path
(`../service/.venv/bin/python`), e.g. `make smoke-test PY=python3`.

### Hardware run prerequisites

`make hardware-test` drives the **actual board**, not a self-contained test:

1. Configure the host NIC for the board link: `sudo ./setup/net_setup.sh`
   (see [connection-test.md](../../docs/connection-test.md)).
2. Board programmed with the bitstream and the Ethernet link up
   (`ifconfig en5` shows `status: active`).

If it reports zero trades, the board isn't sending orders back (bitstream not
running, RGMII RX failing CRC, or the stream didn't trigger the strategy) --
see the hardware-side checklist in
[connection-test.md](../../docs/connection-test.md).
