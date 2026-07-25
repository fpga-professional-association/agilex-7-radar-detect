#!/usr/bin/env python3
"""Drive a SPEC 18 resource-calibration sweep and export one JSON record per point.

Governing spec: SPEC.md 18 (Resource-Calibration Phase), 15, 17, 23.

SPEC 18 requires representative kernels to be synthesized on their own before the
full design is built, swept over pipeline depth, register placement, multiplier
implementation and the rest, with DSP mapping, ALMs, Fmax, retiming and routing
delay MEASURED -- "Do not build the full design based solely on theoretical
DSP-count arithmetic." This script is the sweep driver. It is deliberately
kernel-agnostic: everything specific to a kernel lives in its parameter matrix
below and in its calibration project under ``quartus/calibration/``, so the nine
kernels that follow the complex multiplier add a matrix entry and a project, not
a script.

    python scripts/run_calibration.py --kernel cmult
    python scripts/run_calibration.py --kernel cmult --jobs 2
    python scripts/run_calibration.py --kernel cmult --points mult4_p3_round
    python scripts/run_calibration.py --kernel cmult --resume
    python scripts/run_calibration.py --kernel cmult --summary-only

Windows side only, like every other Quartus entry point in this repository: this
host's WSL has Windows interop disabled, so quartus_sh.exe cannot be launched
from Linux (see the note at the top of the Makefile). ``make calibrate-cmult``
is the sanctioned invocation.

How a point is measured
-----------------------
Each point is one full compile of the kernel's calibration project with one set
of elaboration parameters:

    quartus_sh  -t quartus/scripts/calibrate.tcl compile <kernel> <point> ...
    quartus_sta -t quartus/scripts/calibrate.tcl sta     <kernel> <point>

The two phases exist because the data lives behind two different APIs; see the
header of calibrate.tcl. Each writes a flat key/value file, and this script
merges the pair into one JSON record, adds the derived comparisons, and appends
it to ``results/synthesis/calibration_<kernel>.json``.

Isolated working copies
-----------------------
With ``--jobs > 1`` each point compiles in its own copy of the calibration
project, because two Quartus compiles cannot share a project database. The copy
lives at ``results/calib_<kernel>_<point>/`` -- deliberately TWO levels below the
repository root, exactly like ``quartus/calibration/``, so that the ``../../rtl``
paths inside the copied qsf still resolve to the same source files. The copy is
byte-identical to the tracked project; only its location differs, and the
location is recorded in the point's record. Working copies are deleted after
each point unless ``--keep-work`` is given.

Everything under ``results/`` is generated and is never committed (PLAN.md
standing rule 3). What survives a sweep is the JSON record -- pasted into the
pull request -- and, compactly, the table in DECISIONS.md.

Runs on stdlib alone.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CALIB_DIR = REPO_ROOT / "quartus" / "calibration"
CALIB_TCL = REPO_ROOT / "quartus" / "scripts" / "calibrate.tcl"
RESULTS_DIR = REPO_ROOT / "results" / "synthesis"

SCHEMA_VERSION = 1

# Device totals, SPEC.md 2. Repeated from scripts/parse_quartus.py rather than
# imported so this script keeps working if that one is refactored; both are
# checked against the device string in every record.
DEVICE = "AGMF039R47B1E1VC"
TOTAL_ALMS = 1_305_600
TOTAL_DSP = 12_300


# ---------------------------------------------------------------------------
# Parameter matrices
# ---------------------------------------------------------------------------
# One entry per SPEC 18 kernel. `params` are the elaboration parameters passed
# to `set_parameter` on the calibration project's top-level entity; `label` is
# what the summary table prints.
#
# PRUNING (issue #9). The full complex-multiplier matrix is
#     {MULT4, MULT3} x PIPE_STAGES {2,3,4,5} x ROUND_OUT {1,0}  =  16 compiles,
# and one compile of this project on AGMF039R47B1E1VC measures at about nine
# minutes wall clock, so the full matrix is two and a half hours. It is pruned to
# ten, which is what the issue's wall-time budget allows:
#
#   * the pipeline axis is swept FULLY for both variants at ROUND_OUT=1 (8
#     points). That is the axis the downstream kernels have to choose from, and
#     it is the axis on which the two variants are being compared.
#   * the output-format axis is measured at ONE depth, PIPE_STAGES=4, for both
#     variants (2 points). Rounding is a fixed combinational network hanging off
#     the post-adder register; it does not interact with how many stages precede
#     it, so measuring it at every depth would buy four copies of one number.
#     PIPE_STAGES=4 is chosen because that is the depth at which the output
#     register exists, which is the configuration in which the rounding network
#     is actually a register-to-register path rather than part of a longer one.
#
# A point that is pruned is pruned in this table, in the open, with the reason
# beside it -- not by quietly not running it.
MATRICES: dict[str, dict] = {
    "cmult": {
        "description": "SPEC 6 complex multiplier: 4-mult vs 3-mult (Karatsuba)",
        "top": "cmult_wrap",
        "axes": {
            "variant": {"0": "MULT4", "1": "MULT3"},
            "pipe_stages": [2, 3, 4, 5],
            "round_out": [0, 1],
        },
        # Ordered so that the two variants ALTERNATE. A sweep stopped early then
        # still holds a like-for-like comparison at every depth it reached,
        # instead of holding every MULT4 point and no MULT3 point.
        "points": (
            [
                {
                    "id": f"{'mult3' if v else 'mult4'}_p{p}_round",
                    "label": f"{'MULT3' if v else 'MULT4'} stages={p} round",
                    "params": {
                        "VARIANT_SEL": v,
                        "PIPE_STAGES": p,
                        "ROUND_OUT": 1,
                    },
                }
                for p in (2, 3, 4, 5)
                for v in (0, 1)
            ]
            + [
                {
                    "id": f"{'mult3' if v else 'mult4'}_p4_full",
                    "label": f"{'MULT3' if v else 'MULT4'} stages=4 full",
                    "params": {
                        "VARIANT_SEL": v,
                        "PIPE_STAGES": 4,
                        "ROUND_OUT": 0,
                    },
                }
                for v in (0, 1)
            ]
        ),
    },
}


# ---------------------------------------------------------------------------
# Tool location
# ---------------------------------------------------------------------------


def default_quartus_bin() -> Path:
    env = os.environ.get("QUARTUS_SH")
    if env:
        return Path(env).parent
    return Path("C:/altera_pro/26.1/quartus/bin64")


def tool(bindir: Path, name: str) -> Path:
    exe = bindir / f"{name}.exe"
    return exe if exe.exists() else bindir / name


# ---------------------------------------------------------------------------
# key/value files written by calibrate.tcl
# ---------------------------------------------------------------------------


def read_kv(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path.is_file():
        return out
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line or line.startswith("#"):
            continue
        if "\t" not in line:
            continue
        key, _, value = line.partition("\t")
        out[key.strip()] = value.strip()
    return out


def as_num(value: str | None):
    """A JSON number when the field holds one, else None. Never a bare string:
    a measurement that could not be taken is null, not the empty string, so a
    consumer never has to distinguish 'absent' from 'zero-length'."""
    if value is None:
        return None
    v = value.strip().replace(",", "")
    if not v:
        return None
    try:
        i = int(v)
        return i
    except ValueError:
        pass
    try:
        return float(v)
    except ValueError:
        return None


def as_text(value: str | None):
    if value is None:
        return None
    v = value.strip()
    return v or None


# ---------------------------------------------------------------------------
# One point
# ---------------------------------------------------------------------------


class PointResult:
    def __init__(self, point: dict) -> None:
        self.point = point
        self.ok = False
        self.record: dict = {}
        self.error = ""
        self.seconds = 0.0


def point_dir(kernel: str, point_id: str) -> Path:
    return RESULTS_DIR / "calibration" / kernel / point_id


def work_dir(kernel: str, point_id: str) -> Path:
    # TWO levels below the repository root, matching quartus/calibration/, so the
    # ../../rtl paths in the copied qsf resolve to the same sources.
    return REPO_ROOT / "results" / f"calib_{kernel}_{point_id}"


def make_work_copy(kernel: str, point_id: str) -> Path:
    dst = work_dir(kernel, point_id)
    if dst.exists():
        shutil.rmtree(dst, ignore_errors=True)
    dst.mkdir(parents=True, exist_ok=True)
    for pattern in ("*.qpf", "*.qsf", "*.sdc", "*.sv"):
        for src in sorted(CALIB_DIR.glob(pattern)):
            shutil.copy2(src, dst / src.name)
    return dst


def run_tool(exe: Path, args: list[str], log: Path) -> tuple[int, str]:
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("w", encoding="utf-8", errors="replace") as fh:
        proc = subprocess.run(
            [str(exe)] + args,
            cwd=str(REPO_ROOT),
            stdout=fh,
            stderr=subprocess.STDOUT,
            text=True,
        )
    tail = ""
    try:
        lines = log.read_text(encoding="utf-8", errors="replace").splitlines()
        tail = "\n".join(lines[-25:])
    except OSError:
        pass
    return proc.returncode, tail


def run_point(kernel: str, point: dict, bindir: Path, seed: int,
              isolate: bool, keep_work: bool, verbose: bool) -> PointResult:
    res = PointResult(point)
    pid = point["id"]
    started = time.time()

    pdir = point_dir(kernel, pid)
    pdir.mkdir(parents=True, exist_ok=True)

    proj = CALIB_DIR
    if isolate:
        proj = make_work_copy(kernel, pid)

    param_args = [f"{k}={v}" for k, v in sorted(point["params"].items())]
    common = [kernel, pid, "--seed", str(seed), "--projdir", str(proj)]

    print(f"[calib] {pid}: compile ({' '.join(param_args)})", flush=True)
    rc, tail = run_tool(
        tool(bindir, "quartus_sh"),
        ["-t", str(CALIB_TCL), "compile"] + common + param_args,
        pdir / "compile.log",
    )
    if rc != 0:
        res.error = f"compile failed (exit {rc})"
        if verbose:
            print(tail, flush=True)
        res.seconds = time.time() - started
        return res

    print(f"[calib] {pid}: sta", flush=True)
    rc, tail = run_tool(
        tool(bindir, "quartus_sta"),
        ["-t", str(CALIB_TCL), "sta"] + common,
        pdir / "sta.log",
    )
    if rc != 0:
        res.error = f"sta failed (exit {rc})"
        if verbose:
            print(tail, flush=True)
        res.seconds = time.time() - started
        return res

    res.record = build_record(kernel, point, pdir)
    res.ok = bool(res.record.get("compile_ok"))
    if not res.ok:
        res.error = res.record.get("fatal") or "no usable data in the point files"
    res.seconds = time.time() - started
    res.record["wall_seconds"] = round(res.seconds, 1)

    if isolate and not keep_work:
        shutil.rmtree(proj, ignore_errors=True)
    return res


def build_record(kernel: str, point: dict, pdir: Path) -> dict:
    """Merges compile.kv and timing.kv into one JSON record for the point."""
    c = read_kv(pdir / "compile.kv")
    t = read_kv(pdir / "timing.kv")

    params = {k[len("param_"):]: as_num(v) for k, v in c.items()
              if k.startswith("param_")}

    # Which DSP modes Quartus actually chose, under the labels Quartus used.
    # SPEC 18 asks for "DSP mapping"; a block count alone is not a mapping.
    dsp_modes = {k[len("dspmode_"):]: as_num(v) for k, v in c.items()
                 if k.startswith("dspmode_")}

    # PLACED blocks versus NEEDED blocks. The Fitter reports
    #     DSP Blocks Needed [=A+B+C-D]
    # where A is what it actually placed and D is its estimate of what dense
    # merging could recover. Those are different numbers and the difference is
    # the finding: a variant can place three blocks and still be reported as
    # needing two. Both are recorded, from the verbatim rows in dsp.txt, so the
    # comparison between variants is a comparison of the same quantity.
    dsp_placed = None
    dsp_recoverable = None
    dsp_txt = pdir / "dsp.txt"
    if dsp_txt.is_file():
        for line in dsp_txt.read_text(encoding="utf-8",
                                      errors="replace").splitlines():
            cells = [x.strip() for x in line.split("|")]
            if len(cells) < 2:
                continue
            label = cells[0].lstrip("[]ABCD ").strip()
            if label.startswith("Total Fixed Point DSP Blocks"):
                dsp_placed = as_num(cells[1])
            elif label.startswith("Estimate of DSP Blocks recoverable"):
                dsp_recoverable = as_num(cells[1])

    alm = as_num(c.get("alm_used"))
    dsp = as_num(c.get("dsp_used"))

    rec: dict = {
        "schema_version": SCHEMA_VERSION,
        "kernel": kernel,
        "point_id": point["id"],
        "label": point["label"],
        "parameters": params,
        "declared_parameters": point["params"],

        "device": as_text(c.get("device")),
        "quartus_version": as_text(c.get("quartus_version")),
        "commit": as_text(c.get("commit")),
        "timestamp": as_text(c.get("timestamp")),
        "seed": as_num(c.get("seed")),
        "top": as_text(c.get("top")),
        "project_dir": as_text(c.get("project_dir")),

        "compile_ok": c.get("stages_completed", "") == "syn,fit"
                      and not c.get("fatal"),
        "fatal": as_text(c.get("fatal")),
        "errors": as_num(c.get("errors")),
        "warnings": as_num(c.get("warnings")),
        "syn_seconds": as_num(c.get("syn_seconds")),
        "fit_seconds": as_num(c.get("fit_seconds")),

        # --- SPEC 17 utilization -------------------------------------------
        "utilization": {
            "alm_used": alm,
            "alm_percent": (round(100.0 * alm / TOTAL_ALMS, 6)
                            if alm is not None else None),
            "alm_reg_used": as_num(c.get("alm_reg_used")),
            "combinational_aluts": as_num(c.get("combinational_aluts")),
            "dsp_used": dsp,
            "dsp_percent": (round(100.0 * dsp / TOTAL_DSP, 6)
                            if dsp is not None else None),
            "m20k_used": as_num(c.get("m20k_used")),
            "mlab_used": as_num(c.get("mlab_used")),
            "pins_used": as_num(c.get("pins_used")),
            "virtual_pins": as_num(c.get("virtual_pins")),
            "source_stage": as_text(c.get("resource_source_stage")),
        },

        # --- SPEC 18 DSP mapping --------------------------------------------
        "dsp": {
            "blocks": dsp,                       # "DSP Blocks Needed", = placed - recoverable
            "blocks_placed": dsp_placed,         # what the Fitter actually placed
            "blocks_recoverable": dsp_recoverable,
            "mult_18x19": as_num(c.get("mult_18x19")),
            "mult_27x27": as_num(c.get("mult_27x27")),
            "modes": dsp_modes,
            "panel": as_text(c.get("dsp_panel")),
            "detail_file": "dsp.txt",
        },

        # --- the kernel instance alone, without the wrapper's boundary regs ---
        "kernel_entity": {
            "alm_used": as_num(c.get("kernel_alm_used")),
            "alm_reg_used": as_num(c.get("kernel_alm_reg_used")),
            "combinational_aluts": as_num(c.get("kernel_comb_aluts")),
            "dsp_used": as_num(c.get("kernel_dsp_used")),
            "m20k_used": as_num(c.get("kernel_m20k_used")),
            "row": as_text(c.get("kernel_entity_row")),
        },

        # --- SPEC 17 timing --------------------------------------------------
        # `fmax` is the register-to-register measurement and is THE calibration
        # number; `quartus_restricted_fmax_mhz` is Quartus's own whole-design
        # figure, which on a virtual-pin harness is dominated by output-port
        # clock-insertion skew. Both are recorded, named for what they are. See
        # the long note in quartus/scripts/calibrate.tcl.
        "timing": {
            "clock": as_text(t.get("clock_name")),
            "probe_constraint_mhz": as_num(t.get("constraint_mhz")),
            "probe_period_ns": as_num(t.get("period_ns")),
            "fmax_mhz": as_num(t.get("reg2reg_fmax_mhz")),
            "fmax_source": "register-to-register worst setup slack",
            "reg2reg_wns_ns": as_num(t.get("reg2reg_wns_ns")),
            "reg2reg_logic_depth": as_num(t.get("reg2reg_logic_depth")),
            "reg2reg_cell_delay_ns": as_num(t.get("reg2reg_cell_delay_ns")),
            "reg2reg_routing_delay_ns": as_num(t.get("reg2reg_routing_delay_ns")),
            "reg2reg_clock_skew_ns": as_num(t.get("reg2reg_clock_skew_ns")),
            "reg2reg_source": as_text(t.get("reg2reg_source")),
            "reg2reg_destination": as_text(t.get("reg2reg_destination")),
            "critical_path_in_kernel": (as_num(t.get("reg2reg_in_kernel")) == 1),
            "quartus_restricted_fmax_mhz": as_num(t.get("restricted_fmax_mhz")),
            "quartus_fmax_mhz": as_num(t.get("fmax_mhz")),
            "design_wns_ns": as_num(t.get("wns_ns")),
            "design_tns_ns": as_num(t.get("tns_ns")),
            "hold_wns_ns": as_num(t.get("hold_wns_ns")),
            "unconstrained_paths": as_num(t.get("unconstrained_paths")),
        },

        # --- SPEC 17 / 23 retiming ------------------------------------------
        "retiming": {
            "limit_domain": as_text(c.get("retiming_limit_domain")),
            "limit_reason": as_text(c.get("retiming_limiting_reason")
                                    or c.get("retiming_limit_reason")),
            "recommendation": as_text(c.get("retiming_recommendation")),
            "design_registers": as_num(t.get("design_registers")),
            "design_hyper_registers": as_num(t.get("design_hyper_regs")),
            "kernel_registers": as_num(t.get("kernel_registers")),
            "kernel_hyper_registers": as_num(t.get("kernel_hyper_regs")),
            "kernel_sync_reset_registers": as_num(t.get("kernel_sync_reset")),
            "kernel_async_reset_registers": as_num(t.get("kernel_async_reset")),
            "kernel_clock_enable_registers": as_num(t.get("kernel_clock_enable")),
            "detail_files": ["retiming.txt", "retiming_limits.txt"],
        },

        "evidence_dir": str(pdir.relative_to(REPO_ROOT)).replace("\\", "/"),
        "notes": [],
    }

    notes = rec["notes"]
    # A point whose register-to-register paths MET the probe constraint has not
    # been pushed as hard as the Fitter could push it: it stopped when the
    # fabric paths passed. Its Fmax is therefore a LOWER BOUND, not a limit, and
    # saying so is the difference between a measurement and a number. Raising the
    # probe and re-running resolves it; the record says which points need that.
    r2r = rec["timing"]["reg2reg_wns_ns"]
    if r2r is not None and r2r >= 0:
        notes.append(
            "the register-to-register paths MET the probe constraint "
            f"({rec['timing']['probe_constraint_mhz']} MHz, slack {r2r} ns), so "
            "fmax_mhz is a lower bound rather than a measured limit; re-run this "
            "point at a higher probe to resolve it")
    if rec["device"] != DEVICE:
        notes.append(f"device is {rec['device']}, expected {DEVICE}")
    if not rec["timing"]["critical_path_in_kernel"]:
        notes.append(
            "the register-to-register critical path does not touch the kernel "
            "instance; this point measured the wrapper, not the kernel")
    if rec["timing"]["unconstrained_paths"] not in (0, None):
        notes.append(
            f"{rec['timing']['unconstrained_paths']} unconstrained paths "
            "(SPEC 2 requires zero)")
    declared = {k: v for k, v in point["params"].items()}
    seen = {k: v for k, v in params.items()}
    if declared != seen:
        notes.append(
            f"Quartus elaborated {seen}, the sweep asked for {declared}")
    return rec


# ---------------------------------------------------------------------------
# JSON output
# ---------------------------------------------------------------------------


def summary_path(kernel: str) -> Path:
    return RESULTS_DIR / f"calibration_{kernel}.json"


def load_summary(kernel: str) -> dict:
    path = summary_path(kernel)
    if path.is_file():
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            pass
    return {}


def write_summary(kernel: str, matrix: dict, records: list[dict],
                  seed: int, pruned_note: str) -> Path:
    path = summary_path(kernel)
    path.parent.mkdir(parents=True, exist_ok=True)
    doc = {
        "schema_version": SCHEMA_VERSION,
        "kernel": kernel,
        "description": matrix["description"],
        "device": DEVICE,
        "top": matrix["top"],
        "seed": seed,
        "probe_constraint_note": (
            "The calibration project is constrained at 600 MHz "
            "(quartus/calibration/*_calib.sdc), deliberately above the SPEC 2 "
            "450 MHz design target, so that no point meets timing and every "
            "reported Fmax is a measurement of a critical path rather than of "
            "the constraint. The benchmark's own 450 MHz constraint in "
            "quartus/constraints/clocks.sdc is untouched."),
        "fmax_note": (
            "timing.fmax_mhz is the register-to-register measurement and is the "
            "calibration number. timing.quartus_restricted_fmax_mhz is Quartus's "
            "whole-design figure, which on a virtual-pin harness is dominated by "
            "output-port clock-insertion skew that no fitter can remove and that "
            "does not exist at a fabric-internal boundary."),
        "matrix_axes": matrix["axes"],
        "pruning": pruned_note,
        "point_count": len(records),
        "points": records,
    }
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)
    return path


# ---------------------------------------------------------------------------
# Summary table
# ---------------------------------------------------------------------------


def fmt(v, spec="{}"):
    return "--" if v is None else spec.format(v)


def print_table(records: list[dict]) -> str:
    cols = ("variant", "stages", "out", "DSP", "18x18", "ALM", "ALM(kern)",
            "regs", "hyper", "Fmax MHz", "depth", "fit s")
    widths = (7, 6, 6, 4, 6, 6, 9, 5, 6, 9, 5, 6)
    lines = []
    lines.append("  ".join(c.ljust(w) for c, w in zip(cols, widths)).rstrip())
    lines.append("  ".join("-" * w for w in widths))
    for r in sorted(records, key=lambda x: x["point_id"]):
        p = r.get("parameters", {})
        u = r.get("utilization", {})
        k = r.get("kernel_entity", {})
        t = r.get("timing", {})
        rt = r.get("retiming", {})
        d = r.get("dsp", {})
        modes = d.get("modes", {}) or {}
        sum2 = None
        for name, value in modes.items():
            if "sum_of_two" in name or "18x18" in name or "18x19" in name:
                sum2 = value
                break
        row = (
            "MULT3" if p.get("VARIANT_SEL") == 1 else "MULT4",
            fmt(p.get("PIPE_STAGES")),
            "round" if p.get("ROUND_OUT") == 1 else "full",
            fmt(u.get("dsp_used")),
            fmt(sum2),
            fmt(u.get("alm_used")),
            fmt(k.get("alm_used")),
            fmt(u.get("alm_reg_used")),
            fmt(rt.get("design_hyper_registers")),
            fmt(t.get("fmax_mhz")),
            fmt(t.get("reg2reg_logic_depth")),
            fmt(r.get("fit_seconds")),
        )
        lines.append("  ".join(str(c).ljust(w) for c, w in zip(row, widths)).rstrip())
    text = "\n".join(lines)
    print(text)
    return text


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--kernel", default="cmult",
                   help=f"kernel to sweep; one of {', '.join(MATRICES)}")
    p.add_argument("--jobs", type=int, default=1,
                   help="points to compile at once (each gets its own project "
                        "copy). MEASURED on this host: one Fitter run of this "
                        "project on AGMF039R47B1E1VC reports a ~19.5 GB peak "
                        "virtual memory, and TWO at once drove a 32 GB machine "
                        "to 0.6 GB free and into thrashing — the pair made less "
                        "progress in 30 minutes than one point makes in nine. "
                        "Raise this only with the RAM to match. Default 1.")
    p.add_argument("--seed", type=int, default=1,
                   help="Fitter seed, recorded in every record (SPEC 25)")
    p.add_argument("--points", nargs="*", default=None,
                   help="only these point ids (default: the whole matrix)")
    p.add_argument("--resume", action="store_true",
                   help="skip points already present in the summary JSON")
    p.add_argument("--keep-work", action="store_true",
                   help="keep the per-point project copies for inspection")
    p.add_argument("--summary-only", action="store_true",
                   help="rebuild the JSON and the table from existing point "
                        "directories; compile nothing")
    p.add_argument("--quartus-bin", default=None,
                   help="directory holding quartus_sh / quartus_sta")
    p.add_argument("--verbose", action="store_true",
                   help="print the tail of a failing tool log")
    args = p.parse_args()

    if args.kernel not in MATRICES:
        print(f"ERROR: no calibration matrix for kernel '{args.kernel}'. "
              f"Known: {', '.join(MATRICES)}", file=sys.stderr)
        return 2
    matrix = MATRICES[args.kernel]

    points = matrix["points"]
    if args.points:
        wanted = set(args.points)
        points = [pt for pt in points if pt["id"] in wanted]
        missing = wanted - {pt["id"] for pt in points}
        if missing:
            print(f"ERROR: unknown point id(s): {', '.join(sorted(missing))}",
                  file=sys.stderr)
            return 2

    pruned_note = (
        "Full matrix is 2 variants x 4 pipeline depths x 2 output formats = 16 "
        "compiles; one compile measures at about nine minutes on this host. "
        "Pruned to 10: the pipeline axis is swept fully for both variants at "
        "ROUND_OUT=1, and the output-format axis is measured at PIPE_STAGES=4 "
        "only, because the rounding network is a fixed combinational block on "
        "the post-adder register and does not interact with the number of "
        "stages ahead of it. See scripts/run_calibration.py.")

    existing = load_summary(args.kernel)
    records: dict[str, dict] = {r["point_id"]: r
                                for r in existing.get("points", [])}

    if args.summary_only:
        rebuilt = []
        for pt in matrix["points"]:
            pdir = point_dir(args.kernel, pt["id"])
            if not (pdir / "compile.kv").is_file():
                continue
            rebuilt.append(build_record(args.kernel, pt, pdir))
        for r in rebuilt:
            records[r["point_id"]] = r
        out = write_summary(args.kernel, matrix, list(records.values()),
                            args.seed, pruned_note)
        print(f"[calib] rebuilt {out.relative_to(REPO_ROOT)} "
              f"from {len(rebuilt)} point directories")
        print()
        print_table([r for r in records.values() if r.get("compile_ok")])
        return 0

    if args.resume:
        before = len(points)
        points = [pt for pt in points
                  if not records.get(pt["id"], {}).get("compile_ok")]
        print(f"[calib] resume: {before - len(points)} point(s) already done")

    bindir = Path(args.quartus_bin) if args.quartus_bin else default_quartus_bin()
    sh = tool(bindir, "quartus_sh")
    if not sh.exists():
        print(f"ERROR: quartus_sh not found at {sh}. Set --quartus-bin or "
              "QUARTUS_SH.", file=sys.stderr)
        return 2

    print(f"[calib] kernel={args.kernel} device={DEVICE} top={matrix['top']}")
    print(f"[calib] quartus={sh}")
    print(f"[calib] points={len(points)} jobs={args.jobs} seed={args.seed}")
    # ALWAYS compile in an isolated copy, not only when running several points at
    # once. Two reasons, both learned the hard way: `project_close` exports the
    # in-memory assignment database over the qsf, so even a read-only STA run
    # writes tool bookkeeping into a hand-maintained tracked file; and a compile
    # leaves db/, qdb/ and output_files/ behind. Working in a copy keeps
    # quartus/calibration/ exactly as it is in the repository, which is the state
    # a clean checkout has to reproduce.
    isolate = True

    started = time.time()
    failures: list[tuple[str, str]] = []

    def finish(res: PointResult) -> None:
        pid = res.point["id"]
        if res.ok:
            records[pid] = res.record
            t = res.record["timing"]
            u = res.record["utilization"]
            print(f"[calib] {pid}: OK in {res.seconds/60:.1f} min "
                  f"(DSP={u['dsp_used']} ALM={u['alm_used']} "
                  f"Fmax={t['fmax_mhz']} MHz)", flush=True)
        else:
            failures.append((pid, res.error))
            print(f"[calib] {pid}: FAILED — {res.error} "
                  f"(log: {point_dir(args.kernel, pid)})", flush=True)
        write_summary(args.kernel, matrix, list(records.values()), args.seed,
                      pruned_note)

    if args.jobs <= 1:
        for pt in points:
            finish(run_point(args.kernel, pt, bindir, args.seed, isolate,
                             args.keep_work, args.verbose))
    else:
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as ex:
            futures = {
                ex.submit(run_point, args.kernel, pt, bindir, args.seed,
                          isolate, args.keep_work, args.verbose): pt
                for pt in points
            }
            for fut in concurrent.futures.as_completed(futures):
                finish(fut.result())

    out = write_summary(args.kernel, matrix, list(records.values()), args.seed,
                        pruned_note)
    elapsed = (time.time() - started) / 60.0

    good = [r for r in records.values() if r.get("compile_ok")]
    print()
    print(f"[calib] {len(good)} successful point(s) in {elapsed:.1f} min")
    print(f"[calib] record: {out.relative_to(REPO_ROOT)}")
    print()
    print_table(good)
    if failures:
        print()
        for pid, why in failures:
            print(f"[calib] FAILED {pid}: {why}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
