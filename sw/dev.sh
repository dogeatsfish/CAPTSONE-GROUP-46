#!/usr/bin/env bash
# One-command dev startup: builds engine_sim, runs the FastAPI backend
# natively (uvicorn in sw/service/.venv) plus the UI (vite), and tears both
# down together on Ctrl-C. Works for every mode -- offline, loopback online,
# and the real board.
#
# The backend runs natively so it shares the host's real network stack --
# that is what lets its UDP traffic reach the board through the static ARP
# entry `setup/net_setup.sh` adds for 192.168.0.1, and lets the board's
# replies come back.
#
# Platform: macOS, Linux, or WSL2 (on WSL2 also set networkingMode=mirrored
# in .wslconfig, Windows 11 22H2+, so WSL shares the host's NIC instead of
# NATing through its own adapter). Native Windows is not supported. For the
# board, run `setup/net_setup.sh` first.
#
# Usage: ./dev.sh              (from sw/, or anywhere -- it cd's to its own directory)
#        ./dev.sh --no-ui     backend only; skips the npm checks and the Vite
#                             dev server, and holds until Ctrl-C
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

START_UI=1
for arg in "$@"; do
    case "$arg" in
        --no-ui|--backend-only) START_UI=0 ;;
        -h|--help)
            echo "Usage: ./dev.sh [--no-ui]"
            echo "  --no-ui   start the backend only and hold until Ctrl-C"
            exit 0
            ;;
        *) echo "Unknown option: $arg (try --help)" >&2; exit 2 ;;
    esac
done

API_URL="http://127.0.0.1:8000/"
UVICORN_PID=""

fail() {
    echo
    echo "==> $1" >&2
    [ -n "$UVICORN_PID" ] && kill "$UVICORN_PID" >/dev/null 2>&1
    exit 1
}

cleanup() {
    echo
    echo "==> Shutting down -- stopping the backend..."
    [ -n "$UVICORN_PID" ] && kill "$UVICORN_PID" >/dev/null 2>&1
}
trap cleanup EXIT

case "$(uname -s)" in
    Linux*|Darwin*) : ;;
    *)
        fail "This looks like native Windows ($(uname -s)), not macOS/Linux/WSL2. \
The engine's Makefile only compiles hardware/online support off Windows_NT \
(engine/Makefile builds the Python module with -DCT_NO_ONLINE_SIM there) -- \
run this from WSL2 (with \"mirrored\" networking mode) or a macOS/Linux box \
instead."
        ;;
esac

command -v python3 >/dev/null 2>&1 \
    || fail "python3 isn't installed or not on PATH."

command -v g++ >/dev/null 2>&1 \
    || fail "g++ isn't installed or not on PATH (needed to build the engine's Python module)."

if [ "$START_UI" -eq 1 ]; then
    command -v npm >/dev/null 2>&1 \
        || fail "npm isn't installed or not on PATH. Install Node.js: https://nodejs.org/ (or run with --no-ui)"

    [ -d "ui/node_modules" ] \
        || fail "ui/node_modules is missing. Run 'npm install' inside sw/ui/ first (or run with --no-ui)."
fi

# sw/service/.venv, not sw/.venv: engine/Makefile's online tests default to
# PY ?= ../service/.venv/bin/python, and docs/testing/system-testing.md's manual
# setup uses the same path -- reusing it here means this script, the
# Makefile's test-book generation, and the docs all agree on one venv
# instead of three.
if [ ! -d "service/.venv" ]; then
    echo "==> Creating a venv at sw/service/.venv..."
    python3 -m venv service/.venv || fail "Failed to create the venv."
fi
PY="./service/.venv/bin/python"

echo "==> Installing service dependencies..."
"$PY" -m pip install --quiet --disable-pip-version-check -r service/requirements.txt \
    || fail "pip install failed -- see the error above."

echo "==> Building the engine's Python module (make pymodule)..."
( cd engine && make pymodule ) \
    || fail "Building engine_sim failed -- see the error above. Common cause: pybind11 not installed for the 'python3' on PATH (pip install pybind11 --user, or into a python3 pybind11 can see)."

# engine/Makefile always builds against whatever 'python3' resolves to on
# PATH, so this only actually imports if the venv (above) was created from
# that same python3 -- true by construction since we just ran
# `python3 -m venv .venv`, but worth a clear error if it's somehow not.
if ! "$PY" -c "import sys; sys.path.insert(0, 'engine'); import engine_sim" 2>/dev/null; then
    fail "engine_sim built, but the venv's python can't import it -- likely a python3 version mismatch between what built it and service/.venv. Delete service/.venv and re-run this script."
fi

echo "==> Starting the backend natively (uvicorn) so it shares the host's real network stack..."
( cd service/src && exec "../.venv/bin/uvicorn" app:app --host 0.0.0.0 --port 8000 ) \
    > /tmp/commontrader-uvicorn.log 2>&1 &
UVICORN_PID=$!

echo "==> Waiting for the backend to answer at $API_URL..."
ready=0
for _ in $(seq 1 30); do
    if curl -sf "$API_URL" >/dev/null 2>&1; then
        ready=1
        break
    fi
    if ! kill -0 "$UVICORN_PID" 2>/dev/null; then
        break # process already died -- stop waiting, go report it below
    fi
    sleep 1
done

if [ "$ready" -ne 1 ]; then
    echo "==> Backend never came up. Its log:" >&2
    cat /tmp/commontrader-uvicorn.log >&2
    fail "Backend didn't respond at $API_URL within 30s -- see the log above."
fi

echo "==> Backend is up."
echo "==> Reminder: setup/net_setup.sh must have already been run for this host session"
echo "    (static IP + ARP entry for the board) -- see docs/connection-test.md."
if [ "$START_UI" -eq 1 ]; then
    echo "==> Starting the UI dev server (npm run dev). Ctrl-C stops both."
    (cd ui && npm run dev)
else
    echo "==> Backend only (--no-ui). API at $API_URL"
    echo "==> Start the UI yourself with: cd ui && npm run dev"
    echo "==> Ctrl-C to stop the backend."
    wait "$UVICORN_PID"
fi
