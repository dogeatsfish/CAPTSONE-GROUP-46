#!/usr/bin/env bash
# One-command software-side dev startup: backend (docker compose) + UI (vite),
# torn down together on exit. Doesn't touch the board -- see
# vivado/synthesis_implementation.md and docs/connection-test.md for that.
#
# Offline/loopback simulation only. For online_target="hardware" (talking to
# the real board), use dev-hardware.sh instead: Docker Desktop's networking
# is isolated from the host's physical NIC, so a Dockerized backend can't
# reach the board even with net_setup.sh's static ARP entry in place.
#
# Usage: ./dev.sh   (from sw/, or anywhere -- it cd's to its own directory)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

API_URL="http://127.0.0.1:8000/"

fail() {
    echo
    echo "==> $1" >&2
    docker compose down >/dev/null 2>&1
    exit 1
}

cleanup() {
    echo
    echo "==> Shutting down -- stopping backend (docker compose down)..."
    docker compose down >/dev/null 2>&1
}
trap cleanup EXIT

command -v docker >/dev/null 2>&1 \
    || fail "Docker isn't installed or not on PATH. Install Docker Desktop: https://www.docker.com/products/docker-desktop/"

docker info >/dev/null 2>&1 \
    || fail "Docker daemon isn't running. Start Docker Desktop (or the Docker service) and try again."

command -v npm >/dev/null 2>&1 \
    || fail "npm isn't installed or not on PATH. Install Node.js: https://nodejs.org/"

[ -d "ui/node_modules" ] \
    || fail "ui/node_modules is missing. Run 'npm install' inside sw/ui/ first."

echo "==> Starting backend (docker compose up --build)..."
docker compose up --build -d \
    || fail "docker compose failed to start the backend. Run 'docker compose up --build' manually in sw/ to see the full error."

echo "==> Waiting for the backend to answer at $API_URL..."
ready=0
for _ in $(seq 1 60); do
    if curl -sf "$API_URL" >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 1
done

if [ "$ready" -ne 1 ]; then
    echo "==> Backend never came up. Last 40 lines of its logs:" >&2
    docker compose logs --tail=40 api >&2
    fail "Backend didn't respond at $API_URL within 60s -- see logs above."
fi

echo "==> Backend is up."
echo "==> Starting the UI dev server (npm run dev). Ctrl-C stops both."
(cd ui && npm run dev)
