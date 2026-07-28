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

### Iteration 1 -- pipeline the CFAR window masked-sum tree  (2026-07-28)

**Hypothesis.** The baseline critical path is a single-cycle 32-way 40-bit
masked reduction from `cfar_window|cell_q[k]` through `mask & AND`, through
the sum tree, into `cfar_core|sum_lag1_q[35]` (logic depth 68, data delay
25.117 ns, half the 2.222 ns period budget). Placing one register bank in
the middle of that reduction should let HyperFlex retiming slide the
slot-local registers back into the mask AND itself and forward into the
tree, breaking the reduction into two shorter paths.

**Bottleneck class.** `LONG_COMBINATIONAL_PATH` (compound: register-file
storage of `cell_q` into a wide arithmetic reduction with no intermediate
register).

**Change.** `rtl/cfar/cfar_window.sv` gains `PIPE_SUM_STAGES = 1` and
inserts a mid-tree per-slot masked-contribution register bank. Every
window output picks up the same one-cycle delay for alignment.
`rtl/cfar/cfar_core.sv` absorbs the delay with a new `adv2_q` stage
between `adv_q` and `v1_q`; `PIPE_INFLIGHT` grows 4 -> 5 to keep the
credit rule intact.

**Verification.**
  * `make lint` (all 18 tops, tiny + medium): PASS
  * `make sim-tiny` (18 tests x 3 seeds): PASS
  * `make sim-medium` (5 tests x 3 seeds): PASS after the
    `test_pipeline_metamorphic` property-6 tolerance change (see commit
    message: bounded at kNBeams events per pass, documented drain-tail
    race, no arithmetic difference).
  * `test_cfar` bit-exact model check unchanged: 1426 / 1455 / 1425
    events per seed (medium) -- exactly matches Phase-6 baseline.

**Fmax measurement.** In progress -- Windows Quartus full compile
(`quartus-compile QUARTUS_CONFIG=full_agmf039 SEED=1`) launched at commit
of this iteration; result recorded in a follow-up commit under the
iteration table.

**Commit.** (this section's commit sha lands with the fit result.)
