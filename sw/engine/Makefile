# Makefile for the trading engine
# Modules:
#   shared/           - common structs (Order, Trade, L1State, FillReport, OnlineConfig)
#   match/            - OrderBook matching engine
#   network/          - ITCH/OUCH wire protocol (protocol.h/.cpp)
#   simulation/include/  - simulation headers (offline/online sim, online_config, user_strategy)
#   simulation/src/      - OfflineSimulation / OnlineSimulation + trading_context (fixed Strategy machinery)
#   simulation/templates/- trading_template (editable on_market_update strategy body)
#   tests/src/test.cpp   - online (real-time) CLI entry point (online_run)
#   tests/include/test.h - TestConfig (INI decoder, used only by test.cpp)
#   bindings/            - pybind11 wrapper exposing the simulation to Python
#   ../compiler/         - strategy-compiler entry point (main_job, job template)
#
# Targets:
#   make            -> build the real-time CLI binary (online_run)
#   make run        -> build + run the CLI (defaults, or FILE=<config.ini> to
#                      run a config file, or FILE=<mbo.bin> SCALE=<x>)
#   make pymodule   -> build the importable Python extension (engine_sim*.so)
#   make clean      -> remove all build artifacts

CXX      := g++
CXXFLAGS := -std=c++17 -O2 -Wall -Wextra

# Per-module include directories (headers are referenced by bare name)
INCLUDES := -Ishared/include -Imatch/include -Isimulation/include -Inetwork/include -Itests/include

# Core engine sources shared by both the CLI and the Python module.
# OFFLINE_CORE_SRCS has no socket usage and is portable as-is; ONLINE_SRCS
# (real-time ITCH/OUCH replay) uses POSIX sockets (sys/socket.h etc.) that
# don't exist on native Windows/MinGW without a Winsock2 port -- see the
# Windows branch of the pymodule target below.
OFFLINE_CORE_SRCS := simulation/src/offline_simulation.cpp \
                     network/src/protocol.cpp \
                     simulation/src/trading_context.cpp \
                     simulation/templates/trading_template.cpp \
                     match/src/orderbook.cpp
ONLINE_SRCS := simulation/src/online_simulation.cpp
CORE_SRCS := $(OFFLINE_CORE_SRCS) $(ONLINE_SRCS)

# ---------------------------------------------------------
# Online (real-time) CLI binary
# ---------------------------------------------------------
ONLINE_TARGET := online_run
ONLINE_SRCS   := tests/src/test.cpp $(CORE_SRCS)

# Default data file used by `make run` (override with FILE=..., which may be an
# MBO .bin or a .ini config file).
FILE ?= ../data_pipeline/data/synthetic_mbo_stream.bin

# Pacing factor for `make run` (override with SCALE=...). Ignored when FILE is
# a .ini (the config carries its own time_scale).
# 1.0 = true real time; smaller replays faster; 0 disables pacing.
SCALE ?= 0.001

# ---------------------------------------------------------
# Python extension module (pybind11)
# ---------------------------------------------------------
PY_MODULE  := engine_sim
PY_INCLUDES := $(shell python3 -m pybind11 --includes)
# $(strip ...) matters here: some python3-config builds (observed with MSYS2's
# mingw-w64 Python) emit a trailing space on --extension-suffix, which Windows
# silently rejects as part of a filename.
PY_SUFFIX   := $(strip $(shell python3-config --extension-suffix))
PY_TARGET   := $(PY_MODULE)$(PY_SUFFIX)

# Native Windows/MinGW has no OnlineSimulation support yet (see ONLINE_SRCS
# above) and needs explicit linking against the Python library instead of the
# macOS-only "-undefined dynamic_lookup" (which GNU ld on Linux rejects
# outright -- it's an ld64/Apple-only flag). Detected via Make's standard
# $(OS) (set to "Windows_NT" by the Windows environment; unset elsewhere) and
# `uname -s` for the macOS/Linux split.
ifeq ($(OS),Windows_NT)
PY_SRCS      := bindings/src/bindings.cpp $(OFFLINE_CORE_SRCS)
PY_DEFINES   := -DCT_NO_ONLINE_SIM
PY_LINK_LIBS := $(shell python3-config --ldflags)
else
PY_SRCS      := bindings/src/bindings.cpp $(CORE_SRCS)
PY_DEFINES   :=
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
PY_LINK_LIBS := -undefined dynamic_lookup
else
# Linux: extension modules conventionally link nothing and resolve Python
# symbols against the hosting interpreter at import time -- no special flag
# needed (ELF shared objects tolerate unresolved symbols by default, unlike
# Windows PE/COFF).
PY_LINK_LIBS :=
endif
endif

.PHONY: all online run pymodule smoke-test hardware-test clean

all: $(ONLINE_TARGET)

# ---------------------------------------------------------
# Online (real-time) CLI binary
# ---------------------------------------------------------
online: $(ONLINE_TARGET)

$(ONLINE_TARGET): $(ONLINE_SRCS)
	$(CXX) $(CXXFLAGS) $(INCLUDES) $(ONLINE_SRCS) -o $(ONLINE_TARGET) -lpthread

run: $(ONLINE_TARGET)
	./$(ONLINE_TARGET) $(FILE) $(SCALE)

pymodule: $(PY_TARGET)

$(PY_TARGET): $(PY_SRCS)
	$(CXX) $(CXXFLAGS) $(PY_DEFINES) -shared -fPIC \
		$(INCLUDES) $(PY_INCLUDES) $(PY_SRCS) $(PY_LINK_LIBS) -o $(PY_TARGET)

# ---------------------------------------------------------
# Test runs (drive online_run against a config)
# ---------------------------------------------------------
# Python interpreter used to generate the smoke/flood market-data books.
# Override with PY=... if needed.
PY ?= ../service/.venv/bin/python

# ../data_pipeline/src/gen_test_datasets.py produces smoke_book.bin + flood_book.bin.
GEN_TEST_DATASETS := ../data_pipeline/src/gen_test_datasets.py

# Loopback smoke test: generate the short smoke_book, then replay it through
# online_run over loopback (127.0.0.1) in real time. Software-only, no board.
# Override with SMOKE_CONFIG=... to run a different .ini.
SMOKE_CONFIG ?= tests/config/smoke_test.ini

smoke-test: $(ONLINE_TARGET) $(GEN_TEST_DATASETS)
	$(PY) $(GEN_TEST_DATASETS)
	./$(ONLINE_TARGET) $(SMOKE_CONFIG)

# Real-hardware run: stream the MBO feed at the FPGA over UDP/192.168.0.1 and
# watch tcpdump/the activity LED for OUCH responses (see docs/connection-test.md
# step 4). Needs the host <-> FPGA link already configured. Override with
# HARDWARE_CONFIG=... to run a different .ini.
HARDWARE_CONFIG ?= tests/config/hardware_test.ini

hardware-test: $(ONLINE_TARGET)
	./$(ONLINE_TARGET) $(HARDWARE_CONFIG)

clean:
	rm -f $(ONLINE_TARGET) $(PY_MODULE)*.so
