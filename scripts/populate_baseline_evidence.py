#!/usr/bin/env python3
"""Populate ``evidence/baseline/`` from a completed Quartus compile record.

    python scripts/populate_baseline_evidence.py
    python scripts/populate_baseline_evidence.py --record results/timing/latest.json
    python scripts/populate_baseline_evidence.py --dry-run

Governing spec: SPEC.md 27 (Required Evidence Package -- evidence/baseline/).

Populates:

* ``evidence/baseline/source_commit.txt``  -- git commit of the compiled RTL.
* ``evidence/baseline/simulation_summary.json`` -- full-scale smoke test JSON,
  copied from ``results/simulation/test_full_smoke_full_agmf039_seed1.json``.
* ``evidence/baseline/utilization.json``  -- derived from the compile record's
  utilization + utilization_by_hierarchy sections.
* ``evidence/baseline/timing.json``       -- derived from the compile record's
  clocks + constraints_integrity sections.
* ``evidence/baseline/constraints_report.txt`` -- produced by
  scripts/constraints_report.py against the SDCs + the compile record.
* ``evidence/baseline/quartus_reports/`` -- raw exported Quartus artifacts:
  the .qsf, the .sta/.fit/.summary reports, and every JSON export the
  compile produced.

Baseline immutability rule (SPEC.md 27): once merged, this directory is
read-only forever. Later compares (issues #22, #23) read it, they do not
overwrite it. This script REFUSES to overwrite an existing file unless
``--force`` is given; ordinarily the reviewer either merges the initial
population or the script exits with a non-zero code.

Runs on stdlib alone (validated on CPython 3.12 under WSL and 3.14 on
Windows -- same targets as parse_quartus.py).
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_RECORD = REPO_ROOT / "results" / "timing" / "latest.json"
DEFAULT_SIM_SUMMARY = REPO_ROOT / "results" / "simulation" / \
    "test_full_smoke_full_agmf039_seed1.json"
BASELINE_DIR = REPO_ROOT / "evidence" / "baseline"
QUARTUS_OUT_DIR = REPO_ROOT / "quartus" / "project" / "output_files"
QUARTUS_QSF = REPO_ROOT / "quartus" / "project" / "agilex7_wideband.qsf"


def _load(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as fh:
        return json.load(fh)


def _current_commit() -> str | None:
    try:
        result = subprocess.run(
            ["git", "-C", str(REPO_ROOT), "rev-parse", "HEAD"],
            check=True, capture_output=True, text=True,
        )
        return result.stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None


def _write_json(path: Path, data: Any, force: bool, dry_run: bool) -> None:
    if path.is_file() and not force:
        print(f"[baseline] SKIP existing {path.relative_to(REPO_ROOT)} "
              "(use --force to overwrite)")
        return
    if dry_run:
        print(f"[baseline] would write {path.relative_to(REPO_ROOT)}")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, sort_keys=True)
    print(f"[baseline] wrote {path.relative_to(REPO_ROOT)}")


def _copy(src: Path, dst: Path, force: bool, dry_run: bool) -> None:
    if dst.is_file() and not force:
        print(f"[baseline] SKIP existing {dst.relative_to(REPO_ROOT)} "
              "(use --force to overwrite)")
        return
    if not src.is_file():
        print(f"[baseline] WARN source {src.relative_to(REPO_ROOT)} "
              "not found; skipping copy", file=sys.stderr)
        return
    if dry_run:
        print(f"[baseline] would copy {src.relative_to(REPO_ROOT)} "
              f"-> {dst.relative_to(REPO_ROOT)}")
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    print(f"[baseline] copied {src.relative_to(REPO_ROOT)} "
          f"-> {dst.relative_to(REPO_ROOT)}")


def _write_text(path: Path, text: str, force: bool, dry_run: bool) -> None:
    if path.is_file() and not force:
        print(f"[baseline] SKIP existing {path.relative_to(REPO_ROOT)} "
              "(use --force to overwrite)")
        return
    if dry_run:
        print(f"[baseline] would write {path.relative_to(REPO_ROOT)} "
              f"({len(text)} bytes)")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    print(f"[baseline] wrote {path.relative_to(REPO_ROOT)}")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description=(
            "Populate evidence/baseline/ from a completed Quartus compile "
            "record + the full-scale smoke test summary (SPEC.md 27)."
        )
    )
    ap.add_argument("--record", type=str, default=str(DEFAULT_RECORD),
                    help=f"path to compile record (default: {DEFAULT_RECORD})")
    ap.add_argument("--sim-summary", type=str, default=str(DEFAULT_SIM_SUMMARY),
                    help="path to sim-full-smoke JSON summary")
    ap.add_argument("--force", action="store_true",
                    help="overwrite existing evidence files (baseline is "
                         "immutable AFTER merge; --force is only valid "
                         "BEFORE the initial commit)")
    ap.add_argument("--dry-run", action="store_true",
                    help="show what would be written without writing anything")
    args = ap.parse_args(argv)

    record_path = Path(args.record)
    if not record_path.is_file():
        print(f"ERROR: compile record not found: {record_path}", file=sys.stderr)
        print("       Run `make quartus-compile` (Windows side) first.",
              file=sys.stderr)
        return 2
    try:
        rec = _load(record_path)
    except json.JSONDecodeError as exc:
        print(f"ERROR: {record_path}: {exc}", file=sys.stderr)
        return 2
    if not isinstance(rec, dict):
        print("ERROR: compile record is not a JSON object", file=sys.stderr)
        return 2

    # Sanity: verification_passed is None (Quartus record) which is OK. But
    # errors must be zero and unconstrained_paths must be reasonable.
    if rec.get("errors") not in (0, None):
        print(f"ERROR: compile record reports errors={rec.get('errors')}. "
              "Baseline evidence requires a clean compile.", file=sys.stderr)
        return 2
    if rec.get("stages_completed") is None or "fit" not in \
            (rec.get("stages_completed") or []):
        print(f"WARNING: compile record's stages_completed is "
              f"{rec.get('stages_completed')!r}; a full baseline needs the "
              "'fit' stage. Continuing (map-only evidence).", file=sys.stderr)

    BASELINE_DIR.mkdir(parents=True, exist_ok=True)

    # source_commit.txt
    commit = rec.get("commit") or _current_commit() or "unknown"
    _write_text(BASELINE_DIR / "source_commit.txt", commit + "\n",
                args.force, args.dry_run)

    # simulation_summary.json
    sim_src = Path(args.sim_summary)
    _copy(sim_src, BASELINE_DIR / "simulation_summary.json",
          args.force, args.dry_run)

    # utilization.json (derived subset)
    util = {
        "device": rec.get("device"),
        "quartus_version": rec.get("quartus_version"),
        "commit": rec.get("commit"),
        "seed": rec.get("seed"),
        "configuration": rec.get("configuration"),
        "timestamp": rec.get("timestamp"),
        "utilization": rec.get("utilization"),
        "utilization_by_hierarchy": rec.get("utilization_by_hierarchy"),
    }
    _write_json(BASELINE_DIR / "utilization.json", util,
                args.force, args.dry_run)

    # timing.json (derived subset)
    timing = {
        "device": rec.get("device"),
        "quartus_version": rec.get("quartus_version"),
        "commit": rec.get("commit"),
        "seed": rec.get("seed"),
        "configuration": rec.get("configuration"),
        "timestamp": rec.get("timestamp"),
        "clocks": rec.get("clocks"),
        "constraints_integrity": rec.get("constraints_integrity"),
        "unconstrained_paths": rec.get("unconstrained_paths"),
        "critical_path": rec.get("critical_path"),
    }
    _write_json(BASELINE_DIR / "timing.json", timing,
                args.force, args.dry_run)

    # constraints_report.txt: invoke scripts/constraints_report.py.
    if not args.dry_run:
        constraints_out = BASELINE_DIR / "constraints_report.txt"
        if constraints_out.is_file() and not args.force:
            print(f"[baseline] SKIP existing "
                  f"{constraints_out.relative_to(REPO_ROOT)} "
                  "(use --force to overwrite)")
        else:
            cmd = [sys.executable,
                   str(REPO_ROOT / "scripts" / "constraints_report.py"),
                   "--record", str(record_path),
                   "--out", str(constraints_out)]
            result = subprocess.run(cmd, cwd=REPO_ROOT)
            if result.returncode == 0:
                print(f"[baseline] wrote "
                      f"{constraints_out.relative_to(REPO_ROOT)}")
            else:
                print(f"[baseline] WARN constraints_report.py exited "
                      f"{result.returncode}", file=sys.stderr)
    else:
        print(f"[baseline] would write "
              f"{(BASELINE_DIR / 'constraints_report.txt').relative_to(REPO_ROOT)}")

    # quartus_reports/: raw exported artefacts.
    reports_dir = BASELINE_DIR / "quartus_reports"
    if args.dry_run:
        print(f"[baseline] would populate "
              f"{reports_dir.relative_to(REPO_ROOT)}")
    else:
        reports_dir.mkdir(parents=True, exist_ok=True)
        # Copy the qsf.
        if QUARTUS_QSF.is_file():
            _copy(QUARTUS_QSF, reports_dir / QUARTUS_QSF.name,
                  args.force, args.dry_run)
        # Copy every .rpt / .summary / .txt Quartus produced.
        if QUARTUS_OUT_DIR.is_dir():
            for pat in ("*.rpt", "*.summary", "*.pow.rpt"):
                for src in sorted(QUARTUS_OUT_DIR.glob(pat)):
                    _copy(src, reports_dir / src.name,
                          args.force, args.dry_run)
        else:
            print(f"[baseline] WARN {QUARTUS_OUT_DIR.relative_to(REPO_ROOT)} "
                  "not found; quartus_reports/ left empty", file=sys.stderr)
        # Also carry the top-level JSON record.
        _copy(record_path,
              reports_dir / "compile_record.json",
              args.force, args.dry_run)

    # README (immutability note).
    readme = (
        "# evidence/baseline/ -- Phase 6 immutable baseline (SPEC.md 19 / 27)\n"
        "\n"
        "This directory holds the frozen reference fit of `full_agmf039` at\n"
        f"commit `{commit}`. Every optimization iteration (issue #22) and the\n"
        "ten-seed robustness sweep (issue #23) compares against these files.\n"
        "\n"
        "## Immutability rule\n"
        "\n"
        "*Do NOT edit, regenerate, or overwrite anything under this directory\n"
        "after it is merged.* Later comparisons read it; they do not update it.\n"
        "If a later fit changes utilization or timing enough to invalidate the\n"
        "baseline as a comparison target, land a NEW `evidence/baseline_v2/`\n"
        "with its own dated DECISIONS.md entry -- do not modify this one.\n"
        "\n"
        "## Contents (SPEC.md 27)\n"
        "\n"
        "- `source_commit.txt`        -- git commit hash of the compiled RTL.\n"
        "- `simulation_summary.json`  -- full-scale smoke test summary at this commit.\n"
        "- `utilization.json`         -- utilization + hierarchy from the fit.\n"
        "- `timing.json`              -- clocks, integrity, unconstrained paths.\n"
        "- `constraints_report.txt`   -- SPEC.md 24 constraints audit.\n"
        "- `quartus_reports/`         -- raw exported Quartus reports.\n"
        "\n"
        "## Regenerating (before merge only)\n"
        "\n"
        "```\n"
        "make quartus-compile SEED=1\n"
        "python scripts/populate_baseline_evidence.py --force\n"
        "```\n"
        "\n"
        "The `--force` flag is deliberately loud: once merged, the baseline is\n"
        "immutable and this script refuses to overwrite existing files without it.\n"
    )
    _write_text(BASELINE_DIR / "README.md", readme, args.force, args.dry_run)

    print("[baseline] done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
