import os
import sys
from pathlib import Path

# --- Directory layout (this file lives in service/api/config) ---
CONFIG_DIR = Path(__file__).resolve().parent  # service/api/config
API_DIR = CONFIG_DIR.parent  # service/api
INCLUDE_DIR = API_DIR / "include"  # service/api/include
SERVICE_ROOT = API_DIR.parent  # service
REPO_ROOT = SERVICE_ROOT.parent  # sw
ENGINE_DIR = REPO_ROOT / "engine"
DATA_DIR = REPO_ROOT / "data_pipeline" / "data"
DEFAULT_DATA_FILE = DATA_DIR / "synthetic_mbo_stream.bin"
REPO_TOP = REPO_ROOT.parent  # repo root (sibling of sw/, vivado/, rtl/)

# --- Alpha Engine compile pipeline (FS-16 first slice: OOC synth + report) ---
# Vivado executable; override via env var if it isn't on PATH.
VIVADO_BIN = os.environ.get("VIVADO_BIN", "vivado")
COMPILE_TCL_SCRIPT = REPO_TOP / "vivado" / "scripts" / "compile_alpha_engine.tcl"
# Per-job workspaces (submitted source + Vivado logs/reports). Not committed --
# see .gitignore.
COMPILE_JOBS_DIR = SERVICE_ROOT / "compiler_jobs"
COMPILE_JOBS_DIR.mkdir(parents=True, exist_ok=True)

# --- Software strategy compile pipeline (UI "compiler" section, sw-only) ---
# g++ (or another compiler) used to build a per-job native simulation binary
# from the submitted on_market_update body; override via env var if it isn't
# on PATH.
CXX_BIN = os.environ.get("CXX_BIN", "g++")
STRATEGY_JOB_TEMPLATE = ENGINE_DIR / "simulation" / "src" / "user_strategy.job_template.cpp"
STRATEGY_MAIN_JOB_SRC = ENGINE_DIR / "simulation" / "src" / "main_job.cpp"
# Wall-clock caps on the compile and run subprocesses (basic isolation tier --
# same trust model as the Vivado CompileJob above, not a container sandbox).
STRATEGY_COMPILE_TIMEOUT_S = float(os.environ.get("STRATEGY_COMPILE_TIMEOUT_S", "15"))
STRATEGY_RUN_TIMEOUT_S = float(os.environ.get("STRATEGY_RUN_TIMEOUT_S", "15"))

# --- Persistent run logging (FS-15 -- see db.py for current scope) ---
# Override via env var so a containerized deployment can point this at a
# mounted volume outside the code tree (see sw/Dockerfile, docker-compose.yml).
DB_PATH = Path(os.environ.get("CT_DB_PATH", str(SERVICE_ROOT / "commontrader.db")))

# --- Online (real-time) simulation transport (server-side ONLY) ---
# The online simulation broadcasts market data over a UDP (ITCH) socket and
# accepts order entry over a TCP (OUCH) socket. These are internal transport
# details of the C++ engine and are deliberately NOT surfaced in any API
# request/response schema, so front-end clients never deal with sockets,
# hosts, or ports. Adjust here if the ports collide with something else.
ONLINE_ITCH_ADDRESS = "127.0.0.1"
ONLINE_ITCH_PORT = 26000
ONLINE_OUCH_PORT = 26001
# Wall-clock pacing factor used when the request does not specify one.
# 0.0 = no pacing (return as fast as possible); 1.0 = true real time.
ONLINE_DEFAULT_TIME_SCALE = 0.0

# Pacing for the streaming endpoint. The engine samples PnL once per SIMULATED
# second, so a factor of 1.0 (true real time) makes telemetry arrive at roughly
# one event per wall-clock second -- the cadence the live UI expects. Lower it
# (e.g. 0.1) to fast-forward the replay while still streaming.
ONLINE_STREAM_TIME_SCALE = 1.0

# Make the schema modules and the compiled engine importable.
for _path in (INCLUDE_DIR, ENGINE_DIR):
    if str(_path) not in sys.path:
        sys.path.insert(0, str(_path))

try:
    import engine_sim  # re-exported for the routes to use
except ImportError as exc:  # pragma: no cover - build/environment issue
    raise ImportError(
        f"Could not import the compiled 'engine_sim' module from {ENGINE_DIR}. "
        "Build it first: run `make pymodule` in the engine/ directory."
    ) from exc
