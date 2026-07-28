#!/usr/bin/env python3
"""Diff two Quartus compile records (SPEC.md 17) and emit a delta report.

    python scripts/compare_runs.py baseline.json candidate.json
    python scripts/compare_runs.py evidence/baseline/timing.json results/timing/latest.json
    python scripts/compare_runs.py --json a.json b.json > delta.json

Governing spec: SPEC.md 16 (`make compare-baseline`), SPEC.md 17
(per-compile JSON record shape), SPEC.md 27 (`evidence/baseline/` package).

Inputs
------
Two JSON records produced by ``scripts/parse_quartus.py`` (or equivalently by
``quartus/scripts/export_results.tcl`` merged from the SPEC.md 17 fragments).
The first argument is the BASELINE, the second is the CANDIDATE. Deltas are
computed as ``candidate - baseline``: positive = candidate uses more, negative
= candidate improved.

Outputs
-------
Text (default): a human-readable table of utilization deltas per resource,
per-clock Fmax / WNS / TNS deltas, compile-time deltas, and a verdict line
that flags regressions (any clock's WNS moved negative, any resource
increased by more than the printed tolerance).

JSON (``--json``): a machine-readable delta record with the same shape as the
input records but every leaf value is ``{"baseline": v_b, "candidate": v_c,
"delta": v_c - v_b}`` for numeric fields, or the two values verbatim for
non-numeric fields.

Runs on stdlib alone (CPython 3.12 under WSL and 3.14 on Windows -- same
targets as parse_quartus.py).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent


def _load(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as fh:
        return json.load(fh)


def _delta(baseline: Any, candidate: Any) -> Any:
    """Compute a delta of any value type."""
    if baseline is None and candidate is None:
        return None
    if isinstance(baseline, (int, float)) and isinstance(candidate, (int, float)):
        # bool is a subclass of int; treat as string.
        if isinstance(baseline, bool) or isinstance(candidate, bool):
            return {"baseline": baseline, "candidate": candidate,
                    "delta": None}
        return {"baseline": baseline, "candidate": candidate,
                "delta": candidate - baseline}
    return {"baseline": baseline, "candidate": candidate, "delta": None}


def _walk(a: Any, b: Any) -> Any:
    """Compute a delta of two records, key-by-key."""
    if isinstance(a, dict) and isinstance(b, dict):
        keys = sorted(set(a.keys()) | set(b.keys()))
        return {k: _walk(a.get(k), b.get(k)) for k in keys}
    if isinstance(a, list) and isinstance(b, list):
        if a == b:
            return a
        return {"baseline": a, "candidate": b, "delta": None}
    return _delta(a, b)


def _fmt(val: Any, unit: str = "", nd: int = 3) -> str:
    if val is None:
        return "--"
    if isinstance(val, bool):
        return "yes" if val else "no"
    if isinstance(val, float):
        return f"{val:+.{nd}f}{unit}" if val != 0 else f"{val:.{nd}f}{unit}"
    if isinstance(val, int):
        return f"{val:+,}{unit}" if val != 0 else f"{val:,}{unit}"
    return f"{val}{unit}"


def _fmt_v(val: Any, unit: str = "", nd: int = 3) -> str:
    if val is None:
        return "--"
    if isinstance(val, bool):
        return "yes" if val else "no"
    if isinstance(val, float):
        return f"{val:.{nd}f}{unit}"
    if isinstance(val, int):
        return f"{val:,}{unit}"
    return f"{val}{unit}"


def _delta_of(node: Any) -> Any:
    """Extract the ``delta`` field from a walked node, or None if not present."""
    if isinstance(node, dict) and "delta" in node and "baseline" in node:
        return node["delta"]
    return None


def _leaf_v(node: Any, side: str) -> Any:
    """Extract baseline or candidate value from a walked leaf node."""
    if isinstance(node, dict) and side in node:
        return node[side]
    return node


def _report_text(baseline: dict, candidate: dict, tree: Any) -> tuple[str, list[str]]:
    """Render a human-readable delta report.

    Returns (report_text, warnings). Non-empty warnings signal a regression.
    """
    warnings: list[str] = []
    out: list[str] = []
    w = 78
    rule = "-" * w
    out.append("=" * w)
    out.append("  Quartus compile record delta (SPEC.md 17)")
    out.append("=" * w)

    def row(label: str, value: str) -> None:
        out.append(f"  {label:<26}{value}")

    row("baseline commit", str(baseline.get("commit", "?")))
    row("candidate commit", str(candidate.get("commit", "?")))
    row("baseline seed", str(baseline.get("seed", "?")))
    row("candidate seed", str(candidate.get("seed", "?")))
    row("device (both)", str(baseline.get("device")) if
        baseline.get("device") == candidate.get("device") else
        f"{baseline.get('device')} vs {candidate.get('device')} (MISMATCH)")
    if baseline.get("device") != candidate.get("device"):
        warnings.append("device mismatch between baseline and candidate")
    out.append(rule)

    # Utilization deltas.
    util_tree = tree.get("utilization") or {}
    if util_tree:
        out.append(f"  {'UTILIZATION':<20}{'baseline':>12}{'candidate':>14}"
                   f"{'delta':>16}")
        for label, key in (
            ("ALMs", "alm_used"),
            ("ALM registers", "alm_registers"),
            ("M20K", "m20k"),
            ("DSP", "dsp"),
            ("MLAB", "mlab"),
            ("RAM bits", "ram_bits"),
            ("virtual pins", "virtual_pins"),
        ):
            node = util_tree.get(key)
            b = _leaf_v(node, "baseline")
            c = _leaf_v(node, "candidate")
            d = _delta_of(node)
            out.append(
                f"  {label:<20}{_fmt_v(b):>12}{_fmt_v(c):>14}{_fmt(d):>16}"
            )
            # Regression flag: any resource grew by more than a 1% ratio
            # (or by 100 units minimum). This is a heuristic, tunable.
            if isinstance(b, (int, float)) and isinstance(d, (int, float)):
                if b > 0 and d > max(100, 0.01 * b):
                    warnings.append(
                        f"utilization.{key} grew by {d:+,} ({100.0 * d / b:+.2f}%)"
                    )
        for label, key in (
            ("ALM %", "alm_percent"),
            ("ALM reg %", "alm_reg_percent"),
            ("M20K %", "m20k_percent"),
            ("DSP %", "dsp_percent"),
        ):
            node = util_tree.get(key)
            b = _leaf_v(node, "baseline")
            c = _leaf_v(node, "candidate")
            d = _delta_of(node)
            out.append(
                f"  {label:<20}{_fmt_v(b, ' %'):>12}{_fmt_v(c, ' %'):>14}"
                f"{_fmt(d, ' %pt'):>16}"
            )
    out.append(rule)

    # Timing deltas per clock.
    b_clocks = baseline.get("clocks") or {}
    c_clocks = candidate.get("clocks") or {}
    all_clocks = sorted(set(b_clocks.keys()) | set(c_clocks.keys()))
    if all_clocks:
        out.append(f"  {'CLOCK':<15}  {'fmax_base':>10}{'fmax_cand':>11}"
                   f"{'d_fmax':>10}{'d_wns':>10}{'d_tns':>11}"
                   f"{'d_fail':>9}")
        for name in all_clocks:
            cb = b_clocks.get(name) or {}
            cc = c_clocks.get(name) or {}
            fb = cb.get("fmax_mhz")
            fc = cc.get("fmax_mhz")
            df = (fc - fb) if (isinstance(fb, (int, float)) and
                               isinstance(fc, (int, float))) else None
            wb = cb.get("wns_ns")
            wc = cc.get("wns_ns")
            dw = (wc - wb) if (isinstance(wb, (int, float)) and
                               isinstance(wc, (int, float))) else None
            tb = cb.get("tns_ns")
            tc = cc.get("tns_ns")
            dt = (tc - tb) if (isinstance(tb, (int, float)) and
                               isinstance(tc, (int, float))) else None
            fb_fail = cb.get("failing_paths_setup")
            fc_fail = cc.get("failing_paths_setup")
            dfail = ((fc_fail or 0) - (fb_fail or 0)) \
                if (fb_fail is not None or fc_fail is not None) else None
            out.append(
                f"  {name:<15}  {_fmt_v(fb, '', 1):>10}{_fmt_v(fc, '', 1):>11}"
                f"{_fmt(df, '', 1):>10}{_fmt(dw, '', 3):>10}"
                f"{_fmt(dt, '', 3):>11}{_fmt(dfail):>9}"
            )
            # Regression: WNS moved more negative, or Fmax dropped by
            # more than 1 MHz, or new failing paths appeared.
            if isinstance(dw, (int, float)) and dw < -0.005:
                warnings.append(
                    f"clock '{name}': WNS regressed by {dw:.3f} ns"
                )
            if isinstance(df, (int, float)) and df < -1.0:
                warnings.append(
                    f"clock '{name}': Fmax dropped by {-df:.1f} MHz"
                )
            if isinstance(dfail, int) and dfail > 0:
                warnings.append(
                    f"clock '{name}': {dfail:+d} new failing setup paths"
                )
    else:
        out.append("  TIMING           -- no clock records in either input --")
    out.append(rule)

    # Compile-time and ancillary deltas.
    cs_node = tree.get("compile_seconds")
    if cs_node is not None:
        b_cs = _leaf_v(cs_node, "baseline")
        c_cs = _leaf_v(cs_node, "candidate")
        d_cs = _delta_of(cs_node)
        row("compile time",
            f"{_fmt_v(b_cs, ' s', 1)}  ->  {_fmt_v(c_cs, ' s', 1)}  "
            f"{_fmt(d_cs, ' s', 1)}")
    pk_node = tree.get("peak_memory_mb")
    if pk_node is not None:
        row("peak memory",
            f"{_fmt_v(_leaf_v(pk_node, 'baseline'), ' MB')}  ->  "
            f"{_fmt_v(_leaf_v(pk_node, 'candidate'), ' MB')}  "
            f"{_fmt(_delta_of(pk_node), ' MB')}")
    ucp_node = tree.get("unconstrained_paths")
    if ucp_node is not None:
        b_ucp = _leaf_v(ucp_node, "baseline")
        c_ucp = _leaf_v(ucp_node, "candidate")
        d_ucp = _delta_of(ucp_node)
        row("unconstrained paths",
            f"{_fmt_v(b_ucp)}  ->  {_fmt_v(c_ucp)}  {_fmt(d_ucp)}")
        if isinstance(d_ucp, int) and d_ucp > 0:
            warnings.append(
                f"unconstrained_paths grew by {d_ucp:+d} -- new "
                "uncovered endpoints; SPEC.md 24 requires justification"
            )
    out.append(rule)
    if warnings:
        out.append("  REGRESSIONS DETECTED")
        for w in warnings:
            out.append(f"    * {w}")
    else:
        out.append("  no regressions detected")
    out.append("=" * w)
    return "\n".join(out), warnings


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description=(
            "Compare two Quartus compile records (SPEC.md 17). Prints a "
            "utilization/timing delta table and flags regressions."
        )
    )
    ap.add_argument("baseline", help="path to baseline JSON record")
    ap.add_argument("candidate", help="path to candidate JSON record")
    ap.add_argument("--json", action="store_true",
                    help="emit a machine-readable delta record as JSON")
    ap.add_argument("--strict", action="store_true",
                    help="exit non-zero on any detected regression")
    args = ap.parse_args(argv)

    b_path = Path(args.baseline)
    c_path = Path(args.candidate)
    if not b_path.is_file():
        print(f"ERROR: baseline not found: {b_path}", file=sys.stderr)
        return 2
    if not c_path.is_file():
        print(f"ERROR: candidate not found: {c_path}", file=sys.stderr)
        return 2

    try:
        baseline = _load(b_path)
        candidate = _load(c_path)
    except json.JSONDecodeError as exc:
        print(f"ERROR: JSON parse failure: {exc}", file=sys.stderr)
        return 2

    if not isinstance(baseline, dict) or not isinstance(candidate, dict):
        print("ERROR: both records must be JSON objects", file=sys.stderr)
        return 2

    tree = _walk(baseline, candidate)

    if args.json:
        json.dump(tree, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        # In --json mode --strict still returns a status code but no stderr
        # noise (the caller reads the JSON, not stderr).
        _, warnings = _report_text(baseline, candidate, tree)
        return 1 if (args.strict and warnings) else 0

    text, warnings = _report_text(baseline, candidate, tree)
    print(text)
    return 1 if (args.strict and warnings) else 0


if __name__ == "__main__":
    sys.exit(main())
