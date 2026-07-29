# TODO

Known gaps, tracked in one place instead of scattered across Discord/in-code
comments/the design doc. Not a replacement for GitHub Issues if the team wants
those later — just a starting checklist. Update this as items land or new
gaps are found; a stale TODO list is worse than none.

## Hardware (`rtl/`)

- [ ] `commontrader_top.sv`: instantiate the MMCM (Clocking Wizard) for the
      250 MHz core clock from the 125 MHz RGMII reference.
- [ ] `commontrader_top.sv`: instantiate the RX CDC FIFO (125 MHz -> 250 MHz).
- [ ] `commontrader_top.sv`: instantiate the TX CDC FIFO + TX MAC Core
      (250 MHz -> 125 MHz -> RGMII).
- [ ] `vivado/constraints/` is empty — no board XDC pin constraints committed
      yet. Blocks full implementation/bitstream generation.
- [ ] `pre_trade_risk_gateway.sv`: **Restricted Ticker Blacklist** check is
      declared (`viol_blacklist`) but never driven — hardcoded to 0 in the
      final `violations` assignment. Design doc §3.1.5 describes this as
      implemented; it isn't yet.
- [ ] `pre_trade_risk_gateway.sv`: **CRC Integrity Drop** check is declared
      (`viol_crc`) but never driven — same hardcoded-0 gap. This is the check
      that's supposed to make the parser's cut-through forwarding safe.
- [ ] Confirm the actual Vivado `-part` string for the Alinx AX7A200B (speed
      grade / package). Currently pinned to `xc7a200t-2fbg484` (block
      diagram's value) as a placeholder in `vivado/scripts/compile_alpha_engine.tcl`
      — nothing in-repo confirms the exact SKU.

## Software engine (`sw/engine/`)

- [x] ~~Port `online_simulation.cpp`/`.h` to Winsock2 for native Windows
      builds~~ — **decided against.** `sw/Dockerfile` fully covers this: the
      container compiles `online_simulation.cpp` in with no
      `CT_NO_ONLINE_SIM` restriction at all (real Linux, real POSIX
      sockets), so anyone needing `OnlineSimulation` on a Windows/macOS host
      just runs the service in Docker. Not worth a real Winsock2 port for
      the marginal case of the bare CLI harnesses (`make test-online`/
      `make socket-test`) running natively on Windows outside the container.
- [x] `engine_sim.cpython-314-darwin.so` was committed to git — resolved via
      PR #15 (merged), which removed it along with 3 other stray compiled
      test binaries (`socket_test`, `stress_orderbook`, `test_online`) that
      shouldn't have been tracked either. Also added a VS Code Dev Container
      (`sw/.devcontainer/`) for engine development — a real Ubuntu 24.04
      environment with gcc-13/gdb/valgrind, complementary to `sw/Dockerfile`
      (that one runs the *service*; this one is for editing/building/
      debugging the C++ engine natively inside VS Code). Remember to pull
      `main` into `kael/software` to pick this up.

## Compile API (`sw/service/api/`, `vivado/scripts/compile_alpha_engine.tcl`)

- [ ] Currently out-of-context (OOC) synthesis + report only — no full
      bitstream generation, no DFX partial reconfiguration, no JTAG board
      flash. Depends on the hardware TODOs above (top-level completeness +
      XDC constraints) being done first.
- [ ] Once the top level is complete, revisit whether NF-3's 80%
      device-wide utilization budget should be checked automatically here
      (not meaningful yet since this only synthesizes the sandbox module in
      isolation, not the full static platform).

## Containerization (`sw/Dockerfile`, `sw/docker-compose.yml`)

- [x] **Build-tested for real** (after installing Docker Desktop):
      `docker compose up --build` builds cleanly, the container starts, and
      `/`, `/datasets`, and `/simulate` all respond correctly. Ran a real
      simulation through it (4655 trades) and confirmed it matches the
      native-Windows run exactly. Confirmed `engine_sim` builds *with full
      OnlineSimulation support* inside the container (real Linux, real
      POSIX sockets — no `CT_NO_ONLINE_SIM` needed), and confirmed FS-15 DB
      logging persists correctly to the mounted volume via `CT_DB_PATH`.
- [x] Fixed a real bug this surfaced: the Makefile's non-Windows
      `pymodule` branch used `-undefined dynamic_lookup` unconditionally,
      which is a macOS/ld64-only linker flag — GNU ld on Linux would have
      rejected it, breaking the exact same way the Windows build originally
      did. Now split on `uname -s` (Darwin gets the flag, Linux gets none).
- [ ] Only covers `sw/engine` + `sw/service` (not `rtl/`/`vivado/` — see the
      scope note at the top of `sw/Dockerfile`). `/compile` will not work
      inside the container since Vivado isn't installed there; run the
      service natively for that endpoint.
- [ ] Only build-tested on this one Windows/Docker Desktop machine — worth
      someone confirming `docker compose up --build` on macOS/Linux too,
      though there's no reason to expect it'd differ (it's the same Linux
      image either way).
- [x] `sw/service/api/requirements.txt` is new — no Python dependency
      manifest (`requirements.txt`/`pyproject.toml`) existed anywhere in the
      repo before this. Now exact-pinned (full transitive closure via
      `pip freeze` against the real built image) and rebuild-verified.

## Database logging (FS-15, `sw/service/api/src/db.py`)

- [x] `runs`/`fills`/`metrics` tables — one row per completed run, its
      executed trades, and its PnL samples. Wired into the blocking
      `/simulate` and `/simulate/online` endpoints only.
- [ ] `book_snapshots`, `orders`, `order_events` (the other three tables in
      the design doc's schema) aren't populated — they need per-tick L2 book
      depth and full order-lifecycle events (submit/ack/cancel/reject), which
      `engine_sim.SimulationResult` doesn't currently expose (only `trades`
      and `pnl_curve`). Getting that data means extending the C++ matching
      engine / pybind11 bindings (`orderbook.cpp`, `bindings.cpp`) — needs
      buy-in from whoever owns that code before touching it.
- [ ] Not wired into the SSE streaming path (`/simulate/online/stream` in
      `stream_manager.py`) yet — only the two blocking endpoints log today.
      Would need a per-run write hook added to `StreamSession`.
- [ ] `db.py` opens a fresh connection per call under a single process-wide
      lock, sized for the end-of-run bulk-write case (one INSERT batch per
      completed run). If per-tick streaming writes get added (previous
      bullet), revisit against the design doc's batched-commit policy
      (every 200 records / 50 ms) — the current approach doesn't scale to
      that write volume.

## UI (`sw/ui/`)

- [ ] **The single biggest gap between the design doc and reality.**
      `sw/ui/src/` is just `App.jsx` — a PnL/position line-chart demo
      connected to the SSE stream. FS-18 (marked *Essential*) calls for a
      live L2 order-book ladder/depth chart and a full order blotter
      (New/Partial Fill/Filled/Cancelled-Rejected lifecycle); neither exists
      in code at all. This is presumably Nikola's in-progress work (Discord:
      "filler for now") — not something to build without syncing with him
      first, but worth being clear-eyed that it's not close to done, not
      just polish-away-from-done.

## Testing / verification gaps

- [ ] `sim/` has run scripts for 6 of the 8 RTL testbenches in `tb/` —
      `tb/risk_gateway/risk_gateway_tb.sv` and `tb/rx_mac/rx_mac_tb.sv` exist
      but have no corresponding `sim/run_*.sh` script.
- [ ] Verilator isn't installed on every dev machine, so **none of the 8
      testbenches have a confirmed-passing record tracked anywhere** — this
      is a gap in verification, not a claim that they fail.
      `.github/workflows/ci.yml`'s RTL lint is `workflow_dispatch` (manual)
      only, so nothing runs automatically on push/PR either — there's no
      continuous verification of the RTL at all right now.
- [ ] Zero automated Python tests anywhere in the repo (no `test_*.py`
      for `routes.py`/`db.py`/`compile_manager.py`/`stream_manager.py`/
      `data_pipeline`). Everything on the software side has only ever been
      manually smoke-tested ad hoc — no CI job covers it.

## Process / tracking

- [ ] `.github/CODEOWNERS` still has placeholder usernames
      (`@owner-alpha`, `@owner-rxmac`, etc.) — never filled in with real
      GitHub handles, so it doesn't actually auto-assign reviewers. It's
      also **path-stale**: it references `/sw/market_sim/`,
      `/sw/matching_engine/`, `/sw/api/`, none of which match the real
      layout (`sw/engine/`, `sw/service/api/`, `sw/data_pipeline/`).
- [ ] `README.md`'s "Subsystem Owners" table is still completely empty,
      despite clear de facto ownership existing in the commit history
      (Victor: alpha engine/parser/tx-gen/order-book; rx_mac/risk-gateway
      per the `goldenow` branch; Minh: market sim/matching engine/API;
      presumably Nikola: UI). Worth filling in now that it's this clear.
- [ ] `sw/data_pipeline/src/cmd_L1_to_L3.py`'s `DatabaseL1Reader` class is
      an unimplemented stub (`read_ticks` is just `pass`) — low priority,
      since the pipeline only actually uses `CSVL1Reader` in practice, but
      it's dead scaffolding if nobody's building toward it.
