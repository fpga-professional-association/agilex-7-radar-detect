# Accepted changes -- Phase 7 timing-closure iterations (issue #22)

Human-readable log of every accepted iteration under issue #22. One section
per accepted change, cross-referencing its commit and PR. The
machine-readable log is `optimization_history.jsonl` at repo root; this file
is written for a reviewer walking the closure story rather than a script.

Governing docs: SPEC.md 20-23, 28; DECISIONS.md 2026-07-28 issue #22 gate
entry (SPC=2 accepted FINAL); `evidence/baseline/` (immutable Phase-6
reference: core_clk fmax 39.67 MHz, WNS -22.987 ns, critical path
CFAR window slot compare/mask reduction into `sum_lag1_q`).

## Iteration 0 -- baseline (issue #21, informational)

The immutable Phase-6 baseline that every iteration below is measured
against.

  * Commit: `739313cb68` (main).
  * Configuration: `full_agmf039` (SPC=2 per DECISIONS.md 2026-07-27 issue
    #20 Decision 3; HISTORY_FRAMES=256 per 2026-07-28 issue #21 Decision 8).
  * Seed: 1 (SPEC 25 dev seed).
  * core_clk fmax: 39.67 MHz.
  * Setup WNS / TNS: -22.987 ns / -1146299.488 ns.
  * Critical path source: `u_pipe|g_cfar_per_beam[15].u_cfar|u_window`
    (slot register file, one of the 32 masked slots feeding the reference
    sum).
  * Critical path destination: `u_pipe|g_cfar_per_beam[15].u_cfar|sum_lag1_q[35]`
    (Stage-1 lag-side reference sum capture register).
  * Logic depth on that path: 68 levels of combinational logic (masked
    sum-and-tree reduction over 32 40-bit reference cells into a 47-bit
    sum, all in a single cycle before it is registered).
  * Utilization: ALM 23.12%, M20K 90.70%, DSP 20.36%.

## Iterations

Iterations land below as they are accepted. Each has: hypothesis, bottleneck
class (SPEC 21), smallest defensible change (SPEC 20 step 3), verification
evidence (SPEC 20 step 4), before/after Quartus metrics (SPEC 20 step 6), and
commit SHA.
