# Makefile for the trading engine
# Modules:
#   shared/           - types everyone shares: common.h (Order, events, L2),
#                       feed.h (MBORecord), telemetry.h (run results)
#   exchange/         - OrderBook: matching, depth, queue position
#   simcore/          - what makes it a SIMULATED exchange: the Scheduler
#                       (clock + event queue), the latency model, Accounts
#   participants/     - the Participant port and its implementations;
#                       agents/ is where the built-in bots go
#   strategy/         - the player's strategy, split in two: src/ is the
#                       fixed half they cannot change, templates/ is the
#                       editable on_market_update body
#   runner/           - ways to run a simulation: OfflineSimulation (replay a
#                       file) and OnlineSimulation (real time over sockets)
#   network/          - ITCH/OUCH wire protocol + the cross-platform socket layer
#   tools/online_run.cpp   - online (real-time) CLI entry point
#   tools/link_flash.cpp   - UDP link check: flashes the board's LED
#   tools/bench_scheduler.cpp - wall-clock fan-out benchmark
#   tests/src/           - unit tests (test_*.cpp)
#   bindings/            - pybind11 wrapper exposing the simulation to Python
#   ../compiler/         - strategy-compiler entry point (main_job, job template)
#
# Targets:
#   make            -> build the real-time CLI binary (online_run)
#   make run        -> build + run the CLI (FILE=<mbo.bin> SCALE=<x>
#                      ITCH_ADDR=<ip> to stream somewhere other than loopback)
#   make pymodule   -> build the importable Python extension (engine_sim*.so)
#   make test       -> build + run the C++ unit tests (tests/src/test_*.cpp)
#   make test-python-> build the Python module and check it
#                      (../service/tests/test_bindings.py)
#   make flash      -> send ITCH packets at the board and watch its LED
#                      (visual check, not automated -- see the file header)
#   make bench      -> measure the engine's own fan-out cost (wall clock)
#   make headers    -> check every header compiles on its own
#   make rebuild    -> clean, then build from scratch
#   make clean      -> remove all build artifacts

# Everything the build produces goes here, so the module directories stay
# source-only and `git status` never shows a binary.
BUILD_DIR := build

CXX      := g++
CXXFLAGS := -std=c++17 -O2 -Wall -Wextra

# Every module that publishes headers. One list, because INCLUDES and ALL_HDRS
# must never disagree: a module missing from INCLUDES fails loudly ("no such
# file"), but a module missing from ALL_HDRS fails SILENTLY -- make goes on
# thinking a binary is current after you edit one of its headers.
MODULES := shared exchange simcore participants strategy runner network

# Headers are referenced by bare name; these -I flags are what resolves them.
INCLUDES := $(addprefix -I,$(addsuffix /include,$(MODULES)))

# Core engine sources shared by both the CLI and the Python module.
# OFFLINE_CORE_SRCS has no socket usage and is portable as-is;
# RUNNER_ONLINE_SRCS (real-time ITCH/OUCH replay) uses POSIX sockets that
# don't exist on native Windows/MinGW without a Winsock2 port -- see the
# Windows branch of the pymodule target below.
OFFLINE_CORE_SRCS := runner/src/offline_simulation.cpp \
                     simcore/src/scheduler.cpp \
                     participants/src/participant.cpp \
                     simcore/src/account.cpp \
                     network/src/protocol.cpp \
                     strategy/src/strategy_fixed.cpp \
                     strategy/templates/trading_template.cpp \
                     exchange/src/orderbook.cpp
RUNNER_ONLINE_SRCS := runner/src/online_simulation.cpp
CORE_SRCS := $(OFFLINE_CORE_SRCS) $(RUNNER_ONLINE_SRCS)

# Every engine header. Each build target lists these as prerequisites because
# the compile lines name only .cpp files -- without them, editing a header
# leaves `make` thinking the binary is up to date and you keep running the old
# one. A wildcard (not a hand-written list) so a new header is covered the day
# it's added.
ALL_HDRS := $(wildcard $(addsuffix /include/*.h,$(MODULES)))

# Everything a target that drives the scheduler has to link. Defined up here,
# above every rule that names it: a prerequisite list is expanded when make
# READS the rule, so a group defined further down expands to nothing and the
# target silently stops depending on its own sources. (bench_scheduler had
# exactly that bug -- it relinked only when its own .cpp changed.)
SCHED_SRCS   := simcore/src/scheduler.cpp participants/src/participant.cpp \
                simcore/src/account.cpp exchange/src/orderbook.cpp
TEST_NAMES   := test_orderbook test_account test_scheduler test_participant
TEST_TARGETS := $(addprefix $(BUILD_DIR)/,$(TEST_NAMES))

# ---------------------------------------------------------
# Online (real-time) CLI binary
# ---------------------------------------------------------
ONLINE_TARGET := $(BUILD_DIR)/online_run
ONLINE_RUN_SRCS := tools/online_run.cpp $(CORE_SRCS)

# Default data file used by `make run` (override with FILE=..., which may be an
# MBO .bin file).
FILE ?= ../data_pipeline/data/synthetic_mbo_stream.bin

# Pacing factor for `make run` (override with SCALE=...).
# 1.0 = true real time; smaller replays faster; 0 disables pacing.
SCALE ?= 0.001

# Where `make run` broadcasts ITCH and listens for OUCH. The defaults keep
# everything on loopback; point ITCH_ADDR at the board to drive real hardware:
#   make run SCALE=1.0 ITCH_ADDR=192.168.0.1
ITCH_ADDR ?= 127.0.0.1
ITCH_PORT ?= 50001
OUCH_PORT ?= 50001

# ---------------------------------------------------------
# Python extension module (pybind11)
# ---------------------------------------------------------
PY_MODULE  := engine_sim
PY_INCLUDES := $(shell python3 -m pybind11 --includes)
# $(strip ...) matters here: some python3-config builds (observed with MSYS2's
# mingw-w64 Python) emit a trailing space on --extension-suffix, which Windows
# silently rejects as part of a filename.
# Asks the interpreter itself rather than python3-config, which venvs
# (including CI's) don't ship.
PY_SUFFIX   := $(strip $(shell python3 -c "import sysconfig; print(sysconfig.get_config_var('EXT_SUFFIX'))"))
PY_TARGET   := $(BUILD_DIR)/$(PY_MODULE)$(PY_SUFFIX)

# Native Windows/MinGW has no OnlineSimulation support yet (see ONLINE_SRCS
# above) and needs explicit linking against the Python library instead of the
# macOS-only "-undefined dynamic_lookup" (which GNU ld on Linux rejects
# outright -- it's an ld64/Apple-only flag). Detected via Make's standard
# $(OS) (set to "Windows_NT" by the Windows environment; unset elsewhere) and
# `uname -s` for the macOS/Linux split.
ifeq ($(OS),Windows_NT)
# Winsock (see network/include/socket_compat.h); POSIX sockets need no extra lib.
NET_LIBS     := -lws2_32
PY_SRCS      := bindings/src/bindings.cpp $(OFFLINE_CORE_SRCS)
PY_DEFINES   := -DCT_NO_ONLINE_SIM
PY_LINK_LIBS := $(shell python3-config --ldflags)
else
NET_LIBS     :=
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

.PHONY: all online rebuild run pymodule test test-python headers flash bench clean

all: $(ONLINE_TARGET)

# Order-only (after the |): the directory's timestamp changes whenever a file
# lands in it, so as a normal prerequisite it would rebuild everything every
# time something else was built.
$(BUILD_DIR):
	@mkdir -p $@

# Force a from-scratch build. Rarely needed now that headers are tracked as
# prerequisites -- reach for this when you've changed CXXFLAGS or switched
# compilers, not as a habit.
rebuild:
	$(MAKE) clean
	$(MAKE) all

# ---------------------------------------------------------
# Online (real-time) CLI binary
# ---------------------------------------------------------
online: $(ONLINE_TARGET)

$(ONLINE_TARGET): $(ONLINE_RUN_SRCS) $(ALL_HDRS) | $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) $(INCLUDES) $(ONLINE_RUN_SRCS) -o $(ONLINE_TARGET) -lpthread $(NET_LIBS)

run: $(ONLINE_TARGET)
	./$(ONLINE_TARGET) $(FILE) $(SCALE) $(ITCH_PORT) $(OUCH_PORT) $(ITCH_ADDR)

pymodule: $(PY_TARGET)

$(PY_TARGET): $(PY_SRCS) $(ALL_HDRS) | $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) $(PY_DEFINES) -shared -fPIC \
		$(INCLUDES) $(PY_INCLUDES) $(PY_SRCS) $(PY_LINK_LIBS) -o $(PY_TARGET)

# ---------------------------------------------------------
# Link check (visual -- deliberately not in CI)
# ---------------------------------------------------------
# Streams ITCH packets at the board so its receive LED flashes. There is
# nothing to assert: the board never acknowledges anything, so you confirm it
# by looking at the board. See tools/link_flash.cpp.
# FLASH_RATE is packets per second; FLASH_COUNT 0 means continuous (Ctrl-C).
# These comments sit above the assignments, not after them: make keeps the
# whitespace between a value and a trailing '#', so `X ?= 5   # note` sets X to
# "5   ", which survives shell word-splitting here but breaks the moment the
# value is quoted or compared.
FLASH_TARGET := $(BUILD_DIR)/link_flash
FLASH_ADDR  ?= 192.168.0.1
FLASH_RATE  ?= 5
FLASH_COUNT ?= 0
FLASH_PORT  ?= 50001

flash: $(FLASH_TARGET)
	./$(FLASH_TARGET) $(FLASH_ADDR) $(FLASH_RATE) $(FLASH_COUNT) $(FLASH_PORT)

$(FLASH_TARGET): tools/link_flash.cpp network/src/protocol.cpp $(ALL_HDRS) | $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) $(INCLUDES) tools/link_flash.cpp network/src/protocol.cpp \
		-o $@ -lpthread $(NET_LIBS)

# ---------------------------------------------------------
# Header hygiene
# ---------------------------------------------------------
# Every header must compile on its own. Without this it is easy for a header
# to quietly rely on a sibling's includes -- which is how protocol.h ended up
# including offline_simulation.h, dragging the scheduler and the whole
# participant layer into every file that only wanted to talk ITCH.
headers:
	@for h in $(ALL_HDRS); do \
	    $(CXX) $(CXXFLAGS) $(INCLUDES) -fsyntax-only -x c++ $$h \
	        -Wno-pragma-once-outside-header -Wno-unused-const-variable \
	        || exit 1; \
	done
	@echo "all $(words $(ALL_HDRS)) headers compile standalone"

# ---------------------------------------------------------
# Benchmark (wall clock -- deliberately not in CI)
# ---------------------------------------------------------
# Measures how long the engine itself takes to fan a trade out to N
# participants. Timing on a shared CI runner is noise, so this is run by hand.
BENCH_TARGET := $(BUILD_DIR)/bench_scheduler
BENCH_TRIALS ?= 5000

bench: $(BENCH_TARGET)
	./$(BENCH_TARGET) $(BENCH_TRIALS)

$(BENCH_TARGET): tools/bench_scheduler.cpp $(SCHED_SRCS) $(ALL_HDRS) | $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) $(INCLUDES) tools/bench_scheduler.cpp $(SCHED_SRCS) -o $@

# ---------------------------------------------------------
# Unit tests
# ---------------------------------------------------------
# The binaries live in $(BUILD_DIR) now, but `make test_orderbook`,
# `make link_flash` and `make bench_scheduler` are what people's fingers
# already know -- keep them working as aliases.
.PHONY: $(TEST_NAMES) link_flash bench_scheduler
$(TEST_NAMES): %: $(BUILD_DIR)/%
link_flash: $(FLASH_TARGET)
bench_scheduler: $(BENCH_TARGET)

test: $(TEST_TARGETS)
	@for t in $(TEST_NAMES); do echo "== $$t"; ./$(BUILD_DIR)/$$t || exit 1; done

# Checks the Python bindings from the service side; needs pybind11 in the
# python3 on PATH. The test lives with the service because the service is what
# consumes engine_sim.
test-python: pymodule
	python3 ../service/tests/test_bindings.py

$(BUILD_DIR)/test_orderbook: tests/src/test_orderbook.cpp exchange/src/orderbook.cpp $(ALL_HDRS) | $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) $(INCLUDES) tests/src/test_orderbook.cpp exchange/src/orderbook.cpp -o $@

$(BUILD_DIR)/test_account: tests/src/test_account.cpp simcore/src/account.cpp $(ALL_HDRS) | $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) $(INCLUDES) tests/src/test_account.cpp simcore/src/account.cpp -o $@

$(BUILD_DIR)/test_scheduler: tests/src/test_scheduler.cpp $(SCHED_SRCS) $(ALL_HDRS) | $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) $(INCLUDES) tests/src/test_scheduler.cpp $(SCHED_SRCS) -o $@

$(BUILD_DIR)/test_participant: tests/src/test_participant.cpp $(SCHED_SRCS) $(ALL_HDRS) | $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) $(INCLUDES) tests/src/test_participant.cpp $(SCHED_SRCS) -o $@

clean:
	rm -rf $(BUILD_DIR)
	@# Build output used to land here; sweep it so a stale engine_sim*.so in
	@# the engine root cannot shadow the real one in $(BUILD_DIR)/ on sys.path.
	@rm -f online_run link_flash bench_scheduler $(TEST_NAMES) $(PY_MODULE)*.so
