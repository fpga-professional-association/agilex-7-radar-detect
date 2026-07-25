# Agilex 7 Wideband Processing Benchmark — top-level entry points
#
# Governing spec: SPEC.md 16 (Build Commands). Execution plan: PLAN.md.
#
# ---------------------------------------------------------------------------
# Execution environment
# ---------------------------------------------------------------------------
# Canonical shell:   WSL Ubuntu-24.04 bash, GNU Make 4.3, g++ 13.3.
# Simulation side:   Verilator 5.020 inside WSL.
# Quartus side:      Quartus Prime Pro 26.1 on Windows, driven through
#                    quartus_sh.exe.
#
# NOTE (measured 2026-07-25, issue #3): this host's WSL distribution has
# Windows interop DISABLED (/proc/sys/fs/binfmt_misc/WSLInterop is absent), so
# WSL cannot execute /mnt/c/.../quartus_sh.exe — or any other .exe — directly.
# The quartus-* targets must therefore run from the Windows side. GNU Make 4.4.1
# ships with Quartus and works from Git Bash:
#
#   C:/altera_pro/26.1/riscfree/build_tools/bin/make.exe quartus-map
#
# QUARTUS_CHECK probes executability and prints this guidance rather than
# letting the shell try to interpret a PE binary as a script.
#
# This Makefile detects whether it is running under WSL/Linux or under a native
# Windows make and dispatches each target to the correct toolchain host:
#
#   lint, sim-*        run under WSL/Linux. Invoked from native Windows make
#                      they are re-dispatched with
#                      `wsl.exe -d $(WSL_DISTRO) -- make -C $(WSL_REPO_DIR) <t>`.
#   quartus-*          run quartus_sh.exe directly on either side, never WSL.
#
# A native Windows make must supply a POSIX shell (Git Bash / MSYS); the
# canonical and supported invocation is from WSL.
#
# ---------------------------------------------------------------------------
# Environment variables (all optional; defaults shown)
# ---------------------------------------------------------------------------
#   QUARTUS_SH     Absolute path to quartus_sh.exe.
#                  WSL/Linux default: /mnt/c/altera_pro/26.1/quartus/bin64/quartus_sh.exe
#                  Windows default:   C:/altera_pro/26.1/quartus/bin64/quartus_sh.exe
#   WSL_DISTRO     WSL distribution used for simulation.      default: Ubuntu-24.04
#   WSL_REPO_DIR   Repo path as seen from WSL.                default: /mnt/d/agielx-7-radar-test
#   CONFIG         Size config name from config/*.json.       default: tiny
#   SEED           Deterministic seed for randomized runs.    default: 1
#   SEEDS          Seed list looped by sim-tiny.              default: 1 2 3
#   JOBS           Parallel job count for builds/compiles.    default: 16
#   TEST           Test stem under sim/tests/.                default: test_stream_loopback
#   PYTHON         Python interpreter for scripts/.           default: python3
#   RESULTS_DIR    Run-summary output directory.              default: results/simulation
#
# A clean checkout plus these variables is sufficient to run every target
# (SPEC.md 16).
#
# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
# Implemented: `lint` and `sim-tiny` (issue #2, Verilator flow; extended by
# issue #5 with the stream-primitive and negative-assertion tests, by issue #7
# with the register/control plane, and by issue #6 with the FIFO and CDC
# primitives plus the SPEC 8 CDC inventory report) and the quartus-* targets
# (issue #3).
#
# Everything else is still a scaffold stub from issue #1. Stubs fail loudly:
# they print `TODO(issue #N)` and the stub command exits 1. GNU make then
# reports its own exit status 2, which is make's documented status for a failed
# recipe (1 is reserved for -q question mode), so `make <target>; echo $$?`
# prints 2. No stub ever silently succeeds. Run `make help` for the target list
# and the issue that implements each one.
#
# The four SPEC 12.1 build modes are all driven by scripts/build_verilator.py.
# `lint` and `sim-tiny` use the lint and fast modes; the coverage and debug modes
# are invoked directly (see sim/verilator/README.md) until sim-coverage lands in
# issue #17.

SHELL := /bin/sh

# --- host detection --------------------------------------------------------

UNAME_S := $(shell uname -s 2>/dev/null)
UNAME_R := $(shell uname -r 2>/dev/null)

ifeq ($(UNAME_S),)
  HOST_KIND := windows
else
  ifneq ($(findstring icrosoft,$(UNAME_R)),)
    HOST_KIND := wsl
  else
    ifneq ($(findstring MINGW,$(UNAME_S))$(findstring MSYS,$(UNAME_S))$(findstring CYGWIN,$(UNAME_S)),)
      HOST_KIND := windows
    else
      HOST_KIND := posix
    endif
  endif
endif

# --- configurable environment ---------------------------------------------

WSL_DISTRO   ?= Ubuntu-24.04
WSL_REPO_DIR ?= /mnt/d/agielx-7-radar-test
CONFIG       ?= tiny
SEED         ?= 1
# sim-tiny runs the loopback test once per seed. Three distinct seeds is the
# floor the issue #2 gate asks for; SEEDS='1 3 7 11 17' widens it without a
# rebuild. The SPEC 25 ten-seed list belongs to seed-sweep (issue #23), not here.
SEEDS        ?= 1 2 3
JOBS         ?= 16
TEST         ?= test_stream_loopback
RESULTS_DIR  ?= results/simulation

# Deferred (`=`, not `:=`): PYTHON is probed further down, after host detection
# has chosen the candidate order.
BUILD_VERILATOR = $(PYTHON) scripts/build_verilator.py
SIM_TINY_BIN    = sim/verilator/build/fast_tiny/Vbenchmark_sim_top_$(TEST)

# --- stream primitives (issue #5, SPEC 5 / 13.1 / 14) ----------------------
# Two further self-contained builds, each with its own top and file list, for
# the same reason the numerics cross-check has one: a failure in either is then
# unambiguously a failure of the thing it tests.
#
#   stream_prims_top     the three canonical stream primitives in four
#                        configurations, exercised per primitive by
#                        test_stream_primitives.
#   stream_violator_top  a deliberately protocol-violating stage with the SPEC 14
#                        checker bound onto it. test_stream_assertions requires
#                        each expected assertion to fire, and the clean mode to
#                        stay clean; the binary exits 0 when every expected
#                        failure was observed, which is what makes the assertion
#                        set provably load-bearing rather than decorative. Its
#                        RTL is knowingly wrong and appears in no other file list.
STREAM_TOP   := stream_prims_top
STREAM_FILES := sim/verilator/files_stream.f
STREAM_TEST  := test_stream_primitives
STREAM_BIN    = sim/verilator/build/fast_tiny_$(STREAM_TOP)/V$(STREAM_TOP)_$(STREAM_TEST)

VIOL_TOP     := stream_violator_top
VIOL_FILES   := sim/verilator/files_violator.f
VIOL_TEST    := test_stream_assertions
VIOL_BIN      = sim/verilator/build/fast_tiny_$(VIOL_TOP)/V$(VIOL_TOP)_$(VIOL_TEST)

# --- CDC and FIFO primitives (issue #6, SPEC 8 / 13.1 / 14) ----------------
# Two further self-contained builds, for the same reason the stream primitives
# have their own: a failure in either is then unambiguously a failure of the
# thing it tests.
#
#   cdc_prims_top      rtl/common/sync_fifo.sv in two configurations plus every
#                      rtl/cdc/ primitive, driven by three tests: the FIFO
#                      cycle-accurate reference-model comparison, the
#                      asynchronous-FIFO clock-ratio sweep, and the
#                      pulse/handshake/status-bit sweep.
#   cdc_violator_top   a deliberately broken crossing with the SPEC 14 CDC
#                      checkers bound onto it. test_cdc_assertions requires each
#                      expected assertion to fire BY NAME and the clean mode to
#                      stay clean, which is what makes the Gray-transition and
#                      handshake-stability properties provably load-bearing. Its
#                      RTL is knowingly wrong and appears in no other file list.
CDC_TOP      := cdc_prims_top
CDC_FILES    := sim/verilator/files_cdc.f
CDC_TESTS    := test_sync_fifo test_async_fifo test_cdc_synchronizers
CDC_BIN_DIR   = sim/verilator/build/fast_tiny_$(CDC_TOP)

CDCV_TOP     := cdc_violator_top
CDCV_FILES   := sim/verilator/files_cdc_violator.f
CDCV_TEST    := test_cdc_assertions
CDCV_BIN      = sim/verilator/build/fast_tiny_$(CDCV_TOP)/V$(CDCV_TOP)_$(CDCV_TEST)

# SPEC 8 "Generate an explicit CDC inventory report". `cdc-inventory` elaborates
# the CDC file list with `verilator --xml-only` and joins the elaborated instance
# tree against the (* cdc_primitive *) declarations in the RTL. --strict fails
# the run when any crossing could not be classified, which is what stops an
# untagged crossing from being added silently. Like numerics-check it is a
# sub-target of sim-tiny, not a SPEC 16 entry point. The report is generated, so
# it lands under results/ and is never committed (PLAN.md standing rule 3).
CDC_INVENTORY_JSON ?= $(RESULTS_DIR)/cdc_inventory.json

# --- register/control plane (issue #7, SPEC 9 / 13.1 / 14) -----------------
# A fourth self-contained build, for the reason the others have one: a failure
# in it is unambiguously a control-plane failure. control_top holds the whole of
# rtl/control/ plus a second fabric attached to a block that never answers, so
# the watchdog escape is an exercised path rather than an untested comment.
CONTROL_TOP   := control_top
CONTROL_FILES := sim/verilator/files_control.f
CONTROL_TEST  := test_control_regs
CONTROL_BIN    = sim/verilator/build/fast_tiny_$(CONTROL_TOP)/V$(CONTROL_TOP)_$(CONTROL_TEST)

# The register map is generated from control/regmap.json by scripts/gen_regmap.py.
# The SystemVerilog package, the C++ header and docs/regmap.md are committed — a
# clean checkout must lint and simulate without running a generator first — and
# `--check` regenerates them in memory and fails if what is on disk differs. So
# neither a hand edit of a generated file nor a source-of-truth change that was
# never regenerated survives `make lint` or `make sim-tiny`.
GEN_REGMAP = $(PYTHON) scripts/gen_regmap.py

# `regmap-check` is host-independent: it is Python reading two text files, so it
# runs wherever make runs and is never dispatched into WSL. Not a SPEC 16 entry
# point; it is a prerequisite of both lint and sim-tiny, and is runnable on its
# own while editing the register map.
define REGMAP_CHECK_RECIPE
	$(PYTHON_CHECK)
	@printf '[regmap] checking generated artefacts against %s\n' 'control/regmap.json'
	$(GEN_REGMAP) --check
endef

# --- numerics cross-check (issue #4, SPEC 6 / 12.4) ------------------------
# `numerics-check` is NOT a SPEC 16 entry point; it is a sub-target that
# `sim-tiny` depends on, so the fixed-point equivalence proof runs on every
# regression without adding a top-level command the spec does not name.
CXX           ?= g++
NUMERICS_DIR  := model/cpp/build
NUMERICS_BIN  := $(NUMERICS_DIR)/test_fxp_vectors
NUMERICS_SRC  := model/cpp/test/test_fxp_vectors.cpp
VECTORS_DIR   ?= model/vectors
# The build contract from the issue #4 gate. -Werror is not decoration: the
# reference model is compiled into the harness of every later test, and a
# warning there is a numerics warning.
NUMERICS_CXXFLAGS ?= -std=c++17 -O3 -Wall -Wextra -Werror -Imodel/cpp
FXP_TOP       := fxp_probe_top
FXP_TEST      := test_fxp_rtl
FXP_FILES     := sim/verilator/files_fxp.f
FXP_BIN        = sim/verilator/build/fast_tiny_$(FXP_TOP)/V$(FXP_TOP)_$(FXP_TEST)

ifeq ($(HOST_KIND),windows)
  QUARTUS_SH ?= C:/altera_pro/26.1/quartus/bin64/quartus_sh.exe
else
  QUARTUS_SH ?= /mnt/c/altera_pro/26.1/quartus/bin64/quartus_sh.exe
endif

CONFIG_JSON := config/$(CONFIG).json

# --- stub helper -----------------------------------------------------------
# $(1) = issue number, $(2) = issue title (no commas)

define TODO
	@printf 'TODO(issue #%s): implemented by %s. Not yet available.\n' '$(1)' "'$(2)'" 1>&2; exit 1
endef

# --- simulation-side recipes -----------------------------------------------
# On Windows every simulation target re-dispatches into WSL, forwarding the
# tunable variables so the WSL-side make sees the same configuration. On
# WSL/Linux the real Verilator flow runs.

ifeq ($(HOST_KIND),windows)

define SIM_DISPATCH
	@printf '[dispatch] %s -> wsl -d %s make -C %s\n' '$@' '$(WSL_DISTRO)' '$(WSL_REPO_DIR)'
	@wsl.exe -d $(WSL_DISTRO) -- make -C $(WSL_REPO_DIR) $@ \
	    CONFIG='$(CONFIG)' SEED='$(SEED)' SEEDS='$(SEEDS)' JOBS='$(JOBS)' \
	    TEST='$(TEST)' RESULTS_DIR='$(RESULTS_DIR)'
endef

LINT_RECIPE      = $(SIM_DISPATCH)
SIM_TINY_RECIPE  = $(SIM_DISPATCH)
NUMERICS_RECIPE  = $(SIM_DISPATCH)
CDC_INVENTORY_RECIPE = $(SIM_DISPATCH)
SIM_STUB_17      = $(SIM_DISPATCH)
SIM_STUB_20      = $(SIM_DISPATCH)

else

# `lint`: SPEC 12.1 lint build. build_verilator.py omits --Wno-fatal, so any
# warning not justified in sim/verilator/lint_waivers.vlt exits non-zero.
define LINT_RECIPE
	@printf '[lint] verilator --lint-only --Wall, config=%s, waivers=%s\n' \
	    '$(CONFIG)' 'sim/verilator/lint_waivers.vlt'
	$(REGMAP_CHECK_RECIPE)
	@printf '[lint] 1/6 %s\n' 'benchmark_sim_top'
	$(BUILD_VERILATOR) --mode lint --config $(CONFIG) --jobs $(JOBS) --test $(TEST)
	@printf '[lint] 2/6 %s\n' '$(STREAM_TOP)'
	$(BUILD_VERILATOR) --mode lint --config $(CONFIG) --jobs $(JOBS) \
	    --top $(STREAM_TOP) --files $(STREAM_FILES) --test $(STREAM_TEST)
	@printf '[lint] 3/6 %s\n' '$(VIOL_TOP)'
	$(BUILD_VERILATOR) --mode lint --config $(CONFIG) --jobs $(JOBS) \
	    --top $(VIOL_TOP) --files $(VIOL_FILES) --test $(VIOL_TEST)
	@printf '[lint] 4/6 %s\n' '$(CONTROL_TOP)'
	$(BUILD_VERILATOR) --mode lint --config $(CONFIG) --jobs $(JOBS) \
	    --top $(CONTROL_TOP) --files $(CONTROL_FILES) --test $(CONTROL_TEST)
	@printf '[lint] 5/6 %s\n' '$(CDC_TOP)'
	$(BUILD_VERILATOR) --mode lint --config $(CONFIG) --jobs $(JOBS) \
	    --top $(CDC_TOP) --files $(CDC_FILES) --test $(firstword $(CDC_TESTS))
	@printf '[lint] 6/6 %s\n' '$(CDCV_TOP)'
	$(BUILD_VERILATOR) --mode lint --config $(CONFIG) --jobs $(JOBS) \
	    --top $(CDCV_TOP) --files $(CDCV_FILES) --test $(CDCV_TEST)
endef

# `sim-tiny`: SPEC 12.1 fast build of every simulation top, then every test
# once per seed in SEEDS. Each run prints its own seed and RESULT: line; a single
# failing seed fails the target, and the remaining seeds still run so one
# invocation shows whether a failure is seed-specific.
#
# Test list (grows with the design; numerics-check runs first, as a prerequisite)
#   test_stream_loopback     benchmark_sim_top — the SPEC 5 loopback, now built
#                            from the canonical primitives, plus the beat-by-beat
#                            packing cross-check against the RTL's m_payload.
#   test_stream_primitives   stream_prims_top — per-primitive stall, framing,
#                            occupancy, capacity, latency and throughput checks.
#   test_stream_assertions   stream_violator_top — the negative test. Exits 0
#                            when every expected assertion fired, so an
#                            expected failure is a passing result for the suite.
#   test_control_regs        control_top — the SPEC 9 register/control plane.
#   test_sync_fifo           cdc_prims_top — rtl/common/sync_fifo.sv against the
#                            cycle-accurate C++ reference model, every observable
#                            on every cycle, in two configurations.
#   test_async_fifo          cdc_prims_top — async_fifo and stream_cdc across the
#                            seven-entry clock-ratio sweep, both directions,
#                            scoreboarded for loss, duplication and reordering.
#   test_cdc_synchronizers   cdc_prims_top — cdc_pulse, cdc_handshake and
#                            cdc_sync2 across the same sweep, including the pulse
#                            overrun case and back-to-back handshakes.
#   test_cdc_assertions      cdc_violator_top — the CDC negative test. Requires
#                            a_gray_one_bit and a_hs_data_stable (among others)
#                            to fire by name, and the clean mode to stay clean.
define SIM_TINY_RECIPE
	$(REGMAP_CHECK_RECIPE)
	$(BUILD_VERILATOR) --mode fast --config tiny --jobs $(JOBS) --test $(TEST)
	$(BUILD_VERILATOR) --mode fast --config tiny --jobs $(JOBS) \
	    --top $(STREAM_TOP) --files $(STREAM_FILES) --test $(STREAM_TEST)
	$(BUILD_VERILATOR) --mode fast --config tiny --jobs $(JOBS) \
	    --top $(VIOL_TOP) --files $(VIOL_FILES) --test $(VIOL_TEST)
	$(BUILD_VERILATOR) --mode fast --config tiny --jobs $(JOBS) \
	    --top $(CONTROL_TOP) --files $(CONTROL_FILES) --test $(CONTROL_TEST)
	@for t in $(CDC_TESTS); do \
	    $(BUILD_VERILATOR) --mode fast --config tiny --jobs $(JOBS) \
	        --top $(CDC_TOP) --files $(CDC_FILES) --test $$t || exit 1; \
	  done
	$(BUILD_VERILATOR) --mode fast --config tiny --jobs $(JOBS) \
	    --top $(CDCV_TOP) --files $(CDCV_FILES) --test $(CDCV_TEST)
	@printf '[sim-tiny] seeds: %s\n' '$(SEEDS)'
	@printf '[sim-tiny] tests: %s %s %s %s %s %s\n' '$(TEST)' '$(STREAM_TEST)' \
	    '$(VIOL_TEST)' '$(CONTROL_TEST)' '$(CDC_TESTS)' '$(CDCV_TEST)'
	@rc=0; for s in $(SEEDS); do \
	    printf '\n[sim-tiny] ===== seed %s : %s =====\n' "$$s" '$(TEST)'; \
	    ./$(SIM_TINY_BIN) +seed=$$s +results=$(RESULTS_DIR) || rc=1; \
	    printf '\n[sim-tiny] ===== seed %s : %s =====\n' "$$s" '$(STREAM_TEST)'; \
	    ./$(STREAM_BIN) +seed=$$s +results=$(RESULTS_DIR) || rc=1; \
	    printf '\n[sim-tiny] ===== seed %s : %s (expects assertions to fire) =====\n' \
	        "$$s" '$(VIOL_TEST)'; \
	    ./$(VIOL_BIN) +seed=$$s +results=$(RESULTS_DIR) || rc=1; \
	    printf '\n[sim-tiny] ===== seed %s : %s =====\n' "$$s" '$(CONTROL_TEST)'; \
	    ./$(CONTROL_BIN) +seed=$$s +results=$(RESULTS_DIR) || rc=1; \
	    for t in $(CDC_TESTS); do \
	      printf '\n[sim-tiny] ===== seed %s : %s =====\n' "$$s" "$$t"; \
	      ./$(CDC_BIN_DIR)/V$(CDC_TOP)_$$t +seed=$$s +results=$(RESULTS_DIR) || rc=1; \
	    done; \
	    printf '\n[sim-tiny] ===== seed %s : %s (expects assertions to fire) =====\n' \
	        "$$s" '$(CDCV_TEST)'; \
	    ./$(CDCV_BIN) +seed=$$s +results=$(RESULTS_DIR) || rc=1; \
	  done; \
	  if [ $$rc -ne 0 ]; then \
	    printf '\n[sim-tiny] FAILED (seeds: %s)\n' '$(SEEDS)' 1>&2; exit 1; \
	  fi; \
	  printf '\n[sim-tiny] PASS for every seed: %s\n' '$(SEEDS)'
endef

# `numerics-check` (issue #4): the SPEC 6 / 12.4 fixed-point equivalence proof.
# Two steps, both of which must pass before sim-tiny runs anything else:
#
#   1. Standalone C++: builds model/cpp/fxp with plain g++ under the gate's
#      -O3 -Wall -Wextra -Werror contract and checks every vector in
#      model/vectors/ bit-exactly. No Verilator involved, because the reference
#      model has to stand on its own before it is trusted as the RTL oracle.
#   2. Verilator: drives the same vectors through fxp_probe_top — which is
#      nothing but calls into rtl/packages/fxp_pkg.sv — and compares against
#      both the vectors and the C++ library.
#
# Steps 1 and 2 also re-verify that the committed vectors are exactly what
# model/python/gen_fxp_vectors.py produces for its recorded seed, when a Python
# interpreter is available; without one the vector files are still checked
# against their own declared record counts by the loader.
define NUMERICS_RECIPE
	@printf '[numerics] 1/4 vectors: regenerate-and-compare (%s)\n' '$(VECTORS_DIR)'
	@if [ -n '$(PYTHON)' ]; then \
	    $(PYTHON) model/python/gen_fxp_vectors.py --out $(VECTORS_DIR) --check; \
	  else \
	    printf '[numerics] no Python found; skipping the vector regeneration check\n'; \
	  fi
	@printf '[numerics] 2/4 lint the probe build (%s is sim-only, not in files.f)\n' '$(FXP_TOP)'
	$(BUILD_VERILATOR) --mode lint --config tiny --jobs $(JOBS) \
	    --top $(FXP_TOP) --files $(FXP_FILES) --test $(FXP_TEST)
	@printf '[numerics] 3/4 C++ reference model vs vectors (%s %s)\n' '$(CXX)' '$(NUMERICS_CXXFLAGS)'
	@mkdir -p $(NUMERICS_DIR)
	$(CXX) $(NUMERICS_CXXFLAGS) -o $(NUMERICS_BIN) $(NUMERICS_SRC)
	./$(NUMERICS_BIN) --vectors $(VECTORS_DIR)
	@printf '[numerics] 4/4 RTL fxp_pkg vs vectors vs C++ (Verilator, top=%s)\n' '$(FXP_TOP)'
	$(BUILD_VERILATOR) --mode fast --config tiny --jobs $(JOBS) \
	    --top $(FXP_TOP) --files $(FXP_FILES) --test $(FXP_TEST)
	./$(FXP_BIN) +seed=$(SEED) +results=$(RESULTS_DIR) +vectors=$(VECTORS_DIR)
	@printf '\n[numerics] PASS: RTL, C++ and NumPy agree bit-exactly\n'
endef

# `cdc-inventory` (issue #6): the SPEC 8 "explicit CDC inventory report".
# A sub-target of sim-tiny, not a SPEC 16 entry point, for the same reason
# numerics-check is one: the report must be regenerated and re-checked on every
# regression without adding a top-level command the spec does not name.
#
# The lint pass first is not redundant. It is what regenerates
# sim/verilator/generated/config_pkg.sv from config/<name>.json, so
# `make cdc-inventory` works from a clean checkout without having built
# anything else.
#
# --strict: a crossing the script cannot classify — including any instantiated
# module with two or more clock ports that carries no (* cdc_primitive *)
# attribute — fails the target. That is what keeps the inventory complete as the
# design grows, rather than complete on the day it was written.
define CDC_INVENTORY_RECIPE
	@printf '[cdc-inventory] SPEC 8 crossing report for top=%s -> %s\n' \
	    '$(CDC_TOP)' '$(CDC_INVENTORY_JSON)'
	$(PYTHON_CHECK)
	$(BUILD_VERILATOR) --mode lint --config $(CONFIG) --jobs $(JOBS) \
	    --top $(CDC_TOP) --files $(CDC_FILES) --test $(firstword $(CDC_TESTS)) --quiet
	$(PYTHON) scripts/cdc_inventory.py --top $(CDC_TOP) --files $(CDC_FILES) \
	    --out $(CDC_INVENTORY_JSON) --print --strict
endef

# Remaining simulation entry points. The Verilator flow itself exists as of
# issue #2; what these targets are missing is the RTL and the tests they would
# run, so they stay stubs pointed at the issues that deliver those.
define SIM_STUB_17
	$(call TODO,17,Phase 3: Medium pipeline integration - stress and coverage)
endef

define SIM_STUB_20
	$(call TODO,20,Phase 5: Full-scale elaboration and smoke tests)
endef

endif

# --- Quartus-side recipe ---------------------------------------------------
# Never dispatches into WSL. Validates the toolchain path first so an absent or
# mislocated Quartus fails loudly rather than silently.

# quartus_sta lives next to quartus_sh. report_sta / report_congestion /
# report_retiming need the ::quartus::sta timing-netlist API, so they run under
# quartus_sta; compile / report_utilization / export_results run under
# quartus_sh.
QUARTUS_BIN := $(dir $(QUARTUS_SH))
QUARTUS_STA ?= $(QUARTUS_BIN)quartus_sta$(suffix $(QUARTUS_SH))
QSCRIPTS    := quartus/scripts

# Python for scripts/parse_quartus.py and scripts/build_verilator.py. Order
# matters on Windows: `python3`
# there resolves to the Microsoft Store alias stub, which is not an
# interpreter, so the py launcher is tried first.
ifeq ($(HOST_KIND),windows)
  PYTHON_CANDIDATES := py python3 python
else
  PYTHON_CANDIDATES := python3 python
endif
PYTHON ?= $(shell for p in $(PYTHON_CANDIDATES); do \
	  if command -v $$p >/dev/null 2>&1 && $$p -c '' >/dev/null 2>&1; then echo $$p; break; fi; \
	done)

define QUARTUS_CHECK
	@test -x '$(QUARTUS_SH)' || { \
	  printf 'ERROR: quartus_sh not found or not executable: %s\n' '$(QUARTUS_SH)' 1>&2; \
	  printf 'Set QUARTUS_SH to the absolute path of quartus_sh.exe.\n' 1>&2; \
	  exit 2; }
	@'$(QUARTUS_SH)' --version >/dev/null 2>&1 || { \
	  printf 'ERROR: cannot execute %s from this host.\n' '$(QUARTUS_SH)' 1>&2; \
	  if test '$(HOST_KIND)' = 'wsl'; then \
	    printf '\n' 1>&2; \
	    printf 'This WSL distribution has Windows interop disabled: /proc/sys/fs/binfmt_misc/\n' 1>&2; \
	    printf 'WSLInterop is absent, so Linux cannot launch any Windows .exe, and the\n' 1>&2; \
	    printf 'quartus-* targets cannot run from here.\n' 1>&2; \
	    printf '\n' 1>&2; \
	    printf 'Run Quartus targets from the Windows side instead, e.g. from Git Bash:\n' 1>&2; \
	    printf '  C:/altera_pro/26.1/riscfree/build_tools/bin/make.exe $@\n' 1>&2; \
	    printf '\n' 1>&2; \
	    printf 'Or enable interop (a host configuration change, not done by this Makefile):\n' 1>&2; \
	    printf '  add [interop] enabled=true to /etc/wsl.conf and run wsl --shutdown.\n' 1>&2; \
	  fi; \
	  exit 2; }
	@test -x '$(QUARTUS_STA)' || { \
	  printf 'ERROR: quartus_sta not found or not executable: %s\n' '$(QUARTUS_STA)' 1>&2; \
	  printf 'Set QUARTUS_STA to the absolute path of quartus_sta.exe.\n' 1>&2; \
	  exit 2; }
	@printf '[quartus] host=%s quartus_sh=%s seed=%s\n' '$(HOST_KIND)' '$(QUARTUS_SH)' '$(SEED)'
endef

define PYTHON_CHECK
	@test -n '$(PYTHON)' || { \
	  printf 'ERROR: no working Python found (tried: $(PYTHON_CANDIDATES)).\n' 1>&2; \
	  printf 'Set PYTHON to an interpreter, e.g. make quartus-report PYTHON=py\n' 1>&2; \
	  exit 2; }
endef

# Every report script degrades gracefully when the stage it needs has not run
# (it writes a "requires fit" fragment and exits 0), so this block is safe
# after a bare quartus-map as well as after a full compile.
define QUARTUS_REPORTS
	@'$(QUARTUS_STA)' -t $(QSCRIPTS)/report_sta.tcl
	@'$(QUARTUS_SH)'  -t $(QSCRIPTS)/report_utilization.tcl
	@'$(QUARTUS_STA)' -t $(QSCRIPTS)/report_congestion.tcl
	@'$(QUARTUS_STA)' -t $(QSCRIPTS)/report_retiming.tcl
endef

# ===========================================================================
# Help (default goal)
# ===========================================================================

.DEFAULT_GOAL := help

help:
	@printf 'Agilex 7 Wideband Processing Benchmark — make entry points (SPEC.md 16)\n'
	@printf '\n'
	@printf 'Host detected: %s   (uname -s=%s)\n' '$(HOST_KIND)' '$(UNAME_S)'
	@printf 'Simulation:    WSL %s, Verilator\n' '$(WSL_DISTRO)'
	@printf 'Quartus:       %s\n' '$(QUARTUS_SH)'
	@printf 'Config:        CONFIG=%s -> %s   SEED=%s   JOBS=%s\n' '$(CONFIG)' '$(CONFIG_JSON)' '$(SEED)' '$(JOBS)'
	@printf 'sim-tiny:      TEST=%s   SEEDS=%s\n' '$(TEST)' '$(SEEDS)'
	@printf '\n'
	@printf 'TARGET             SIDE      STATUS\n'
	@printf -- '------------------ --------- ---------------------------------------------\n'
	@printf '%-18s %-9s %s\n' 'help'             'local'   'this message (default goal)'
	@printf '%-18s %-9s %s\n' 'env-check'        'local'   'report detected toolchain locations'
	@printf '\n'
	@printf '%-18s %-9s %s\n' 'lint'             'wsl'     'verilator --lint-only --Wall (zero unwaived warnings)'
	@printf '%-18s %-9s %s\n' 'numerics-check'   'wsl'     'SPEC 6/12.4 fixed-point equivalence (sub-target of sim-tiny)'
	@printf '%-18s %-9s %s\n' 'regmap-check'     'local'   'SPEC 9 register map: generated artefacts match control/regmap.json'
	@printf '%-18s %-9s %s\n' 'cdc-inventory'    'wsl'     'SPEC 8 CDC crossing report (sub-target of sim-tiny)'
	@printf '%-18s %-9s %s\n' 'sim-tiny'         'wsl'     'numerics + regmap + inventory + fast builds + every test'
	@printf '%-18s %-9s %s\n' 'sim-medium'       'wsl'     'TODO(issue #17) medium-config regression'
	@printf '%-18s %-9s %s\n' 'sim-random'       'wsl'     'TODO(issue #17) randomized regression'
	@printf '%-18s %-9s %s\n' 'sim-stress'       'wsl'     'TODO(issue #17) long stress test'
	@printf '%-18s %-9s %s\n' 'sim-coverage'     'wsl'     'TODO(issue #17) coverage build and report'
	@printf '%-18s %-9s %s\n' 'sim-full-smoke'   'wsl'     'TODO(issue #20) full-scale smoke test'
	@printf '\n'
	@printf '%-18s %-9s %s\n' 'quartus-map'      'windows' 'Analysis and Synthesis (quartus_syn)'
	@printf '%-18s %-9s %s\n' 'quartus-fit'      'windows' 'Analysis and Synthesis + Fitter'
	@printf '%-18s %-9s %s\n' 'quartus-sta'      'windows' 'STA + all reports on the existing fit'
	@printf '%-18s %-9s %s\n' 'quartus-report'   'windows' 'export JSON record + validate/summarise'
	@printf '%-18s %-9s %s\n' 'quartus-compile'  'windows' 'full compile + STA + reports + export'
	@printf '\n'
	@printf '%-18s %-9s %s\n' 'seed-sweep'       'windows' 'TODO(issue #23) ten-seed robustness sweep'
	@printf '%-18s %-9s %s\n' 'compare-baseline' 'local'   'TODO(issue #21) compare current run to baseline'
	@printf '%-18s %-9s %s\n' 'reproduce-final'  'both'    'TODO(issue #25) reproduce the final result'
	@printf '\n'
	@printf 'numerics-check and cdc-inventory are not SPEC 16 entry points; they are\n'
	@printf 'the issue #4 numerics gate and the SPEC 8 CDC inventory report, run\n'
	@printf 'automatically as prerequisites of sim-tiny and listed here so each can\n'
	@printf 'also be run on its own while working on the code it covers.\n'
	@printf '\n'
	@printf 'lint and sim-tiny (issue #2), numerics-check (issue #4) and the quartus-*\n'
	@printf 'targets (issue #3) are implemented. Targets marked TODO are still stubs:\n'
	@printf 'they print TODO(issue #N)\n'
	@printf 'and exit 1; GNU make then reports its own exit status 2 for the failed\n'
	@printf 'recipe.\n'
	@printf '\n'
	@printf 'The coverage and debug build modes (SPEC 12.1) have no make target yet; run\n'
	@printf 'scripts/build_verilator.py --mode coverage|debug directly. See\n'
	@printf 'sim/verilator/README.md.\n'
	@printf '\n'
	@printf 'This host has WSL Windows-interop DISABLED, so quartus-* cannot run from WSL.\n'
	@printf 'Run them from the Windows side with the make that ships with Quartus:\n'
	@printf '  C:/altera_pro/26.1/riscfree/build_tools/bin/make.exe quartus-map\n'

env-check:
	@printf 'HOST_KIND     = %s\n' '$(HOST_KIND)'
	@printf 'uname -s      = %s\n' '$(UNAME_S)'
	@printf 'uname -r      = %s\n' '$(UNAME_R)'
	@printf 'CURDIR        = %s\n' '$(CURDIR)'
	@printf 'WSL_DISTRO    = %s\n' '$(WSL_DISTRO)'
	@printf 'WSL_REPO_DIR  = %s\n' '$(WSL_REPO_DIR)'
	@printf 'QUARTUS_SH    = %s' '$(QUARTUS_SH)'
	@if test -x '$(QUARTUS_SH)'; then printf '   [found]'; else printf '   [MISSING]'; fi
	@if '$(QUARTUS_SH)' --version >/dev/null 2>&1; then printf ' [runnable]\n'; else printf ' [NOT RUNNABLE FROM THIS HOST]\n'; fi
	@printf 'QUARTUS_STA   = %s' '$(QUARTUS_STA)'
	@if test -x '$(QUARTUS_STA)'; then printf '   [found]\n'; else printf '   [MISSING]\n'; fi
	@printf 'CONFIG        = %s -> %s' '$(CONFIG)' '$(CONFIG_JSON)'
	@if test -f '$(CONFIG_JSON)'; then printf '   [found]\n'; else printf '   [MISSING]\n'; fi
	@printf 'SEED          = %s\n' '$(SEED)'
	@printf 'SEEDS         = %s\n' '$(SEEDS)'
	@printf 'JOBS          = %s\n' '$(JOBS)'
	@printf 'TEST          = %s\n' '$(TEST)'
	@printf 'RESULTS_DIR   = %s\n' '$(RESULTS_DIR)'
	@printf 'PYTHON        = %s' '$(PYTHON)'
	@if command -v $(PYTHON) >/dev/null 2>&1; then printf '   [found]\n'; else printf '   [MISSING]\n'; fi
	@printf 'verilator     = %s' "$$(command -v verilator 2>/dev/null || echo '(not on PATH)')"
	@if command -v verilator >/dev/null 2>&1; then printf '   [%s]\n' "$$(verilator --version)"; else printf '\n'; fi

# ===========================================================================
# Simulation targets (SPEC.md 16) — WSL / Verilator
# ===========================================================================

lint:
	$(LINT_RECIPE)

# `numerics-check` is a sub-target of sim-tiny, not a SPEC 16 entry point. On
# Windows the dependency is deliberately omitted: sim-tiny re-dispatches the
# whole target into WSL, and the WSL-side make applies the dependency there, so
# adding it here too would run the numerics gate twice.
ifneq ($(HOST_KIND),windows)
sim-tiny: numerics-check cdc-inventory
endif

numerics-check:
	$(NUMERICS_RECIPE)

cdc-inventory:
	$(CDC_INVENTORY_RECIPE)

# The register-map regeneration gate (issue #7). Also run inside lint and
# sim-tiny; standalone here so it can be run while editing control/regmap.json.
regmap-check:
	$(REGMAP_CHECK_RECIPE)

sim-tiny:
	$(SIM_TINY_RECIPE)

sim-medium:
	$(SIM_STUB_17)

sim-random:
	$(SIM_STUB_17)

sim-stress:
	$(SIM_STUB_17)

sim-coverage:
	$(SIM_STUB_17)

sim-full-smoke:
	$(SIM_STUB_20)

# ===========================================================================
# Quartus targets (SPEC.md 16) — Windows Quartus Prime Pro 26.1
# ===========================================================================

# Project: quartus/project/agilex7_wideband.{qpf,qsf}, top benchmark_fabric_top,
# device AGMF039R47B1E1VC. Scripts under quartus/scripts/ (SPEC.md 15).
# SEED flows into the Fitter and is recorded in the exported JSON (SPEC.md 25);
# it is never written into the tracked qsf.

# Analysis & Synthesis only (Pro: quartus_syn). Phase 0 gate, SPEC.md 19.
quartus-map:
	$(QUARTUS_CHECK)
	@'$(QUARTUS_SH)' -t $(QSCRIPTS)/compile.tcl map $(SEED)

# Analysis & Synthesis + Fitter.
quartus-fit:
	$(QUARTUS_CHECK)
	@'$(QUARTUS_SH)' -t $(QSCRIPTS)/compile.tcl fit $(SEED)

# Timing analysis + every report, against the existing fit. Does not recompile.
quartus-sta:
	$(QUARTUS_CHECK)
	@'$(QUARTUS_SH)' -t $(QSCRIPTS)/compile.tcl sta $(SEED)
	$(QUARTUS_REPORTS)

# Refresh every report against whatever the last compile produced, merge them
# into one JSON record, then validate and summarise it. Safe after a bare
# quartus-map: the reports that need a fit degrade to a documented "requires
# fit" fragment and the record's timing fields come out null with a note.
quartus-report:
	$(QUARTUS_CHECK)
	$(PYTHON_CHECK)
	$(QUARTUS_REPORTS)
	@'$(QUARTUS_SH)' -t $(QSCRIPTS)/export_results.tcl $(SEED)
	@$(PYTHON) scripts/parse_quartus.py results/timing/latest.json

# Full compile: syn + fit + sta, then every report and the JSON export.
quartus-compile:
	$(QUARTUS_CHECK)
	$(PYTHON_CHECK)
	@'$(QUARTUS_SH)' -t $(QSCRIPTS)/compile.tcl all $(SEED)
	$(QUARTUS_REPORTS)
	@'$(QUARTUS_SH)' -t $(QSCRIPTS)/export_results.tcl $(SEED)
	@$(PYTHON) scripts/parse_quartus.py results/timing/latest.json

# ===========================================================================
# Cross-toolchain analysis targets (SPEC.md 16)
# ===========================================================================

seed-sweep:
	$(call TODO,23,Phase 8: Ten-seed robustness sweep)

compare-baseline:
	$(call TODO,21,Phase 6: Baseline fit and comparison tooling)

reproduce-final:
	$(call TODO,25,Evidence package and reproducibility)

.PHONY: help env-check \
        lint numerics-check regmap-check cdc-inventory \
        sim-tiny sim-medium sim-random sim-stress sim-coverage sim-full-smoke \
        quartus-map quartus-fit quartus-sta quartus-report quartus-compile \
        seed-sweep compare-baseline reproduce-final
