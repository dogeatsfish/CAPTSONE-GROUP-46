# Engine Tests

The software engine has two test executables plus a market-data generator,
all under `sw/engine/tests/`. This document describes **what each one tests** and
**the specific cases** it covers. For how to build/run them (and variable
overrides like `PY=`), see [build-and-test.md](build-and-test.md).

| Target / file | Layer under test | Network? |
|---|---|---|
| `stress-book` — `tests/src/stress_orderbook.cpp` | `OrderBook` matching engine | no |
| `socket-test` — `tests/src/socket_test.cpp` (`socket_test.ini`) | OUCH order-entry path via socket | loopback |
| `test-online` — `tests/src/socket_test.cpp` (`test_online.ini`) | Full online sim: ITCH out + OUCH in/out | loopback |
| `flood-test` — `tests/src/socket_test.cpp` (`flood_test.ini`) | `socket-test`'s scenario, denser resting book | loopback |
| `fpga-test` — `tests/src/fpga_test.cpp` | Real FPGA over Ethernet: ITCH out, decode OUCH in | **real hardware** |
| `tests/src/gen_market_ladder.py` | Generates the market-data book the loopback tests replay | n/a |

`socket-test`/`test-online`/`flood-test` are one binary (`tests/src/socket_test.cpp`)
driven by three different `tests/config/*.ini` files -- which orders it sends,
what response type/trade count each order is expected to produce, and whether
it also verifies the ITCH broadcast are all config, not separate `.cpp` files.
See the header comment in `socket_test.cpp` for the full key list.

> **Transport note.** All three loopback scenarios drive order entry with a
> **TCP** client, so they set `cfg.ouch_transport = OuchTransport::TCP`. The
> engine's *default* is UDP (to match the FPGA). They also pin
> `cfg.itch_address = "127.0.0.1"` so the loopback ITCH subscriber receives the
> broadcast. Both are required because the shipping defaults target the hardware.

---

## `stress_orderbook.cpp` — matching-engine correctness + stress

Pure C++, no sockets or Python. Two phases: deterministic correctness checks,
then randomized/adversarial stress with invariant checking. Uses a small
`CHECK(cond, msg)` framework and exits non-zero if any check fails.

### Correctness cases

| Test | What it verifies |
|---|---|
| `test_no_cross_rests` | A bid and a higher ask both rest without trading; L1 best bid/ask correct; no trades logged. |
| `test_full_and_partial_fill` | Aggressive taker fully consumed against a larger maker; maker's leftover stays at the same level; then a second taker consumes the remainder and rests the surplus on the opposite side. Checks fill size, fill price, and L1 after each step. |
| `test_multi_level_sweep_vwap` | Aggressive order sweeps three ask levels; verifies total filled size, the **VWAP** across levels, and that three trades are logged. |
| `test_price_time_priority` | Two asks at the *same* price fill in arrival order (earliest `maker_id` first). |
| `test_cancel` | Cancel moves L1 to the next level; cancelling a non-existent id on either side is a safe no-op. |

### Stress cases

| Test | What it verifies |
|---|---|
| `stress_random(ops, seed)` | Runs 100k / 500k / 1M random add/cancel ops (~70% add, ~30% cancel) across a price band. Core **invariant: the resting book is never crossed** (`best_bid < best_ask`). Reports throughput (M ops/s) and trade count. |
| `stress_deep_sweep(levels)` | One huge aggressive order sweeps a deep book (1k and 10k price levels). Verifies the entire book is filled and the swept side is cleared; reports sweep latency. |

**Pass criteria:** all `CHECK`s pass (0 failures) and zero cross violations.

---

## `socket_test.cpp` — OUCH client vs a rising bid ladder

The online engine makes no trading decisions itself; every order arrives over
the OUCH socket, exactly like a co-located FPGA/strategy would send it. This
one binary plays that external client, config-driven so the same source
covers three scenarios (see the header comment in the file for the full key
list: `order_count`/`orderN_*`, `min_trades`/`max_trades`, `verify_itch`,
`pre_send_delay_ms`). Self-contained -- regenerates the ladder book if it's
missing.

**Flow:** optionally subscribe to the ITCH UDP broadcast (`verify_itch`), run
the sim on the ladder in the background, connect over OUCH (TCP), send the
configured orders and read each response (printed as both raw hex and decoded
fields, since raw OUCH bytes are binary and unreadable as text), then check
the configured trade-count bounds (and, if `verify_itch`, the captured ITCH
packets). Example printed response:

```
   raw OUCH [25 B]: 45 00 00 00 00 35 A4 E9 01 40 59 00 00 00 00 00 00 40 59 1C CC CC CC CC CD
   decoded: type=EXECUTED('E')  order_id=900000001  size=100.0000  price=100.4500
```

### `socket-test` / `flood-test` — `socket_test.ini` / `flood_test.ini`

Same client behavior (`flood_test.ini` just points at a far denser resting
book -- see `gen_test_datasets.py`); no ITCH verification, no per-order
expected-response check.

| Order | Setup | Expected |
|---|---|---|
| SELL 100 @ 99.00 | Crosses the highest resting bid(s) | EXECUTED (sweeps top of book). |
| SELL 100 @ 100.00 | Crosses the next resting bid(s) | EXECUTED. |

**Pass criteria:** at least 2 OUCH-driven trades. Final position ends short
(`-200`) after the two sells.

### `test-online` — `test_online.ini`

The fuller end-to-end check: also subscribes to the ITCH UDP broadcast on
loopback **before** the run starts (so it captures every market-data
datagram), and checks each OUCH response's *exact* type, not just a trade
count.

| Order | Setup | Expected |
|---|---|---|
| SELL 100 @ 100.00 | Crosses the resting bids | **EXECUTED** response; contributes the run's single trade. |
| SELL 100 @ 200.00 | Above every bid, cannot cross | **ACCEPTED** response (rests, no fill). |

**Pass criteria:** ≥1 ITCH packet received and all captured ITCH packets are
Adds (`'A'`); first order EXECUTED, second ACCEPTED; exactly 1 total trade.

---

## `fpga_test.cpp` — real FPGA hardware harness

Unlike the loopback tests, this drives the **actual board** over Ethernet. The
"client" sending OUCH orders is the FPGA itself. It uses the **default** network
config, no ports/addresses overridden:

- ITCH market data is broadcast to `192.168.0.1:50001` (the board),
- OUCH order entry is received over **UDP** on `0.0.0.0:50001` (matches the FPGA),
- it replays the **synthetic MBO stream** (`../data_pipeline/data/synthetic_mbo_stream.bin`).

Every OUCH packet the FPGA sends back is printed as **raw hex + decoded fields**
(type, order id, side, qty, price), via an OUCH observer hook on the engine
(`OnlineSimulation::set_ouch_observer`). Example line:

```
[OUCH #1] raw [47 B]: 4F 00 00 00 01 42 00 00 00 64 ...
          decoded: type=ENTER('O')  order_id=1  side=B  qty=100  price=100.5000
```

### Prerequisites (this is hardware, not a self-contained unit test)

1. Host NIC configured for the board link: `sudo ./setup/net_setup.sh`
   (see [connection-test.md](../../docs/connection-test.md)).
2. Board programmed with the bitstream and the Ethernet link up
   (`ifconfig en5` shows `status: active`).

### What it tells you

- **OUCH packets printed** → the full chain works: the board received the ITCH
  stream, ran the strategy, and transmitted an order back, which the host
  received and decoded.
- **Zero received** → the board isn't sending orders back (bitstream not running,
  RGMII RX failing CRC, or the stream didn't trigger the strategy). See the
  hardware-side checklist in [connection-test.md](../../docs/connection-test.md).

### How to run

```bash
cd sw/engine
sudo ../../setup/net_setup.sh        # (re)configure the host link first
make run-fpga-test                   # build + run against the board (real time)
# or build only, then run manually with custom args:
make fpga-test
./fpga_test ../data_pipeline/data/synthetic_mbo_stream.bin 1.0
#           [mbo_file]                                     [time_scale]
```

Override the stream or pacing via make variables:

```bash
make run-fpga-test FPGA_FILE=/path/to/stream.bin FPGA_SCALE=0
```

---

## `gen_market_ladder.py` — market-data generator

Produces the packed-binary MBO book the online tests replay
(`tests/data/market_ladder.bin`). `make test-online` and `make socket-test` run
it automatically first.

- `EventGenerator.generate_events(EventConfig)` builds a linearly-interpolated
  price ladder of `'A'` (Add) events.
- `dict_to_bin` / `dict_to_csv` serialise to the packed MBO format
  (`struct "<QcQcdd"`: timestamp, msg type, order id, side, price, size) or CSV.
- Default when run directly: a rising **bid** ladder, 100 orders from 100.00 to
  104.95 (step +0.05), size 100, 50 ms apart.

Run standalone:

```bash
python3 tests/src/gen_market_ladder.py
```

---

## Running everything

```bash
cd sw/engine
make stress-book                 # no deps
make test-online  PY=python3     # regenerates the ladder, then runs
make socket-test  PY=python3
```

Override `PY=` if your Python 3 isn't at the Makefile's default venv path.
