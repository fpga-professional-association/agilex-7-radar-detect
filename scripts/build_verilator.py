#!/usr/bin/env python3
"""Drive Verilator for the four SPEC 12.1 build modes.

    scripts/build_verilator.py --mode lint|fast|coverage|debug
                               --config tiny|medium|large|full_agmf039
                               [--jobs N] [--seed N] [--test NAME] [--threads N]
                               [--top MODULE] [--files LIST.f]

``--top`` / ``--files`` select a different design to verilate; they are changed
together, and a non-default top builds into its own directory so the two never
share objects. The only secondary top today is ``fxp_probe_top``
(``sim/verilator/files_fxp.f``), the SPEC 12.4 numerics cross-check that
``make numerics-check`` runs.

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

# Default design under test: the SPEC 4.1 simulation top, built from files.f.
# `--top` / `--files` override both together for a self-contained secondary
# build. The only one today is the SPEC 12.4 numerics cross-check
# (`fxp_probe_top` + sim/verilator/files_fxp.f, driven by `make numerics-check`),
# which is kept independent of the rest of the design on purpose: a failure
# there is then always a numerics failure.
TOP_MODULE = "benchmark_sim_top"
FILES_F = Path("sim/verilator/files.f")
WAIVERS = Path("sim/verilator/lint_waivers.vlt")
GENERATED_DIR = Path("sim/verilator/generated")
BUILD_ROOT = Path("sim/verilator/build")

HARNESS_DIR = Path("sim/verilator/harness")
SIM_MAIN = Path("sim/verilator/sim_main.cpp")
TESTS_DIR = Path("sim/tests")

# Bit-accurate C++ reference model (SPEC 12.4). On the include path for every
# build so a test can compare RTL against the model in the same binary.
MODEL_CPP_DIR = Path("model/cpp")

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
    """SPEC 5 stream bundle geometry and the derived payload layout.

    MIRROR, NOT SOURCE. The normative definition of the SPEC 5 payload layout is
    ``rtl/packages/stream_pkg.sv`` — its field order and its offset functions.
    What is computed here is a second implementation of the same arithmetic, so
    that the C++ harness (which cannot call a SystemVerilog function) and the
    generated configuration package can be built from plain constants.

    The two are compared at time 0 of every simulation by the ``initial`` block
    at the bottom of ``sim/verilator/tops/benchmark_sim_top.sv``, which $fatals
    by name on any disagreement. Change the field order in stream_pkg.sv without
    changing this function and the next run fails immediately; that is the point.

    Canonical field order (stream_pkg.sv, NORMATIVE)::

        MSB                                                     LSB
        +--------+-----+-----+-----------+---------+--------+
        |  data  | sof | eof | stream_id |   seq   |  user  |
        +--------+-----+-----+-----------+---------+--------+
    """
    sample_w = int(params["SAMPLE_W"])
    n_antennas = int(params["N_ANTENNAS"])

    # One complex sample per beat: {I, Q}, each SAMPLE_W wide.
    data_w = 2 * sample_w
    # Wide enough for one stream per antenna, floored at 2 bits so the smallest
    # configuration still exercises multi-stream scoreboarding.
    id_w = max(2, clog2(n_antennas))
    # 16 bits of sequence: long enough that no unit test wraps it, which keeps
    # the scoreboard's transaction identity unique within a run.
    seq_w = 16
    # Carries the frame tag (see sim/tests/test_stream_loopback.cpp).
    user_w = 4

    # Field offsets, in the order stream_pkg.sv defines them.
    user_lsb = 0
    seq_lsb = user_w
    id_lsb = user_w + seq_w
    eof_lsb = user_w + seq_w + id_w
    sof_lsb = eof_lsb + 1
    data_lsb = sof_lsb + 1
    payload_w = data_lsb + data_w

    return {
        "STREAM_DATA_W": data_w,
        "STREAM_ID_W": id_w,
        "STREAM_SEQ_W": seq_w,
        "STREAM_USER_W": user_w,
        "STREAM_PAYLOAD_W": payload_w,
        "STREAM_USER_LSB": user_lsb,
        "STREAM_SEQ_LSB": seq_lsb,
        "STREAM_ID_LSB": id_lsb,
        "STREAM_EOF_LSB": eof_lsb,
        "STREAM_SOF_LSB": sof_lsb,
        "STREAM_DATA_LSB": data_lsb,
        # stream_loopback is skid -> elastic -> skid; each contributes one cycle
        # of latency with no backpressure. benchmark_sim_top checks this number
        # against the sum the RTL computes from stream_pkg's own constants.
        "STREAM_LOOPBACK_ELASTIC_DEPTH": 4,
        "STREAM_LOOPBACK_LATENCY": 3,
        # Geometry of the four DUTs in sim/verilator/tops/stream_prims_top.sv,
        # so the per-primitive test and that top agree on depth and stage count
        # without either hard-coding the other's numbers.
        "STREAM_PRIM_EB_SHALLOW_DEPTH": 2,
        "STREAM_PRIM_EB_DEEP_DEPTH": 8,
        "STREAM_PRIM_PIPE_STAGES": 4,
        "STREAM_PRIM_PIPE_OUT_DEPTH": 6,
        # Geometry of the DUTs in sim/verilator/tops/cdc_prims_top.sv (issue #6),
        # so the CDC unit tests and that top agree on depth and synchronizer stage
        # count without either hard-coding the other's numbers. These are
        # unit-test sizes, not design sizes: a real crossing sizes DEPTH against
        # its own synchronizer round trip (see rtl/cdc/async_fifo.sv).
        "CDC_SYNC_FIFO_DEPTH": 8,
        "CDC_SYNC_FIFO_SA_DEPTH": 4,
        "CDC_ASYNC_FIFO_DEPTH": 8,
        "CDC_STREAM_CDC_DEPTH": 16,
        "CDC_SYNC_STAGES": 2,
        "CDC_HANDSHAKE_W": 16,
        # Geometry of sim/verilator/tops/cdc_violator.sv, the SPEC 14 negative
        # test's deliberately broken crossing. Four pointer bits is the smallest
        # width at which a binary counter diverges from a Gray one within three
        # increments, which is what mode 1 has to demonstrate.
        "CDC_VIOLATOR_PTR_W": 4,
        # Geometry of sim/verilator/tops/telemetry_top.sv (issue #8), so the
        # telemetry tests and that top agree on counter widths, FIFO depth and
        # tracked-stream count without either hard-coding the other's numbers.
        #
        # TELEM_TRACKED_IDS is deliberately SMALLER than 2**STREAM_ID_W: the
        # sequence checker must count a beat on a stream it does not track
        # rather than fold it onto one it does, and a configuration in which
        # every id is tracked would leave that path unreachable. telemetry_top
        # $fatals at time 0 if this stops being true.
        #
        # TELEM_PROBE_W is 8 because SPEC 13.4 requires counter wrap to be
        # exercised, and a 32-bit counter cannot be wrapped in a unit test. Eight
        # bits wraps in 256 events, so wrap is a directed case in every seed
        # rather than a condition reasoned about and never reached.
        "TELEM_FIFO_DEPTH": 8,
        "TELEM_COUNT_W": 32,
        "TELEM_WIDE_W": 64,
        "TELEM_TRACKED_IDS": 2,
        "TELEM_PROBE_W": 8,
        "TELEM_PROBE_INCR_W": 4,
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
        "  // ---- SPEC 5 stream bundle geometry and payload layout (issue #5) ----",
        "  // Mirror of rtl/packages/stream_pkg.sv; checked against it at time 0 by",
        "  // benchmark_sim_top. See scripts/build_verilator.py:derive_stream_params.",
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
    lines.append("// SPEC 5 stream bundle geometry and payload layout (issue #5).")
    lines.append("// Mirror of rtl/packages/stream_pkg.sv, checked against it at time 0 by")
    lines.append("// benchmark_sim_top; the C++ harness packs and unpacks with these.")
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


def cpp_sources(test: str, top: str = TOP_MODULE) -> list[str]:
    """Harness sources + entry point + the selected test, in a stable order.

    Absolute paths: Verilator's generated makefile runs with the --Mdir as its
    working directory, so a repo-relative user source would not resolve.

    Top-specific harness modules (e.g. ``pipeline_tb.cpp``) include a
    ``V<top>.h`` header and are only added when the top matches. That keeps
    ``pipeline_tb.cpp`` out of every non-pipeline build, exactly as
    ``packet_tb.h`` is confined to the packet builds (it is header-only, so
    ``glob("*.cpp")`` never picks it up).
    """
    all_cpp = sorted(str(p) for p in (REPO_ROOT / HARNESS_DIR).glob("*.cpp"))
    srcs: list[str] = []
    for p in all_cpp:
        base = Path(p).name
        if base == "pipeline_tb.cpp" and top != "pipeline_top":
            continue
        srcs.append(p)
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


def build_dir(mode: str, config: str, top: str = TOP_MODULE) -> Path:
    # A non-default top gets its own build directory so the two never share
    # objects or a binary name.
    stem = f"{mode}_{config}" if top == TOP_MODULE else f"{mode}_{config}_{top}"
    return BUILD_ROOT / stem


def binary_path(mode: str, config: str, test: str, top: str = TOP_MODULE) -> Path:
    return build_dir(mode, config, top) / f"V{top}_{test}"


def verilator_command(args, cfg_name: str) -> list[str]:
    mdir = build_dir(args.mode, cfg_name, args.top)
    cmd = [
        args.verilator,
        "--top-module",
        args.top,
        "--Mdir",
        str(mdir),
        "-f",
        str(args.files),
        str(WAIVERS),
    ]

    # The medium-config pipeline exercises a Verilator 5.020 internal error
    # (V3DfgPeephole OOPS at rtl/align/align_collect.sv:316) when compiled at
    # BIN_PAR = 2 through the alignment network. Disabling the DFG peephole
    # optimizer avoids the crash without changing observable behaviour.
    # DECISIONS.md 2026-07-27 "Verilator 5.020 DFG peephole workaround".
    if args.top == "pipeline_top" and args.mode != "coverage":
        cmd += ["-fno-dfg-peephole"]

    if args.mode == "lint":
        # No --Wno-fatal: an unwaived warning must fail the gate.
        cmd += ["--lint-only", "--Wall", "--assert"]
        return cmd

    prefix = f"V{args.top}"
    exe_name = f"V{args.top}_{args.test}"
    cflags = [
        "-std=c++17",
        f"-I{REPO_ROOT / 'sim/verilator'}",
        f"-I{REPO_ROOT / GENERATED_DIR}",
        # model/cpp is on the include path so a test can compare the RTL against
        # the bit-accurate C++ reference model in one binary (SPEC 12.4).
        f"-I{REPO_ROOT / MODEL_CPP_DIR}",
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
        # VM_COVERAGE=1 must be defined on the USER source compile line, not
        # just on the Verilator-generated files, or sim_main.cpp's
        # `#if VM_COVERAGE` guard around the .dat write is compiled out and
        # the per-run coverage file lands zero-length (issue #17).
        cflags += ["-O2", "-DVM_COVERAGE=1"]
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
    cmd += cpp_sources(args.test, args.top)
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
        "--top",
        default=TOP_MODULE,
        help=(
            f"top module to verilate (default: {TOP_MODULE}). Change it together "
            "with --files; a non-default top builds into its own directory."
        ),
    )
    p.add_argument(
        "--files",
        default=str(FILES_F),
        help=f"Verilator -f file list (default: {FILES_F})",
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
        print(REPO_ROOT / binary_path(args.mode, args.config, args.test, args.top))
        return 0

    if shutil.which(args.verilator) is None:
        sys.exit(
            f"ERROR: '{args.verilator}' not found on PATH. Simulation runs inside "
            "WSL Ubuntu-24.04 (PLAN.md split-toolchain rule)."
        )

    if args.clean:
        target = REPO_ROOT / build_dir(args.mode, args.config, args.top)
        if target.exists():
            shutil.rmtree(target)

    generate_config(args.config, args.quiet)

    # Verilator only creates the last component of --Mdir.
    (REPO_ROOT / build_dir(args.mode, args.config, args.top)).mkdir(
        parents=True, exist_ok=True
    )

    cmd = verilator_command(args, args.config)
    if not args.quiet:
        print(f"[verilator] mode={args.mode} config={args.config} "
              f"top={args.top} threads={args.threads} jobs={args.jobs}")
        print("[verilator] " + " ".join(cmd))
    rc = subprocess.call(cmd, cwd=REPO_ROOT)
    if rc != 0:
        print(f"ERROR: verilator ({args.mode}) failed with exit status {rc}",
              file=sys.stderr)
        return rc

    if args.mode == "lint":
        print(f"[lint] clean: zero unwaived warnings for {args.top} "
              f"(config {args.config})")
        return 0

    binary = REPO_ROOT / binary_path(args.mode, args.config, args.test, args.top)
    if not binary.is_file():
        print(f"ERROR: expected binary not produced: {binary}", file=sys.stderr)
        return 1
    if not args.quiet:
        print(f"[build] {binary.relative_to(REPO_ROOT)}")
        print(f"[build] run with: {binary.relative_to(REPO_ROOT)} +seed={args.seed}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
