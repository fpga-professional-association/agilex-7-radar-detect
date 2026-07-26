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
| `perf_counter` + `telemetry_block` (issue #8) | `sim/tests/test_perf_counters.cpp` | count, gate, clear and snapshot on 8-bit probes; traffic counted exactly against a harness tally; injected overflow, saturation and CDC events; FIFO high-water against the FIFO's own tracker | SPEC §13.4 wrap: 300 events into an 8-bit modulo counter, the same into a saturating one, and a weighted counter that steps *over* the boundary rather than landing on it; a coherent 21-register sweep taken while traffic runs | 40 frames of randomized traffic at heavy/bursty backpressure interleaved with randomized register access, snapshots, clears and event injection, then a full window dump | reset re-run before three of the nine passes; every reset default re-read; `ENABLE`/`CLEAR` exercised as a second, software-visible reset | heavy source and bursty sink; the stall counter is required to be non-zero, so a pass in which nothing stalled is a failed pass | `telemetry_assertions` inside every `perf_counter`: gate, clear, shadow-holds, shadow-latched, shadow-valid, sticky wrap, and the mode-specific saturating/modulo pair. Live counters compared with the tally, and all three probes with `telemetry::CounterModel`, on **every cycle** |
| `seq_checker` (issue #8) | `sim/tests/test_seq_checker.cpp` | gap, duplicate, reorder and untracked each injected alone and required to land in its own category with its own count; nominal traffic required to produce exactly zero | the duplicate/reorder boundary (one behind against two behind); a gap of one; `0xFFFF -> 0x0000` in order, and a gap, a duplicate and a reorder that straddle it | ~500 beats carrying ~16% deliberate faults of all four kinds, against `telemetry::SeqTrackerModel` | reset re-run before seven of the nine passes; `SEQ_ENABLE` low then high checked to re-initialise rather than report a loss | n/a for the injected path (no handshake); the nominal pass runs at heavy source and bursty sink backpressure | `seq_checker_assertions` inside the module: one classification per beat, no classification without a transfer, no zero-beat gap. Classification, counts and sticky flags compared with the model on **every cycle** |
| `complex_multiplier`, all 12 elaborations (issue #9) | `sim/tests/test_cmult.cpp` (RTL vs NumPy vs C++) and `model/cpp/test/test_fxp_vectors.cpp` group 4 (C++ vs NumPy) | 864 directed vectors from `model/vectors/cmult.vec`, each checked against 12 RTL instances, both C++ arithmetic paths and the NumPy expectation | the 144-pair Q1.15 corner grid including `(-1-1j)^2`, the +2^31 case that needs the 33rd bit; the round-then-saturate edge swept one LSB at a time in both directions, both tie directions; the Karatsuba pre-adder extremes at ±2^16; every single-LSB sign combination | 24 000 fresh operand pairs per seed (12 000 dense, 12 000 bursty-gapped); a third of the drawn components come from the Q1.15 endpoints so full-scale combinations appear in the random stream and not only in the directed set | reset re-run before every pass and before every DUT of the latency sweep | n/a (fixed-latency kernel, no ready); the gapped pass is the valid-pipeline stress | `cmult_assertions` on all 6 matched MULT4/MULT3 pairs on every cycle, plus `a_cmult_re/im_matches_pkg` and `a_cmult_post_adder_fits_*` inside the module itself. A flag audit fails the run if all four saturation cases were not observed |
| `streaming_fft`, all 5 elaborations (issue #11) | `sim/tests/test_fft.cpp` (RTL vs NumPy vs C++) and `model/cpp/test/test_fft_ref.cpp` (C++ vs NumPy) | all 36 records of `model/vectors/fft64.vec` driven **back to back with no gap**: impulse at six position classes plus one on the imaginary axis and one at the `-1.0` sample, DC at three amplitudes, single-bin tones at low bins / N/4 / both Nyquist neighbours / Nyquist, three negative-frequency tones, three two-tone pairs, three seeded random frames, four maximum-amplitude saturation patterns, and three records repeated with `REORDER = 0` | the `-1.0` sample whose `-j` negation saturates; the `a-b = 2^16-1` pair that rounds one LSB past Q1.15; full-scale input with the shifts REMOVED from the schedule; Nyquist and both its neighbours; bin `N-1` | 24 fresh random frames per seed, driven twice — dense, then again under bursty input gaps and heavy output backpressure, with the two runs required to be **identical** | reset re-run before every pass and before each of the 36 flag sessions | bursty on the input and heavy on the output, both mid-frame and between frames; content invariance under backpressure is the property | `streaming_fft`'s metadata/position alignment (which is the latency check), `fft_bf2`'s scaled-headroom pair and sum-width bound, `fft_delay_line`'s shadow shift register, `fft_reorder`'s frame-boundary warmth, `fft_core`'s lane lockstep, and both twiddle multipliers' rounding checked against `fxp_pkg` — all on every cycle. Plus the SPEC §5 checker on the master interface and inside the input elastic buffer |
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

Three more were injected into the issue #8 telemetry primitives, against the checks that
issue adds, and each was caught (`make sim-tiny`, seed 1):

| Injected fault | Detected as |
|---|---|
| `perf_counter` ignores `SATURATE` and wraps instead | `a_sat_holds_max` assertion, plus a `counter_model` divergence at the wrapping cycle (RTL 0, model 255) |
| `perf_counter` shadow latches `count_q` instead of `count_d` (a stale snapshot) | `a_shadow_latched` assertion, plus a `counter_model` divergence on all three probes in the same cycle |
| `seq_checker` stops classifying a duplicate | `seq_classify` (the directed case names the category it expected), `seq_count` and `seq_sticky` divergences against `telemetry::SeqTrackerModel` |

Each of the three was caught by two independent mechanisms — an assertion inside the RTL and
the cycle-accurate C++ model — which is the property that makes the pair worth having: the
assertion localises the defect, and the model proves it changed an observable.

One was injected into the issue #11 FFT, into the place where a defect would be hardest to
notice by inspection — the twiddle exponent, which is arithmetic on a sample's position that
no waveform makes obviously wrong:

| Injected fault | Detected as |
|---|---|
| `fft_pkg::fft_r22_tw_exp` weights `k2` by 3 instead of 2 (one wrong twiddle index per position class) | 69 `rtl_vs_model` mismatches, beginning at **beat 2 of the first frame**, across the directed vectors, the random frames and the 256-point smoke alike; `RESULT: FAIL … rtl_vs_model=69` |

The category is the diagnosis and it is the right one: the exponent lives in the RTL package,
the C++ model carries its own mirror of the same formula, and the vectors carry a third — so
a change to one of the three is reported as *that pair* disagreeing rather than as a general
failure. The float cross-check in `gen_fft_vectors.py` is the second, independent net under
the same class of defect: a single wrong twiddle index moves a record hundreds of LSBs away
from `numpy.fft.fft`, against a committed worst case of 3.0 LSB.

The clean tree was rebuilt and re-run after each injection and passed, so the detections
are attributable to the fault and not to the edit.

Repeat this whenever a check is added or relaxed.

#### `test_pfb_bank` — polyphase FIR bank (SPEC §7.1, issue #10)

Drives `pfb_top`, which holds **two complete banks** differing only in accumulation
structure (`TREE` and `SYSTOLIC`) and admitting exactly the same beats. Every output beat of
both is checked against the bit-accurate C++ model (`model/cpp/pfb/pfb_model.hpp`) and, on
the directed pass, against the independent NumPy expectation committed in
`model/vectors/pfb_*.vec`. The two structures are checked against each other by
construction — they scoreboard against the same expectation list.

The SPEC §7.1 verification list, and where each case lives:

| SPEC §7.1 case | Where |
|---|---|
| zero input | the directed pass (every set opens with zeros) and the per-pass prologue |
| complex impulse | the directed pass. With the `ident` set the output **is** the input; with `proto` it is the programmed response tap by tap — the only stimulus that checks coefficient **order** |
| constant input | the directed pass |
| single complex sinusoid | the directed pass |
| random samples | the directed pass plus three backpressure passes, seeded from `+seed` |
| maximum positive and negative | the directed pass |
| saturation | the `random` and `max` coefficient sets saturate on most beats; a coverage audit fails the run if both directions were not observed, so the flag checks cannot pass vacuously |
| coefficient-bank swap | a dedicated pass: two frames, a swap requested **mid-frame**, each frame checked against its own coefficient set, with the whole of the second set written into the spare bank **while the first frame streams** |
| random output backpressure | three passes at none / light / heavy, all scoreboarded by sequence number, so content invariance under backpressure is checked rather than asserted |

**Matching is by sequence number, not by position.** Every beat carries `seq`, `stream_id`
and `user`, and every output is matched to its input by `seq`. That is what makes SPEC §7.1's
"valid metadata must travel with the corresponding samples" a checked property: a result
delivered against the wrong metadata fails on content, and a metadata field that did not
travel fails on its own comparison. It is also what lets one scoreboard serve two banks whose
latencies differ in **kind**.

**The systolic transition window is predicted, not excused.** An adder-tree lane multiplies
all `TAPS` taps of a beat in the same cycle, so a coefficient swap is instantaneous. A
systolic cascade samples tap `j`'s coefficient `j` beats late — `y(n) = sum_j h_j(n+j)·x(n-j)`
— so a swap at beat `B` gives outputs `n` in `[B-TAPS+1, B-1]` a *mixture* of the two sets,
one tap at a time. The test builds a second expectation set that computes exactly that
mixture and requires the RTL to match it bit for bit. A cascade that switched cleanly would
fail just as loudly as one that switched at the wrong beat.

Also covered: the SPEC §9 telemetry counters (saturation events, snapshot coherence, frame
count) against an independent harness tally, and the C++ model against the NumPy vectors
before the RTL is compared against the model at all — an oracle that agrees only with itself
is not an oracle (SPEC §12.4).

**Fault injection.** The oracle was proved to bite by changing `fir_lane`'s coefficient index
to `(k+1) % TAPS` — a one-token off-by-one in the tap index — and re-running seed 1:

```text
RESULT: FAIL seed=1 test=test_pfb_bank rtl_vs_model=22028 rtl_vs_vector=1494 ...
```

with the first failure on the very first directed set. The injection was reverted; the
transcript is in the issue #10 pull request.

#### `test_beamformer` — beamforming matrix (SPEC §7.5, issue #12)

Drives `beamformer_top`, which holds **three complete matrices** in one elaboration,
admitting exactly the same beats, differing only in the two things this issue has to defend:

| DUT | `BIN_PAR` | `BEAM_PAR` | `BEAM_MUX` | `ADD_REG_EVERY` | what it proves |
|---|---|---|---|---|---|
| `ref` | 2 | 4 | 1 | 1 | the reference engine |
| `mux2` | 2 | 2 | 2 | 1 | time multiplexing produces the same beams, spread over twice as many output beats |
| `reg2` | 2 | 4 | 1 | 2 | two adders per register stage is the same integer |

plus **two standalone 16-antenna dot products** (`ADD_REG_EVERY` 1 and 2) sharing one operand
port — the SPEC §7.5 nominal antenna count and the geometry the SPEC §18 calibration
compiles — and one weight bank with the frame-boundary rule disabled, outside the datapath.

All three matrices have the same input payload width, so one stimulus port drives them and
the equivalences are **same-cycle facts about one stream** rather than comparisons of
separate runs. The visible consequence of lockstep admission is that the whole top runs at
`mux2`'s rate, which is exactly the throughput reduction SPEC §7.5 asks to be made visible.

The SPEC §7.5 / §13.1 verification list, and where each case lives:

| Case | Where |
|---|---|
| zero input, zero weights | pass 1, on the 16-antenna dot product. Both directions of the SPEC §13.2 zero relation; the expected value needs no model |
| unit weights → passthrough | pass 2 (dot) and pass 4 (matrix). Beam *b* selects antenna *(b+1) mod N_ANT* and nothing else, so the expectation is that antenna's sample scaled by `0x7FFF`, computed by a **one-term** dot product rather than by the general path |
| orthogonal weight patterns | pass 2. Rows of a 16×16 Sylvester Hadamard matrix scaled to ±1/16 (2048 in Q1.15, exactly representable): a stimulus equal to row *p* lands entirely in beam *p* and **exactly zero** in every other. An expectation with no model in it that exercises every antenna at full weight |
| maximum-amplitude saturation | pass 3 (dot, three amplitude regimes) and pass 8 (matrix, full-scale weights against full-scale input), with a coverage audit that fails the run if both saturation directions were not observed |
| random samples and weights, ≥3 seeds | passes 3 and 5, seeded from `+seed`; 5504 dot results and 7448 output beats per seed |
| weight-bank swap | pass 6: two frames, a swap requested **mid-frame**, each frame checked against its own weight set, with the whole of the second set written into the spare bank **while the first frame streams** |
| random output backpressure | pass 5, three profiles at none / light / heavy |
| time multiplexing | every matrix pass, plus an explicit output-beat count check: `mux2` must produce exactly `BEAM_MUX` output beats per input beat |
| adder-tree pipelining | every pass; `reg2` and `u_dot16_r2` must be bit-identical to their `ADD_REG_EVERY = 1` twins |

**Matching is by sequence number, not by position**, for the reason `test_pfb_bank` gives —
and here it does one more job: it lets one expectation serve three engines whose output
**rates** differ. `mux2`'s output sequence is `{seq_in, group}`, so its two beats per input
land on two distinct, predictable keys.

**Content invariance under backpressure is a direct comparison.** The three profiles drive
the **same stimulus** (different sequence numbers, so the SPEC §5 protocol checker stays
happy; identical data), and the stalled runs are required to be beat-for-beat identical to
the dense run — not merely both correct against the model.

**The predicted transition behaviour at a weight swap is "none", and that is a claim rather
than an absence.** A beamformer has no sample history, so every dot product of a beat reads
the weight bank on the same cycle: the swap is atomic at the beat that carries it and there
is no transition window at all. Contrast the polyphase bank's systolic cascade, whose taps
sample the coefficient set up to `TAPS-1` beats apart and which therefore *has* a predicted
mixed window. The expectation is built with a hard switch at the swap beat, so if the RTL had
a transition window this pass would fail on every beat of it — which is exactly how the
swap-point defect recorded in DECISIONS.md (issue #12, decision 4) was found.

**The independent cross-check is in C++, not NumPy, and that is a recorded deviation.**
SPEC §12.4's standing problem is that an oracle agreeing only with itself is not an oracle,
and the C++ model shares `fxp_pkg`'s definitions with the RTL *by design* — that is what
makes them bit-exact. Every non-saturating beat is therefore also checked against
`bf::dot_float()`, a **double-precision** evaluation of the same sum through no shared code,
to within 2 output LSB.

Issues #4, #9, #10 and #11 discharge the same obligation with a committed NumPy vector set.
This issue does not ship one, deliberately:

* the beamformer is **stateless** — no history, no schedule, no twiddle table — so a golden
  file would carry no information the weight set and the input beat do not already carry,
  whereas an FFT vector pins a whole scaling schedule and a PFB vector pins a tap ordering;
* the two error classes a vector file exists to catch here are covered more directly and
  more cheaply: a **wrong algorithm** by the double-precision leg (a different number system
  entirely), and a **wrong index** by the orthogonality case and the permutation relation
  (expectations with no model in them at all);
* the generator, the committed vectors and the regenerate-and-compare wiring would be real
  files that must be kept in step forever, for a block whose reference is four lines of
  arithmetic.

If a later issue makes the beamformer stateful — a per-beam gain schedule, an adaptive
update — this trade stops holding and a generator should be added with it.

**Fault injection.** The oracle was proved to bite by **transposing the weight index** in
`rtl/beamformer/beamformer.sv` (`w_rows[b][a] <= w_all[a*N_BEAMS + b]`) and re-running seed 1:

```text
RESULT: FAIL seed=1 test=test_beamformer rtl_vs_model=41472 rtl_vs_float=41472
        rtl_vs_directed=1024 metamorphic=1024 ...
```

The experiment also **changed the test**. With the first version of the unit-weight pass —
beam *b* selects antenna *b* — the matrix `W` is the identity, which is **symmetric** and
therefore unchanged by a transpose, and that pass reported `rtl_vs_directed = 0` while 38 400
model comparisons failed around it. The same is true of the Hadamard pass, whose matrix is
symmetric by construction (`H[p][a]` depends only on `popcount(p & a)`). The unit-weight pass
was changed to a cyclic shift, which is asymmetric for every `N_ANT > 2`, and the injection
was re-run to confirm it now fails too. The injection was then reverted; both transcripts are
in the issue #12 pull request.

The lesson is recorded because it generalises: **a directed case built from a symmetric
matrix cannot detect a transpose**, and a transpose is the most likely defect in any matrix
kernel. The permutation relation below is the check that does not depend on getting that
right.

### 4.2 Metamorphic tests (SPEC §13.2)

Populated progressively by issues #10–#14; #10 and #12 have landed.

Implemented for the polyphase FIR bank (issue #10), in `test_pfb_bank`, on stimulus held at
half scale under an L1-scaled filter so that nothing saturates and the relations are not
vacuous:

| Relation | Statement | Why it is exact |
|---|---|---|
| negation | `y(-x) == -y(x)` | round-to-nearest-even is symmetric about zero, so the identity is exact rather than approximate — no tolerance, no epsilon |
| delay | delaying the input by `D` beats delays the output by `D` beats, value for value | the lane is time-invariant by construction; a history that advanced on clocks rather than samples would break this and nothing else |
| scaling | doubling the input doubles the exact accumulator, so the output doubles to within the one LSB rounding may move it | the exact half — RTL against the model on the scaled run — is checked separately; this is the oracle-free half |

The pass fails if it compared fewer lane-beats than it drove, so a relation that silently
found nothing to check is a failure rather than a pass.

Implemented for the beamforming matrix (issue #12), in `test_beamformer`, on stimulus held at
half scale under small weights so that nothing saturates and the relations are not vacuous:

| Relation | Statement | Why it is exact |
|---|---|---|
| **permutation** | permuting the antenna inputs **and** the antenna axis of the weights by the same permutation leaves every beam output **bit-identical** | the accumulation carries no intermediate saturation and integer addition is commutative, so "equivalent" is stronger than SPEC §13.2 asks for. This is the relation SPEC §13.2 names for this block specifically |
| negation | `y(-x) == -y(x)` | round-to-nearest-even is symmetric about zero |
| scaling | doubling the input doubles the output to within the one LSB rounding may move it | the exact half — RTL against the model on the scaled run — is checked separately |
| delay | delaying the input by `D` beats delays the output by `D` beats, value for value | the block is memoryless across beats by construction |

The permutation used is a **rotation by one**, chosen because it is the permutation a
transposed or off-by-one weight index is least able to survive, and fixed rather than random
so that a failure is reproducible from the message alone. The pass fails if it compared fewer
slots than it drove, so a relation that silently found nothing to check is a failure rather
than a pass.

This is also the strongest available check on the weight **index**. A transposed or rotated
index still produces beams, still saturates plausibly and still passes every protocol check;
what it cannot do is commute with a permutation applied to both operands — see the fault
injection under §4.1.

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

Issue #8 adds no crossing: `telemetry_block` is single-clock by construction and the register
interface, not the counters, is what crosses when the register plane is in another domain
(DECISIONS.md issue #8, decision 4). The inventory is therefore unchanged at **24 crossings,
0 unknown**, which is itself the check that the claim is true.

### 5.8 Telemetry assertion set (SPEC §14, issue #8)

SPEC §14 requires assertions for "arithmetic overflow where overflow is forbidden" and for
"sequence discontinuity". Both are delivered as property text in
`sim/assertions/telemetry_sva.svh` and instantiated from inside the RTL under
`ifndef SYNTHESIS`, so they are active in the fast build with no test-side wiring — the
arrangement `stream_protocol_checker` and the CDC checkers already use.

There is exactly **one** counter implementation and one sequence classifier in this design, so
checking each at its own definition checks every instance in every build: the telemetry
block's nine counters, the sequence checker's five, the three narrow probes, and every counter
a Phase 2 kernel instantiates without its author knowing this file exists.

| Assertion | Instantiated in | What a failure means |
|---|---|---|
| `a_count_gated` | `perf_counter` | the counter advanced while the measurement window was shut, so every number downstream is wrong by an unknown amount |
| `a_count_cleared` | `perf_counter` | a clear did not take effect in one cycle, or lost to a simultaneous event |
| `a_shadow_holds` | `perf_counter` | the shadow moved without a strobe — the whole coherent-read mechanism is void |
| `a_shadow_latched` | `perf_counter` | the shadow does not equal the live count one cycle after a strobe, i.e. the snapshot is off by one event |
| `a_shadow_valid` | `perf_counter` | the shadow-valid flag dropped without a clear |
| `a_wrapped_sticky` | `perf_counter` | the sticky range flag dropped without a clear |
| `a_wrap_needs_event` | `perf_counter` | the counter passed its maximum in a cycle with nothing to add |
| `a_sat_holds_max` | `perf_counter`, saturating instances | SPEC §14 forbidden overflow: a saturating counter reported passing its limit without holding all ones |
| `a_sat_never_falls` | `perf_counter`, saturating instances | a saturating counter decreased, so an event was lost to overflow |
| `a_mod_wraps_down` | `perf_counter`, modulo instances | a reported wrap was not a wrap: every increment is below the modulus, so the value after must be below the value before |
| `a_seq_one_kind` | `seq_checker` | one beat classified as more than one kind of fault, so the counts double-count and still look plausible |
| `a_seq_needs_beat` | `seq_checker` | a fault reported with no accepted transfer |
| `a_seq_gap_nonzero` | `seq_checker` | a loss of zero beats reported |

Two covers, counted only in the `--mode coverage` build, record that the interesting states
were reached rather than merely not violated: `c_wrap` (a counter passed its maximum at all)
and `c_snapshot_while_counting` (a snapshot taken in a cycle in which the counter was still
moving — the case the whole shadow mechanism exists for).

The stream's own continuity is checked elsewhere and deliberately: `STREAM_SVA_FRAMING` in
`sim/assertions/stream_sva.svh` already asserts that the sequence field increments by one per
beat on every interface inside a stream primitive. That property is about the producer; the
three above are about the detector. The two together are what make the counts trustworthy —
one says a nominal run contains no discontinuity, the others say the classifier does not
invent one. It is also why a fault cannot be injected into the datapath to test the checker:
the producer-side assertion fires first, correctly, and aborts. `telemetry_top` therefore
gives the checker a stimulus override, and `test_seq_checker` drives faults into it directly.

### 5.9 Complex-multiplier assertion set (SPEC §14, issue #9)

Two sets, in two places, for two different obligations.

**Inside the module** (`rtl/common/complex_multiplier.sv`, under `ifndef SYNTHESIS`), so they
hold in every build that instantiates the kernel, with no test-side wiring — the arrangement
the stream, CDC and telemetry primitives already use:

| Assertion | What a failure means |
|---|---|
| `a_cmult_re_matches_pkg` / `a_cmult_im_matches_pkg` | the arithmetic core disagrees with `fxp_pkg::fxp_cmul_q15_{re,im}_raw`, the package's canonical four-multiply definition, on operands carried alongside the pipeline in a shadow chain. For `VARIANT = "MULT3"` this *is* the Karatsuba exactness claim, checked against the package rather than against a second copy of the same algebra |
| `a_cmult_post_adder_fits_re` / `_im` | the MULT3 post-adder, formed at 34 bits and cast to the 33-bit output, lost a bit — i.e. the width discharge in NUMERICS.md §9.0 is wrong |

**On a matched pair** (`sim/assertions/cmult_assertions.sv`, instantiated by `cmult_top` once
per MULT4/MULT3 pair — all five pipeline depths plus the `ROUND_OUT = 0` pair):

| Assertion | What a failure means |
|---|---|
| `a_cmult_latency_a` / `_b` | `valid_out` is not `valid_in` delayed by exactly `PIPE_STAGES`, measured against an independent shift register in the checker. A kernel whose latency is not its parameter breaks every block that composes it |
| `a_cmult_valid_aligned` | the two variants present results on different cycles. A queue-based scoreboard would still call them equal; this does not |
| `a_cmult_p_re_match` / `_p_im_` / `_y_re_` / `_y_im_` / `_flags_re_` / `_flags_im_` / `_ovf_` | the two variants disagree on an output bit. This is the SPEC §6 obligation that the three-multiply form "must produce this exact result", checked structurally rather than by trusting that both happened to match one reference model |
| `a_cmult_round_re` / `_im` | the rounded output is not `fxp_round_sat` of the full-precision output. The two ports must be two views of one number, not two computations |
| `a_cmult_flags_re_def` / `_im_def` | a saturation flag does not equal `fxp_sat_flags(fxp_round(p, …))`. This is SPEC §14's "saturation flags match the expected overflow cases", stated as a *definition* so it holds on every operand pair rather than only on the directed ones |
| `a_cmult_ovf_def` | `ovf` is not the OR of the four flag bits |
| `a_cmult_no_flags_when_unrounded` | `ROUND_OUT = 0` produced a non-zero rounded output or a flag. Without it, that configuration would be checked for what it does produce and never for what it must not |

**No violator top for this set, and why.** Issues #5 and #6 each built a deliberately broken
DUT so their assertion sets could be proven to fire. This issue does not, because the same
evidence is available more cheaply and more honestly: the assertions above are redundant
with an independent oracle — the C++ model and the committed NumPy vectors — so a fault that
one misses the other catches, and both were exercised together during development by
inverting the sign of the MULT3 imaginary post-adder. That single-character fault was caught
by `a_cmult_p_im_match` (by name, aborting the run) and independently by
`test_cmult`'s `rtl_vs_model` and `rtl_vs_vector` counters, on beat 13 of the directed set.
A third RTL implementation maintained solely to be wrong would add maintenance without adding
a check that the oracle does not already provide. Where issues #5 and #6 needed a violator —
because a protocol assertion has no oracle to be redundant with — this set has one.

### 5.10 Polyphase FIR assertion set (SPEC §14, issue #10)

Two checker modules, both **instantiated by the RTL** under `` `ifndef SYNTHESIS `` rather
than bound from a test — the same arrangement `rtl/stream/` uses, and for the same reason:
the properties then hold wherever the modules are used, in the fast build, in every test,
with no test-side wiring, and a future integration cannot forget to attach them.

| Property | Module | What it forbids |
|---|---|---|
| `a_coeff_swap_at_sof` | `coeff_bank_checker` | the bank **in use** changing on any cycle that is not an admitted start-of-frame beat (SPEC §7.1's "safe frame boundary") |
| `a_coeff_stable_between` | `coeff_bank_checker` | the active bank's **contents** moving without a bank change — the inactive-bank-write-has-no-effect property, stated on the output rather than on the write logic so it survives a rewrite of the write logic |
| `a_pfb_out_never_blocked` | `pfb_assertions` | the output elastic buffer refusing a beat; if it ever fires, the fixed-latency interior stalled and a beat was lost |
| `a_pfb_lane_valid_uniform` | `pfb_assertions` | the lanes disagreeing about when a result is valid |
| `a_pfb_no_credit_no_admit` | `pfb_assertions` | `s_ready` asserting with an empty credit counter |
| `a_pfb_credit_bound` | `pfb_assertions` | the credit counter exceeding `OUT_DEPTH` (elaborated only where the counter's own width does not already imply it) |
| `a_pfb_admit_is_a_transfer` | `pfb_assertions` | a beat entering the datapath without a completed `valid && ready` handshake |
| `a_fir_mult_valid_uniform` | `fir_lane` (inline) | the per-tap multipliers disagreeing about validity, which would otherwise surface only as a wrong sum |
| `a_coeff_wr_valid_follows_write` | `reg_block_coeff` (inline) | the coefficient transfer strobe widening into a level, which the crossing would read as a second write |

### 5.11 Proof that the polyphase assertions fire (issue #10)

`a_coeff_swap_at_sof` is the one property in this set that a correct design can never
provoke, so `rtl/pfb/coeff_bank.sv` carries an `ALLOW_UNSAFE_SWAP` parameter that makes the
swap take effect the moment the request arrives instead of at the next start of frame.
`sim/verilator/tops/pfb_top.sv` elaborates exactly one such instance, **outside the
datapath**, wired to its own ports.

`test_pfb_bank` runs it as its **final** mode, with `Verilated::fatalOnError(false)` and
stdout captured, and requires that property to fire **by name**. It runs last because
clearing `fatalOnError` weakens every assertion in the build, so nothing may run after it.
An unprovoked run is a failure:

```text
  swap assertion   : 1 expected fire(s)
  expected failure : %Error: coeff_bank_checker.sv:72: Assertion failed in
                     TOP.pfb_top.u_unsafe.u_chk.a_coeff_swap_at_sof:
                     coeff_bank: active bank changed outside a start-of-frame beat
```

This is the same expected-failure mechanism §5.2 and §5.6 use for the stream and CDC
checkers.

### 5.12 Beamforming assertion set (SPEC §14, issue #12)

One checker module plus two inline property groups, all **instantiated by the RTL** under
`` `ifndef SYNTHESIS `` rather than bound from a test, for the reason §5.10 gives.

The weight bank contributes **no new properties**, and that is the point of how it is built:
`rtl/beamformer/weight_bank.sv` reuses `rtl/pfb/coeff_bank.sv`, so `a_coeff_swap_at_sof` and
`a_coeff_stable_between` (§5.10) already hold for the beam weights, with no second copy to
drift.

| Property | Module | What it forbids |
|---|---|---|
| `a_bf_admit_only_when_group_complete` | `beamformer_assertions` | **the property this file exists for.** A new input beat being admitted while the held beat still has beam groups to issue. That overwrites a beat whose remaining beams were never computed, and the result is *silently missing beams*: every output beat is still a well-formed beam sample, the protocol is still legal and the frame counts still add up |
| `a_bf_group_advances_on_issue` | `beamformer_assertions` | the beam-group counter not advancing exactly once per issued group |
| `a_bf_group_holds_when_idle` | `beamformer_assertions` | the group counter advancing on a cycle with nothing issued, which would slide the group index away from the metadata travelling with it |
| `a_bf_group_in_range` | `beamformer_assertions` | the group counter leaving `[0, BEAM_MUX)` (elaborated only where the counter's own width does not already imply it) |
| `a_bf_issue_implies_held` | `beamformer_assertions` | a group being issued with no beat held, which would multiply whatever the deliberately-unreset hold register happened to contain — plausible noise rather than an X |
| `a_bf_out_never_blocked` | `beamformer_assertions` | the output elastic buffer refusing a beat; if it fires, the fixed-latency interior stalled |
| `a_bf_no_credit_no_admit` | `beamformer_assertions` | `s_ready` asserting with fewer than `BEAM_MUX` credits. An input beat is an all-or-nothing commitment to `BEAM_MUX` outputs, so a partial reservation is not a smaller commitment — it is a beat whose later groups have nowhere to go |
| `a_bf_credit_bound` | `beamformer_assertions` | the credit counter exceeding `OUT_DEPTH` |
| `a_bf_dot_valid_uniform` | `beamformer_assertions` | the `BIN_PAR × BEAM_PAR` dot products disagreeing about when a result is valid |
| `a_bf_mult_valid_uniform` | `bf_dot` (inline) | the per-antenna multipliers disagreeing about validity |
| `a_bf_tree_matches_flat_sum` | `bf_dot` (inline) | the adder tree computing anything other than the sum of its own leaves. A flat reduction of level 0, delayed by exactly the tree's register depth, is compared against the tree output on every valid cycle; any mis-wired level, wrong register stride or leaf-padding off-by-one shows up immediately instead of as a wrong beam sample thousands of beats later |
| `a_weight_wr_valid_follows_write` | `reg_block_coeff` (inline) | the **weight** transfer strobe widening into a level. Stated separately from the coefficient one so a failure names *which* store lost a transfer |
| `a_weight_index_moves_only_on_purpose` | `reg_block_coeff` (inline) | the live weight index moving without a `WEIGHT_ADDR` or auto-incremented `WEIGHT_DATA` write |

`a_bf_admit_only_when_group_complete` and the two group-counter properties are elaborated
only when `BEAM_MUX > 1`; at `BEAM_MUX = 1` every group is the last group and they are
constant-true. That is precisely why `beamformer_top` elaborates a multiplexed instance:
a property that only a multiplexed configuration can violate is untested in a build that has
none, and the weight-swap defect of DECISIONS.md (issue #12, decision 4) was invisible at
`BEAM_MUX = 1` for the same reason.

**Proof that they fire.** `a_coeff_swap_at_sof` is provoked by name, exactly as §5.11
describes: `beamformer_top` elaborates one `weight_bank` with `ALLOW_UNSAFE_SWAP = 1`,
outside the datapath, and `test_beamformer` runs it as its **final** mode with
`Verilated::fatalOnError(false)` and stdout captured. An unprovoked run is a failure:

```text
  swap assertion   : 1 expected fire(s)
  expected failure : %Error: coeff_bank_checker.sv:72: Assertion failed in
                     TOP.beamformer_top.u_unsafe.u_store.u_chk.a_coeff_swap_at_sof:
                     coeff_bank: active bank changed outside a start-of-frame beat
```


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
| `make lint` | implemented (issue #2, extended by #5, #7, #6, #8 and #9) — `regmap-check`, then `--lint-only --Wall` on `benchmark_sim_top`, `stream_prims_top`, `stream_violator_top`, `control_top`, `cdc_prims_top`, `cdc_violator_top`, `telemetry_top` and `cmult_top`; zero unwaived warnings |
| `make sim-tiny` | implemented (issue #2, extended by #5, #7, #6, #8 and #9) — `numerics-check`, `regmap-check` and `cdc-inventory`, then the fast build of eight tops, then `test_stream_loopback`, `test_stream_primitives`, `test_stream_assertions`, `test_control_regs`, `test_sync_fifo`, `test_async_fifo`, `test_cdc_synchronizers`, `test_cdc_assertions`, `test_perf_counters`, `test_seq_checker` and `test_cmult` once per seed in `SEEDS` (default `1 2 3`) |
| `make calibrate-cmult` | implemented (issue #9) — not a SPEC §16 entry point and not part of any regression: the SPEC §18 resource-calibration sweep, Windows side, about an hour and a half of Fitter time. `make calibrate-summary` rebuilds the JSON and the table from evidence already on disk |
| `make regmap-check` | implemented (issue #7) — not a SPEC §16 entry point; a prerequisite of `lint` and `sim-tiny`, runnable alone while editing `control/regmap.json` |
| `make cdc-inventory` | implemented (issue #6) — not a SPEC §16 entry point; a prerequisite of `sim-tiny`, runnable alone. Fails on any unclassified crossing |
| `make sim-medium` | TODO(issue #17) |
| `make sim-random` | TODO(issue #17) |
| `make sim-stress` | TODO(issue #17) |
| `make sim-coverage` | TODO(issue #17) |
| `make sim-full-smoke` | TODO(issue #20) |

Unimplemented targets still fail loudly with `TODO(issue #N)` and a non-zero exit.
