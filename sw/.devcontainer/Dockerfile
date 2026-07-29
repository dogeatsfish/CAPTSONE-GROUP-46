# Linux C++ toolchain for the CommonTrader engine.
#
# Base: Microsoft's devcontainer C++ image on Ubuntu 24.04 (Noble). It already
# ships build-essential, CMake, and GDB; we pin a modern GCC and add the extra
# tooling the project (and debugging) needs. Because this is a real Linux
# userland, <sys/socket.h> and the rest of the POSIX networking headers are
# present natively — no source changes required.
FROM mcr.microsoft.com/devcontainers/cpp:1-ubuntu-24.04

# Avoid interactive apt prompts during image build.
ENV DEBIAN_FRONTEND=noninteractive

# Modern GCC (13) + the build/debug tooling you asked for.
# Ubuntu 24.04 provides gcc/g++-13 and gcc/g++-14 in the default repos.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        gcc-13 g++-13 \
        make \
        cmake \
        ninja-build \
        gdb \
        valgrind \
        pkg-config \
        python3 \
        python3-pip \
        python3-venv \
        python3-pybind11 \
    && rm -rf /var/lib/apt/lists/*

# Make gcc-13/g++-13 the default `gcc`/`g++` in the container.
# NOTE: cc/c++ are their own master alternatives on this base image, so they
# cannot be registered as slaves of gcc (that triggers
# "alternative cc can't be slave of gcc"). We remap gcc/g++ only — that's what
# the Makefile (`g++`) and CMake (`g++-13`) actually use.
RUN update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-13 100 \
        --slave /usr/bin/g++ g++ /usr/bin/g++-13

# Sanity echo at build time (visible in the image build log).
RUN g++ --version && cmake --version && make --version | head -1
