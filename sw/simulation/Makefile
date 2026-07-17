# Makefile for the offline simulation engine
# Run from the simulation/ directory:
#   make            -> build the simulation_run binary
#   make run        -> build, then run with the default data file
#   make run FILE=../path/to/data.csv  -> run with a custom data file
#   make clean      -> remove build artifacts

CXX      := g++
CXXFLAGS := -std=c++17 -O2 -Wall -Wextra

# Module locations (relative to this Makefile)
ROOT    := ..
MATCH   := $(ROOT)/match
SHARED  := $(ROOT)/shared

INCLUDES := -Iinclude -I$(MATCH)/include -I$(SHARED)/include

SRCS := src/main.cpp \
        src/offline_simulation.cpp \
        src/user_strategy.cpp \
        $(MATCH)/src/orderbook.cpp

TARGET := simulation_run

# Default data file used by `make run` (override with FILE=...)
FILE ?= $(ROOT)/data_pipeline/data/synthetic_mbo_stream.csv

.PHONY: all run clean

all: $(TARGET)

$(TARGET): $(SRCS)
	$(CXX) $(CXXFLAGS) $(INCLUDES) $(SRCS) -o $(TARGET)

run: $(TARGET)
	./$(TARGET) $(FILE)

clean:
	rm -f $(TARGET)
