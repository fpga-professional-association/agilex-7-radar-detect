# Agilex 7 Wideband Processing Benchmark — standalone C++ builds.
#
# PLACEHOLDER. Deliberately still empty after issue #2.
#
# The Verilator flow does NOT use CMake. Issue #2 established that
# `scripts/build_verilator.py` drives Verilator and `verilator --build` drives
# the C++ compile of the harness, the test and the verilated model in one step
# (see DECISIONS.md 2026-07-25, decision 8). Adding CMake on top of that would
# mean maintaining two descriptions of one binary, with the usual result. To
# build or run a simulation, use:
#
#   make lint
#   make sim-tiny
#   python3 scripts/build_verilator.py --mode lint|fast|coverage|debug --config <name>
#
# See sim/verilator/README.md.
#
# This file becomes real in issue #4, which adds the bit-accurate C++ reference
# model under model/cpp/. That library is the first component that has to build
# and be unit-tested *without* Verilator — it is validated against Python/NumPy
# vectors before it is trusted as the RTL oracle (SPEC.md 12.4) — and a
# standalone CMake target is the right way to do that.
#
# Configuring this project is therefore still unsupported; the message below
# says so plainly rather than producing an empty build tree.
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
  "TODO(issue #4): implemented by 'Fixed-point numerics: shared SV package + "
  "bit-identical C++ types'. Not yet available. The Verilator simulation flow "
  "does not use CMake — run 'make lint' / 'make sim-tiny', or "
  "scripts/build_verilator.py directly. See sim/verilator/README.md.")
