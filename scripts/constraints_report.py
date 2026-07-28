#!/usr/bin/env python3
"""Enumerate every timing exception in the constraints database.

    python scripts/constraints_report.py                    # every SDC file
    python scripts/constraints_report.py --sdc quartus/constraints/*.sdc
    python scripts/constraints_report.py --record results/timing/latest.json \
                                        --out evidence/baseline/constraints_report.txt

Governing spec: SPEC.md 24 (Constraints Integrity Rules).

Purpose
-------
SPEC.md 24 requires an audit of every ``set_false_path``,
``set_multicycle_path``, ``set_clock_groups``, ``set_max_delay``,
``set_min_delay`` and unconstrained endpoint in the design's timing
constraints, with a "reviewer-facing explanation" for every exception.

This script is the local, tool-independent side of that audit: it reads
the checked-in ``quartus/constraints/*.sdc`` and emits a plain-text
report enumerating every exception found, its file/line, the directive
verbatim, and any adjacent comment (which is where the "reviewer-facing
explanation" for each exception lives).

If ``--record`` is given, the report also folds in the constraints_integrity
section of the Quartus-side JSON record (produced by
``quartus/scripts/export_results.tcl`` via ``report_sta.tcl``). That
provides the counts the tool itself measured (``unconstrained_paths``,
``ignored_sdc_constraints``), and the report highlights any mismatch
between what the SDCs say and what the fitter reported.

This is enough for SPEC.md 27's ``evidence/baseline/constraints_report.txt``:
the immutable audit of what the design's timing setup actually was at the
baseline commit. Re-derivation of the same file at a later commit is a diff
of the SDC files, so a reviewer can trust the report as long as they trust
the SDC file at that commit.

Runs on stdlib alone (validated on CPython 3.12 and 3.14 -- same targets
as parse_quartus.py).
"""

from __future__ import annotations

import argparse
import glob
import json
import re
import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SDC_GLOB = "quartus/constraints/*.sdc"

# Directives SPEC.md 24 tracks. Order is the report order.
TRACKED_DIRECTIVES = (
    ("set_false_path",     "false path"),
    ("set_multicycle_path", "multicycle path"),
    ("set_clock_groups",   "clock group"),
    ("set_max_delay",      "max delay"),
    ("set_min_delay",      "min delay"),
    ("set_disable_timing", "disabled timing arc"),
)


def _read(path: Path) -> list[str]:
    """Read a file into a list of lines (no line endings preserved)."""
    with path.open("r", encoding="utf-8", errors="replace") as fh:
        return fh.read().splitlines()


def _extract_directives(lines: list[str],
                        directives: tuple[tuple[str, str], ...]
                        ) -> list[dict[str, Any]]:
    """Find every occurrence of any of ``directives`` in ``lines``.

    Returns a list of dicts with keys: line_no (1-based), directive,
    description (the pretty label), text (the directive line stripped),
    preceding_comment (comments immediately above the directive, joined
    with newlines), continuation (True if the directive was continued on
    subsequent lines via ``\\``).
    """
    dirmap = {d: label for d, label in directives}
    all_dirs = "|".join(re.escape(d) for d in dirmap)
    pattern = re.compile(rf"(^|\[|\s)({all_dirs})(\s|$)")

    found: list[dict[str, Any]] = []
    n = len(lines)
    i = 0
    pending_comment: list[str] = []
    while i < n:
        raw = lines[i]
        stripped = raw.strip()
        if not stripped:
            pending_comment.clear()
            i += 1
            continue
        if stripped.startswith("#"):
            pending_comment.append(stripped[1:].strip())
            i += 1
            continue
        m = pattern.search(stripped)
        if m:
            directive = m.group(2)
            # Collect the rest of the (possibly multi-line) directive.
            body = [raw.rstrip()]
            j = i
            while body[-1].endswith("\\") and j + 1 < n:
                j += 1
                body.append(lines[j].rstrip())
            found.append({
                "line_no": i + 1,
                "directive": directive,
                "description": dirmap[directive],
                "text": " ".join(b.rstrip("\\").strip() for b in body),
                "preceding_comment": "\n".join(pending_comment),
                "continuation": len(body) > 1,
            })
            pending_comment.clear()
            i = j + 1
        else:
            pending_comment.clear()
            i += 1
    return found


def _summarise(dir_findings: dict[str, list[dict]]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for directive, _label in TRACKED_DIRECTIVES:
        counts[directive] = sum(1 for f in dir_findings.get(directive, []))
    return counts


def _render(sdc_paths: list[Path], per_file: dict[Path, list[dict]],
            record: dict | None) -> str:
    out: list[str] = []
    rule = "=" * 78
    subrule = "-" * 78
    out.append(rule)
    out.append("  Constraints integrity report (SPEC.md 24)")
    out.append(rule)
    out.append("")

    # High-level summary.
    total_counts: dict[str, int] = {d: 0 for d, _ in TRACKED_DIRECTIVES}
    for findings in per_file.values():
        for f in findings:
            total_counts[f["directive"]] = total_counts.get(f["directive"], 0) + 1

    out.append("SDC files scanned:")
    for p in sdc_paths:
        try:
            rel = p.relative_to(REPO_ROOT)
        except ValueError:
            rel = p
        out.append(f"  * {rel}")
    out.append("")

    out.append("Summary counts (SDC directive occurrences):")
    for directive, label in TRACKED_DIRECTIVES:
        out.append(f"  {label:<24} {total_counts.get(directive, 0):>5}")
    out.append("")

    if record is not None:
        integ = record.get("constraints_integrity") or {}
        if integ:
            out.append("Constraints integrity from Quartus record:")
            for k in ("false_paths", "multicycle_paths", "clock_groups",
                      "max_delays", "min_delays", "disabled_arcs",
                      "ignored_sdc_constraints", "unconstrained_paths"):
                v = integ.get(k)
                if v is None:
                    continue
                out.append(f"  {k:<28} {v}")
            out.append("")
            # Cross-check: SDC-scan vs. Quartus-side count.
            xrefs = {
                "false_paths": "set_false_path",
                "multicycle_paths": "set_multicycle_path",
                "clock_groups": "set_clock_groups",
                "max_delays": "set_max_delay",
                "min_delays": "set_min_delay",
            }
            mismatches = []
            for record_key, sdc_dir in xrefs.items():
                r = integ.get(record_key)
                l = total_counts.get(sdc_dir, 0)
                if isinstance(r, int) and r != l:
                    mismatches.append(f"    {record_key}: record={r} sdc-scan={l}")
            if mismatches:
                out.append("MISMATCH between SDC-scan and Quartus record counts:")
                out.extend(mismatches)
                out.append("")

    out.append(subrule)
    out.append("Per-file directive detail")
    out.append(subrule)
    out.append("")

    for p in sdc_paths:
        try:
            rel = p.relative_to(REPO_ROOT)
        except ValueError:
            rel = p
        findings = per_file.get(p, [])
        out.append(f"FILE: {rel}")
        out.append("")
        if not findings:
            out.append("  (no tracked directives)")
        else:
            for f in findings:
                out.append(f"  line {f['line_no']:>5}: {f['description'].upper()}")
                if f["preceding_comment"]:
                    for line in f["preceding_comment"].splitlines():
                        out.append(f"    # {line}")
                out.append(f"    {f['text']}")
                if f["continuation"]:
                    out.append("    (continuation lines joined for readability)")
                out.append("")
        out.append("")

    if record is not None:
        clocks = record.get("clocks") or {}
        if clocks:
            out.append(subrule)
            out.append("Clock constraints per record")
            out.append(subrule)
            out.append("")
            for name, c in clocks.items():
                out.append(f"  clock '{name}':")
                for k in ("constraint_mhz", "fmax_mhz", "restricted_fmax_mhz",
                          "wns_ns", "tns_ns", "failing_paths_setup",
                          "failing_paths_hold", "failing_paths_recovery",
                          "failing_paths_removal", "logic_depth"):
                    v = c.get(k)
                    if v is None:
                        continue
                    out.append(f"    {k:<28} {v}")
                out.append("")

    out.append(rule)
    return "\n".join(out) + "\n"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description=(
            "Enumerate every timing exception in the checked-in SDC files "
            "and cross-check against a Quartus compile record's "
            "constraints_integrity section (SPEC.md 24)."
        )
    )
    ap.add_argument("--sdc", nargs="*", default=None,
                    help=(
                        "explicit SDC files to scan. If omitted, every file "
                        f"matching {DEFAULT_SDC_GLOB} is used."
                    ))
    ap.add_argument("--record", type=str, default=None,
                    help="path to a SPEC.md 17 JSON record for cross-checking")
    ap.add_argument("--out", "-o", type=str, default=None,
                    help="write the report to this file (default: stdout)")
    ap.add_argument("--strict", action="store_true",
                    help=("exit non-zero if any exception is found but has "
                          "NO preceding comment (SPEC.md 24 requires a "
                          "reviewer-facing explanation for every exception)"))
    args = ap.parse_args(argv)

    if args.sdc:
        sdc_files = [Path(p) for p in args.sdc]
    else:
        sdc_files = sorted(REPO_ROOT.glob(DEFAULT_SDC_GLOB))

    if not sdc_files:
        print("ERROR: no SDC files found. Point --sdc at explicit files or "
              f"place them under {DEFAULT_SDC_GLOB}.", file=sys.stderr)
        return 2

    record: dict | None = None
    if args.record:
        path = Path(args.record)
        if not path.is_file():
            print(f"ERROR: record not found: {path}", file=sys.stderr)
            return 2
        try:
            with path.open("r", encoding="utf-8") as fh:
                record = json.load(fh)
        except json.JSONDecodeError as exc:
            print(f"ERROR: {path}: {exc}", file=sys.stderr)
            return 2
        if not isinstance(record, dict):
            print("ERROR: record must be a JSON object", file=sys.stderr)
            return 2

    per_file: dict[Path, list[dict]] = {}
    for p in sdc_files:
        if not p.is_file():
            print(f"[constraints_report] warn: {p} not found; skipping",
                  file=sys.stderr)
            continue
        lines = _read(p)
        per_file[p] = _extract_directives(lines, TRACKED_DIRECTIVES)

    text = _render(sdc_files, per_file, record)
    if args.out:
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)

    if args.strict:
        undocumented = 0
        for findings in per_file.values():
            for f in findings:
                if not f["preceding_comment"].strip():
                    undocumented += 1
                    print(f"[constraints_report] STRICT: undocumented "
                          f"exception at {f.get('directive')} line "
                          f"{f['line_no']}", file=sys.stderr)
        if undocumented > 0:
            return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
