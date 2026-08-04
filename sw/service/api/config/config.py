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
STRATEGY_JOB_TEMPLATE = (
    ENGINE_DIR / "simulation" / "src" / "user_strategy.job_template.cpp"
)
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

# Pacing for the streaming endpoint. The engine samples PnL once per SIMULATED
# second, so a factor of 1.0 (true real time) would make telemetry arrive at
# roughly one event per wall-clock second -- but the bundled dataset's replay
# spans ~19,200 simulated seconds (~5.3 real hours) and the default strategy
# stays flat for most of that before its PnL moves late in the replay, so 1.0
# makes the live demo look inert for a very long time. 0.001 (~1000x) finishes
# the full replay in well under 30s while still streaming visibly rather than
# jumping straight to the end -- use the new stop endpoint (see routes.py) if
# even that's more than you want to sit through.
ONLINE_STREAM_TIME_SCALE = 0.001

# Cap on any single inter-record sleep (OnlineSimulation::Config::max_sleep_ns),
# in nanoseconds. The engine default (5 real seconds) is sized for the
# hardware target's true real-time pacing; at loopback's 1000x speed it instead
# makes real market data's quiet stretches show up as multi-second dead pauses
# in the live UI, immediately followed by a burst of catch-up samples once
# data resumes -- visibly "jumpy" rather than smooth. 150ms keeps the same
# relative bursty/quiet shape (this is still a real-time-paced replay, not a
# fixed-cadence tick) while making the worst-case pause barely noticeable.
ONLINE_STREAM_MAX_SLEEP_NS = 150_000_000

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
