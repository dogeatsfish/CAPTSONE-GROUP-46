# Containerizes the software side only: the C++ matching engine (engine/)
# and the FastAPI service (service/api/). This is deliberately NOT meant to
# cover rtl/ or vivado/ -- Vivado needs a license, a GUI, and direct USB/JTAG
# access to the physical board, none of which containerize in a way that's
# worth the effort here. Build/program the FPGA natively; run the
# engine+service in here.
#
# Bonus: this sidesteps the whole cross-platform mess documented in TODO.md.
# Inside a Linux container, engine/simulation/src/online_simulation.cpp's
# POSIX socket headers (sys/socket.h etc.) just exist -- no Winsock2 port
# needed, and everyone gets the exact same compiled engine_sim regardless of
# whether their host is Windows, macOS, or Linux.
#
# Build (from the sw/ directory):
#   docker build -t commontrader-service .
# Run:
#   docker run --rm -p 8000:8000 -v commontrader-data:/app/data \
#       -e CT_DB_PATH=/app/data/commontrader.db commontrader-service
# Or just: docker compose up --build   (see docker-compose.yml, which sets
# all of this up already)

# ---- Stage 1: compile engine_sim against this stage's own Python ----------
FROM python:3.12-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir pybind11

WORKDIR /app/engine
COPY engine/ ./
RUN make pymodule

# ---- Stage 2: runtime image -- FastAPI service + the compiled module ------
FROM python:3.12-slim AS runtime

WORKDIR /app

COPY service/api/requirements.txt ./service/api/requirements.txt
RUN pip install --no-cache-dir -r ./service/api/requirements.txt

COPY service/ ./service/
COPY data_pipeline/data/ ./data_pipeline/data/
COPY --from=builder /app/engine/engine_sim*.so ./engine/

# A dedicated, code-free directory for anything that needs to survive a
# container rebuild (right now: just the SQLite db -- see config.py's
# CT_DB_PATH override and docker-compose.yml's volume mount). Deliberately
# NOT declared as a Dockerfile VOLUME over /app/service itself: that would
# make a named volume "adopt" today's code on first run and then silently
# ignore all future image rebuilds.
RUN mkdir -p /app/data

EXPOSE 8000
WORKDIR /app/service/api/src
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
