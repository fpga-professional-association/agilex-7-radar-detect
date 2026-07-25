# Timing Closure Plan

The procedure for taking the full AGMF039 configuration from its first baseline fit to
its final timing result, and the evidence trail that makes that result credible. Every
optimization iteration is a recorded experiment: one hypothesis, one smallest defensible
change, re-proven function, one compile, parsed results, an explicit accept or reject.
Governing requirements: [SPEC.md](SPEC.md) §18 (resource calibration), §20 (the loop),
§21 (bottleneck classification), §22 (optimization priority), §23 (HyperFlex rules),
§24 (constraints integrity), §25 (seed experiment).

Non-negotiable: constraints are never relaxed, timing exceptions are never invented to
hide a real path, and correctness is re-established before any result is accepted
(SPEC §24, §28).

> **Status: skeleton (issue #1).** Headings only. The loop is executed by issue #22;
> baseline capture by issue #21; seed robustness by issue #23.

## 1. Resource calibration (SPEC §18)

Per-kernel Quartus calibration compiles that fix the full-scale parameters before
elaboration. Results archived under `results/synthesis/`.

TODO — each of issues #9–#16 lands its own calibration data; consolidated by issue #20.

## 2. Baseline capture (SPEC §19 Phase 6)

The immutable baseline: source commit, project, reports, seed, simulation result,
utilization, timing, power estimate. Nothing is optimized before this is stored.

TODO — populated by issue #21. Artifacts under `results/synthesis/` and
`results/timing/`.

## 3. The iteration loop (SPEC §20)

| Step | Action |
|---|---|
| 1 | Preserve correctness — re-run the required simulation evidence |
| 2 | State exactly one hypothesis |
| 3 | Make the smallest defensible change |
| 4 | Prove functional behavior |
| 5 | Compile |
| 6 | Parse results |
| 7 | Accept or reject explicitly |
| 8 | Commit the result with its evidence |

TODO — populated by issue #22. One log entry per iteration, no batching of changes.

## 4. Bottleneck classification (SPEC §21)

Taxonomy for each failing path (control, routing, fanout, arithmetic depth, memory,
crossing, floorplan) and the evidence used to classify it.

TODO — populated by issue #22.

## 5. Optimization priority (SPEC §22)

The ordered list of permitted remedies, applied in order; later remedies are only
attempted after earlier ones are shown insufficient.

TODO — populated by issue #22.

## 6. HyperFlex-specific rules (SPEC §23)

Retiming-friendly coding, register placement, and what may not be done to game
Hyper-Retiming.

TODO — populated by issue #22.

## 7. Constraints integrity (SPEC §24)

Rules that keep the benchmark honest: no relaxed clocks, no false paths or multicycles
that hide real logic, no unconstrained crossings. Every constraint change is a
DECISIONS.md entry.

TODO — populated by issue #3 (initial SDC) and audited by issue #22.

## 8. Seed robustness (SPEC §19 Phase 8, §25)

Fixed seed set `1, 3, 7, 11, 17, 23, 31, 43, 59, 73`, frozen before results are seen.
Reported as a distribution, not a best case.

TODO — populated by issue #23. Artifacts under `results/seed_sweeps/`.

## 9. Reporting and comparison

`make quartus-report`, `make compare-baseline`, `make reproduce-final`, and the
dashboard/parse tooling under `scripts/`.

TODO — populated by issues #21 (parse/dashboard), #23 (comparison report), #25
(reproducibility).
