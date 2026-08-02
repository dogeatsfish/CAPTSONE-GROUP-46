# Running the Simulation Dashboard

How to get the full stack running locally: the C++ engine's Python module,
the FastAPI service, and the React dashboard. Three pieces, two terminals.

```
engine_sim (C++, via pybind11)  ->  FastAPI service (:8000)  ->  React UI (:5173)
```

## Prerequisites

| Tool | Needed for | Notes |
|------|------------|-------|
| C++ toolchain (`g++`/Clang) | Building `engine_sim` | See [build-and-test.md](build-and-test.md) for the macOS/Linux split. |
| Python 3 + `pybind11` | Building `engine_sim` | Preinstalled in the [Dev Container](README.md). |
| Python packages `fastapi`, `uvicorn`, `pydantic` | Running the API | Installed below into a venv. |
| Node.js + `npm` | Running the UI | Any recent LTS version. |

## 1. Build the Python engine module

From `sw/engine`:

```bash
cd sw/engine
make pymodule
```

This produces `engine_sim*.so` in `sw/engine/`, which the API imports directly
(see `service/api/config/config.py`). On Linux, `make pymodule` needs the
manual build command instead — see
[build-and-test.md § Building the Python module](build-and-test.md#building-the-python-module--macos-vs-linux).

## 2. Set up the API service

From `sw/service`:

```bash
cd sw/service
python3 -m venv .venv
.venv/bin/pip install fastapi uvicorn pydantic
```

`.venv` at this path is the default the Makefile's online tests also expect
(`PY ?= ../service/.venv/bin/python`), so reuse it rather than creating a venv
elsewhere.

## 3. Set up the UI

From `sw/ui`:

```bash
cd sw/ui
npm install
```

## Running it

Two terminals, both left running.

**Terminal 1 — API** (from `sw/service/api/src`):

```bash
cd sw/service/api/src
../../.venv/bin/uvicorn app:app --reload
```

Serves on `http://127.0.0.1:8000`. Confirm it's up:

```bash
curl http://127.0.0.1:8000/datasets
# {"data_dir": ".../sw/data_pipeline/data", "datasets": ["synthetic_mbo_stream.bin"]}
```

**Terminal 2 — UI** (from `sw/ui`):

```bash
npm run dev
```

Open `http://localhost:5173`. The Vite dev server proxies `/simulate`,
`/datasets`, `/compile`, and `/runs` to the API on port 8000 (see
`vite.config.js`), so the two just need to both be running — no CORS setup
required.

## Using the dashboard

The top nav switches between three routed pages: **Online Simulation** (this
dashboard), **Strategy Compiler** (edit `on_market_update`, compile it to a
native binary, and run it against a dataset), and **Alpha Engine Compiler**
(edit `alpha_engine_core`, run it through an out-of-context Vivado synthesis,
and see utilization/timing — requires Vivado installed and on `PATH`; see the
in-page instructions on each page for specifics).

1. **Mode** — `Offline` runs `engine_sim.OfflineSimulation` end to end.
   `Online` runs `engine_sim.OnlineSimulation` over the engine's internal
   ITCH/OUCH sockets, live (see the note below).
2. **Data file** — pick from the toggle list, sourced from the `.bin` files in
   `sw/data_pipeline/data`. Prices aren't generated in the browser; this only
   selects which pre-built file the run reads.
3. **Run Simulation**:
   - `Offline` POSTs to `/simulate` (blocking) and renders the response once
     the whole run finishes.
   - `Online` opens `/simulate/online/stream` (SSE) instead and updates live:
     a **Top of Book** card (best bid/best ask) ticks every simulated second
     as market data replays, then the rest of the page renders from the
     terminal `complete` event once the run finishes.
   - **Final Results** — current PnL, compute time, max drawdown, Sharpe
     ratio, volatility (drawdown/Sharpe/volatility are computed API-side in
     `service/api/include/metrics.py` from the run's PnL curve; the engine
     itself only returns raw trades/PnL samples/compute time).
   - **PnL Curve** — realized, unrealized, and total PnL over simulated time.
   - **Order Blotter** — every filled trade, side-coded buy/sell.

> **Online mode currently shows zero trades.** `OnlineSimulation` broadcasts
> market data and opens an OUCH listener, but nothing auto-connects to send
> orders against it — unlike offline mode, it doesn't run the strategy
> internally. The Top of Book card updates live off the real market-data feed
> (that part doesn't need a connected client), but the run still completes
> with an empty blotter and a flat PnL curve. This is a real gap in the
> engine/API, not a UI bug — see `sw/engine/simulation/src/online_simulation.cpp`.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `ImportError: Could not import the compiled 'engine_sim' module` | Run `make pymodule` in `sw/engine` (step 1). |
| `ModuleNotFoundError: No module named 'fastapi'` (or `pydantic`/`uvicorn`) | Re-run step 2's `pip install` — make sure you're using `.venv/bin/pip`, not the system `pip`. |
| Dataset list is empty in the UI | Confirm `.bin` files exist in `sw/data_pipeline/data`; `GET /datasets` lists exactly what's there. |
| `Data file not found: .../service/<name>.bin` | Stale API image/process — `_resolve_data_file` now checks `DATA_DIR` first for a bare filename (fixed; previously only checked the service directory, so anything picked from the dataset dropdown 404'd). Rebuild/restart the service if you still see this. |
| UI shows "Simulation failed: ..." | Check the API terminal for the underlying engine error/traceback. |
| `Address already in use` on port 8000 or 5173 | Something else is bound to that port — stop it, or run `uvicorn app:app --reload --port 8001` and update `API_TARGET` in `sw/ui/vite.config.js` to match. |
