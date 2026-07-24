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
             simulation/src/user_strategy.cpp \
             match/src/orderbook.cpp

# ---------------------------------------------------------
# Native CLI binary
# ---------------------------------------------------------
TARGET := simulation_run
CLI_SRCS := simulation/src/main.cpp $(CORE_SRCS)

# Default data file used by `make run` (override with FILE=...)
FILE ?= ../data_pipeline/data/synthetic_mbo_stream.bin

# ---------------------------------------------------------
# Python extension module (pybind11)
# ---------------------------------------------------------
PY_MODULE  := engine_sim
PY_INCLUDES := $(shell python3 -m pybind11 --includes)
PY_SUFFIX   := $(shell python3-config --extension-suffix)
PY_TARGET   := $(PY_MODULE)$(PY_SUFFIX)
PY_SRCS     := bindings/src/bindings.cpp $(CORE_SRCS)

.PHONY: all run pymodule stress-book stress-sim clean

all: $(TARGET)

$(TARGET): $(CLI_SRCS)
	$(CXX) $(CXXFLAGS) $(INCLUDES) $(CLI_SRCS) -o $(TARGET)

run: $(TARGET)
	./$(TARGET) $(FILE)

pymodule: $(PY_TARGET)

$(PY_TARGET): $(PY_SRCS)
	$(CXX) $(CXXFLAGS) -shared -fPIC -undefined dynamic_lookup \
		$(INCLUDES) $(PY_INCLUDES) $(PY_SRCS) -o $(PY_TARGET)

# ---------------------------------------------------------
# Stress / correctness tests
# ---------------------------------------------------------
# C++ OrderBook stress + correctness harness.
STRESS_BOOK_BIN  := tests/stress_orderbook
STRESS_BOOK_SRCS := tests/stress_orderbook.cpp match/src/orderbook.cpp

# Python interpreter used to run the simulation stress test (must be able to
# import the built engine_sim*.so). Override with PY=... if needed.
PY ?= ../service/.venv/bin/python

stress-book: $(STRESS_BOOK_SRCS)
	$(CXX) $(CXXFLAGS) $(INCLUDES) $(STRESS_BOOK_SRCS) -o $(STRESS_BOOK_BIN)
	./$(STRESS_BOOK_BIN)

stress-sim: pymodule
	$(PY) tests/stress_simulation.py

clean:
	rm -f $(TARGET) $(PY_MODULE)*.so $(STRESS_BOOK_BIN)
