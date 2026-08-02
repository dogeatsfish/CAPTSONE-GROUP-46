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

# Core engine sources shared by both the CLI and the Python module
CORE_SRCS := simulation/src/offline_simulation.cpp \
             simulation/src/online_simulation.cpp \
             simulation/src/protocol.cpp \
             simulation/src/user_strategy.cpp \
             match/src/orderbook.cpp

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
PY_SUFFIX   := $(shell python3-config --extension-suffix)
PY_TARGET   := $(PY_MODULE)$(PY_SUFFIX)
PY_SRCS     := bindings/src/bindings.cpp $(CORE_SRCS)

.PHONY: all run online run-online pymodule stress-book test-online socket-test fpga-test run-fpga-test clean

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
	$(CXX) $(CXXFLAGS) -shared -fPIC -undefined dynamic_lookup \
		$(INCLUDES) $(PY_INCLUDES) $(PY_SRCS) -o $(PY_TARGET)

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
TEST_ONLINE_BIN  := tests/src/test_online
TEST_ONLINE_SRCS := tests/src/test_online.cpp $(CORE_SRCS)
GEN_LADDER       := tests/src/gen_market_ladder.py

test-online: $(TEST_ONLINE_SRCS) $(GEN_LADDER)
	$(PY) $(GEN_LADDER)
	$(CXX) $(CXXFLAGS) $(INCLUDES) $(TEST_ONLINE_SRCS) -o $(TEST_ONLINE_BIN) -lpthread
	./$(TEST_ONLINE_BIN)

# OUCH socket client vs a generated rising bid ladder.
SOCKET_TEST_BIN  := tests/src/socket_test
SOCKET_TEST_SRCS := tests/src/socket_test.cpp $(CORE_SRCS)

socket-test: $(SOCKET_TEST_SRCS) $(GEN_LADDER)
	$(PY) $(GEN_LADDER)
	$(CXX) $(CXXFLAGS) $(INCLUDES) $(SOCKET_TEST_SRCS) -o $(SOCKET_TEST_BIN) -lpthread
	./$(SOCKET_TEST_BIN)

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
