# Rejected experiments -- Phase 7 timing-closure iterations (issue #22)

Human-readable log of every rejected/reverted iteration under issue #22. Kept
alongside `accepted_changes.md` so that the closure history is complete: a
loop that only records successes is a loop that appears to walk in a
straight line to the answer.

Each entry has hypothesis, bottleneck class (SPEC 21), what was changed,
what was measured, and why it was reverted. The machine-readable log is
`optimization_history.jsonl` at repo root (with `"decision": "reject"`);
this file is the reviewer view.

## Rejected iterations

(none yet)

## Successor-agent handoff (2026-07-28, mid-iteration-1+2 fit)

### State at handoff

  * **Iteration 1**: `cfar_window` PIPE_SUM_STAGES=1 + `cfar_core` +adv2_q
    stage. Committed as 2e37031 (RTL) + fadffa6 (log). Lint + sim-medium
    PASS. test_cfar bit-exact model check PASS (arithmetic unchanged).
  * **Iteration 2**: `benchmark_fabric_top` gains one register stage on
    every core_clk stream/DMA/telemetry port. Committed as 947e76f (RTL)
    + 4a72b9a (log). Lint + sim-medium PASS.
  * **Iteration 1+2 combined fit**: LAUNCHED 2026-07-28 15:55 against
    `full_agmf039` seed 1 (Windows Quartus 26.1). Expected duration
    ~1h45m. Log at `results/timing/logs/iter1and2_v2_fit.log`.

### Fit-launch guardrail

The Makefile's `QUARTUS_CONFIG_REGEN` step regenerates
`sim/verilator/generated/config_pkg.sv` from
`config/full_agmf039.json` before every quartus target -- but a direct
`quartus_sh -t compile.tcl all 1` invocation BYPASSES the Makefile and
uses whatever config_pkg.sv happens to be on disk. The initial iter-1
fit ran ~22 minutes against `medium` before I caught it (a preceding
sim-medium run had left medium's config_pkg.sv in place).

**Rule for the successor**: before every direct `quartus_sh` fit
launch, run
```
python3 scripts/build_verilator.py --mode lint --config-only --config full_agmf039
```
to regenerate config_pkg.sv. Or use `make quartus-compile` which does it
automatically.

### After the fit lands

1. Copy `results/timing/latest.json` to
   `results/timing/compile_<timestamp>_iter1and2.json` (immutable record).
2. Read fmax + setup WNS + hold WNS from `latest.json.clocks.core_clk`;
   read the top setup path from `agilex7_wideband.sta.rpt`.
3. Update the iteration table in the PR body with iter-1 and iter-2 rows.
4. Append rows to `optimization_history.jsonl`.
5. Update `accepted_changes.md` with the numbers.
6. Commit as `Issue #22: iter 1+2 fit result -- fmax=<X> MHz, WNS=<Y> ns`.
7. Decide iteration 3 from the new critical path.

### Iteration 3 selection tree

Look at the top setup path in the new STA:

  A. **Still `u_pipe|g_cfar_per_beam[*].u_cfar|u_window|cell_q[*] ->
     sum_lag1_q[*]`** (sum tree not fully split). Add
     PIPE_SUM_STAGES=2 to `cfar_window` -- one more mid-tree register
     bank. Same shape as iter 1; extend the parameter and the alignment
     bank + core adv3_q stage.

  B. **`u_pipe|u_bf|...|dot|acc_q[*]`** (beamformer dot-product tree).
     Register the antenna-accumulator at half-tree; same shape as
     cfar_window sum-tree split but on `bf_dot.sv`.

  C. **`u_pipe|g_pfb[*].u_pfb|...` after iter-2 boundary reg absorbed
     the hold path** -- likely the PFB coefficient bank -> FIR MAC.
     Register the coeff read at the M20K output (already-registered mode
     switch in `coeff_bank.sv` if not enabled).

  D. **`u_pipe|u_pipe_ctrl|...`** -- control-plane fanout to many
     downstream blocks. Duplicate high-fanout controls
     (SPEC 23 rule "duplicate high-fanout controls where functionally
     safe").

  E. **Hold slack still bad** -- likely iter 2 didn't reach the failing
     path. Widen boundary reg to the s_ready return path with a proper
     `stream_skid_buffer` per-antenna instance (rtl/stream/
     stream_skid_buffer.sv).

Regardless of which one wins: keep the same discipline. One hypothesis,
one smallest defensible change, one fit.

### Budget note

The current agent has ~1h45m per fit and started at 15:29 local. If a
successor arrives before the iter-1+2 fit at 15:55 lands, WAIT for it;
do NOT start a new fit on top of the running one (fits stack-cost each
other severely).

