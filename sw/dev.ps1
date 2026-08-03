# One-command software-side dev startup: backend (docker compose) + UI (vite),
# torn down together on exit. Doesn't touch the board -- see
# vivado/synthesis_implementation.md and docs/connection-test.md for that.
#
# Offline/loopback simulation only -- there is no hardware-target equivalent
# of this script for native Windows. Docker Desktop's networking is isolated
# from the host's physical NIC (a Dockerized backend can't reach the board
# even with net_setup.ps1's static ARP entry in place), AND engine/Makefile
# only compiles online/hardware support when NOT building on Windows_NT, so
# native Windows can't do hardware-target testing at all, containerized or
# not. Use dev-hardware.sh from WSL2 (mirrored networking mode) or a
# macOS/Linux box for that.
#
# Usage: .\dev.ps1   (from sw/, or anywhere -- it Set-Location's to its own directory)

Set-Location -Path $PSScriptRoot

$ApiUrl = "http://127.0.0.1:8000/"

function Write-Fail($msg) {
    Write-Host ""
    Write-Host "==> $msg" -ForegroundColor Red
    docker compose down > $null
    exit 1
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Fail "Docker isn't installed or not on PATH. Install Docker Desktop: https://www.docker.com/products/docker-desktop/"
}

docker info > $null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Docker daemon isn't running. Start Docker Desktop and try again."
}

if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    Write-Fail "npm isn't installed or not on PATH. Install Node.js: https://nodejs.org/"
}

if (-not (Test-Path "ui/node_modules")) {
    Write-Fail "ui/node_modules is missing. Run 'npm install' inside sw/ui/ first."
}

Write-Host "==> Starting backend (docker compose up --build)..." -ForegroundColor Cyan
docker compose up --build -d
if ($LASTEXITCODE -ne 0) {
    Write-Fail "docker compose failed to start the backend. Run 'docker compose up --build' manually in sw/ to see the full error."
}

Write-Host "==> Waiting for the backend to answer at $ApiUrl..." -ForegroundColor Cyan
$ready = $false
for ($i = 0; $i -lt 60; $i++) {
    try {
        Invoke-WebRequest -Uri $ApiUrl -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop | Out-Null
        $ready = $true
        break
    } catch {
        Start-Sleep -Seconds 1
    }
}

if (-not $ready) {
    Write-Host "==> Backend never came up. Last 40 lines of its logs:" -ForegroundColor Red
    docker compose logs --tail=40 api
    Write-Fail "Backend didn't respond at $ApiUrl within 60s -- see logs above."
}

Write-Host "==> Backend is up." -ForegroundColor Green
Write-Host "==> Starting the UI dev server (npm run dev). Ctrl-C stops both." -ForegroundColor Cyan

Push-Location ui
try {
    npm run dev
} finally {
    Pop-Location
    Write-Host ""
    Write-Host "==> Shutting down -- stopping backend (docker compose down)..." -ForegroundColor Cyan
    docker compose down > $null
}
