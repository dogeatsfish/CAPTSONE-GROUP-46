# TODO

Known gaps, tracked in one place instead of scattered across Discord/in-code
comments/the design doc. Not a replacement for GitHub Issues if the team wants
those later — just a starting checklist. Update this as items land or new
gaps are found; a stale TODO list is worse than none.

As of the HW integration merge (PR #16), the hardware team maintains much more
rigorous tracking of their own than this file did — `docs/known_limitations.md`
(pinned-by-testbench defect tracking), `docs/hw_sw_interface.md`, and
`docs/hw_sw_transport_gaps.md` (both explicitly addressed to the software lead)
are now authoritative for their scope. This file defers to them rather than
duplicating; see below for the summary and what to actually do about it.

## HW <-> SW integration — the real next thing (`docs/hw_sw_*.md`)

**Read `docs/hw_sw_transport_gaps.md` and `docs/hw_sw_interface.md` in full —
this section is a pointer, not a substitute.** Written explicitly for
"software lead." Bottom line: the FPGA and the online simulation
(`sw/engine/simulation/src/online_simulation.cpp` etc.) have never actually
been connected, and the two sides were built against assumptions that were
never reconciled. Of 11 identified transport gaps, most are flagged as
blockers:

- [ ] **The fundamental question to settle first, per the doc itself:** was
      `OnlineSimulation` ever intended to talk to the real FPGA, or is it a
      pure-software demo (TCP client) with the board integration being
      separate, not-yet-written host code? Everything else follows from the
      answer. Needs a team decision, not a code change.
- [ ] OUCH order entry: FPGA emits **UDP**, `OnlineSimulation` listens
      **TCP**, on mismatched ports (50001 vs 26001) — a UDP datagram cannot
      reach a TCP listener at all.
- [ ] The `'O'` Enter Order message is a completely different format on each
      side: RTL's is real OUCH 5.0 (47 B, integer price, ASCII ticker,
      big-endian), `protocol.cpp`'s is a custom 26-byte encoding with
      IEEE-754 double price/size. Same story for `'A'` Add Order: **same
      length (36 B) on both sides but a different byte layout** — silently
      corrupts rather than rejecting.
- [ ] `protocol.cpp`'s `'C'` Cancel (20 B) doesn't match either RTL message;
      per `hw_sw_interface.md` it must map to ITCH `'D'` Delete, not `'X'`
      Cancel (a `C`→`X` mapping happens to work today by accident, and would
      silently start producing wrong results the moment a partial cancel is
      emitted).
- [ ] `OnlineSimulation` broadcasts ITCH to `127.0.0.1` (loopback — can never
      reach a NIC/cable) and omits the MoldUDP64 header the RTL parser
      hard-strips 20 bytes for. `sim/csv_to_itch.py` (new in PR #16) is a
      working reference encoder with the correct framing — port it rather
      than re-deriving the format.
- [ ] The FPGA has no ingress path for OUCH acknowledgements at all — it's
      fire-and-forget. Any design assuming the client acks orders needs
      rethinking (or that's simply out of scope, per the fundamental
      question above).
- [ ] `tx_mac_core`'s `DST_MAC` is a placeholder (`AA:BB:CC:DD:EE:FF`) that
      belongs to no real device — real NICs silently drop non-matching
      frames in hardware. HW-side fix (broadcast MAC for bring-up is the
      recommended first step), but affects whether SW can ever receive
      anything real to test against.
- [ ] **Symbol identity is OPEN**: `cmd_L1_to_L3.py`'s CSV output has no
      symbol column at all (single unnamed instrument, max 2 concurrent live
      orders), but the RTL maintains 5 independent per-asset books. Someone
      needs to decide: add a real symbol column to the SW pipeline (correct,
      requires pipeline work), or accept that only 1 of 5 books is ever
      exercised. `sim/csv_to_itch.py` currently round-robins symbols as a
      test-harness choice, which is explicitly called out as not the same
      thing as a product decision.
- [ ] **Numeric scaling is OPEN**: the RTL's 4-implied-decimal price scaling
      only has 1.43x headroom against the observed data's price range
      (uint32, $301k observed vs. ~$429k theoretical ceiling) — not
      comfortable. Needs either a confirmed bound on price range or a
      smaller scale factor; `PRICE_W` is a shared `ct_pkg` parameter, so this
      isn't a local edit.
- [ ] Confirmed independently (matches what was already tracked here):
      `online_simulation.cpp` is POSIX-only, won't build natively on
      Windows. Still not worth a Winsock2 port — see the Software Engine
      section below, this was already decided and the reasoning holds
      regardless of the transport-format issues above.

## Hardware (`rtl/`)

Resolved by PR #16 (verify against `docs/known_limitations.md` if in doubt,
don't re-derive here): `commontrader_top.sv`'s MMCM/RX+TX CDC
FIFO/TX MAC instantiation, XDC pin/timing constraints
(`vivado/constraints/`), and the TX CDC FIFO overflow defect (`known_limitations.md`
L1, now pinned by a regression test).

- [x] Confirmed actual Vivado `-part` string for the Alinx AX7A200B: Victor
      confirmed `xc7a200tfbg484-2` (independently corroborated — it's in the
      header comment of the new `commontrader_pins.xdc`). Updated in
      `vivado/scripts/compile_alpha_engine.tcl` and re-verified with a real
      OOC synthesis run.
- [ ] `pre_trade_risk_gateway.sv`'s Blacklist + CRC-drop checks are **still
      not implemented** (confirmed unchanged in PR #16's diff) — this is now
      formally tracked as `known_limitations.md` L3, with a pinning
      testbench (`commontrader_top_tb` check T9) that will need its
      expectation flipped once these land. Per Victor: don't chase this
      further right now, HW team is aware.
- [ ] `known_limitations.md` L4 (approved orders can be dropped without
      backpressure once the rate limiter isn't the binding constraint) and
      L2 (sustained order rate is ~1000/s by design, not the wire's 1.09M/s
      ceiling) are both informational/by-design per that doc — no action,
      just don't misquote the wire ceiling as the system's throughput in
      anything user-facing.

## Software engine (`sw/engine/`)

- [x] ~~Port `online_simulation.cpp`/`.h` to Winsock2 for native Windows
      builds~~ — **decided against.** `sw/Dockerfile` fully covers this: the
      container compiles `online_simulation.cpp` in with no
      `CT_NO_ONLINE_SIM` restriction at all (real Linux, real POSIX
      sockets), so anyone needing `OnlineSimulation` on a Windows/macOS host
      just runs the service in Docker. Not worth a real Winsock2 port for
      the marginal case of the bare CLI harnesses (`make test-online`/
      `make socket-test`) running natively on Windows outside the container.
      Independently confirmed by `docs/hw_sw_transport_gaps.md` #10/#11.
      **Caveat found 2026-08-02:** this holds for loopback online-mode
      testing (container talking to itself), but NOT for `online_target =
      "hardware"` against the real board -- Docker Desktop's networking is
      an isolated VM, so a Dockerized backend never reaches the host's
      physical NIC/static-ARP setup, and the board's replies never reach the
      container. `sw/dev-hardware.sh` works around it by running the service
      natively on macOS/Linux/WSL2 instead, but that still leaves native
      Windows with zero hardware-target path (`CT_NO_ONLINE_SIM` at compile
      time, container or not). Worth revisiting if native-Windows
      hardware-target support actually matters for the team.
- [x] `engine_sim.cpython-314-darwin.so` was committed to git — resolved via
      PR #15 (merged), which removed it along with 3 other stray compiled
      test binaries (`socket_test`, `stress_orderbook`, `test_online`) that
      shouldn't have been tracked either. Also added a VS Code Dev Container
      (`sw/.devcontainer/`) for engine development — a real Ubuntu 24.04
      environment with gcc-13/gdb/valgrind, complementary to `sw/Dockerfile`
      (that one runs the *service*; this one is for editing/building/
      debugging the C++ engine natively inside VS Code).
- [ ] `sw/data_pipeline/src/cmd_L1_to_L3.py` needs a symbol column added if
      the team decides that way on the "Symbol identity" item above — see
      the HW<->SW integration section. Directly affects whether FS-15's DB
      schema (`db.py`) ever needs a symbol/asset column too.

## Compile API (`sw/service/api/`, `vivado/scripts/compile_alpha_engine.tcl`)

- [x] No UI existed for the `/compile` (Alpha Engine hardware synthesis)
      endpoint at all — `compile_manager.py`/`CompileRequest` backed a route
      nothing in the frontend called. Added
      `sw/ui/src/pages/AlphaEngineCompilerPage.jsx` (third routed page,
      mirrors the Strategy Compiler's edit/run/stream-log pattern), source
      editor pre-filled with the shipped `alpha_engine_core.sv`. Requires
      Vivado on the host running the API — confirmed it fails cleanly (SSE
      `error` event, no crash) when Vivado isn't installed.
- [ ] Currently out-of-context (OOC) synthesis + report only — no full
      bitstream generation, no DFX partial reconfiguration, no JTAG board
      flash. The top-level completeness blocker is now resolved (PR #16),
      so a full-chip build flow is more realistic to attempt than it was —
      but this hasn't been built yet, just unblocked.
- [ ] Once attempting a full-chip build, revisit whether NF-3's 80%
      device-wide utilization budget should be checked automatically here
      (not meaningful for the current OOC-only flow, which only synthesizes
      the sandbox module in isolation).

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
- [x] Wired into the SSE streaming path (`/simulate/online/stream` in
      `stream_manager.py`) — `StreamSession._run` now calls the same
      best-effort `db.log_run` as the blocking endpoints once the engine
      thread finishes.
- [ ] `db.py` opens a fresh connection per call under a single process-wide
      lock, sized for the end-of-run bulk-write case (one INSERT batch per
      completed run). If per-tick streaming writes get added (previous
      bullet), revisit against the design doc's batched-commit policy
      (every 200 records / 50 ms) — the current approach doesn't scale to
      that write volume.
- [ ] See the symbol-identity item above — if the data pipeline gains a real
      symbol column, this schema likely needs one too.

## UI (`sw/ui/`)

- [x] Online mode's "live" telemetry was never actually wired up — it POSTed
      to the blocking `/simulate/online` and just waited for the whole run,
      same as offline mode, even though `/simulate/online/stream` (SSE) was
      fully built on the backend. Rewired `OnlineDemoPage`'s Online mode to
      use the existing stream instead; the "complete" SSE event now also
      carries the full `trades`/`pnl_curve`/`metrics` (previously just
      `total_trades`/`compute_time_us`) so the rest of the page (PnL chart,
      results, blotter) renders the same way it does for offline mode.
- [x] Added a live L1 top-of-book readout (`TopOfBook.jsx`) driven by
      `best_bid`/`best_ask`, now threaded through
      `OrderBook::get_l1_state()` -> `OnlineSimulation::SampleCallback` (new
      second arg) -> pybind11 -> `stream_manager.py`'s `"pnl"` SSE event.
      Team decision: L1 only, not the full FS-18 L2/L3 ladder or an
      order-lifecycle blotter (New/Partial/Filled/Cancelled/Rejected) —
      those remain unbuilt and are still Nikola's territory; don't start
      them without syncing first.
- [x] Found and fixed while testing the above: `_resolve_data_file` in
      `routes.py` resolved relative filenames against the *service*
      directory, not `DATA_DIR` — so selecting anything from the dataset
      dropdown (which sends bare filenames straight from `/datasets`) 404'd,
      across every mode (offline, online, and the new stream), not just
      online. Pre-existing bug, unrelated to this round of changes; now
      tries `DATA_DIR` first and falls back to the old service-relative
      behavior for an explicit path.

## Testing / verification gaps

- [x] `sim/` now has run scripts for all 8 RTL testbenches (PR #16 added the
      2 that were missing: `risk_gateway`, `rx_mac`), plus a proper
      regression harness (`sim/regression_crv.sh`, `sim/run_all_tb.sh`,
      `sim/README.md` documents the whole flow, both Verilator and Vivado
      xsim supported). Per Victor: team-wide regressions are all passing,
      and there's a bitstream with timing closed.
- [ ] `.github/workflows/ci.yml`'s RTL lint is still `workflow_dispatch`
      (manual) only, so nothing runs automatically on push/PR — worth
      wiring an automatic job at some point even though the manual
      regressions are passing today.
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
- [x] ~~`README.md`'s "Subsystem Owners" table is empty~~ — per Victor,
      team-wide consensus is this table is irrelevant and not worth filling
      in. Leaving it as-is rather than doing unrequested work.
- [ ] `sw/data_pipeline/src/cmd_L1_to_L3.py`'s `DatabaseL1Reader` class is
      an unimplemented stub (`read_ticks` is just `pass`) — low priority on
      its own, since the pipeline only actually uses `CSVL1Reader` in
      practice, but now entangled with the symbol-identity decision above
      if the pipeline gets real rework.
- [x] Docker install instructions — added to the root `README.md`
      ("Don't have Docker yet?"): Docker Desktop for Windows/macOS, Docker
      Engine for Linux, plus the `docker info` sanity check.
