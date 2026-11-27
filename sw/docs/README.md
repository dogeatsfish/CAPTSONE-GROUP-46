# Software Documentation

Documentation for the software side of CommonTrader: the C++ trading engine,
the FastAPI service, the React UI, and the data pipeline — everything under
`sw/`.

Split three ways: **design** explains how things are built and why; **idea**
collects proposals for work that is not built or not yet agreed; **testing** tells
you what to run and how to read the result.

## Design

How the software works internally. Read these to change the engine, or to
understand a behaviour you didn't expect.

- **[Engine architecture](design/engine-architecture.md)** — participants, the
  scheduler's priority queue, the latency model, accounts, and the order book.
  How one order moves through the system, where events get routed, what makes
  a run reproducible, and the known simplifications. Diagrams included.

## Idea

Proposals and explorations, for work that has not been built and in some cases has
not been agreed. Read these before starting the ticket they describe; they are
meant to be argued with.

- **[App design](idea/app_design.md)** — the whole app at a high level, with UI notes:
  Tutorial (a story that explains markets, from a first trade to the chip), Games (trading
  by hand, the daily challenge, a live market against the FPGA house bot) and League (write
  a strategy in C or Verilog, test it in software, run it on the FPGA). How the one board is
  shared, the site map, key screens, accounts and sandboxing, and the build phases.
- **[Calibration from L1](idea/calibration.md)** — ticket #23. What the TAQ sample
  in the repo can honestly support and what has to come from published stylised
  facts, the shapes `calibration.json` could take so an assumption can later be
  promoted to a measurement without breaking its consumers, and how the numbers
  would reach the C++ side.
- **[Calibration from a month of Massive data](idea/calibration_11242026.md)** —
  update to the above. One stock of mid liquidity, quotes and trades kept out of git,
  how bots scale the base config without drifting the market, and modelling one market
  now with venue profiles at #21.
- **[Game progression](idea/game_progression.md)** — hand-played trading games
  (auctions, making a market, card markets, quant-interview betting games) solo against
  bots or in multiplayer rooms, and the board challenge: one strategy on the FPGA against
  four scenarios at once, scored on profit and on-chip latency. Rooms and the board share
  one external-participant runtime.

## Testing

What to run, in what order, and how to tell a pass from a failure.

- **[System testing](testing/system-testing.md)** — the whole stack together:
  FPGA, engine, backend and UI. Bringing the stack up, verifying each layer on
  its own, running against the real board, and narrowing a failure to the layer
  that caused it.
- **[Engine testing](testing/engine-testing.md)** — building the engine, every
  Makefile target, what each unit test covers, running the engine by hand, and
  the offline baseline to diff a change against.

## Related documents

Outside `sw/`, mostly hardware-side:

- [Host ↔ FPGA link setup and connection test](../../docs/connection-test.md) —
  wiring the host to the board, configuring the NIC, verifying the link.
- [Testing the board from scratch](../../docs/board-test-checklist.md) — the
  cold-start sequence, bitstream through to live trades.
- [HW ↔ SW interface](../../docs/hw_sw_interface.md) and
  [transport gaps](../../docs/hw_sw_transport_gaps.md) — the wire contract
  between the engine and the RTL.
- [Known limitations](../../docs/known_limitations.md).

## Quick reference

| | |
|---|---|
| Run the whole stack | `cd sw && ./dev.sh` (add `--no-ui` for backend only) |
| Build the engine CLI | `make -C sw/engine` |
| Build the Python module | `make -C sw/engine pymodule` |
| Run the tests | `make -C sw/engine test` (C++) and `make -C sw/engine test-python` (Python) |
| Check the board is receiving | `make -C sw/engine flash` (watch the LED) |
| Stream at the real board | `make -C sw/engine run SCALE=1.0 ITCH_ADDR=192.168.0.1` |
| Wire protocols | `sw/engine/network/include/protocol.h` (ITCH in, OUCH out) |
| Networking config | `OnlineConfig` in `sw/engine/runner/include/online_config.h` |
| API | `http://127.0.0.1:8000` · UI `http://localhost:5173` |
