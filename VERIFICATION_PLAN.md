# Verification Plan

How correctness is established and kept established for the benchmark: the per-phase
gates that block progress, the categories of test that feed those gates, the reference
model against which everything is compared, and the coverage evidence required before
the design is allowed to scale. Governing requirements: [SPEC.md](SPEC.md) §12
(Verilator strategy), §13 (tests), §14 (assertions), §19 (phase gates).

Correctness always precedes optimization: no timing-closure iteration may land without
the simulation evidence named here (SPEC §20 step 1).

> **Status: skeleton (issue #1).** Headings only. Test content is added by the issue
> that implements the thing being tested.

## 1. Phase gates (SPEC §19)

Each gate must pass from a clean checkout before the next phase begins.

| Phase | Gate | Status | Owning issue |
|---|---|---|---|
| 0 Infrastructure | `make lint`, `make sim-tiny`, `make quartus-map` pass | TODO | #1, #2, #3 |
| 1 Common infrastructure | unit tests, random stalls, CDC tests, assertions pass | TODO | #4–#8 |
| 2 DSP kernels | bit-accurate vs C++ model; directed, random, boundary coverage | TODO | #9–#14 |
| 3 Medium pipeline | continuous frames, random backpressure, config changes, stress, coverage | TODO | #15–#17 |
| 4 Packet/control fabric | no loss or duplication; random destination/stall; priority and fairness; counters | TODO | #18, #19 |
| 5 Full-scale elaboration | Verilator compiles full config; smoke passes; Quartus A&S succeeds; no logic removal; resource in target region | TODO | #20 |
| 6 Initial fit | immutable baseline captured (source, project, reports, seed, sim result, utilization, timing, power) | TODO | #21 |
| 7 Timing closure | every iteration re-proves function before acceptance | TODO | #22 |
| 8 Seed robustness | ten fixed seeds (1, 3, 7, 11, 17, 23, 31, 43, 59, 73) | TODO | #23 |
| 9 HBM2e integration | behavioral memory under Verilator; traffic generators and counters | TODO | #24 |

## 2. Simulation infrastructure

Verilator build modes (lint / fast / coverage / debug), the C++ multi-clock harness, and
the clock scheduler, per SPEC §12.1–§12.3.

TODO — populated by issue #2.

## 3. Reference model and scoreboard

Bit-accurate C++ model under `model/cpp/`, vector generation under `model/python/` and
`model/vectors/`, and the scoreboard comparison strategy per SPEC §12.4–§12.5.

TODO — populated by issue #2 (harness and scoreboard skeleton) and issue #4 (numeric
types); extended per kernel by issues #9–#14.

Standing rule (PLAN.md #5): latency changes update scoreboard metadata only, never
expected numerical values.

## 4. Test categories

### 4.1 Unit tests (SPEC §13.1)

TODO — one entry per module, added by the implementing issue.

### 4.2 Metamorphic tests (SPEC §13.2)

TODO — populated by issues #10–#14.

### 4.3 Random testing (SPEC §13.3)

Deterministic seeds only; every failing seed is recorded and replayable.

TODO — populated by issue #2 (framework) and extended per block.

### 4.4 Long stress test (SPEC §13.4)

TODO — populated by issue #17.

### 4.5 Full-scale smoke tests (SPEC §13.5)

TODO — populated by issue #20.

## 5. Assertions (SPEC §14)

Protocol, CDC, and structural assertions, and where each is enabled.

TODO — populated by issue #5 (stream protocol), issue #6 (CDC), issue #18 (packet
fabric); assertion sources live in `sim/assertions/`.

## 6. Coverage strategy

Coverage build, metrics collected, targets per phase, and how coverage reports are
archived under `results/simulation/`.

TODO — populated by issue #2 (coverage build) and issue #17 (coverage targets).

## 7. Failure handling and reproduction

Failing seeds and waveforms are captured under `sim/failures/`; every failure must be
reproducible from a recorded seed plus config name.

TODO — populated by issue #2.

## 8. Regression entry points

`make lint`, `make sim-tiny`, `make sim-medium`, `make sim-random`, `make sim-stress`,
`make sim-coverage`, `make sim-full-smoke` (SPEC §16). Currently scaffold stubs that
exit non-zero with `TODO(issue #2)`.

TODO — implemented by issue #2.
