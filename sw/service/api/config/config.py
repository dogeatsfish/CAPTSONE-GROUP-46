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
COMPILER_DIR = (
    REPO_ROOT / "compiler"
)  # strategy-compiler sources (main_job, strategy_base, template)
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
STRATEGY_JOB_TEMPLATE = COMPILER_DIR / "src" / "user_strategy.job_template.cpp"
STRATEGY_MAIN_JOB_SRC = COMPILER_DIR / "src" / "main_job.cpp"
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
# accepts order entry over an OUCH socket. These are internal transport
# details of the C++ engine and are deliberately NOT surfaced in any API
# request/response schema, so front-end clients never deal with sockets,
# hosts, or ports. Adjust here if the ports collide with something else.
#
# These are the FPGA hardware defaults: ITCH market data is unicast to the
# board at 192.168.0.1:50001 (the RTL's SRC_IP), and OUCH order entry is
# received over UDP on the same port to match the FPGA's OUCH DST_PORT. Used
# by the blocking /simulate/online endpoint and the hardware test targets --
# anything meant to actually reach the board.
ONLINE_ITCH_ADDRESS = "192.168.0.1"
ONLINE_ITCH_PORT = 50001
ONLINE_OUCH_PORT = 50001
# Wall-clock pacing factor used when the request does not specify one.
# 0.0 = no pacing (return as fast as possible); 1.0 = true real time.
ONLINE_DEFAULT_TIME_SCALE = 1.0

# --- Live streaming demo (UI "Online mode", /simulate/online/stream) ---
# This is the LOOPBACK half of that endpoint's config (SimulationRequest.
# online_target picks between this and the FPGA addressing above; see
# stream_manager.build_online_config). Deliberately separate from the FPGA
# addressing: sending UDP to a real device's unicast IP (192.168.0.1) with no
# such host actually reachable can stall per-packet on ARP resolution
# depending on the host's network config (observed under WSL2), which made
# the "live" demo look hung rather than just slow whenever nothing was
# plugged in. Loopback avoids that entirely, and is the default.
ONLINE_STREAM_ITCH_ADDRESS = "127.0.0.1"
ONLINE_STREAM_ITCH_PORT = 26000
ONLINE_STREAM_OUCH_PORT = 26001

# Pacing for the streaming endpoint. 1.0 = true real time: simulated time
# elapsed matches wall-clock time elapsed 1:1, so a run stopped after N real
# seconds shows exactly N seconds of PnL-curve time, not a compressed/inflated
# span. This does mean a long dataset takes just as long to fully complete as
# it would live -- use the Stop button (see routes.py) rather than waiting out
# a multi-hour file if you don't need the whole thing.
ONLINE_STREAM_TIME_SCALE = 1.0

# --- Auto-fill toggle (online simulation) -------------------------------
# Set to 1 to force every aggressive order the engine submits (the local
# strategy's orders in the loopback demo, and inbound OUCH ENTER orders) to
# fill completely at its limit price, instead of only partially filling (or
# resting) against this dataset's thin, often one-sided book. 0 = off (only
# genuine book fills count). Applied to ALL online runs -- both the loopback
# stream and the hardware-addressed /simulate/online endpoint. Maps to
# OnlineSimulation::Config::auto_fill (see online_simulation.h) via the engine
# binding. THIS is the knob to flip.
#
# NOTE for real-hardware runs: auto_fill synthesizes fills the real book
# wouldn't support, so PnL is optimistic. Set this to 0 when you want a run to
# reflect only genuine fills against the actual board.
ONLINE_AUTO_FILL = 1

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
