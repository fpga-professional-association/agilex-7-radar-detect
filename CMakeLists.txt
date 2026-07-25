# Agilex 7 Wideband Processing Benchmark — standalone C++ builds.
#
# PLACEHOLDER. Still deliberately empty after issue #4. This is a decision, not
# an omission: see DECISIONS.md 2026-07-25 (issue #4, decision 9).
#
# The Verilator flow does NOT use CMake. Issue #2 established that
# `scripts/build_verilator.py` drives Verilator and `verilator --build` drives
# the C++ compile of the harness, the test and the verilated model in one step
# (DECISIONS.md 2026-07-25, issue #2, decision 8). Adding CMake on top of that
# would mean maintaining two descriptions of one binary, with the usual result.
#
# Issue #2 expected this file to become real in issue #4, which adds the
# bit-accurate C++ reference model under model/cpp/ — the first component that
# has to build and be unit-tested *without* Verilator (SPEC.md 12.4). Two facts
# measured while doing that work changed the answer:
#
#   1. cmake is not installed in WSL Ubuntu-24.04, the canonical build host.
#      A CMake description that has never been executed is worse than none.
#   2. The reference model is header-only plus one test translation unit, so its
#      entire standalone build is a single compiler invocation. There is no
#      build graph for CMake to describe.
#
# The standalone build and its unit test therefore run from the Makefile:
#
#   make numerics-check     # vectors + C++ unit test + RTL cross-check
#   make sim-tiny           # depends on numerics-check
#   make lint
#
# which expands to, for the C++ half:
#
#   g++ -std=c++17 -O3 -Wall -Wextra -Werror -Imodel/cpp \
#       -o model/cpp/build/test_fxp_vectors model/cpp/test/test_fxp_vectors.cpp
#   ./model/cpp/build/test_fxp_vectors --vectors model/vectors
#
# Revisit when some component genuinely needs a build graph rather than a
# command — several translation units with a link step, or an external
# dependency to find. Until then, configuring this project stays unsupported and
# the message below says so plainly rather than producing an empty build tree.
#
# See sim/verilator/README.md and NUMERICS.md.
#
# Canonical build host: WSL Ubuntu-24.04 (g++ 13.3, Verilator 5.020).

cmake_minimum_required(VERSION 3.22)

project(agilex7_wideband
        VERSION 0.0.0
        DESCRIPTION "Agilex 7 wideband processing benchmark: C++ reference model"
        LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

message(FATAL_ERROR
  "This project has no CMake build (DECISIONS.md 2026-07-25, issue #4, "
  "decision 9). Use 'make numerics-check' for the standalone C++ reference "
  "model and its unit test, and 'make lint' / 'make sim-tiny' for simulation. "
  "See sim/verilator/README.md.")
