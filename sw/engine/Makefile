# Makefile for the trading engine
# Modules:
#   shared/      - common structs (Order, Trade, L1State, FillReport)
#   match/       - OrderBook matching engine
#   simulation/  - Strategy + OfflineSimulation + CLI entry point
#   bindings/    - pybind11 wrapper exposing the simulation to Python
#
# Targets:
#   make            -> build the native CLI binary (simulation_run)
#   make run        -> build + run the CLI with the default data file
#   make pymodule   -> build the importable Python extension (engine_sim*.so)
#   make clean      -> remove all build artifacts

CXX      := g++
CXXFLAGS := -std=c++17 -O2 -Wall -Wextra

# Per-module include directories (headers are referenced by bare name)
INCLUDES := -Ishared/include -Imatch/include -Isimulation/include

# Core engine sources shared by both the CLI and the Python module.
# OFFLINE_CORE_SRCS has no socket usage and is portable as-is; ONLINE_SRCS
# (real-time ITCH/OUCH replay) uses POSIX sockets (sys/socket.h etc.) that
# don't exist on native Windows/MinGW without a Winsock2 port -- see the
# Windows branch of the pymodule target below.
OFFLINE_CORE_SRCS := simulation/src/offline_simulation.cpp \
                     simulation/src/protocol.cpp \
                     simulation/src/strategy_base.cpp \
                     simulation/src/user_strategy.cpp \
                     match/src/orderbook.cpp
ONLINE_SRCS := simulation/src/online_simulation.cpp
CORE_SRCS := $(OFFLINE_CORE_SRCS) $(ONLINE_SRCS)

# ---------------------------------------------------------
# Native CLI binary
# ---------------------------------------------------------
TARGET := simulation_run
CLI_SRCS := simulation/src/main.cpp $(CORE_SRCS)

# Online (real-time) CLI binary
ONLINE_TARGET := online_run
ONLINE_SRCS   := simulation/src/main_online.cpp $(CORE_SRCS)

# Default data file used by `make run` (override with FILE=...)
FILE ?= ../data_pipeline/data/synthetic_mbo_stream.bin

# Pacing factor for `make run-online` (override with SCALE=...).
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

.PHONY: all run online run-online pymodule stress-book test-online socket-test flood-test hw-smoke-test fpga-test run-fpga-test clean

all: $(TARGET) $(ONLINE_TARGET)

$(TARGET): $(CLI_SRCS)
	$(CXX) $(CXXFLAGS) $(INCLUDES) $(CLI_SRCS) -o $(TARGET)

run: $(TARGET)
	./$(TARGET) $(FILE)

# ---------------------------------------------------------
# Online (real-time) CLI binary
# ---------------------------------------------------------
online: $(ONLINE_TARGET)

$(ONLINE_TARGET): $(ONLINE_SRCS)
	$(CXX) $(CXXFLAGS) $(INCLUDES) $(ONLINE_SRCS) -o $(ONLINE_TARGET) -lpthread

run-online: $(ONLINE_TARGET)
	./$(ONLINE_TARGET) $(FILE) $(SCALE)

pymodule: $(PY_TARGET)

$(PY_TARGET): $(PY_SRCS)
	$(CXX) $(CXXFLAGS) $(PY_DEFINES) -shared -fPIC \
		$(INCLUDES) $(PY_INCLUDES) $(PY_SRCS) $(PY_LINK_LIBS) -o $(PY_TARGET)

# ---------------------------------------------------------
# Stress / correctness tests
# ---------------------------------------------------------
# C++ OrderBook stress + correctness harness.
STRESS_BOOK_BIN  := tests/src/stress_orderbook
STRESS_BOOK_SRCS := tests/src/stress_orderbook.cpp match/src/orderbook.cpp

# Python interpreter used by the online tests to generate market-data books.
# Override with PY=... if needed.
PY ?= ../service/.venv/bin/python

stress-book: $(STRESS_BOOK_SRCS)
	$(CXX) $(CXXFLAGS) $(INCLUDES) $(STRESS_BOOK_SRCS) -o $(STRESS_BOOK_BIN)
	./$(STRESS_BOOK_BIN)

# Online simulation end-to-end test (ITCH replay + OUCH connect/send/receive).
# The market-data book is produced by the Python EventGenerator first.
# Socket addresses/ports/transport and the dataset file live in
# tests/config/test_online.ini, not hardcoded here -- override with
# TEST_ONLINE_CONFIG=... to run against a different .ini.
TEST_ONLINE_BIN    := tests/src/test_online
TEST_ONLINE_SRCS   := tests/src/test_online.cpp $(CORE_SRCS)
TEST_ONLINE_CONFIG ?= tests/config/test_online.ini
GEN_LADDER         := tests/src/gen_market_ladder.py

test-online: $(TEST_ONLINE_SRCS) $(GEN_LADDER)
	$(PY) $(GEN_LADDER)
	$(CXX) $(CXXFLAGS) $(INCLUDES) $(TEST_ONLINE_SRCS) -o $(TEST_ONLINE_BIN) -lpthread
	./$(TEST_ONLINE_BIN) $(TEST_ONLINE_CONFIG)

# OUCH socket client vs a generated rising bid ladder. Config (see above):
# tests/config/socket_test.ini, override with SOCKET_TEST_CONFIG=...
SOCKET_TEST_BIN    := tests/src/socket_test
SOCKET_TEST_SRCS   := tests/src/socket_test.cpp $(CORE_SRCS)
SOCKET_TEST_CONFIG ?= tests/config/socket_test.ini

socket-test: $(SOCKET_TEST_SRCS) $(GEN_LADDER)
	$(PY) $(GEN_LADDER)
	$(CXX) $(CXXFLAGS) $(INCLUDES) $(SOCKET_TEST_SRCS) -o $(SOCKET_TEST_BIN) -lpthread
	./$(SOCKET_TEST_BIN) $(SOCKET_TEST_CONFIG)

# tests/src/gen_test_datasets.py produces smoke_book.bin (hw-smoke-test) and
# flood_book.bin (flood-test) -- same price band/shape as market_ladder.bin,
# just shorter or denser, so the existing test assertions still hold.
GEN_TEST_DATASETS := tests/src/gen_test_datasets.py

# Flood/stress the online engine with a dense burst of ITCH messages, reusing
# socket_test's OUCH client against tests/config/flood_test.ini (loopback).
flood-test: $(SOCKET_TEST_SRCS) $(GEN_TEST_DATASETS)
	$(PY) $(GEN_TEST_DATASETS)
	$(CXX) $(CXXFLAGS) $(INCLUDES) $(SOCKET_TEST_SRCS) -o $(SOCKET_TEST_BIN) -lpthread
	./$(SOCKET_TEST_BIN) tests/config/flood_test.ini

# Quick "is the board alive" check for demo day -- streams a short ladder at
# the real FPGA over UDP/192.168.0.1 and relies on tcpdump/the activity LED
# to confirm OUCH responses (see docs/connection-test.md step 4). Needs the
# host <-> FPGA link already configured; this only builds/runs online_run.
hw-smoke-test: $(ONLINE_TARGET) $(GEN_TEST_DATASETS)
	$(PY) $(GEN_TEST_DATASETS)
	./$(ONLINE_TARGET) tests/config/hardware_smoke.ini

# ---------------------------------------------------------
# FPGA hardware test (real board over Ethernet)
# ---------------------------------------------------------
# Streams the synthetic MBO stream to the board using the DEFAULT network config
# (ITCH -> 192.168.0.1:50001, OUCH received over UDP on 50001) and decodes/prints
# every OUCH packet the FPGA sends back. Requires the board link to be up
# (sudo ../../setup/net_setup.sh) and the bitstream loaded.
FPGA_TEST_BIN  := fpga_test
FPGA_TEST_SRCS := tests/src/fpga_test.cpp $(CORE_SRCS)

# Market-data stream fed to the board (override with FILE=...).
FPGA_FILE ?= ../data_pipeline/data/synthetic_mbo_stream.bin
# Real-time pacing for the hardware run (override with SCALE=...).
FPGA_SCALE ?= 1.0

fpga-test: $(FPGA_TEST_BIN)

$(FPGA_TEST_BIN): $(FPGA_TEST_SRCS)
	$(CXX) $(CXXFLAGS) $(INCLUDES) $(FPGA_TEST_SRCS) -o $(FPGA_TEST_BIN) -lpthread

run-fpga-test: $(FPGA_TEST_BIN)
	./$(FPGA_TEST_BIN) $(FPGA_FILE) $(FPGA_SCALE)

clean:
	rm -f $(TARGET) $(ONLINE_TARGET) $(PY_MODULE)*.so $(STRESS_BOOK_BIN) $(TEST_ONLINE_BIN) $(SOCKET_TEST_BIN) $(FPGA_TEST_BIN)
