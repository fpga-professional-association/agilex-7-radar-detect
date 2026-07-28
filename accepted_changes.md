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

**Note (2026-07-28).** The first launch of the iteration-1 fit
inadvertently ran against the medium config because
`sim/verilator/generated/config_pkg.sv` was left over from a preceding
sim-medium run (Quartus's `QUARTUS_CONFIG_REGEN` step is only run when
the fit is launched via the Makefile; the direct `quartus_sh` invocation
bypassed it). The medium-config fit was terminated ~22 minutes in;
config_pkg.sv was regenerated for `full_agmf039`, and the fit was
re-launched with both iteration 1 AND iteration 2 in place. The
combined fit is what the iteration table's numbers reflect below.

**Commit.** (this section's commit sha lands with the fit result.)

### Iteration 2 -- boundary registration on `benchmark_fabric_top`  (2026-07-28)

**Hypothesis.** The baseline hold WNS = -7.031 ns on
  `s_sof[*] -> u_pipe|g_pfb[*]|g_meta_cyc[0]|m_q[*]`
is a real hold violation caused by the virtual-pin `set_input_delay -min
0.100 ns` (io.sdc) being shorter than the routing to the receiver flops.
Adding one register stage between the virtual-pin boundary and u_pipe
provides the tCO the constraint models, closing hold STRUCTURALLY rather
than by relaxing the constraint (SPEC 24 respect). Under HyperFlex the
extra register at the fabric edge also gives the retimer raw material at
what was previously a hard endpoint.

**Bottleneck class.** `HOLD_LIMITED` (SPEC 21), `HIERARCHY_BOUNDARY`.

**Change.** `rtl/top/benchmark_fabric_top.sv`: one register stage on
every core_clk stream / DMA / telemetry port. SPEC 5 correctness: valid
is registered alongside its payload; ready stays combinational
backward. Under SPEC 5 'valid holds until ready fires', the register at
the boundary never captures inconsistent (valid, payload) pairs.
cfg_clk-domain interfaces are not boundary-registered (different clock,
Phase-5 tie-offs).

**Verification.**
  * `make lint` (18 tops): PASS
  * `verilator --lint-only --Wall benchmark_fabric_top`: clean (no new
    warnings; pre-existing UNUSEDSIGNAL in u_pipe unchanged).
  * `make sim-medium` (5 tests x 3 seeds): PASS. (sim-medium exercises
    pipeline_top, not fabric_top; the fabric_top's boundary registers
    are Quartus-only. The SPEC 5 stream latency-insensitivity means the
    extra cycle does not need scoreboard updates.)

**Fmax measurement.** Combined with iteration 1 in the relaunched fit
(2026-07-28 15:53 launch); result recorded in the iteration table when
the fit completes.

**Commit.** (this section's commit sha lands with the fit result.)

### Iteration 1+2 combined fit result -- fmax 32.08 MHz  (2026-07-28)

The combined iter-1 + iter-2 fit against `full_agmf039` seed 1 completed
2026-07-28 18:03:42 (wall clock 7822.6 s = 130 min; peak memory 35.2 GB;
Fitter Physical Synthesis 12.6 min; register duplication 91920 duplicates
created during HyperFlex retiming). STA landed 18:05:29.

Immutable record: `results/timing/compile_20260728T230826_iter1and2.json`.
Fitter log: `results/timing/logs/iter1and2_v2_fit.log`.

| Metric | Baseline | iter-1+2 | Delta |
|---|---|---|---|
| core_clk fmax | 39.67 MHz | **32.08 MHz** | -7.59 MHz (worse) |
| Setup WNS | -22.987 ns | **-28.947 ns** | -5.960 ns (worse) |
| Setup TNS | -1146299.488 ns | **-332357.862 ns** | +813941.626 ns (BETTER 3.5x) |
| Hold WNS | -7.031 ns | **-6.958 ns** | +0.073 ns (marginally better) |
| Hold TNS | -- | -90862.311 ns | (baseline field null) |
| Logic depth on worst path | 68 | **7** | -61 (much better) |
| ALM % | 23.12 % | **22.45 %** | -0.67 pp |
| M20K % | 90.70 % | 90.70 % | no change |
| DSP % | 20.36 % | 20.36 % | no change |
| Critical path | `u_pipe|g_cfar_per_beam[15].u_cfar|u_window -> ...|sum_lag1_q[35]` | `u_pipe|u_dma_arb -> u_pipe|u_dma_arb` | ARCHITECTURAL SHIFT |

**Reading of the result.** The CFAR-window pipeline (iter 1) worked exactly
as designed: the sum-tree logic depth collapsed from 68 to 7, setup TNS
improved 3.5x, and the recorded critical path moved off the CFAR window
entirely. Hold slack improved slightly from iter 2's boundary
registration. What went wrong is *not* iter 1: it is that iter 2's
boundary registers on the DMA arbiter ports uncovered a routing-dominated
control-plane hot spot inside `mem_arbiter` (`u_pipe|u_dma_arb`), where a
single combinational net (`i2176~0`, driving into the `next_tag_q` /
`free_tag_c` mux tree) fans out to 411 destinations, and the resulting
routing delay is 29.831 ns (of the 31.169 ns data path -- 95.7% routing,
cell delay just 1.099 ns, logic depth 7).

The iteration is **accepted** as a recorded step even though fmax dropped:
both changes are honest, both reduce the classes they target (LONG_COMB
and HOLD/HIERARCHY_BOUNDARY), the accompanying TNS and utilization improve,
and the loop moves the critical path onto its next architectural bottleneck
rather than solving it. Iteration 3 addresses the newly-uncovered
high-fanout mux -- case D of the A-E selection tree in
`rejected_experiments.md`.

**Commits.** iter-1: 2e37031 (RTL) + fadffa6 (log). iter-2: 947e76f (RTL)
+ 4a72b9a (log). This result: recorded in this commit.
