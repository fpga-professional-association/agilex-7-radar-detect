#!/usr/bin/env python3
"""Drive N Quartus compiles of the same configuration across a seed list.

    python scripts/seed_sweep.py --seeds 1                  # single seed (smoke)
    python scripts/seed_sweep.py --seeds 1,2,3,4,5          # explicit list
    python scripts/seed_sweep.py --seeds 1-10               # inclusive range
    python scripts/seed_sweep.py --config full_agmf039 \
                                --seeds 1-10                # ten-seed sweep
    python scripts/seed_sweep.py --dry-run --seeds 1-3      # print, don't run

Governing spec: SPEC.md 25 (Seed Experiment), SPEC.md 17 (per-compile
records), SPEC.md 27 (Required Evidence Package -- ``evidence/seed_sweep/``).

Purpose
-------
The baseline fit (issue #21) uses only the fixed development seed. The
optimization iteration (#22) and the final ten-seed robustness sweep (#23)
each need many compiles of the SAME configuration at different Fitter seeds
and each needs the per-run parse_quartus.py record aggregated. This script
is the driver:

1. Invoke ``make quartus-compile SEED=<n>`` for every seed in the list.
   Windows side (that is where Quartus runs); the script runs itself on
   any host with Python.
2. After each compile, copy the exported ``results/timing/latest.json``
   under ``results/seed_sweeps/<sweep_name>/seed_<n>.json``. Parse it via
   ``scripts/parse_quartus.py`` to fail loudly if the JSON is malformed
   (SPEC.md 25 requires every record be reproducible from a commit +
   seed pair, so a corrupt record is not a "warn and continue" case).
3. Emit an aggregated ``results/seed_sweeps/<sweep_name>/sweep.json``
   with per-seed { commit, quartus, fmax_by_clock, wns_by_clock,
   utilization } plus min/median/max/stddev across the sweep for each
   scalar. The final-stage sweep (issue #23) reads this file to compare
   against ``evidence/baseline/timing.json`` and produce the acceptance
   verdict SPEC.md 25 requires.

Determinism / idempotency
-------------------------
* Skipping already-completed runs (``--resume``) is supported: if
  ``seed_<n>.json`` already exists AND the recorded commit matches the
  current HEAD, it is left alone. Force a rerun with ``--force``.
* The recipe is a `make` invocation, so incremental rebuilds are
  Quartus's own responsibility; this script does not touch the
  project database directly.

Baseline note (issue #21 scope)
-------------------------------
The baseline itself is NOT swept -- it is one seed, the fixed development
seed (SPEC.md 25). This script MUST exist and MUST work at issue #21's
gate, but the ten-seed sweep is issue #23's gate. So the acceptance for
this file is `--seeds 1 --dry-run` printing a legal plan.

Runs on stdlib alone (validated on CPython 3.12 under WSL and 3.14 on
Windows -- same targets as parse_quartus.py).
"""

from __future__ import annotations

import argparse
import json
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent


def _parse_seeds(spec: str) -> list[int]:
    """Parse '1', '1,2,3', '1-10', or a mix of comma-separated ranges."""
    out: list[int] = []
    for chunk in spec.split(","):
        chunk = chunk.strip()
        if not chunk:
            continue
        if "-" in chunk:
            lo_s, hi_s = chunk.split("-", 1)
            lo, hi = int(lo_s), int(hi_s)
            if lo > hi:
                lo, hi = hi, lo
            out.extend(range(lo, hi + 1))
        else:
            out.append(int(chunk))
    # De-dup while preserving order.
    seen: set[int] = set()
    dedup: list[int] = []
    for s in out:
        if s not in seen:
            seen.add(s)
            dedup.append(s)
    if not dedup:
        raise ValueError(f"empty seed spec: {spec!r}")
    return dedup


def _current_commit(repo: Path) -> str | None:
    try:
        result = subprocess.run(
            ["git", "-C", str(repo), "rev-parse", "HEAD"],
            check=True, capture_output=True, text=True,
        )
        return result.stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None


def _run_one(seed: int, config: str, make_target: str, quartus_bin: str,
             extra_args: list[str], dry_run: bool) -> tuple[int, float]:
    """Invoke `make quartus-compile SEED=<n>` and return (rc, wall_s)."""
    cmd = ["make", make_target, f"SEED={seed}"]
    if config:
        # Config selection is via the Makefile's PIPE_CONFIG variable (SPEC 11).
        cmd.append(f"PIPE_CONFIG={config}")
    if quartus_bin:
        cmd.append(f"QUARTUS_BIN={quartus_bin}")
    cmd.extend(extra_args)
    print(f"[seed_sweep] running: {' '.join(cmd)}", flush=True)
    if dry_run:
        return 0, 0.0
    t0 = time.time()
    result = subprocess.run(cmd, cwd=REPO_ROOT)
    return result.returncode, time.time() - t0


def _capture_record(seed: int, out_dir: Path, sweep_name: str) -> Path | None:
    """Copy results/timing/latest.json under seed_sweeps/<name>/seed_<n>.json."""
    src = REPO_ROOT / "results" / "timing" / "latest.json"
    if not src.is_file():
        print(f"[seed_sweep] warning: {src} not found after compile",
              file=sys.stderr)
        return None
    dst = out_dir / f"seed_{seed}.json"
    out_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    return dst


def _validate_record(path: Path) -> tuple[bool, dict | None]:
    """Run parse_quartus.py --quiet on the record and return (ok, record)."""
    try:
        with path.open("r", encoding="utf-8") as fh:
            rec = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"[seed_sweep] error: {path}: {exc}", file=sys.stderr)
        return False, None
    # parse_quartus.py exit status is authoritative.
    cmd = [sys.executable, str(REPO_ROOT / "scripts" / "parse_quartus.py"),
           "--quiet", str(path)]
    result = subprocess.run(cmd, cwd=REPO_ROOT, capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stdout)
        sys.stderr.write(result.stderr)
        return False, rec
    return True, rec


def _stats(values: list[float | int]) -> dict[str, Any]:
    if not values:
        return {"count": 0, "min": None, "max": None, "median": None,
                "mean": None, "stddev": None}
    xs = list(values)
    return {
        "count": len(xs),
        "min": min(xs),
        "max": max(xs),
        "median": statistics.median(xs),
        "mean": statistics.mean(xs),
        "stddev": statistics.stdev(xs) if len(xs) > 1 else 0.0,
    }


def _aggregate(records: list[tuple[int, dict]]) -> dict[str, Any]:
    """Aggregate per-seed records into one sweep.json."""
    sweep = {
        "records": [],
        "aggregate": {
            "utilization": {},
            "clocks": {},
        },
    }
    per_util: dict[str, list[float]] = {}
    per_clock: dict[str, dict[str, list[float]]] = {}
    per_compile_seconds: list[float] = []

    for seed, rec in records:
        sweep["records"].append({
            "seed": seed,
            "commit": rec.get("commit"),
            "quartus_version": rec.get("quartus_version"),
            "device": rec.get("device"),
            "configuration": rec.get("configuration"),
            "stage": rec.get("stage") or rec.get("stage_requested"),
            "stages_completed": rec.get("stages_completed"),
            "timestamp": rec.get("timestamp"),
            "compile_seconds": rec.get("compile_seconds"),
            "utilization": rec.get("utilization") or {},
            "clocks": rec.get("clocks") or {},
            "unconstrained_paths": rec.get("unconstrained_paths"),
        })
        for k, v in (rec.get("utilization") or {}).items():
            if isinstance(v, (int, float)):
                per_util.setdefault(k, []).append(float(v))
        for name, c in (rec.get("clocks") or {}).items():
            if not isinstance(c, dict):
                continue
            cd = per_clock.setdefault(name, {})
            for k, v in c.items():
                if isinstance(v, (int, float)):
                    cd.setdefault(k, []).append(float(v))
        cs = rec.get("compile_seconds")
        if isinstance(cs, (int, float)):
            per_compile_seconds.append(float(cs))

    for k, vs in per_util.items():
        sweep["aggregate"]["utilization"][k] = _stats(vs)
    for name, cd in per_clock.items():
        sweep["aggregate"]["clocks"][name] = {k: _stats(vs) for k, vs in cd.items()}
    sweep["aggregate"]["compile_seconds"] = _stats(per_compile_seconds)
    return sweep


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description=(
            "Drive N Quartus compiles across a seed list, capturing every "
            "SPEC.md 17 record into results/seed_sweeps/<sweep_name>/. "
            "The baseline (issue #21) runs only one seed; the ten-seed "
            "robustness sweep (issue #23) uses the same driver at N=10."
        )
    )
    ap.add_argument("--seeds", required=True,
                    help='seed list ("1" or "1,2,3" or "1-10")')
    ap.add_argument("--name", default=None,
                    help="sweep name (default: sweep_<config>_<UTC timestamp>)")
    ap.add_argument("--config", default="full_agmf039",
                    help="pipeline config (default: full_agmf039)")
    ap.add_argument("--make-target", default="quartus-compile",
                    help="make target to invoke per seed "
                         "(default: quartus-compile)")
    ap.add_argument("--quartus-bin", default="",
                    help="path to Quartus bin directory (Windows side)")
    ap.add_argument("--resume", action="store_true",
                    help=("if a seed's JSON already exists and its commit "
                          "matches HEAD, skip the compile"))
    ap.add_argument("--force", action="store_true",
                    help="recompile every seed, even if a record exists")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the plan without running any compiles")
    ap.add_argument("--out", type=str, default=None,
                    help=("override output directory "
                          "(default: results/seed_sweeps/<name>)"))
    ap.add_argument("--", dest="_dashdash", nargs=argparse.REMAINDER,
                    help="pass through remaining args to make")
    args = ap.parse_args(argv)

    try:
        seeds = _parse_seeds(args.seeds)
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    if args.resume and args.force:
        print("ERROR: --resume and --force are mutually exclusive",
              file=sys.stderr)
        return 2

    commit = _current_commit(REPO_ROOT)
    if commit is None:
        print("[seed_sweep] warning: could not detect git commit; "
              "record deduplication is disabled")

    ts = time.strftime("%Y-%m-%dT%H-%M-%S", time.gmtime())
    sweep_name = args.name or f"sweep_{args.config}_{ts}"
    out_dir = Path(args.out) if args.out else \
        (REPO_ROOT / "results" / "seed_sweeps" / sweep_name)

    print(f"[seed_sweep] plan: {len(seeds)} seed(s) {seeds} "
          f"-> {out_dir.relative_to(REPO_ROOT) if out_dir.is_absolute() else out_dir}")
    print(f"[seed_sweep] config={args.config} target={args.make_target} "
          f"commit={commit or '?'}")
    if args.dry_run:
        print("[seed_sweep] dry run: no compiles issued")
        return 0

    extra = list(args._dashdash or [])
    records: list[tuple[int, dict]] = []

    for seed in seeds:
        dst = out_dir / f"seed_{seed}.json"
        if args.resume and dst.is_file():
            with dst.open("r", encoding="utf-8") as fh:
                prev = json.load(fh)
            if commit and prev.get("commit") == commit:
                print(f"[seed_sweep] seed {seed}: reusing existing record "
                      f"{dst.relative_to(REPO_ROOT)}")
                records.append((seed, prev))
                continue

        rc, wall = _run_one(seed, args.config, args.make_target,
                            args.quartus_bin, extra, dry_run=False)
        print(f"[seed_sweep] seed {seed}: rc={rc} wall={wall:.1f}s")
        if rc != 0:
            print(f"[seed_sweep] seed {seed} FAILED", file=sys.stderr)
            # Continue with other seeds -- one bad seed is not a sweep failure
            # by itself; the aggregator reports which seeds failed.
            continue

        rec_path = _capture_record(seed, out_dir, sweep_name)
        if rec_path is None:
            continue
        ok, rec = _validate_record(rec_path)
        if not ok or rec is None:
            print(f"[seed_sweep] seed {seed}: record validation FAILED "
                  f"({rec_path})", file=sys.stderr)
            continue
        records.append((seed, rec))

    if not records:
        print("[seed_sweep] no records captured; check the compile logs",
              file=sys.stderr)
        return 1

    sweep = _aggregate(records)
    sweep["sweep_name"] = sweep_name
    sweep["config"] = args.config
    sweep["seeds_requested"] = seeds
    sweep["seeds_completed"] = [s for s, _ in records]
    sweep["commit"] = commit
    sweep["make_target"] = args.make_target

    aggr_path = out_dir / "sweep.json"
    aggr_path.parent.mkdir(parents=True, exist_ok=True)
    with aggr_path.open("w", encoding="utf-8") as fh:
        json.dump(sweep, fh, indent=2, sort_keys=True)
    print(f"[seed_sweep] aggregate: {aggr_path.relative_to(REPO_ROOT)}")
    print(f"[seed_sweep] {len(records)}/{len(seeds)} seeds completed")
    return 0 if len(records) == len(seeds) else 1


if __name__ == "__main__":
    sys.exit(main())
