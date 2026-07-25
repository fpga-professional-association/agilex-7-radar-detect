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
| 1 Common infrastructure | unit tests, random stalls, CDC tests, assertions pass | numerics (#4), stream primitives + protocol assertions (#5) and the register/control plane (#7) pass; CDC TODO | #4–#8 |
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
deterministic seeding, register read/write (`reg_driver.h`, issue #7), the CDC
clock-ratio sweep (`clock_ratios.h`, issue #6) and optional FST tracing. Still owned
elsewhere: memory model (issues #15, #24), reference-model invocation
(issue #4).

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

The bit-accurate C++ reference model under `model/cpp/` exists as of issue #4 for the
shared numeric primitives (`model/cpp/fxp/`), extended per kernel by issues #9–#14. It is
only usable as an RTL oracle because its equivalence to `rtl/packages/fxp_pkg.sv` and to
an independent NumPy model is measured on every regression by `make numerics-check`, a
prerequisite of `make sim-tiny`. Method and triage procedure: [NUMERICS.md](NUMERICS.md)
§10.

Standing rule (PLAN.md #5): latency changes update scoreboard metadata only, never
expected numerical values.

## 4. Test categories

### 4.1 Unit tests (SPEC §13.1)

| Module | Test | Directed | Boundary | Randomized | Reset | Stall | Assertions |
|---|---|---|---|---|---|---|---|
| `stream_loopback` (rebuilt on the primitives, issue #5) | `sim/tests/test_stream_loopback.cpp` | yes | length-1 frame (SOF==EOF), 1-8 length sweep | 4 randomized passes | reset re-run before every pass | 4 stall profiles, both sides | full checker set inside each primitive, plus `a_pack_roundtrip` and `a_elastic_occupancy` |
| `stream_skid_buffer` (issue #5) | `sim/tests/test_stream_primitives.cpp`, dut0 | exact latency 1 and one beat per cycle | frame length 1..8; both storage slots full | 4 randomized stall passes | reset re-run before every pass | fast/slow producer x fast/slow consumer, plus bursty both | shared checker on the master interface |
| `stream_elastic_buffer` DEPTH=2 (issue #5, the two-deep register slice) | `sim/tests/test_stream_primitives.cpp`, dut1 | exact latency 1 and one beat per cycle | both slots full; drain while filling | 4 randomized stall passes | reset re-run before every pass | as above | shared checker plus overflow, underflow, occupancy-shadow, occupancy-bound and pointer-consistency |
| `stream_elastic_buffer` DEPTH=8 (issue #5) | `sim/tests/test_stream_primitives.cpp`, dut2 | exact latency 1 and one beat per cycle | occupancy swept 0..8 and held at 8 | 4 randomized stall passes | reset re-run before every pass | as above | as above |
| `stream_pipe` STAGES=4 OUT_DEPTH=6 (issue #5) | `sim/tests/test_stream_primitives.cpp`, dut3 | exact latency 5 and one beat per cycle | credits exhausted and refilled | 4 randomized stall passes | reset re-run before every pass | as above | shared checker plus buffer-has-room, credits-bounded and credit-conservation |
| stream protocol assertion set (issue #5) | `sim/tests/test_stream_assertions.cpp` | one clean mode, four violating modes | first stall, first frame boundary | n/a (deterministic injection) | reset before every mode | stalls forced to provoke modes 1 and 2 | the set under test; each mode names the assertion it must provoke |
| register/control plane (issue #7) | `sim/tests/test_control_regs.cpp` | identification, build parameters, reset defaults, W1C and pulse semantics, hardware-computed status | walking ones and zeros on every scratch bit; all 15 non-zero byte-enable patterns; the half-writable register; every malformed and unmapped address form | 600 seeded transactions against a C++ model of the map (~30% illegal), then a full register dump | reset re-run before three of the nine passes; every reset default re-read | n/a (no handshake to stall); the watchdog covers a block that never answers | `reg_if_checker` inside `reg_fabric`: master stability, one ready per request, error and read-data confinement, bounded response |
| `sync_fifo` DEPTH=8, registered output, `STORAGE="regs"` (issue #6) | `sim/tests/test_sync_fifo.cpp`, fifo0 | every observable compared against `model/cpp/cdc/fifo_ref.h` on every cycle | frame length 1..8 sweep; empty, full, almost-full and almost-empty all reached | 4 randomized stall passes | reset re-run before every pass | fast/slow producer x fast/slow consumer, plus bursty both | overflow, underflow, occupancy-shadow, occupancy-bound, pointer-consistency, high-water and sticky-flag assertions inside the FIFO, plus the SPEC §5 checker on both interfaces |
| `sync_fifo` DEPTH=4, show-ahead, `STORAGE="mlab"` (issue #6) | `sim/tests/test_sync_fifo.cpp`, fifo1 | as above, with zero-latency output | fills to DEPTH in every stall pass | 4 randomized stall passes | reset re-run before every pass | as above | as above |
| `async_fifo` DEPTH=8, `STORAGE="m20k"` (issue #6) | `sim/tests/test_async_fifo.cpp`, afifo | 7 clock ratios x 2 stall profiles, scoreboarded on transaction identity | in-flight reaches the full DEPTH+1 capacity at every ratio; empty and full both reached | randomized stalls on both sides, independent per domain | two-domain reset re-run before every pass, with different release delays per domain | free-running and stalled profiles at every ratio | Gray one-bit on both pointers, pointer sanity per domain, overflow, underflow, reset-pointers-cleared |
| `stream_cdc` A->B, registered output (issue #6) | `sim/tests/test_async_fifo.cpp`, scdc_f | as above, with the full SPEC §5 field geometry | occupancy swept 0..DEPTH; almost-full reached | as above | as above | as above | the async FIFO set plus the SPEC §5 checker in both clock domains |
| `stream_cdc` B->A, show-ahead read side (issue #6) | `sim/tests/test_async_fifo.cpp`, scdc_r | as above, source in the other domain | as above | as above | as above | as above | as above |
| `cdc_pulse` (issue #6) | `sim/tests/test_cdc_synchronizers.cpp`, phases `pulse_paced` and `pulse_overrun` | delivered strobes equal accepted pulses at all 7 ratios | back-to-back offers on every source cycle (overrun); `src_busy` honoured (paced) | randomized offer pattern per ratio | two-domain reset before every phase | n/a (no handshake); the busy/overrun path is the flow control | `a_no_toggle_while_busy`, `a_no_phantom_pulse`; sticky overrun must latch and then clear |
| `cdc_handshake` (issue #6) | `sim/tests/test_cdc_synchronizers.cpp`, phases `handshake_burst` and `handshake_gapped` | every value observed in order, none lost, duplicated or invented, at all 7 ratios | back-to-back at the crossing's maximum rate; idle gaps up to 12 cycles | randomized gap lengths per ratio | two-domain reset before every phase | `s_valid` held against `s_ready` | `cdc_handshake_checker` in the source domain, plus `a_no_phantom_transfer` |
| `cdc_sync2` (issue #6) | `sim/tests/test_cdc_synchronizers.cpp`, phase `status_bit` | the output equals the held input at the end of every 64-cycle window | at most one output transition per window (glitch / wrong-stage detector) | randomized value per window, per ratio | two-domain reset before every phase | n/a | elaboration `$fatal` on `WIDTH > 1` without `GRAY_CODED`, and on `STAGES < 2` |
| CDC assertion set (issue #6) | `sim/tests/test_cdc_assertions.cpp` | one clean mode, four violating modes | first pointer step; first handshake | n/a (deterministic injection) | reset before every mode | n/a | the set under test; each mode names the assertion it must provoke |
| `fxp_pkg` + `fxp_sticky_flags` (issue #4) | `model/cpp/test/test_fxp_vectors.cpp` (C++ vs NumPy) and `sim/tests/test_fxp_rtl.cpp` (RTL vs NumPy vs C++) | 927 directed vectors | max pos/neg and one/two past, at 8 widths; all four rounding tie classes; ±1.0 wrap; round-then-saturate across the endpoints; every Q1.15 boundary multiply pair | 530 seeded vectors + 6 seeded accumulator walks | accumulator cleared at every sequence start; DUT reset before the first | n/a (no handshake) | property sweeps: shift-0 identity, saturation idempotence, measured rounding bias, accumulator non-overflow |

One row per module, added by the issue that implements it. `stream_loopback` was rebuilt
on the canonical primitives by issue #5 and keeps its row: it is now the integration test
for a skid -> elastic -> skid chain, and the place where the SPEC §5 packing is checked
against the harness beat by beat.

The numerics row is run by `make numerics-check`, which `make sim-tiny` depends on, so
every regression re-proves that the RTL package, the C++ reference model and the
independent NumPy model agree bit-for-bit. Its own fault-injection table and triage
procedure are in [NUMERICS.md](NUMERICS.md) §10.

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

Four more were injected into the issue #5 primitives, against the checks that issue adds,
and each was caught (`make sim-tiny`, seed 1):

| Injected fault | Detected as |
|---|---|
| `stream_elastic_buffer` registered ready ignores occupancy | `a_no_overflow` assertion, at `DEPTH=2` |
| `stream_elastic_buffer` occupancy output under-reports by one | `occupancy` error: reported fill disagrees with the harness count of beats in flight |
| `stream_pipe` credit gate always open | `capacity` error (7 beats in flight against a capacity of 6) and the `a_credits_bounded` assertion |
| `stream_skid_buffer` drops the skidded beat instead of draining it | `sequence` and `order` errors from the scoreboard, and the `a_seq_continuous` assertion |

The clean tree was rebuilt and re-run after each injection and passed, so the detections
are attributable to the fault and not to the edit.

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

Protocol, CDC, and structural assertions, and where each is enabled. Assertion sources
live in `sim/assertions/`. Packet-fabric assertions are issue #18.

### 5.1 Stream protocol assertion set (issue #5)

One definition of the property text, in `sim/assertions/stream_sva.svh`, wrapped as a
module in `sim/assertions/stream_protocol_checker.sv`. Both ways of attaching it are in
use:

* **by instantiation** — every primitive in `rtl/stream/` instantiates a checker on its
  master interface inside `` `ifndef SYNTHESIS ``. Any design built from the primitives is
  therefore checked at every stage boundary with no test-side wiring, in the SPEC §12.1
  fast build (SPEC §14: "Assertions must remain active in fast simulation").
* **by `bind`** — `sim/verilator/tops/stream_violator_top.sv` binds a checker onto a
  module that carries no assertions of its own. This is the mechanism for observing a
  stage whose source should not be edited.

| Property | Kind | Checks |
|---|---|---|
| `a_valid_held` | concurrent | `valid` is never withdrawn without a transfer |
| `a_payload_stable` | concurrent | the whole payload is bit-stable while `valid && !ready` |
| `a_reset_clears_valid` | concurrent | validity is low in the cycle after reset asserts |
| `a_no_x_when_valid` | concurrent | no X on the payload while `valid` (see the note below) |
| `a_sof_opens_frame` | immediate | a beat outside a frame carries `start_of_frame` |
| `a_sof_not_in_frame` | immediate | a beat inside a frame does not carry `start_of_frame` |
| `a_seq_continuous` | immediate | `seq` increments by one per beat within a `stream_id` |
| `c_stall_then_transfer` | cover | a stall that ends in a transfer was reached |
| `c_back_to_back` | cover | two transfers in consecutive cycles were reached |

Framing and sequence state is per `stream_id` and is cleared by reset — control state, not
payload (SPEC §23). The geometry-aware half runs only where the checker is given the four
field widths; a primitive parameterised on payload width alone gets the payload-agnostic
half, which is the correct contract for it.

Primitive-local assertions, in addition to the shared set:

| Assertion | Module | Checks |
|---|---|---|
| `a_no_overflow` | `stream_elastic_buffer` | no write while full (SPEC §14 FIFO overflow) |
| `a_no_underflow` | `stream_elastic_buffer` | reads never exceed writes (SPEC §14 FIFO underflow) |
| `a_occupancy_shadow` | `stream_elastic_buffer` | the occupancy counter equals an independent writes-minus-reads model |
| `a_occupancy_bound` | `stream_elastic_buffer` | occupancy never exceeds `DEPTH` |
| `a_ptr_consistent` | `stream_elastic_buffer` | the pointers agree with the occupancy (SPEC §14 illegal simultaneous read/write states) |
| `a_buffer_has_room` | `stream_pipe` | the free-running delay line never presents a beat to a full buffer |
| `a_credits_bounded` | `stream_pipe` | the credit counter never exceeds `OUT_DEPTH` |
| `a_credit_conservation` | `stream_pipe` | credits plus occupancy never exceed `OUT_DEPTH` |
| `a_pack_roundtrip` | `stream_loopback` | `stream_pack`/`stream_unpack` is the identity on every accepted beat |
| `a_elastic_occupancy` | `stream_loopback` | the internal buffer never exceeds its depth |

`stream_elastic_buffer`'s occupancy assertions are written against a second, deliberately
naive model (two free-running counters) rather than against the counter that drives
`m_valid` and `s_ready`. An assertion written against the signal it is checking is a
tautology; this one disagrees when the counter is wrong.

**What Verilator 5.020 actually enforces.** Measured, not assumed; the table and the
method are in DECISIONS.md 2026-07-26, decision 3. In short: concurrent `assert property`
with `|=>`, `|->`, `$stable`, `$past` and `disable iff` works; immediate assertions in
`always_ff` with an `else $error(...)` action work; `bind` works, concurrent properties
included; `cover property` compiles and is counted only in a `--coverage` build; `##`
cycle-delay sequences are **not supported**, so every property here is written with
implication and `$past`; and `$isunknown` compiles but the tool is two-state, so
`a_no_x_when_valid` is structurally dead under Verilator and exists for four-state
simulators.

### 5.2 Proof that the assertions fire (issue #5)

`sim/tests/test_stream_assertions.cpp` drives `stream_violator_top` — a deliberately
broken stage with the checker bound onto it — once per violation mode, and requires the
*named* property to fire; a checker that fired some other assertion would otherwise look
like a pass. The stimulus source is the ordinary harness `StreamDriver`, which is
protocol-correct by construction, so any assertion that fires is the DUT's fault.

| Mode | Injected violation | Required assertion |
|---|---|---|
| 0 | none — a correct one-deep stage | *none may fire*, over a 400-cycle run with stalls |
| 1 | payload mutated while stalled | `a_payload_stable` |
| 2 | offered beat retracted without a transfer | `a_valid_held` |
| 3 | one sequence field corrupted in flight | `a_seq_continuous` |
| 4 | `start_of_frame` stripped from a frame-opening beat | `a_sof_opens_frame` |

Expected-failure handling: a failing Verilator assertion calls `vl_stop`, which aborts the
process by default. That behaviour is kept everywhere else; this test alone calls
`Verilated::fatalOnError(false)`, so the failure becomes an observable event that the test
reports as an expected failure and the binary exits 0. The run is failed by a violating
mode in which nothing fired, by the wrong property firing, or by the clean mode asserting.
This test runs in `make sim-tiny` on every seed.

### 5.3 Register-interface assertion set (issue #7)

`sim/assertions/reg_if_checker.sv` is instantiated inside `reg_fabric` under
`ifndef SYNTHESIS`, so the SPEC §9 protocol is checked wherever the fabric is used, in the
fast build, with no test-side wiring — the arrangement `rtl/stream/` already uses.

| Property | Obligation of | What it forbids |
|---|---|---|
| `a_request_stable` | the master | changing address, write data, byte enables or either enable before `ready` is observed |
| `a_ready_only_when_busy` | the fabric | a response with no transaction outstanding |
| `a_ready_single_cycle` | the fabric | one request answered twice |
| `a_error_needs_ready` | the fabric | `error` asserted outside a response cycle |
| `a_read_data_needs_ready` | the fabric | non-zero `read_data` outside a response cycle |
| `a_ready_follows_request` | the fabric | a response to a request that was never presented |
| `a_bounded_response` | the fabric | any access outstanding longer than `REG_ACCESS_LATENCY + REG_WATCHDOG_CYCLES + 1` — the machine-checked form of "the register plane never hangs" |

Covers (`c_write`, `c_read`, `c_error`), counted only in the coverage build, record that
successful writes, successful reads and error responses were all actually reached.

Half the set watches the *master*, which is the C++ `RegDriver`, not the RTL. That is
deliberate: a harness that violates the protocol it is testing for is otherwise invisible,
and every result it produces is worthless.

**Proof that the set fires (issue #7).** `RegDriver::apply_pins` was perturbed to toggle one
address bit while a transaction was outstanding, and the run stopped at
`control_top.u_fabric.u_checker.a_request_stable` by name; the perturbation was reverted and
the suite passes. Two further properties of the fabric are proven by construction in the
test rather than by injection: the watchdog escape is exercised every run against a
deliberately dead block (`sim/verilator/tops/reg_block_dead.sv`, pass 8), and every one of
the ~1200 transactions in a run is checked for the exact two-cycle response latency, so an
access that silently varies in length fails the suite.

### 5.4 Register-map drift (issue #7)

`control/regmap.json` is the single source of truth for the register plane; the generated
SystemVerilog package, the C++ harness header and `docs/regmap.md` are committed, and
`make regmap-check` (`python3 scripts/gen_regmap.py --check`) regenerates all three in
memory and fails on any difference. It is a prerequisite of both `make lint` and
`make sim-tiny`, so neither a hand-edited generated file nor a source-of-truth change that
was never regenerated can reach a green gate. Verified by editing `REGMAP_BLOCK_MASK` in the
generated package: `make lint` exited non-zero and quoted the offending line.

The generator is also a static checker of the map itself. It refuses to emit anything if a
window is misaligned or overlaps, if register offsets are not dense within a block, if two
fields overlap, if a reset value does not fit its field, if a hardware-driven or sticky field
carries a non-zero reset, or if the blocks do not between them claim all sixteen SPEC §9
register groups.

### 5.5 CDC assertion set (issue #6)

SPEC §14 names two CDC obligations explicitly — *CDC handshake completion* and *Gray-pointer
one-bit transitions* — alongside the FIFO overflow, underflow and illegal-simultaneous-state
checks that apply to the asynchronous FIFO as much as to the synchronous one. One definition
of the property text lives in `sim/assertions/cdc_sva.svh`, wrapped as two modules
(`sim/assertions/cdc_gray_checker.sv`, `sim/assertions/cdc_handshake_checker.sv`). Both ways
of attaching it are in use, exactly as for the stream set:

* **by instantiation** — `async_fifo` instantiates a Gray checker on each of its two pointers
  and `cdc_handshake` instantiates a handshake checker on its source-side request, inside
  `` `ifndef SYNTHESIS ``. Any design built from these primitives is therefore checked at
  every crossing with no test-side wiring, in the SPEC §12.1 fast build.
* **by `bind`** — `sim/verilator/tops/cdc_violator_top.sv` binds both checkers onto a module
  that carries no assertions of its own.

| Property | Kind | Checks |
|---|---|---|
| `a_gray_one_bit` | immediate | a Gray-coded pointer changes at most one bit per cycle |
| `c_gray_moved` | cover | the pointer actually moved during the run (a stationary pointer satisfies the assertion vacuously) |
| `a_hs_req_held` | concurrent | a raised request is never withdrawn before it is answered |
| `a_hs_data_stable` | concurrent | the payload is frozen for the whole request window |
| `a_hs_ack_after_req` | concurrent | an acknowledge rises only while a request is outstanding |
| `a_hs_ack_held` | concurrent | the acknowledge is not dropped while the request is still up |
| `a_hs_completes` | immediate | no request goes unanswered for more than `ACK_TIMEOUT` cycles (bounded liveness) |
| `c_hs_completed` | cover | a full request/acknowledge overlap was reached |
| `a_fifo_no_overflow` | immediate | the write pointer never runs more than DEPTH ahead of the read pointer, per domain |
| `a_no_overflow` / `a_no_underflow` | immediate | no write committed while full, no read committed while empty |
| `a_wr_reset_pointers_cleared` / `a_rd_reset_pointers_cleared` | immediate | both pointers are zero when the crossing leaves reset — the detector for "the two resets were not asserted together" |
| `a_no_toggle_while_busy` / `a_no_phantom_pulse` | immediate | `cdc_pulse` never accepts a pulse while busy, and never delivers more strobes than it accepted |
| `a_no_phantom_transfer` | immediate | `cdc_handshake` never delivers more values than were offered |

**Scope note, and why one checker was deleted.** The Gray one-bit rule is a statement about
consecutive values of the pointer *register*, so the checker is attached only in the domain
that owns the pointer. Attaching it to a synchronizer *output* fails on correct RTL at every
non-unity clock ratio, because a faster source domain legitimately advances several Gray steps
between two destination samples; this was measured at 2:1 on the first run of the ratio sweep
and the two instances were removed. See DECISIONS.md (issue #6) decision 6.

### 5.6 Proof that the CDC assertions fire (issue #6)

`sim/tests/test_cdc_assertions.cpp` drives `cdc_violator_top` — a deliberately broken crossing
with both checkers bound onto it — once per violation mode, and requires the *named* property
to fire. Expected-failure handling is identical to §5.2: this test and
`test_stream_assertions.cpp` are the only two places that call
`Verilated::fatalOnError(false)`, so a deliberate violation becomes an observable event and
the binary exits 0 when every expected failure was seen.

| Mode | Injected violation | Required assertion |
|---|---|---|
| 0 | none — correct Gray pointer and correct four-phase handshake | *none may fire*, over a 400-cycle run |
| 1 | pointer increments in binary and is presented as Gray-coded | `a_gray_one_bit` |
| 2 | handshake payload mutated while the request was outstanding | `a_hs_data_stable` |
| 3 | request dropped before it was acknowledged | `a_hs_req_held` |
| 4 | acknowledge raised with no request outstanding | `a_hs_ack_after_req` |

Modes 1 and 2 are the two the issue #6 gate names: the Gray transition rule and the handshake
payload-stability rule are the properties the entire asynchronous-FIFO and multibit-handshake
construction rests on. Each mode fires exactly one assertion, by name, within the first seven
cycles; the clean mode fires none. The run is failed by a violating mode in which nothing
fired, by the wrong property firing, or by the clean mode asserting. This test runs in
`make sim-tiny` on every seed.

### 5.7 CDC inventory (SPEC §8, issue #6)

SPEC §8 requires "an explicit CDC inventory report". `scripts/cdc_inventory.py` produces
`results/simulation/cdc_inventory.json` (generated, never committed) by joining two sources:
a scan of `rtl/` for the `(* cdc_primitive = ... *)` attribute above each crossing module,
and the fully elaborated instance tree from `verilator --xml-only`. Each entry carries the
instance path, the crossing type, the source and destination clock nets resolved to top-level
names, the payload width, the synchronizer depth, and the nearest enclosing composite
crossing. Rationale for the mechanism, and the alternatives rejected, are in DECISIONS.md
(issue #6) decision 5.

The report is a gate, not a document: `make cdc-inventory` runs it with `--strict`, is a
prerequisite of `make sim-tiny`, and fails on a non-empty `unknown` list. `unknown` includes
any instantiated module with two or more clock-like ports that carries no `cdc_primitive`
attribute, so a crossing added later without being declared fails the regression rather than
being silently omitted.

Current state (`cdc_prims_top`, the design containing every crossing this issue delivers):
**24 crossings, 0 unknown** — 3 `async_fifo_gray`, 2 `stream_cdc`, 1 `handshake_4phase`,
1 `pulse_toggle`, 17 `sync_ff`. Verified self-maintaining by re-running the script against a
catalog containing only `cdc_sync2`: it reported the seven composite crossings as `unknown`
and exited non-zero.

Two runs of the script produce byte-identical JSON (crossings are emitted in instance-path
order), which is what lets the report be diffed between revisions.

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
| `make lint` | implemented (issue #2, extended by #5, #7 and #6) — `regmap-check`, then `--lint-only --Wall` on `benchmark_sim_top`, `stream_prims_top`, `stream_violator_top`, `control_top`, `cdc_prims_top` and `cdc_violator_top`; zero unwaived warnings |
| `make sim-tiny` | implemented (issue #2, extended by #5, #7 and #6) — `numerics-check`, `regmap-check` and `cdc-inventory`, then the fast build of six tops, then `test_stream_loopback`, `test_stream_primitives`, `test_stream_assertions`, `test_control_regs`, `test_sync_fifo`, `test_async_fifo`, `test_cdc_synchronizers` and `test_cdc_assertions` once per seed in `SEEDS` (default `1 2 3`). Clean run: 52 s |
| `make regmap-check` | implemented (issue #7) — not a SPEC §16 entry point; a prerequisite of `lint` and `sim-tiny`, runnable alone while editing `control/regmap.json` |
| `make cdc-inventory` | implemented (issue #6) — not a SPEC §16 entry point; a prerequisite of `sim-tiny`, runnable alone. Fails on any unclassified crossing |
| `make sim-medium` | TODO(issue #17) |
| `make sim-random` | TODO(issue #17) |
| `make sim-stress` | TODO(issue #17) |
| `make sim-coverage` | TODO(issue #17) |
| `make sim-full-smoke` | TODO(issue #20) |

Unimplemented targets still fail loudly with `TODO(issue #N)` and a non-zero exit.
