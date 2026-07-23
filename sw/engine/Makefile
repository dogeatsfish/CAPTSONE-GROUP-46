# Makefile for the trading engine (order book + strategy + offline simulation)
# Run from the engine/ directory:
#   make            -> build the simulation_run binary
#   make run        -> build, then run with the default data file
#   make run FILE=../path/to/data.bin  -> run with a custom binary data file
#   make clean      -> remove build artifacts

CXX      := g++
CXXFLAGS := -std=c++17 -O2 -Wall -Wextra

INCLUDES := -Iinclude

SRCS := src/main.cpp \
        src/offline_simulation.cpp \
        src/user_strategy.cpp \
        src/orderbook.cpp

TARGET := simulation_run

# Default data file used by `make run` (override with FILE=...)
FILE ?= ../data_pipeline/data/synthetic_mbo_stream.bin

.PHONY: all run clean

all: $(TARGET)

$(TARGET): $(SRCS)
	$(CXX) $(CXXFLAGS) $(INCLUDES) $(SRCS) -o $(TARGET)

run: $(TARGET)
	./$(TARGET) $(FILE)

clean:
	rm -f $(TARGET)
