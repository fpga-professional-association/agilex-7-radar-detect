#!/usr/bin/env python3
"""Validate and summarise a Quartus compile record.

Governing spec: SPEC.md 17 (Quartus Reporting).

The record is produced by ``quartus/scripts/export_results.tcl`` -- one JSON
object per compile. This script is the consumer side: it checks the record
against the SPEC.md 17 schema, applies numeric sanity rules, and prints a
one-screen summary table. ``make quartus-report`` runs it after every export.

A field that the compile stage could not produce is ``null``. That is a valid
record, not an error: a ``map``-only compile has no timing, congestion or
retiming data, and the record's ``notes`` array says so. This script reports
such fields as ``--`` and still exits 0. It exits non-zero only for a record
that is malformed, missing required keys, internally inconsistent, or that
reports a failed compile.

Runs on stdlib alone (validated on CPython 3.12 under WSL and 3.14 on Windows).

Usage
-----
    python scripts/parse_quartus.py [path/to/record.json] [options]

    --quiet          only print the verdict line
    --strict         also fail when required-but-null timing fields are absent
                     (use once a fit is expected, e.g. in the Phase 6 baseline)
    --list           summarise every results/timing/compile_*.json instead
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_RECORD = REPO_ROOT / "results" / "timing" / "latest.json"

# Device totals, SPEC.md 2. Used to cross-check the exporter's percentages
# rather than trusting them.
DEVICE = "AGMF039R47B1E1VC"
TOTAL_ALMS = 1_305_600
TOTAL_ALM_REGS = 5_222_400
TOTAL_M20K = 18_960
TOTAL_DSP = 12_300

# key -> (python types, nullable)
REQUIRED: dict[str, tuple[tuple[type, ...], bool]] = {
    "commit": ((str,), False),
    "quartus_version": ((str,), False),
    "device": ((str,), False),
    "seed": ((int,), False),
    "configuration": ((str,), False),
    "verification_passed": ((bool,), True),
    "unconstrained_paths": ((int,), True),
    "utilization": ((dict,), False),
    "clocks": ((dict,), True),
    "compile_seconds": ((int, float), True),
    "notes": ((list,), False),
}

# Keys that must exist inside "utilization".
REQUIRED_UTIL = ("alm_percent", "m20k_percent", "dsp_percent")

# Fields that only a completed fit can fill in. --strict requires them.
STRICT_REQUIRED = ("clocks", "unconstrained_paths")


class Problem:
    __slots__ = ("level", "text")

    def __init__(self, level: str, text: str) -> None:
        self.level = level
        self.text = text

    def __str__(self) -> str:
        return f"{self.level}: {self.text}"


def _typename(types: tuple[type, ...]) -> str:
    return "/".join(t.__name__ for t in types)


def validate(rec: Any, strict: bool = False) -> list[Problem]:
    """Return the list of schema and sanity problems found in ``rec``."""
    problems: list[Problem] = []

    def err(msg: str) -> None:
        problems.append(Problem("ERROR", msg))

    def warn(msg: str) -> None:
        problems.append(Problem("WARN", msg))

    if not isinstance(rec, dict):
        err(f"top level must be a JSON object, got {type(rec).__name__}")
        return problems

    # --- required keys and types -------------------------------------------
    for key, (types, nullable) in REQUIRED.items():
        if key not in rec:
            err(f"missing required key '{key}'")
            continue
        value = rec[key]
        if value is None:
            if not nullable:
                err(f"'{key}' must not be null")
            continue
        # bool is a subclass of int; keep them distinct.
        if bool in types and not isinstance(value, bool):
            err(f"'{key}' must be {_typename(types)}, got {type(value).__name__}")
        elif bool not in types and isinstance(value, bool):
            err(f"'{key}' must be {_typename(types)}, got bool")
        elif not isinstance(value, types):
            err(f"'{key}' must be {_typename(types)}, got {type(value).__name__}")

    if problems and any(p.level == "ERROR" for p in problems):
        # Type errors make the rest of the checks meaningless.
        return problems

    # --- identity -----------------------------------------------------------
    if rec.get("device") != DEVICE:
        err(f"device is '{rec.get('device')}', expected '{DEVICE}' (SPEC.md 2/15)")
    if not str(rec.get("quartus_version", "")).strip():
        err("quartus_version is empty; the tool version must be detected and recorded")
    if str(rec.get("quartus_version")) == "unknown":
        err("quartus_version was not detected at compile time")
    if rec.get("commit_dirty") is True:
        warn("working tree was dirty at export time; result is not reproducible from the commit alone")

    # --- compile health -----------------------------------------------------
    errors = rec.get("errors")
    if isinstance(errors, int) and errors > 0:
        err(f"compile reported {errors} error(s)")
    seconds = rec.get("compile_seconds")
    if isinstance(seconds, (int, float)) and seconds < 0:
        err(f"compile_seconds is negative ({seconds})")
    seed = rec.get("seed")
    if isinstance(seed, int) and seed < 0:
        err(f"seed is negative ({seed})")
    if not rec.get("stages_completed"):
        warn("stages_completed is empty; no compiler stage finished")

    # --- utilization --------------------------------------------------------
    util = rec.get("utilization") or {}
    for key in REQUIRED_UTIL:
        if key not in util:
            err(f"utilization is missing required key '{key}'")
    for key, value in util.items():
        if value is None or not key.endswith("_percent"):
            continue
        if not isinstance(value, (int, float)):
            err(f"utilization.{key} must be numeric, got {type(value).__name__}")
        elif not 0.0 <= value <= 100.0:
            err(f"utilization.{key} out of range: {value}")

    # Cross-check the exporter's arithmetic against the SPEC.md 2 totals.
    for used_key, pct_key, total in (
        ("alm_used", "alm_percent", TOTAL_ALMS),
        ("alm_registers", "alm_reg_percent", TOTAL_ALM_REGS),
        ("m20k", "m20k_percent", TOTAL_M20K),
        ("dsp", "dsp_percent", TOTAL_DSP),
    ):
        used = util.get(used_key)
        pct = util.get(pct_key)
        if not isinstance(used, (int, float)) or not isinstance(pct, (int, float)):
            continue
        if used > total:
            err(f"utilization.{used_key}={used} exceeds the device total {total}")
        expected = 100.0 * used / total
        if abs(expected - pct) > 0.01:
            err(f"utilization.{pct_key}={pct} disagrees with {used}/{total} = {expected:.3f}")

    # --- timing -------------------------------------------------------------
    ucp = rec.get("unconstrained_paths")
    if isinstance(ucp, int) and ucp < 0:
        err(f"unconstrained_paths is negative ({ucp})")

    clocks = rec.get("clocks")
    if isinstance(clocks, dict):
        for name, c in clocks.items():
            if not isinstance(c, dict):
                err(f"clocks.{name} must be an object")
                continue
            constraint = c.get("constraint_mhz")
            if constraint is not None and (
                not isinstance(constraint, (int, float)) or constraint <= 0
            ):
                err(f"clocks.{name}.constraint_mhz must be a positive number")
            for key in ("fmax_mhz", "restricted_fmax_mhz"):
                v = c.get(key)
                if v is not None and (not isinstance(v, (int, float)) or v <= 0):
                    err(f"clocks.{name}.{key} must be a positive number, got {v!r}")
            wns, tns = c.get("wns_ns"), c.get("tns_ns")
            if isinstance(wns, (int, float)) and isinstance(tns, (int, float)):
                if wns >= 0 and tns < 0:
                    err(f"clocks.{name}: wns={wns} is non-negative but tns={tns} is negative")
                if tns > 0:
                    err(f"clocks.{name}: tns={tns} must be <= 0 by definition")
            for key in (
                "failing_paths_setup",
                "failing_paths_hold",
                "failing_paths_recovery",
                "failing_paths_removal",
            ):
                v = c.get(key)
                if v is not None and (not isinstance(v, int) or v < 0):
                    err(f"clocks.{name}.{key} must be a non-negative integer, got {v!r}")

    # --- SPEC.md 24 constraints integrity ----------------------------------
    integ = rec.get("constraints_integrity")
    if isinstance(integ, dict):
        for key in ("false_paths", "multicycle_paths", "clock_groups"):
            v = integ.get(key)
            if isinstance(v, int) and v > 0:
                warn(
                    f"constraints_integrity.{key}={v}: every exception needs source, "
                    f"destination, functional reason, verification method and a "
                    f"reviewer-facing explanation (SPEC.md 15/24)"
                )

    # --- strict mode --------------------------------------------------------
    if strict:
        for key in STRICT_REQUIRED:
            if rec.get(key) is None:
                err(f"--strict: '{key}' is null; a completed fit + STA is required")

    return problems


# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------

def fmt(value: Any, unit: str = "", nd: int = 3) -> str:
    if value is None:
        return "--"
    if isinstance(value, bool):
        return "yes" if value else "no"
    if isinstance(value, float):
        return f"{value:.{nd}f}{unit}"
    if isinstance(value, int):
        return f"{value:,}{unit}"
    return f"{value}{unit}"


def summarise(rec: dict, problems: list[Problem]) -> str:
    out: list[str] = []
    w = 78
    rule = "-" * w

    def row(label: str, value: str) -> None:
        out.append(f"  {label:<26}{value}")

    util = rec.get("utilization") or {}
    clocks = rec.get("clocks") or {}

    out.append("=" * w)
    # ASCII only: this table is printed to consoles whose encoding we do not
    # control (Windows cp1252 mangles non-ASCII).
    out.append("  Quartus compile record - Agilex 7 wideband benchmark")
    out.append("=" * w)
    row("device", str(rec.get("device")))
    row("quartus", str(rec.get("quartus_version")))
    row("commit", f"{rec.get('commit')}{' (dirty)' if rec.get('commit_dirty') else ''}")
    row("configuration", f"{rec.get('configuration')}  seed={rec.get('seed')}")
    row("stage", f"{rec.get('stage')}  completed=[{', '.join(rec.get('stages_completed') or []) or '-'}]")
    row("timestamp", str(rec.get("timestamp")))
    out.append(rule)
    row("errors / warnings", f"{fmt(rec.get('errors'))} / {fmt(rec.get('warnings'))}")
    row("wall clock", fmt(rec.get("compile_seconds"), " s", 1))
    stage_seconds = rec.get("stage_seconds") or {}
    if stage_seconds:
        row("  per stage", "  ".join(f"{k}={fmt(v, 's', 1)}" for k, v in stage_seconds.items()))
    row("peak memory", fmt(rec.get("peak_memory_mb"), " MB"))
    row("unconstrained paths", fmt(rec.get("unconstrained_paths")))
    out.append(rule)
    out.append("  UTILIZATION            used            total        percent")
    for label, used_key, pct_key, total_key in (
        ("ALMs", "alm_used", "alm_percent", "alm_total"),
        ("ALM registers", "alm_registers", "alm_reg_percent", "alm_registers_total"),
        ("M20K", "m20k", "m20k_percent", "m20k_total"),
        ("DSP", "dsp", "dsp_percent", "dsp_total"),
    ):
        out.append(
            f"  {label:<20}{fmt(util.get(used_key)):>10}{fmt(util.get(total_key)):>16}"
            f"{fmt(util.get(pct_key), ' %'):>15}"
        )
    for label, key in (("MLAB", "mlab"), ("RAM bits", "ram_bits"), ("virtual pins", "virtual_pins")):
        out.append(f"  {label:<20}{fmt(util.get(key)):>10}")
    if util.get("source_stage"):
        row("  source", str(util["source_stage"]))
    out.append(rule)
    if not clocks:
        out.append("  TIMING                 -- not available in this record --")
    else:
        out.append(
            "  CLOCK            constr    Fmax   restr    WNS      TNS   fail  depth"
        )
        for name, c in clocks.items():
            out.append(
                f"  {name:<15}"
                f"{fmt(c.get('constraint_mhz'), '', 1):>7}"
                f"{fmt(c.get('fmax_mhz'), '', 1):>8}"
                f"{fmt(c.get('restricted_fmax_mhz'), '', 1):>8}"
                f"{fmt(c.get('wns_ns'), '', 3):>8}"
                f"{fmt(c.get('tns_ns'), '', 3):>9}"
                f"{fmt(c.get('failing_paths_setup')):>7}"
                f"{fmt(c.get('logic_depth')):>7}"
            )
            src, dst = c.get("source_hierarchy"), c.get("destination_hierarchy")
            if src or dst:
                out.append(f"      critical: {src or '?'} -> {dst or '?'}")
    integ = rec.get("constraints_integrity")
    if isinstance(integ, dict):
        out.append(rule)
        row(
            "exceptions (SPEC 24)",
            "false={} multicycle={} clock_groups={}".format(
                fmt(integ.get("false_paths")),
                fmt(integ.get("multicycle_paths")),
                fmt(integ.get("clock_groups")),
            ),
        )
    notes = rec.get("notes") or []
    if notes:
        out.append(rule)
        out.append("  NOTES")
        for n in notes:
            out.append(f"    - {n}")
    if problems:
        out.append(rule)
        out.append("  VALIDATION")
        for p in problems:
            out.append(f"    {p}")
    out.append("=" * w)
    return "\n".join(out)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def load(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as fh:
        return json.load(fh)


def process(path: Path, args: argparse.Namespace) -> int:
    if not path.is_file():
        print(f"ERROR: no such record: {path}", file=sys.stderr)
        print("Run `make quartus-map` (or quartus-fit) then `make quartus-report`.", file=sys.stderr)
        return 2
    try:
        rec = load(path)
    except json.JSONDecodeError as exc:
        print(f"ERROR: {path} is not valid JSON: {exc}", file=sys.stderr)
        return 2

    problems = validate(rec, strict=args.strict)
    if args.check_region and isinstance(rec, dict):
        problems.extend(check_calibration_region(rec))
    errors = [p for p in problems if p.level == "ERROR"]

    if not args.quiet:
        print(summarise(rec if isinstance(rec, dict) else {}, problems))

    verdict = "FAIL" if errors else "OK"
    print(f"{verdict}  {path}  ({len(errors)} error(s), {len(problems) - len(errors)} warning(s))")
    return 1 if errors else 0


def check_calibration_region(rec: dict) -> list[Problem]:
    """SPEC 25 acceptance region check (issue #20 Phase 5).

    Compare the exported utilization against the calibration-predicted region:
        DSP  75-90%
        M20K 55-80%
        ALMs 55-80%

    of the AGMF039R47B1E1VC device totals. Any out-of-range value is a
    hard ERROR (the design either does not fit, or has accidental logic
    removal). Also flag any hierarchy block that reports zero/near-zero
    resource usage where the calibration predicted nonzero cost -- an
    "accidental logic removal" / Design Assistant "unused logic" finding.
    """
    problems: list[Problem] = []
    util = rec.get("utilization") or {}

    # Region bounds, from SPEC 2 device totals and SPEC 25 acceptance region.
    bounds = {
        "dsp_percent":     (75.0, 90.0, "DSP"),
        "m20k_percent":    (55.0, 80.0, "M20K"),
        "alm_percent":     (55.0, 80.0, "ALM"),
    }
    for key, (lo, hi, label) in bounds.items():
        v = util.get(key)
        if not isinstance(v, (int, float)):
            problems.append(Problem("ERROR",
                f"calibration-region: {key} missing/non-numeric (expected {label} "
                f"in [{lo:.0f}%, {hi:.0f}%])"))
            continue
        if v < lo:
            problems.append(Problem("ERROR",
                f"calibration-region: {label} = {v:.1f}% is BELOW the "
                f"expected {lo:.0f}% lower bound (accidental logic removal? "
                "check hierarchy report)"))
        elif v > hi:
            problems.append(Problem("ERROR",
                f"calibration-region: {label} = {v:.1f}% exceeds the "
                f"expected {hi:.0f}% upper bound (design overflow / "
                "insufficient sharing)"))

    # Hierarchy check: every top-level block the calibration predicts non-zero
    # for MUST report non-zero. This catches "the compiler optimised out my
    # entire pipeline stage" -- a class of bug the fitter is otherwise silent
    # about (the compile succeeds, timing is fantastic, and half the design
    # is gone).
    #
    # Expected non-zero blocks (from SPEC 3 pipeline hierarchy):
    #   u_pipe.g_pfb           -- PFB banks
    #   u_pipe.g_fft           -- streaming FFT
    #   u_pipe.g_hist_rep      -- history_core replicas
    #   u_pipe.u_align         -- alignment network
    #   u_pipe.u_bf            -- beamformer
    #   u_pipe.g_power_fanout  -- Phase-5 power fan-out
    #   u_pipe.u_covar         -- covariance engine
    #   u_pipe.u_cfar          -- CFAR detector
    #   u_pipe.u_dma_fabric    -- packet network
    #   u_pipe.u_dma_arb       -- memory arbiter
    #   u_pipe.u_dma_mem       -- behavioural memory
    expected_blocks = [
        "g_pfb", "g_fft", "g_hist_rep", "u_align", "u_bf",
        "g_power_fanout", "u_covar", "u_cfar",
        "u_dma_fabric", "u_dma_arb", "u_dma_mem",
    ]
    hier = rec.get("utilization_by_hierarchy") or {}
    if isinstance(hier, dict):
        for blk in expected_blocks:
            found = any(blk in name for name in hier.keys())
            if not found:
                problems.append(Problem("WARN",
                    f"calibration-region: expected hierarchy block "
                    f"'{blk}' not found in utilization_by_hierarchy "
                    "(possible accidental removal or missing report)"))
                continue
            # Collect ALM usage for this block.
            alms_sum = 0
            for name, entry in hier.items():
                if blk in name and isinstance(entry, dict):
                    e_alms = entry.get("alms") or entry.get("alm_used") or 0
                    if isinstance(e_alms, (int, float)):
                        alms_sum += e_alms
            if alms_sum < 1:
                problems.append(Problem("ERROR",
                    f"calibration-region: block '{blk}' reports {alms_sum} "
                    "ALMs -- looks like the compiler removed it. Check the "
                    "Design Assistant for 'unused logic' findings."))
    else:
        problems.append(Problem("WARN",
            "calibration-region: no utilization_by_hierarchy in record; "
            "skipping accidental-removal check"))

    return problems


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description="Validate and summarise a Quartus compile record (SPEC.md 17)."
    )
    ap.add_argument("record", nargs="?", default=str(DEFAULT_RECORD),
                    help=f"path to the JSON record (default: {DEFAULT_RECORD})")
    ap.add_argument("--quiet", action="store_true", help="print only the verdict line")
    ap.add_argument("--strict", action="store_true",
                    help="fail when post-fit timing fields are null")
    ap.add_argument("--list", action="store_true",
                    help="process every results/timing/compile_*.json")
    ap.add_argument("--check-region", action="store_true",
                    help=("SPEC 25 calibration-region acceptance gate "
                          "(DSP 75-90%%, M20K 55-80%%, ALM 55-80%%); issue #20"))
    args = ap.parse_args(argv)

    if args.list:
        records = sorted((REPO_ROOT / "results" / "timing").glob("compile_*.json"))
        if not records:
            print("ERROR: no compile records under results/timing/", file=sys.stderr)
            return 2
        rc = 0
        for path in records:
            rc |= process(path, args)
        return rc

    return process(Path(args.record), args)


if __name__ == "__main__":
    sys.exit(main())
