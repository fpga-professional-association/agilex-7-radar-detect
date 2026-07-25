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
| 0 Infrastructure | `make lint`, `make sim-tiny`, `make quartus-map` pass | `lint` and `sim-tiny` pass (#2); `quartus-map` TODO | #1, #2, #3 |
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
the clock scheduler, per SPEC §12.1–§12.3. Implemented by issue #2; the operational detail
and the full argument reference live in
[`sim/verilator/README.md`](sim/verilator/README.md).

**Build modes.** All four are produced by `scripts/build_verilator.py --mode
lint|fast|coverage|debug --config <name>`, each into its own
`sim/verilator/build/<mode>_<config>/`. `make lint` and `make sim-tiny` wrap the lint and
fast modes; coverage and debug are invoked directly until `make sim-coverage` lands in
issue #17. Lint runs `--Wall` *without* `--Wno-fatal`, so any warning not justified in
`sim/verilator/lint_waivers.vlt` fails the build.

**Harness.** A native C++ harness under `sim/verilator/harness/` (SPEC §12.2). Python
launches builds and aggregates results and is never in the per-cycle path. Present today:
multi-clock generation and event scheduling, per-domain reset sequencing, stream drivers
and monitors, randomized backpressure, scoreboards, timeout detection, error collection,
deterministic seeding and optional FST tracing. Still owned elsewhere: register read/write
(issue #7), memory model (issues #15, #24), reference-model invocation (issue #4).

**Clock scheduler.** Integer picosecond time; each clock is stored as a half period, so a
rounded half can never accumulate into period drift. Each edge is processed in two phases
— a sample phase before the toggle and `eval()`, observing exactly the values the
flip-flops are about to capture, and a drive phase after - which is what makes handshake
detection correct without per-DUT delta-cycle tuning. See DECISIONS.md 2026-07-25,
decisions 1 and 2.

**Configuration injection.** `config/<name>.json` is generated into
`sim/verilator/generated/config_pkg.sv` (imported by `benchmark_sim_top`) and
`config_sim.h` (the C++ half), so the RTL and the harness cannot disagree about a
width.

## 3. Reference model and scoreboard

Bit-accurate C++ model under `model/cpp/`, vector generation under `model/python/` and
`model/vectors/`, and the scoreboard comparison strategy per SPEC §12.4–§12.5.

The scoreboard (`sim/verilator/harness/scoreboard.h`, issue #2) keys expected-output
queues on transaction identity rather than on a fixed latency, per SPEC §12.5. The Phase 0
identity is `(stream_id, frame_id, sequence)`; `antenna`, `frequency_bin` and `beam` are
added by the issues that introduce those datapath dimensions (#10, #11, #12). Loss,
duplication, ordering violations, content mismatch, unexpected transactions and
bounded-latency violations are counted separately, so a failure names its own category.

The bit-accurate C++ reference model under `model/cpp/` remains TODO — issue #4 for the
numeric types, extended per kernel by issues #9–#14.

Standing rule (PLAN.md #5): latency changes update scoreboard metadata only, never
expected numerical values.

## 4. Test categories

### 4.1 Unit tests (SPEC §13.1)

| Module | Test | Directed | Boundary | Randomized | Reset | Stall | Assertions |
|---|---|---|---|---|---|---|---|
| `stream_loopback` (provisional, issue #2) | `sim/tests/test_stream_loopback.cpp` | yes | length-1 frame (SOF==EOF), 1-8 length sweep | 4 randomized passes | reset re-run before every pass | 4 stall profiles, both sides | `a_master_stable`, `a_slave_stable` |

One row per module, added by the issue that implements it. The `stream_loopback` row is
retired when issue #5 replaces the module.

**Fault-injection validation.** A test that passes against a correct DUT proves nothing on
its own. Six faults were injected into `stream_loopback.sv` and each was caught, which is
what establishes that the Phase 0 checks are load-bearing:

| Injected fault | Detected as |
|---|---|
| output slot swallows ~1 beat in 8 | `sequence` discontinuity + `order` |
| output `valid` never cleared on transfer | `duplicate` |
| data MSB inverted at the module output | `content` mismatch |
| `ready` ignores skid occupancy (overflow) | `sequence` + `order` |
| output register changes while stalled | `a_master_stable` assertion, SIGABRT |
| unused parameter added to the RTL | `make lint` fails (waiver proven narrow) |

Repeat this whenever a check is added or relaxed.

### 4.2 Metamorphic tests (SPEC §13.2)

TODO — populated by issues #10–#14.

### 4.3 Random testing (SPEC §13.3)

Deterministic seeds only; every failing seed is recorded and replayable.

**Framework (issue #2).** One master seed per run, resolved from `+seed=N`, else
`$SIM_SEED`, else 1, and printed on every run together with the command line that replays
it. Named substreams — `splitmix64(master ^ splitmix64(fnv1a(name)))` — keep each
generator independent of the others, so adding a component to a test does not perturb an
existing component's stimulus for a given seed. Bounded draws use rejection sampling
implemented in the harness rather than `std::uniform_int_distribution`, whose algorithm
the C++ standard leaves unspecified.

**Determinism guarantee.** Every field of the JSON run summary except `wall_time_s` is a
pure function of (seed, config, build mode, test); two runs of one seed produce
byte-identical summaries apart from that line.

Extended per block by the implementing issues.

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

The coverage build (`--mode coverage`) enables Verilator line, branch, toggle and user
coverage and writes `results/simulation/coverage_seed<N>.dat` per run — one file per seed
rather than a shared `coverage.dat`, so the runs of a randomized regression cannot clobber
each other.

TODO — merge tooling, per-phase coverage targets and archival: issue #17.

## 7. Failure handling and reproduction

Failing seeds and waveforms are captured under `sim/failures/`; every failure must be
reproducible from a recorded seed plus config name.

**Reproduction procedure (issue #2).** The `RESULT:` line and the JSON run summary both
carry the seed and the config. To obtain a waveform:

```bash
python3 scripts/build_verilator.py --mode debug --config <config>
./sim/verilator/build/debug_<config>/Vbenchmark_sim_top_<test> +seed=<seed> +trace
```

Tracing is compiled in only for the debug build and stays disarmed until `+trace`, so the
fast regression build carries no tracing code at all. The FST lands at
`sim/failures/<test>_seed<seed>.fst`, named so the artefact states its own reproduction
command. The JSON summary additionally records per-category error counts and the first ten
error messages — the failure-minimisation metadata SPEC §12.2 asks for.

## 8. Regression entry points

`make lint`, `make sim-tiny`, `make sim-medium`, `make sim-random`, `make sim-stress`,
`make sim-coverage`, `make sim-full-smoke` (SPEC §16).

| Target | Status |
|---|---|
| `make lint` | implemented (issue #2) — `--lint-only --Wall`, zero unwaived warnings |
| `make sim-tiny` | implemented (issue #2) — fast build, loopback test once per seed in `SEEDS` (default `1 2 3`) |
| `make sim-medium` | TODO(issue #17) |
| `make sim-random` | TODO(issue #17) |
| `make sim-stress` | TODO(issue #17) |
| `make sim-coverage` | TODO(issue #17) |
| `make sim-full-smoke` | TODO(issue #20) |

Unimplemented targets still fail loudly with `TODO(issue #N)` and a non-zero exit.
