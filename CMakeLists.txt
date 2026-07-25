# Agilex 7 Wideband Processing Benchmark — C++ reference model and Verilator harness.
#
# PLACEHOLDER (issue #1). This file is populated by issue #2 ("Phase 0: Verilator
# flow"), which adds:
#   - the bit-accurate C++ reference model target from model/cpp/
#   - the multi-clock Verilator harness and clock scheduler from sim/verilator/
#   - the lint / fast / coverage / debug build modes of SPEC.md 12.1
#   - verilated object directories under sim/verilator/build*/ (gitignored)
#
# Configuring or building this project is not supported until issue #2 lands; the
# message below makes that explicit rather than failing obscurely later.
#
# Canonical build host: WSL Ubuntu-24.04 (g++ 13.3, Verilator 5.020).

cmake_minimum_required(VERSION 3.22)

project(agilex7_wideband
        VERSION 0.0.0
        DESCRIPTION "Agilex 7 wideband processing benchmark: C++ model and Verilator harness"
        LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

message(FATAL_ERROR
  "TODO(issue #2): implemented by 'Phase 0: Verilator flow'. Not yet available. "
  "CMakeLists.txt is a scaffold placeholder from issue #1 and defines no targets.")
