# evidence/baseline/ -- Phase 6 immutable baseline (SPEC.md 19 / 27)

This directory holds the frozen reference fit of `full_agmf039` at
commit `739313cb68`. Every optimization iteration (issue #22) and the
ten-seed robustness sweep (issue #23) compares against these files.

## Immutability rule

*Do NOT edit, regenerate, or overwrite anything under this directory
after it is merged.* Later comparisons read it; they do not update it.
If a later fit changes utilization or timing enough to invalidate the
baseline as a comparison target, land a NEW `evidence/baseline_v2/`
with its own dated DECISIONS.md entry -- do not modify this one.

## Contents (SPEC.md 27)

- `source_commit.txt`        -- git commit hash of the compiled RTL.
- `simulation_summary.json`  -- full-scale smoke test summary at this commit.
- `utilization.json`         -- utilization + hierarchy from the fit.
- `timing.json`              -- clocks, integrity, unconstrained paths.
- `constraints_report.txt`   -- SPEC.md 24 constraints audit.
- `quartus_reports/`         -- raw exported Quartus reports.

## Regenerating (before merge only)

```
make quartus-compile SEED=1
python scripts/populate_baseline_evidence.py --force
```

The `--force` flag is deliberately loud: once merged, the baseline is
immutable and this script refuses to overwrite existing files without it.
