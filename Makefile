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
#                    quartus_sh.exe. WSL can execute the .exe directly through
#                    /mnt/c, so no round trip through cmd.exe is required.
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
#   JOBS           Parallel job count for builds/compiles.    default: 16
#
# A clean checkout plus these variables is sufficient to run every target
# (SPEC.md 16).
#
# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
# Every target below is a scaffold stub as of issue #1. Stubs fail loudly: they
# print `TODO(issue #N)` and the stub command exits 1. GNU make then reports its
# own exit status 2, which is make's documented status for a failed recipe (1 is
# reserved for -q question mode), so `make <target>; echo $$?` prints 2. No stub
# ever silently succeeds. Run `make help` for the target list and the issue that
# implements each one.

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
JOBS         ?= 16

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

# --- simulation-side recipe ------------------------------------------------
# On Windows, re-dispatch into WSL. On WSL/Linux, run the (not yet existing)
# Verilator flow.

ifeq ($(HOST_KIND),windows)
define SIM_RECIPE
	@printf '[dispatch] %s -> wsl -d %s make -C %s\n' '$@' '$(WSL_DISTRO)' '$(WSL_REPO_DIR)'
	@wsl.exe -d $(WSL_DISTRO) -- make -C $(WSL_REPO_DIR) $@
endef
else
define SIM_RECIPE
	$(call TODO,2,Phase 0: Verilator flow)
endef
endif

# --- Quartus-side recipe ---------------------------------------------------
# Never dispatches into WSL. Validates the toolchain path first so an absent or
# mislocated Quartus fails loudly rather than silently.

define QUARTUS_RECIPE
	@test -x '$(QUARTUS_SH)' || { \
	  printf 'ERROR: quartus_sh not found or not executable: %s\n' '$(QUARTUS_SH)' 1>&2; \
	  printf 'Set QUARTUS_SH to the absolute path of quartus_sh.exe.\n' 1>&2; \
	  exit 2; }
	@printf '[quartus] host=%s quartus_sh=%s\n' '$(HOST_KIND)' '$(QUARTUS_SH)'
	$(call TODO,3,Phase 0: Quartus flow)
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
	@printf '\n'
	@printf 'TARGET             SIDE      STATUS\n'
	@printf -- '------------------ --------- ---------------------------------------------\n'
	@printf '%-18s %-9s %s\n' 'help'             'local'   'this message (default goal)'
	@printf '%-18s %-9s %s\n' 'env-check'        'local'   'report detected toolchain locations'
	@printf '\n'
	@printf '%-18s %-9s %s\n' 'lint'             'wsl'     'TODO(issue #2) Verilator lint'
	@printf '%-18s %-9s %s\n' 'sim-tiny'         'wsl'     'TODO(issue #2) tiny-config regression'
	@printf '%-18s %-9s %s\n' 'sim-medium'       'wsl'     'TODO(issue #2) medium-config regression'
	@printf '%-18s %-9s %s\n' 'sim-random'       'wsl'     'TODO(issue #2) randomized regression'
	@printf '%-18s %-9s %s\n' 'sim-stress'       'wsl'     'TODO(issue #2) long stress test'
	@printf '%-18s %-9s %s\n' 'sim-coverage'     'wsl'     'TODO(issue #2) coverage build and report'
	@printf '%-18s %-9s %s\n' 'sim-full-smoke'   'wsl'     'TODO(issue #2) full-scale smoke test'
	@printf '\n'
	@printf '%-18s %-9s %s\n' 'quartus-map'      'windows' 'TODO(issue #3) Analysis and Synthesis'
	@printf '%-18s %-9s %s\n' 'quartus-fit'      'windows' 'TODO(issue #3) Fitter'
	@printf '%-18s %-9s %s\n' 'quartus-sta'      'windows' 'TODO(issue #3) TimeQuest STA'
	@printf '%-18s %-9s %s\n' 'quartus-report'   'windows' 'TODO(issue #3) machine-readable report export'
	@printf '%-18s %-9s %s\n' 'quartus-compile'  'windows' 'TODO(issue #3) full compile + STA + reports'
	@printf '\n'
	@printf '%-18s %-9s %s\n' 'seed-sweep'       'windows' 'TODO(issue #23) ten-seed robustness sweep'
	@printf '%-18s %-9s %s\n' 'compare-baseline' 'local'   'TODO(issue #21) compare current run to baseline'
	@printf '%-18s %-9s %s\n' 'reproduce-final'  'both'    'TODO(issue #25) reproduce the final result'
	@printf '\n'
	@printf 'Every implementation target is still a stub: it prints TODO(issue #N) and\n'
	@printf 'exits 1. GNU make reports its own exit status 2 for a failed recipe.\n'

env-check:
	@printf 'HOST_KIND     = %s\n' '$(HOST_KIND)'
	@printf 'uname -s      = %s\n' '$(UNAME_S)'
	@printf 'uname -r      = %s\n' '$(UNAME_R)'
	@printf 'CURDIR        = %s\n' '$(CURDIR)'
	@printf 'WSL_DISTRO    = %s\n' '$(WSL_DISTRO)'
	@printf 'WSL_REPO_DIR  = %s\n' '$(WSL_REPO_DIR)'
	@printf 'QUARTUS_SH    = %s' '$(QUARTUS_SH)'
	@if test -x '$(QUARTUS_SH)'; then printf '   [found]\n'; else printf '   [MISSING]\n'; fi
	@printf 'CONFIG        = %s -> %s' '$(CONFIG)' '$(CONFIG_JSON)'
	@if test -f '$(CONFIG_JSON)'; then printf '   [found]\n'; else printf '   [MISSING]\n'; fi
	@printf 'SEED          = %s\n' '$(SEED)'
	@printf 'JOBS          = %s\n' '$(JOBS)'

# ===========================================================================
# Simulation targets (SPEC.md 16) — WSL / Verilator
# ===========================================================================

lint:
	$(SIM_RECIPE)

sim-tiny:
	$(SIM_RECIPE)

sim-medium:
	$(SIM_RECIPE)

sim-random:
	$(SIM_RECIPE)

sim-stress:
	$(SIM_RECIPE)

sim-coverage:
	$(SIM_RECIPE)

sim-full-smoke:
	$(SIM_RECIPE)

# ===========================================================================
# Quartus targets (SPEC.md 16) — Windows Quartus Prime Pro 26.1
# ===========================================================================

quartus-map:
	$(QUARTUS_RECIPE)

quartus-fit:
	$(QUARTUS_RECIPE)

quartus-sta:
	$(QUARTUS_RECIPE)

quartus-report:
	$(QUARTUS_RECIPE)

quartus-compile:
	$(QUARTUS_RECIPE)

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
