#!/usr/bin/env python3
"""Drive Verilator for the four SPEC 12.1 build modes.

    scripts/build_verilator.py --mode lint|fast|coverage|debug
                               --config tiny|medium|large|full_agmf039
                               [--jobs N] [--seed N] [--test NAME] [--threads N]

Modes (SPEC 12.1)
-----------------
lint      ``--lint-only --Wall``. Warnings are fatal: ``--Wno-fatal`` is
          deliberately *not* passed, so any warning not covered by
          ``sim/verilator/lint_waivers.vlt`` fails the build. Waivers carry a
          written justification in that file.
fast      Optimised, assertions on, no trace, no coverage. The regression build.
coverage  ``--coverage`` (line, toggle, user). Slower; not used by sim-tiny.
debug     ``--trace-fst`` with limited depth, ``-O0 -g``, and
          ``-DSIM_TRACE_ENABLED``. Tracing is still disarmed at runtime until
          ``+trace`` is passed, so a debug binary reproduces a failing seed
          before it starts writing a waveform.

Configuration injection
-----------------------
``config/<name>.json`` is the single source of elaboration parameters (issue #1,
DECISIONS.md decision 4). This script reads it and generates two artefacts into
``sim/verilator/generated/`` (gitignored):

    config_pkg.sv    a SystemVerilog package imported by benchmark_sim_top
    config_sim.h     the same constants for the C++ harness and tests

Generating a package rather than passing ``-G`` overrides was chosen because
(a) ``-G`` has to be repeated on every Verilator *and* Quartus invocation and
the two would drift, (b) a package is visible to every module without threading
parameters through each level of hierarchy, and (c) the C++ side needs the same
numbers and a generated header keeps one source of truth. See DECISIONS.md.

Both files are written only when their content changes, so re-running the script
does not force a rebuild.

Python is confined to launching builds, exactly as SPEC 12.2 requires: it is
never in the per-cycle execution path.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

TOP_MODULE = "benchmark_sim_top"
FILES_F = Path("sim/verilator/files.f")
WAIVERS = Path("sim/verilator/lint_waivers.vlt")
GENERATED_DIR = Path("sim/verilator/generated")
BUILD_ROOT = Path("sim/verilator/build")

HARNESS_DIR = Path("sim/verilator/harness")
SIM_MAIN = Path("sim/verilator/sim_main.cpp")
TESTS_DIR = Path("sim/tests")

MODES = ("lint", "fast", "coverage", "debug")

# Empirically chosen; see DECISIONS.md 2026-07-25 "Verilator thread count".
# Re-measure with --threads before changing.
DEFAULT_THREADS = 1


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------


def clog2(n: int) -> int:
    """Ceiling log2, matching SystemVerilog $clog2 (0 and 1 both give 0)."""
    if n <= 1:
        return 0
    return (n - 1).bit_length()


def load_config(name: str) -> dict:
    path = REPO_ROOT / "config" / f"{name}.json"
    if not path.is_file():
        available = sorted(p.stem for p in (REPO_ROOT / "config").glob("*.json"))
        sys.exit(
            f"ERROR: no such config '{name}' ({path}). Available: {', '.join(available)}"
        )
    with path.open("r", encoding="utf-8") as fh:
        cfg = json.load(fh)
    if "params" not in cfg:
        sys.exit(f"ERROR: {path} has no 'params' object")
    return cfg


def derive_stream_params(params: dict) -> dict:
    """Provisional SPEC 5 stream bundle widths for the Phase 0 loopback.

    PROVISIONAL. Issue #5 owns the real stream interface and will replace these.
    They are derived rather than hard-coded so that the loopback and the harness
    resize with the configuration instead of silently staying tiny.
    """
    sample_w = int(params["SAMPLE_W"])
    n_antennas = int(params["N_ANTENNAS"])
    return {
        # One complex sample per beat: {I, Q}, each SAMPLE_W wide.
        "STREAM_DATA_W": 2 * sample_w,
        # Wide enough for one stream per antenna, floored at 2 bits so the
        # smallest configuration still exercises multi-stream scoreboarding.
        "STREAM_ID_W": max(2, clog2(n_antennas)),
        # 16 bits of sequence: long enough that no Phase 0 test wraps, which
        # keeps the scoreboard's transaction identity unique within a run.
        "STREAM_SEQ_W": 16,
        # Carries the frame tag at Phase 0 (see sim/tests/test_stream_loopback.cpp).
        "STREAM_USER_W": 4,
        # Register stages in the provisional loopback DUT.
        "STREAM_LOOPBACK_STAGES": 2,
    }


def render_config_pkg(cfg: dict, stream: dict) -> str:
    name = cfg.get("name", "unknown")
    lines = [
        "// GENERATED FILE - DO NOT EDIT.",
        "//",
        f"// Produced by scripts/build_verilator.py from config/{name}.json.",
        "// Elaboration parameters live in that JSON (DECISIONS.md decision 4);",
        "// editing this file is overwritten by the next build.",
        "",
        "package config_pkg;",
        "",
        f'  localparam string CONFIG_NAME = "{name}";',
        "",
        f"  // ---- SPEC 11 sized parameters ({name}) ----",
    ]
    sized = cfg.get("sized_params", [])
    invariant = cfg.get("invariant_params", [])
    params = cfg["params"]
    for key in sized:
        lines.append(f"  localparam int unsigned {key} = {int(params[key])};")
    lines += ["", "  // ---- SPEC 3 invariant parameters ----"]
    for key in invariant:
        lines.append(f"  localparam int unsigned {key} = {int(params[key])};")
    # Anything present in params but not classified, so a config addition is
    # never silently dropped.
    extra = [k for k in params if k not in sized and k not in invariant]
    if extra:
        lines += ["", "  // ---- unclassified parameters from the config JSON ----"]
        for key in sorted(extra):
            lines.append(f"  localparam int unsigned {key} = {int(params[key])};")
    lines += [
        "",
        "  // ---- provisional SPEC 5 stream bundle (issue #2; replaced by issue #5) ----",
    ]
    for key, value in stream.items():
        lines.append(f"  localparam int unsigned {key} = {value};")
    lines += ["", "endpackage : config_pkg", ""]
    return "\n".join(lines)


def render_config_header(cfg: dict, stream: dict) -> str:
    name = cfg.get("name", "unknown")
    params = cfg["params"]
    lines = [
        "// GENERATED FILE - DO NOT EDIT.",
        "//",
        f"// Produced by scripts/build_verilator.py from config/{name}.json.",
        "// The C++ harness and the RTL read the same numbers from the same JSON;",
        "// this header is the C++ half of that guarantee (SPEC 12.4).",
        "",
        "#ifndef SIM_GENERATED_CONFIG_SIM_H_",
        "#define SIM_GENERATED_CONFIG_SIM_H_",
        "",
        f'#define SIM_CONFIG_NAME "{name}"',
        "",
        "namespace sim_config {",
        "",
        f'inline constexpr const char* kName = "{name}";',
        "",
    ]
    for key in sorted(params):
        lines.append(f"inline constexpr unsigned {key} = {int(params[key])};")
    lines.append("")
    lines.append("// Provisional SPEC 5 stream bundle (issue #2; replaced by issue #5).")
    for key, value in stream.items():
        lines.append(f"inline constexpr unsigned {key} = {value};")
    lines += [
        "",
        "// Mask covering `bits` low bits; bits==64 yields all ones.",
        "constexpr unsigned long long mask_bits(unsigned bits) {",
        "  return bits >= 64 ? ~0ULL : ((1ULL << bits) - 1ULL);",
        "}",
        "",
        "}  // namespace sim_config",
        "",
        "#endif  // SIM_GENERATED_CONFIG_SIM_H_",
        "",
    ]
    return "\n".join(lines)


def write_if_changed(path: Path, content: str) -> bool:
    """Writes `content` to `path` only if different. Returns True if written."""
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_file():
        with path.open("r", encoding="utf-8", newline="") as fh:
            if fh.read() == content:
                return False
    with path.open("w", encoding="utf-8", newline="\n") as fh:
        fh.write(content)
    return True


def generate_config(config_name: str, quiet: bool) -> dict:
    cfg = load_config(config_name)
    stream = derive_stream_params(cfg["params"])
    pkg_path = REPO_ROOT / GENERATED_DIR / "config_pkg.sv"
    hdr_path = REPO_ROOT / GENERATED_DIR / "config_sim.h"
    wrote_pkg = write_if_changed(pkg_path, render_config_pkg(cfg, stream))
    wrote_hdr = write_if_changed(hdr_path, render_config_header(cfg, stream))
    if not quiet:
        print(
            f"[config] {config_name}: {pkg_path.relative_to(REPO_ROOT)} "
            f"{'written' if wrote_pkg else 'unchanged'}, "
            f"{hdr_path.relative_to(REPO_ROOT)} "
            f"{'written' if wrote_hdr else 'unchanged'}"
        )
    return cfg


# ---------------------------------------------------------------------------
# Verilator invocation
# ---------------------------------------------------------------------------


def cpp_sources(test: str) -> list[str]:
    """Harness sources + entry point + the selected test, in a stable order.

    Absolute paths: Verilator's generated makefile runs with the --Mdir as its
    working directory, so a repo-relative user source would not resolve.
    """
    srcs = sorted(str(p) for p in (REPO_ROOT / HARNESS_DIR).glob("*.cpp"))
    srcs.append(str(REPO_ROOT / SIM_MAIN))
    test_path = REPO_ROOT / TESTS_DIR / f"{test}.cpp"
    if not test_path.is_file():
        available = sorted(p.stem for p in (REPO_ROOT / TESTS_DIR).glob("*.cpp"))
        sys.exit(
            f"ERROR: no such test '{test}' ({test_path}). "
            f"Available: {', '.join(available) or '(none)'}"
        )
    srcs.append(str(test_path))
    return srcs


def build_dir(mode: str, config: str) -> Path:
    return BUILD_ROOT / f"{mode}_{config}"


def binary_path(mode: str, config: str, test: str) -> Path:
    return build_dir(mode, config) / f"V{TOP_MODULE}_{test}"


def verilator_command(args, cfg_name: str) -> list[str]:
    mdir = build_dir(args.mode, cfg_name)
    cmd = [
        args.verilator,
        "--top-module",
        TOP_MODULE,
        "--Mdir",
        str(mdir),
        "-f",
        str(FILES_F),
        str(WAIVERS),
    ]

    if args.mode == "lint":
        # No --Wno-fatal: an unwaived warning must fail the gate.
        cmd += ["--lint-only", "--Wall", "--assert"]
        return cmd

    prefix = f"V{TOP_MODULE}"
    exe_name = f"V{TOP_MODULE}_{args.test}"
    cflags = [
        "-std=c++17",
        f"-I{REPO_ROOT / 'sim/verilator'}",
        f"-I{REPO_ROOT / GENERATED_DIR}",
        f"-DSIM_BUILD_MODE_{args.mode.upper()}",
    ]

    cmd += [
        "--cc",
        "--exe",
        "--build",
        "--assert",
        "--prefix",
        prefix,
        "-o",
        exe_name,
        "--threads",
        str(args.threads),
    ]

    # Verilator's generated makefile compiles *user* sources as
    #   $(CXX) $(CXXFLAGS) $(CPPFLAGS) $(OPT) -c ...
    # i.e. $(OPT) lands *after* anything -CFLAGS injects, and its default is
    # -Os. Without overriding OPT, the harness and the test would silently be
    # built at -Os in every mode no matter what -CFLAGS says. -MAKEFLAGS puts a
    # command-line variable override on the generated make invocation, which
    # beats the makefile's own assignment. Keep the value free of spaces.
    # (The variable is OPT_FAST, not OPT: the generated per-user-file rules end
    # with $(OPT_FAST), so that is the one that wins the last-flag-wins race.)
    if args.mode == "fast":
        cflags += ["-O3"]
        if args.march_native:
            cflags += ["-march=native"]
        cmd += ["-O3", "--x-assign", "unique", "--x-initial", "unique"]
        cmd += ["-MAKEFLAGS", "OPT_FAST=-O3"]
    elif args.mode == "coverage":
        cflags += ["-O2"]
        cmd += ["--coverage", "-O2", "-MAKEFLAGS", "OPT_FAST=-O2"]
    elif args.mode == "debug":
        cflags += ["-O0", "-g", "-DSIM_TRACE_ENABLED"]
        cmd += [
            "--trace-fst",
            "--trace-depth",
            str(args.trace_depth),
            "--trace-structs",
            "-O0",
            "-MAKEFLAGS",
            "OPT_FAST=-O0",
        ]

    cmd += ["-CFLAGS", " ".join(cflags)]
    cmd += ["-j", str(args.jobs), "--build-jobs", str(args.jobs)]
    cmd += cpp_sources(args.test)
    return cmd


def main() -> int:
    p = argparse.ArgumentParser(
        description="Build the Verilator model in one of the four SPEC 12.1 modes.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--mode", choices=MODES, required=True, help="SPEC 12.1 build mode")
    p.add_argument(
        "--config",
        default="tiny",
        help="configuration name; reads config/<name>.json (default: tiny)",
    )
    p.add_argument(
        "--test",
        default="test_stream_loopback",
        help="test source stem under sim/tests/ (default: test_stream_loopback)",
    )
    p.add_argument(
        "--jobs",
        type=int,
        default=int(os.environ.get("JOBS", os.cpu_count() or 4)),
        help="parallel jobs for verilation and the C++ build",
    )
    p.add_argument(
        "--threads",
        type=int,
        default=DEFAULT_THREADS,
        help=(
            "Verilator model thread count. SPEC 12.1: 'Measure whether "
            "multithreading improves this particular model.' Default "
            f"{DEFAULT_THREADS}; see DECISIONS.md."
        ),
    )
    p.add_argument(
        "--seed",
        type=int,
        default=1,
        help=(
            "seed recorded for this build. The seed is a *runtime* argument "
            "(+seed=N); this only reports the default the runner should use."
        ),
    )
    p.add_argument("--trace-depth", type=int, default=8, help="debug-mode FST depth")
    p.add_argument(
        "--march-native",
        action="store_true",
        default=True,
        help="use -march=native in fast mode (default: on)",
    )
    p.add_argument(
        "--no-march-native",
        dest="march_native",
        action="store_false",
        help="portable fast build without -march=native",
    )
    p.add_argument(
        "--clean", action="store_true", help="remove the build directory first"
    )
    p.add_argument(
        "--print-binary",
        action="store_true",
        help="print only the resulting binary path and exit 0 (no build)",
    )
    p.add_argument("--quiet", action="store_true", help="less chatter")
    p.add_argument(
        "--verilator",
        default=os.environ.get("VERILATOR", "verilator"),
        help="verilator executable (default: $VERILATOR or 'verilator')",
    )
    args = p.parse_args()

    if args.print_binary:
        print(REPO_ROOT / binary_path(args.mode, args.config, args.test))
        return 0

    if shutil.which(args.verilator) is None:
        sys.exit(
            f"ERROR: '{args.verilator}' not found on PATH. Simulation runs inside "
            "WSL Ubuntu-24.04 (PLAN.md split-toolchain rule)."
        )

    if args.clean:
        target = REPO_ROOT / build_dir(args.mode, args.config)
        if target.exists():
            shutil.rmtree(target)

    generate_config(args.config, args.quiet)

    # Verilator only creates the last component of --Mdir.
    (REPO_ROOT / build_dir(args.mode, args.config)).mkdir(parents=True, exist_ok=True)

    cmd = verilator_command(args, args.config)
    if not args.quiet:
        print(f"[verilator] mode={args.mode} config={args.config} "
              f"threads={args.threads} jobs={args.jobs}")
        print("[verilator] " + " ".join(cmd))
    rc = subprocess.call(cmd, cwd=REPO_ROOT)
    if rc != 0:
        print(f"ERROR: verilator ({args.mode}) failed with exit status {rc}",
              file=sys.stderr)
        return rc

    if args.mode == "lint":
        print(f"[lint] clean: zero unwaived warnings for {TOP_MODULE} "
              f"(config {args.config})")
        return 0

    binary = REPO_ROOT / binary_path(args.mode, args.config, args.test)
    if not binary.is_file():
        print(f"ERROR: expected binary not produced: {binary}", file=sys.stderr)
        return 1
    if not args.quiet:
        print(f"[build] {binary.relative_to(REPO_ROOT)}")
        print(f"[build] run with: {binary.relative_to(REPO_ROOT)} +seed={args.seed}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
