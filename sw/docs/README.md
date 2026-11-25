# Software Documentation

Documentation for the software side of CommonTrader: the C++ trading engine,
the FastAPI service, the React UI, and the data pipeline — everything under
`sw/`.

## Guides

- **[System testing](system-testing.md)** — testing the whole stack together:
  FPGA, engine, backend and UI. How to bring the stack up, verify each layer,
  run against the real board, and narrow a failure to the layer that caused it.
- **[Engine testing](engine-testing.md)** — building the engine, every Makefile
  target, what each unit test covers, the replay scenarios, and the offline
  baseline to check regressions against.
- **[Engine architecture](engine-architecture.md)** — how the engine works
  inside: participants, the scheduler's priority queue, the latency model,
  accounts, and the order book. Diagrams included.

## Related documents

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
| Run the tests | `make -C sw/engine test` and `make -C sw/engine test-python` |
| Stream at the real board | `make -C sw/engine hardware-test` |
| Wire protocols | `sw/engine/network/include/protocol.h` (ITCH in, OUCH out) |
| Networking config | `OnlineConfig` in `sw/engine/simulation/include/online_config.h` |
| API | `http://127.0.0.1:8000` · UI `http://localhost:5173` |
