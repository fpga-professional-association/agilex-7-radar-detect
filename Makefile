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
# Implemented: `lint` and `sim-tiny` (issue #2, Verilator flow) and the
# quartus-* targets (issue #3).
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

LINT_RECIPE     = $(SIM_DISPATCH)
SIM_TINY_RECIPE = $(SIM_DISPATCH)
SIM_STUB_17     = $(SIM_DISPATCH)
SIM_STUB_20     = $(SIM_DISPATCH)

else

# `lint`: SPEC 12.1 lint build. build_verilator.py omits --Wno-fatal, so any
# warning not justified in sim/verilator/lint_waivers.vlt exits non-zero.
define LINT_RECIPE
	@printf '[lint] verilator --lint-only --Wall, config=%s, waivers=%s\n' \
	    '$(CONFIG)' 'sim/verilator/lint_waivers.vlt'
	$(BUILD_VERILATOR) --mode lint --config $(CONFIG) --jobs $(JOBS) --test $(TEST)
endef

# `sim-tiny`: SPEC 12.1 fast build, then the loopback test once per seed in
# SEEDS. Each run prints its own seed and RESULT: line; a single failing seed
# fails the target, and the remaining seeds still run so one invocation shows
# whether a failure is seed-specific.
define SIM_TINY_RECIPE
	$(BUILD_VERILATOR) --mode fast --config tiny --jobs $(JOBS) --test $(TEST)
	@printf '[sim-tiny] seeds: %s\n' '$(SEEDS)'
	@rc=0; for s in $(SEEDS); do \
	    printf '\n[sim-tiny] ===== seed %s =====\n' "$$s"; \
	    ./$(SIM_TINY_BIN) +seed=$$s +results=$(RESULTS_DIR) || rc=1; \
	  done; \
	  if [ $$rc -ne 0 ]; then \
	    printf '\n[sim-tiny] FAILED (seeds: %s)\n' '$(SEEDS)' 1>&2; exit 1; \
	  fi; \
	  printf '\n[sim-tiny] PASS for every seed: %s\n' '$(SEEDS)'
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
	@printf '%-18s %-9s %s\n' 'sim-tiny'         'wsl'     'fast build + loopback test over SEEDS'
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
	@printf 'lint, sim-tiny (issue #2) and the quartus-* targets (issue #3) are\n'
	@printf 'implemented. Targets marked TODO are still stubs: they print TODO(issue #N)\n'
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
        lint sim-tiny sim-medium sim-random sim-stress sim-coverage sim-full-smoke \
        quartus-map quartus-fit quartus-sta quartus-report quartus-compile \
        seed-sweep compare-baseline reproduce-final
