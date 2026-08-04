#!/usr/bin/env bash
# Backend + UI startup for testing against the REAL board (online_target =
# "hardware"), as opposed to dev.sh's Docker-based backend.
#
# Why this exists instead of just using dev.sh: Docker Desktop runs
# containers inside its own virtual network (a VM, on Windows/macOS). The
# backend's UDP traffic to the board never reaches the host's physical NIC or
# the static ARP entry `setup/net_setup.sh` adds for 192.168.0.1, and the
# board's replies never reach the container either -- online mode still
# "works" against Docker (the container can loop packets to itself), but
# hardware mode silently gets no traffic. This script runs the FastAPI
# service natively instead, so it shares the host's real network stack.
#
# Platform: needs a real POSIX build (engine/Makefile only compiles online
# support -- ONLINE_SRCS -- when $(OS) isn't Windows_NT; native Windows
# builds pymodule with -DCT_NO_ONLINE_SIM and can't do hardware mode at all,
# Docker or not). That means macOS, Linux, or WSL2 -- and on WSL2 you also
# need "mirrored" networking mode (Windows 11 22H2+, set networkingMode=mirrored
# in .wslconfig) so WSL shares the host's NIC instead of NATing through its
# own virtual adapter. Run `setup/net_setup.sh` first either way.
#
# Usage: ./dev-hardware.sh   (from sw/, or anywhere -- it cd's to its own directory)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

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
The engine's Makefile can't build hardware/online support there \
(engine/Makefile compiles with -DCT_NO_ONLINE_SIM on Windows_NT, no way \
around it without a POSIX sockets layer) -- run this from WSL2 (with \
\"mirrored\" networking mode) or a macOS/Linux box instead. For \
offline/loopback-only work, ./dev.ps1 is fine on native Windows."
        ;;
esac

command -v python3 >/dev/null 2>&1 \
    || fail "python3 isn't installed or not on PATH."

command -v g++ >/dev/null 2>&1 \
    || fail "g++ isn't installed or not on PATH (needed to build the engine's Python module)."

command -v npm >/dev/null 2>&1 \
    || fail "npm isn't installed or not on PATH. Install Node.js: https://nodejs.org/"

[ -d "ui/node_modules" ] \
    || fail "ui/node_modules is missing. Run 'npm install' inside sw/ui/ first."

# sw/service/.venv, not sw/.venv: engine/Makefile's online tests default to
# PY ?= ../service/.venv/bin/python (see build-and-test.md), and
# run-dashboard.md's manual setup uses the same path -- reusing it here means
# this script, `make test-online`/`socket-test`, and the manual docs all
# agree on one venv instead of three.
if [ ! -d "service/.venv" ]; then
    echo "==> Creating a venv at sw/service/.venv..."
    python3 -m venv service/.venv || fail "Failed to create the venv."
fi
PY="./service/.venv/bin/python"

echo "==> Installing service/api dependencies..."
"$PY" -m pip install --quiet --disable-pip-version-check -r service/api/requirements.txt \
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
( cd service/api/src && exec "../../.venv/bin/uvicorn" app:app --host 0.0.0.0 --port 8000 ) \
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
echo "==> Starting the UI dev server (npm run dev). Ctrl-C stops both."
(cd ui && npm run dev)
