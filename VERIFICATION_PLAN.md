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

#### `test_covariance` — power and covariance engine (SPEC §7.6, issue #13)

`covar_top` holds `power_calc`, three integrators and the `N_PAIRS` cross-power engine in
one elaboration; `sim/tests/test_covariance.cpp` drives all of them from one cycle engine
and compares **every observable against `model/cpp/covariance/covar_model.hpp` on every
cycle**. The model is cycle-accurate — one `step()` per clock edge — so an accumulator that
is right at the end of a window but wrong in the middle, or a window that closes one cycle
early, fails immediately rather than by luck. Results are matched through a pending queue,
so a result the RTL emits that the model did not expect, and one the model expected that the
RTL did not emit, are both named failures.

| Pass | What it drives | What would have to be wrong for it to pass anyway |
|---|---|---|
| 1 geometry | the RTL's `cfg_*` echo against the C++ mirror, and `covar_window_max_exact` / `acc_w_required` against each other at the bound and one past it | nothing — the run stops here if they disagree, so no later comparison can be silently wrong |
| 2 power corners | `(−32768,−32768)` — the `2^31` extreme — zero, ±1 on each component, ±full scale, mixed signs | the squaring, the sign extension into the `POWER_W` field and the closed-form `2^31` claim would all have to be wrong together |
| 3 power integrated | random samples through `power_calc` **and** the integrator behind it | the seam between a `POWER_W` power and a `POWER_W` accumulator is only exercised here; testing the two separately cannot reach it |
| 4 windows | lengths 1, 2, 3, 5, 8, 1, 16, 4, each with a flush between, plus a length written mid-window | a window that closed at the wrong count, an id that skipped, or a short result that was not marked |
| 5 saturation | the narrow (`ACC_W = 34`) integrator past its 3-sample bound in **both** directions, then 256 extreme terms at `POWER_W = 40` (must clamp to `2^39−1`) and 255 (must sum exactly) | the documented bound `N ≤ 2^(w−32) − 1` would have to be wrong in the same direction as the RTL |
| 6 exponential | every `k` in 0..15 bit-exact; convergence asserted for `k ≤ 6`, where the recursion provably settles inside the test's cycle budget | the dead band `y ∈ (x − 2^k, x]` is checked in both directions and `k = 0` must be an exact pass-through |
| 7 cross directed | `X = Y` on every corner: `Rxx.re` must equal the power and `Rxx.im` must be **exactly** zero; orthogonal operands must give a zero real part | a conjugate implemented by negating `y.im` fails here at `y.im = −32768`, which is the corner the list exists for |
| 8 cross random | 400 random source vectors dense, then again under bursty gaps, with the two result streams required to be identical | backpressure invariance — any free-running counter anywhere in the block breaks it |
| 9 pair enable | the mask flipped twice, mid-window both times | a disabled pair that kept accumulating, or an enable change that manufactured a partial window |
| 10 flush determinism | the same stimulus from reset and again after a flush that followed 47 saturating samples | a flush that preserved the window id, the accumulator or the sticky flags would produce a different stream |

The model itself carries two independently written cross-power paths — the direct
definition and the operand-swap wiring the RTL builds — and the test requires them to agree
on every directed operand before either is used as an oracle, the same discipline
`model/cpp/fxp/cmult.hpp` applies to MULT3 against MULT4.

A coverage audit closes the run: it fails if the run never observed **both** saturation
directions, if the random cross-power pass produced no windows, or if the flush pass had
nothing to compare. A saturation test that never saturated proves nothing.

**Fault injection.** The oracle was proved to bite by dropping the conjugate — reverting
`covar_engine`'s operand swap to `b = {re: y.re, im: y.im}`, a two-token change — and
re-running seed 1:

```text
ERROR [cross] @0 ps: pair 0 Rxy.re: RTL acc=0 id=1 n=1 vs model acc=1 id=1 n=1
ERROR [cross] @0 ps: pair 0 Rxy.im: RTL acc=-1 id=1 n=1 vs model acc=0 id=1 n=1
ERROR [cross] @0 ps: pair 1 Rxy.re: RTL acc=0 id=1 n=1 vs model acc=1 id=1 n=1
...
```

on the first emitted window of every pair. The injection was reverted and the suite re-run
green; the transcript is in the issue #13 pull request.

**A defect this suite found in its own RTL.** `a_covar_truncated_implies_flushed` fired
during bring-up on a window that overshot its own length. The cause was the configuration
boundary: a length written in the same cycle as a window's *first* sample was latching while
that sample was already being counted, so the window ran to a length that was never in force
when it opened. The fix is the `!accept` term in `integrator.sv`'s `boundary`; the assertion
is what turned a rare, stimulus-dependent wrong answer into an immediate named failure.

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

#### `test_cfar` — CFAR detector (SPEC §7.7, issue #14)

`cfar_top` holds TWO elaborations of `rtl/cfar/cfar_core.sv` in one build — the configured
geometry from `config/<name>.json` and a second at `MAX_GUARD = 0`, `MAX_REF = 3` — and
`sim/tests/test_cfar.cpp` compares **every emitted event field for field against
`model/cpp/cfar/cfar_model.hpp`, in order**: the kind, the bin index, the frame id, the
reference sum, the reference count, the threshold multiplier, the cell power, the per-frame
counts and the SPEC §5 framing bits of every beat.

**The model is FUNCTIONAL, not cycle-accurate, and that is deliberate.** The covariance
model is stepped once per clock edge because its subject is window *timing*. The CFAR
detector's subject is the detection *arithmetic* and the event *sequence*; its pipeline depth
is an implementation choice SPEC §23 explicitly invites changing for timing closure, so a
cycle-accurate model would have to be edited every time a register is added — and each such
edit is an opportunity to make the model agree with a bug. Modelling the
frame → event-sequence function instead makes the oracle invariant to pipeline depth, to
backpressure and to the phantom-flush mechanism while staying exact on every value and every
ordering. What the model deliberately does not predict — which *cycle* an event appears on —
is checked structurally instead, by pass 9.

| Pass | What it drives | What would have to be wrong for it to pass anyway |
|---|---|---|
| 1 geometry | the RTL's `cfg_*` echo against the C++ mirror: every width, both elaborations' maxima, the event width, and `sum_w` / `cmp_w` / `half_window` / `window_slots` | nothing — the run stops here if they disagree, so no later comparison can be silently wrong |
| 2 injected targets | one target in flat noise (exactly one detection, at the right bin); a pair separated by exactly `guard+1`, so each sits in the OTHER's first reference cell; the same pair one bin closer, inside the guard band | the guard band's *inner* edge. An off-by-one there puts a target inside its own reference window, where it raises its own threshold |
| 3 edges | an enormous target at bins 0, 1, last−1 and last, in DENSE mode; then a frame SHORTER than the window | each target bin must be reported `SUPPRESSED` with a zero reference window, and the frame's suppression count must be exactly `2·(guard+ref)` — an absence would pass a weaker test, a number does not |
| 4 threshold sweep | alpha at the flip integer ±2, computed in closed form from `C·2^F/noise`; then the zero-spectrum and alpha = 1.0 corners, and one LSB below 1.0 | the flip must happen at EXACTLY the integer, in both directions. One LSB below 1.0 every evaluable bin must detect, which is what proves the 1.0 case was a boundary and not a floor |
| 5 masking | a weak target alone (must detect); a strong target inside its leading reference band (must hide it); the same strong target one bin past the band (must not) | all three together pin the reference band's *outer* edge — the third case fails if the band reaches further than the geometry says |
| 6 modes | a worked clutter edge: guard 2, reference 4, alpha 3.0, references 1000 on one side and 20000 on the other, target 40000 — cell averaging detects (`C > 31500`), greatest-of does not (`C > 60000`) | the arithmetic is worked out in the test rather than hoped for, so a GO path that quietly ran cell averaging fails. Plus random clutter frames in both modes |
| 7 random | 12 frames of random power, random geometry and random alpha, in both modes and both output modes, with every third frame near the top of the 40-bit range | the wide end of the comparison — `alpha·sum` reaches `2^59` there — is exercised rather than only the comfortable end |
| 8 dense mode | every bin reported exactly once, with kinds consistent with the sparse run's detection set over the same frame | a dense run that dropped or duplicated a bin |
| 9 invariance | the same four frames dense, then again under bursty input gaps and heavy output stalls, required to produce a BYTE-IDENTICAL event sequence | any free-running counter anywhere in the block, and any dependence of a decision on when its operands happened to arrive |
| 10 reconfiguration | a configuration written half way through a frame: that frame must match the model computed with the OLD configuration, `obs_cfg_pending` must be set, and the NEXT frame must take the new one with no further write | a mid-frame change would corrupt `D` bins after the write and no earlier ones, which a whole-frame comparison catches and a spot check would not |
| 11 faults | the orphan beat, the negative-power clamp (with the frame still matching the model on the clamped values), the out-of-range geometry clamp, the unusable reference geometry, and a stray mid-frame `start_of_frame` | each must land in the right sticky bit AND behave as documented; a fault bit that fires without the behaviour fails the same pass |
| 12 counters | `CFAR_DET_COUNT`, `CFAR_SUP_COUNT` and `CFAR_FRAME_COUNT` against a tally accumulated independently from the summary events | a counter compared against zero — the pass fails if the run observed no detections or no suppressions |

Every event is additionally unpacked a second time, in the test, from the raw packed payload
the top exports as three 64-bit words, and compared against the RTL's own unpacked field
ports. A pack/unpack pair only ever used against itself proves nothing.

**Fault injection.** The oracle was proved to bite twice, with two different off-by-ones in
the same expression, because they fail *different* oracles.

*Variant A — the guard band's inner bound* (`off > g_lead` → `off >= g_lead`), which pulls
one guard cell into the reference sum. Caught by the RTL's own assertion on the first frame,
before any comparison ran:

```text
[0] %Error: cfar_window.sv:367: Assertion failed in
    TOP.cfar_top.u_cfar_a.u_window.a_cfar_mask_count:
    cfar_window: masks selected 5/4 cells but the geometry asks for 4/4
```

*Variant B — the whole band shifted one cell further out* (`off > g_lead + 1` and
`off <= g_lead + 1 + r_lead`), which keeps the cell COUNT right and is therefore invisible to
that assertion. Caught by the C++ model, on the first frame, with the wrong sum named:

```text
ERROR [event] @0 ps: close pair: event 0: RTL   DETECT bin=30 ... sum=8000  n=8
                                    vs model DETECT bin=30 ... sum=47000 n=8
ERROR [edge]  @0 ps: frame suppression count is 13, expected 12
```

The two oracles are complementary by construction — one checks the window's *shape* against
the configuration, the other checks the window's *contents* against an independent
implementation — and it takes both to make an off-by-one in this expression un-missable. Both
injections were reverted and the suite re-run green; the transcripts are in the issue #14
pull request.

**A defect this suite found in its own RTL.** The first flow-control scheme reserved one
output slot per admitted beat, and it deadlocked on the very first frame: a beat's decision
does not retire until `D` advances later, so outstanding reservations grew to `D + pipeline`
before any came back, and with an eight-deep buffer and `D = 10` the block stopped accepting
after six bins and never produced the end-of-frame summary that would have released them. The
arithmetic was correct *in total* — every reservation was eventually returned — and what it
got wrong was the LATENCY between taking one and returning it. The fix sizes the credit bound
against the PIPELINE rather than the window and makes the end-of-frame flush stallable, which
also makes the buffer depth independent of the window geometry; at the SPEC §11 full-scale
size `D` is 36, and a buffer sized to cover it would have been an M20K's worth of storage
bought to solve an accounting problem.

### 4.1.x Time-frequency history and corner turn (issue #15)

`sim/tests/test_history.cpp` over `sim/verilator/tops/history_top.sv`. Nine passes, three
geometries, five core:history clock ratios. Oracle:
`model/cpp/history/history_model.hpp`.

**Three geometries behind one port set**, selected by `dut_sel`, because the block's
behaviour depends on its shape in ways one elaboration cannot exercise:

| sel | antennas | bins | lanes | frames_max | bit-reversed | what it is for |
|---|---|---|---|---|---|---|
| 0 | 2 | 64 | 1 | 4 | no | the SPEC §11 tiny geometry, verbatim |
| 1 | 2 | 64 | 2 | 4 | **yes** | more than one lane AND the bit-reversal absorption, together |
| 2 | 4 | 32 | 1 | 8 | no | four antennas and a deeper rotation |

Sharing the port set is what keeps the driver written once. A suffixed port group per
geometry would triple the test code and make it possible for two geometries to be driven by
two subtly different drivers — a way to pass a test the RTL should fail.

**What is predicted exactly, and what is predicted by identity.** The read side works from a
frame pointer published across a clock-domain crossing, so how many frames it can see at any
instant is a function of the clock ratio and not of the stimulus. Predicting it would be
predicting a latency, which SPEC §12.5 forbids. So:

* passes 2, 4, 5, 6 and 7 **quiesce** — writes stop, the pointer settles — and after that the
  model predicts every returned sample, every flag, every metadata field, the occupancy, the
  readable bound and all six counters;
* pass 8 does not quiesce, and checks instead that every response's antenna vector matches
  the frame *its own metadata claims it came from*, by feeding `(frame_id, bin)` back into
  the pure stimulus generator. A wrong bank, a wrong slot, a wrong lane or a stale pointer
  all land as a mismatch; the frame the pointer happens to be on is not predicted.

| Pass | What it does | What would fail it |
|---|---|---|
| 1 geometry | the RTL's `geo_*` echo against the C++ `hist::Config` table, and the address round trip `stored_bin -> (lane_of_bin, beat_of_bin)` proved a bijection over every bin of every geometry, before any stimulus | a model configured for a different DUT; a mapping that is not one-to-one, which would silently alias two bins |
| 2 exact | write `2 × FRAMES_MAX + 3` frames, quiesce, then read EVERY bin at EVERY readable offset | any wrong value, flag, metadata field or counter, over more than two full rotations |
| 3 ratio sweep | pass 2 again at `1:1` in phase, `1:1` offset, **9:8**, **8:9** and `100:99` drift | a pointer crossing that is safe only at a convenient ratio. 9:8 is the SPEC §8 pair (450 / 400 MHz) and its inverse — the ratios closest to, but not equal to, one, where a crossing is least likely to be accidentally safe |
| 4 overwrite | depth programmed to 3 — the shallowest that leaves anything readable — then twelve frames | an off-by-one in the readable bound; an overwrite count that is not exactly `frames_done − depth`; offset 0 not serving the newest complete frame |
| 5 depth change | request a change MID-FRAME, check it reports pending and does not land; finish the frame, check it lands, bumps the epoch and discards the history; refill and re-read exactly | a change applied mid-frame, which would remap every slot under a half-written frame; an epoch that moves early; a history that survives a remap it cannot survive |
| 6 random | three independent seeded streams of random bins and offsets, one in eight deliberately out of range (including bins past `FFT_SIZE`), with bursty backpressure and randomized write gaps | a clamp that clamps wrong; an error counter that misses a case; anything the directed passes did not reach |
| 7 collision | out-of-range offsets first WITH the clamp (collision count must stay zero, error count must move) and then with `FORCE_UNSAFE` set (collision count must move) | a clamp that lets a request through; and, in the other direction, a collision counter that cannot be made to fire at all — which is the failure mode of every counter nobody has tested |
| 8 concurrent | full-rate writes with no gaps, three full rotations, reads in flight throughout, at both 9:8 and 8:9 | a response whose vector does not belong to the frame it claims; a lost, duplicated or reordered response (the block's own sequence number must advance by exactly one every time); a framing, skew or collision fault on well-formed traffic |
| 9 backpressure | the same request sequence at `none`, `light`, `heavy` and `bursty` | a byte of difference between the four response sequences. Backpressure may change WHEN a response appears; it must never change WHAT it is |

**Proof that the test can fail (SPEC §13, the same discipline as §5.2 and §5.6).** The read
bank-select was changed from the high bits of the bin index to the low bits — a one-line
edit, and the single most plausible way to get a corner turn wrong. The `LANES = 2` geometry
produced a wall of `data` mismatches within one second of simulation, each naming the bin,
the frame, the antenna, the value received and the value expected. The edit was reverted and
the suite passes on seeds 1, 2 and 3.

**Runtime.** 1.6 s per seed in the fast build, which is the whole nine-pass suite across all
three geometries and all five ratios.

**Not covered here, deliberately.** The block's behaviour when the FFT actually drives it —
that is issue #17's medium-pipeline integration, and it is where `REORDER = 0` upstream meets
`INPUT_BIT_REVERSED = 1` here for the first time in one elaboration. The register window's
own behaviour is covered by `test_control_regs`, which walks the generated tables and
therefore picked the new window up automatically.

### 4.1.y Frequency-bin alignment network (issue #16)

`sim/tests/test_align.cpp` over `sim/verilator/tops/align_top.sv`. Eleven passes, four
DUTs. Oracle: `model/cpp/align/align_model.hpp`.

**The organising principle is that the two architectures are never tested differently.**
SPEC §7.4 requires two to be built and compared, and a comparison is only worth having if
both were held to the same standard. One suite therefore runs, unchanged, against each of
four elaborations, with identical pass criteria. Anything that differs between them is a
*measurement*, not an expectation.

| sel | architecture | BIN_PAR | MUX_STAGES | N_ANT | net stages | what it is for |
|---|---|---|---|---|---|---|
| 0 | direct crossbar | 4 | 1 | 2 | 2 | the narrow pair, |
| 1 | omega | 4 | — | 2 | 2 | latency-matched |
| 2 | direct crossbar | 8 | 2 | 4 | 3 | the wide pair, and the widest |
| 3 | omega | 8 | — | 4 | 3 | beat `STREAM_MAX_DATA_W` allows |

Latency matching is part of the fixture, not an accident: `algn_xbar_latency(1) = 2 =
algn_clos_latency(4)` and `algn_xbar_latency(2) = 3 = algn_clos_latency(8)`. The geometry
pass fails the run if a pair is ever un-matched, because a resource or throughput
comparison across mismatched pipeline depths is a comparison of pipeline depths.

**The test owns the history ports.** It accepts the block's `BIN_PAR` read requests and
returns responses with whatever skew, loss, duplication or corruption the pass needs. The
response value is a pure function of `(bin, antenna, frame_id)`, so a sample that arrives at
the wrong beat position, in the wrong antenna slot, or from the wrong frame is a *different
number* rather than a plausible one. It also checks every accepted request against
`algn::port_of` — the rotating schedule is verified, not assumed by the response model.

| Pass | What it does | What it proves |
|---|---|---|
| 1 geometry | reads every DUT's echoed geometry and both latencies before any stimulus | the model is configured for the DUT it is about to drive, and the pairs are latency-matched |
| 2 in-order | zero skew, two frames per DUT | every beat bit-exact: `BIN_PAR × N_ANT` samples, `sof`/`eof`, `sequence`, `user` |
| 3 skew | randomized per-port response delay, three independent seeds | the reassembly buffer absorbs skew, and ordinary skew produces **zero** timeouts — if it did not, the timeout bound would be reporting a stall as a loss |
| 4 reorder stress | wide skew, 25% request-port stalls, light output backpressure | the case where two responses collide on one lane, which is the only thing that distinguishes the two architectures. Records each architecture's blocking count |
| 5 missing | one response never returned | `missing_count == 1` and `timeout_count == 1` exactly, the beat carries `ALGN_USER_MISSING`, its absent lane is zeroed, and the sticky fault sets |
| 6 duplicate | one response returned twice, with every other port held back so the copy provably arrives while the entry is still open | `dup_count == 1`, `missing_count == 0` — a duplicate must not cost a sample — and the **first** copy is the one in the beat |
| 7 backpressure | the same stimulus at `none`/`light`/`heavy`/`bursty` | the first `2 × GROUPS_PER_FRAME` beats are **byte-identical** across all four, and every run's counters match the model |
| 8 tag collision | SPEC §9 `cfg_force_unsafe`: one group's entry is opened under the wrong label | `orphan_count == BIN_PAR` and `missing_count == BIN_PAR` exactly, the injection fires exactly once, and the run recovers cleanly afterwards — an injection, not damage |
| 9 frame identity | one response carries a different absolute frame id | it is rejected rather than assembled into the beat. This is the failure ARCHITECTURE.md calls "not detectably wrong from the output alone" |
| 10 throughput | nothing stalled, four frames | sustained beats per cycle, measured and reported for both architectures; the run fails below 0.5 |
| 11 coverage | reads the delivery census | the run actually exercised the network: at least one cycle delivered two lanes at once, and every lane was used. A run that failed this would have compared two idle networks |

**Model synchronisation, and the two places it is subtle.** The model is functional, not
cycle-accurate: the content of a beat is a pure function of which responses reached the
collector, and re-implementing both architectures' arbitration in C++ would mean comparing a
model of the crossbar against the crossbar. Two consequences the test must respect, and both
were found by the test disagreeing with correct RTL:

* **entries open on the FIRST accepted request of a group, not the last.** The block
  allocates its entry at issue — all `BIN_PAR` requests are loaded in one cycle — so with
  the request ports stalling independently, the answer to the first request can be back
  before the last has been accepted.
* **a cycle's responses are delivered to the model in LANE order.** When several reach one
  entry before it has fixed a frame number, the RTL's reference is the lowest-numbered
  lane; the rotating schedule makes port order and lane order differ on every group but the
  first.
* the model finds an entry by searching its open list **from the back**, because the output
  elastic buffer means the RTL frees an entry when the beat is *pushed* and the test only
  learns about it when the beat is *popped*.

**Proof that the properties fire (SPEC §14).** One deliberate fault per architecture, run,
then reverted:

* `align_xbar`: the per-output request comparison changed to `a_dst[i] == (o+1) % N`, so
  every word is delivered one lane away from where it belongs. `a_align_route_correct`
  fired on the first delivered word: *"lane 0 was given a word belonging at beat position
  1"*.
* `align_clos`: a switch's routing bit changed from `src_dst[J0][RBIT]` to
  `src_dst[J0][0]`, so the network routes on the LSB at every stage while the
  elaboration-time `route_ok()` proof — which is written against the generic expression —
  still passes. `a_clos_arrived_at_destination` fired: *"a word addressed to 1 was
  presented at output 3"*. This is the case the elaboration proof cannot catch, which is
  why the runtime property exists as well.

Both edits were reverted and the suite passes on seeds 1, 2 and 3.

**Runtime.** About 0.9 s per seed in the fast build — the whole eleven-pass suite across all
four DUTs.

**Not covered here, deliberately.** The block driven by real `history_core` instances rather
than by the test's model of them: that is issue #17's medium-pipeline integration, and it is
where independent history occupancies can produce a genuine cross-frame beat rather than an
injected one. The block claims no register window of its own — its configuration reaches it
as ports, and the window belongs to the integration issue that decides where the sweep is
commanded from.

#### Packet network (`packet_top`, issue #18)

`sim/verilator/tops/packet_top.sv` holds the WHOLE SPEC §7.8 fabric at its nominal size in
one elaboration — 16 ingress adapters, two stages of four radix-4 switches wired as a
butterfly, 16 egress reassembly points, four virtual channels, `PACKET_W` from the
configuration — driven by `sim/tests/test_packet.cpp` against
`model/cpp/packet/packet_model.hpp`. Every delivered packet is compared FIELD FOR FIELD and
WORD FOR WORD, in order within its (source, VC, destination) triple.

**The model is functional, not cycle accurate,** and for a stronger version of the reason the
CFAR model is (§4.1): the fabric's subject is DELIVERY — which packets come out, at which
port, in what order, with what contents — while its cycle-by-cycle behaviour is a function of
arbitration state, credit round trips and the testbench's own stall profile, all three of
which SPEC §23 invites changing for timing closure. The model states four properties and
checks them exactly: routing determinism, ordering within a triple (and explicitly NOT across
VCs), payload integrity word for word, and conservation — every injected packet delivered
exactly once, with loss and duplication counted apart because they have different causes.

**Credit conservation is checked in the RTL, on every cycle, not in the model.** Credits are a
per-link invariant with no end-to-end observable, so the honest place for them is inside the
design: `a_pkt_credit_bound`, `a_pkt_credit_no_underflow`, `a_sw_credit_bound`,
`a_sw_credit_held`, `a_sw_no_overrun` and `a_egr_no_overrun` run on every cycle of every pass
below. What the model contributes to the same question is the consequence: a credit lost
anywhere means a packet never delivered, and `finish()` names which one.

| Pass | What it drives | What would have to be wrong for it to pass anyway |
|---|---|---|
| 1 geometry | the RTL's `cfg_*` echo against the C++ mirror: every field width, both the FLIT control offsets and the HEADER field offsets, the detection-event flit count derived from `cfar_pkg`, and every (source, destination) pair's route | nothing — the run stops here if they disagree, so no later comparison can be silently wrong. The routing check is exhaustive over all 256 pairs, not sampled |
| 2 directed | one packet of every SPEC §7.8 type at MINIMUM length (1 flit, header only, both SOF and EOF) and at MAXIMUM length (`PKT_MAX_FLITS` = 32), plus a detection-event-sized packet | the two length extremes are where framing breaks: a header-only packet has no body state to fall through, and a 32-flit one is where a length counter one bit too narrow wraps |
| 3 random | 96 packets per profile of random sources, destinations, VCs, lengths and types, run dense and again at 40% stalls on both sides | zero loss, zero duplication, zero corruption, in-order within every triple. A fabric that dropped one flit in a thousand fails here and nowhere else |
| 4 hotspot | all 16 sources sending equal-length packets to ONE egress port | starvation. The per-source delivered share is a DELTA against a baseline taken at the start of the pass — without that it would report the whole run's history and pass whatever this pass did — and the switch's own overtake metric is checked against the arbitration bound `2·RADIX·N_VC·MAX_FLITS` |
| 5 VC isolation | VC0 disabled at one egress while even ports drive VC0 and odd ports drive VC1 at that port | a jammed VC0 consuming the shared link. Every VC1 packet must be delivered WHILE VC0 is stuck. The sources are SPLIT deliberately: an ingress port has one message interface, so a source half-way through a VC0 packet could not offer VC1 either, and an unsplit test would measure the testbench's head-of-line blocking rather than the fabric's |
| 6 backpressure invariance | the same 48-packet plan dense, then again at 45% stalls on both sides | any dependence of the delivered sequence on when beats happened to arrive. Compared PER TRIPLE, because stalls may legally reorder across triples and a flat comparison would fail a correct fabric |
| 7 fault injection | the credit return of one (stage, port, VC) withheld, then restored; then a TWO-BIT payload corruption | see below |
| 8 telemetry | the RTL's per-ingress and per-egress packet counters against an independent tally kept by the test | a counter that counts something adjacent to packets. Checked per port, not in aggregate |

**Fault injection, and why the credit hook HOLDS rather than DROPS.** The hook withholds the
credits a switch buffer would have returned upstream and releases them when it clears. Dropping
them would be more literal and would make the injection a one-way trip: the upstream counter
never gets them back, that virtual channel is dead for the rest of the run, and "revert and
prove a full recovery" becomes impossible. Holding produces the same stall with a defined end.
The pass requires VC0 to stop making progress, VC1 not to, the fabric to drain completely once
the hook clears, and the scoreboard to find nothing lost.

The second injection is the one that measures the parity scheme's limit rather than asserting
it. A ONE-bit payload flip is caught by `a_sw_parity` at the first hop (that is the negative
suite, below). A TWO-bit flip passes parity by construction — an even error count always does —
and the pass fails unless the payload comparison catches it AND the parity counters stay at
zero. Both halves matter: a run in which the two-bit flip raised a parity error would mean the
parity scheme was not what `packet_pkg` §3 says it is.

**A defect this suite found in its own testbench, twice, and what it changed.** The
VC-isolation pass first drove VC0 and VC1 from every source and reported 44 of 64 VC1 packets
delivered. The fabric was correct; the DRIVER was blocking, because an ingress port hands over
one packet at a time and a VC0 packet stuck mid-handover holds the port. That produced two
changes rather than a fudge: the driver now keeps one queue per (port, VC) and switches
channels when a packet's first beat goes unaccepted, which is what a real producer with per-VC
queues does; and the pass splits the sources, so what it measures is unambiguously the shared
LINK rather than the shared PORT. The distinction is recorded in ARCHITECTURE.md §3.6 as a
property of the design, not hidden in the test.

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

### 5.12 Integration-window assertion set (SPEC §14, issue #13)

`sim/assertions/covar_assertions.sv` is instantiated by `rtl/covariance/integrator.sv`
under `` `ifndef SYNTHESIS`` — not bound from a test — so the window contract holds
wherever an integrator is used, in the fast build, in every test, with no test-side wiring.
There is one instance per power channel and **two per covariance pair**, so a tiny build
already carries seven of them.

| Assertion | Fires on |
|---|---|
| `a_covar_count_nonzero` | a result covering zero samples — it would carry no information and still consume a window id, so a consumer counting ids would see a gap it could not explain |
| `a_covar_count_in_range` | a result covering more samples than the window that was actually running |
| `a_covar_short_window_is_marked` | SPEC §7.6's "never emit a partial window silently": a short result without `truncated` |
| `a_covar_full_window_is_not_marked` | the converse — a full-length result claiming to be truncated |
| `a_covar_truncated_implies_flushed` | a window shortened by anything other than a flush. **This one fired during bring-up and found a real defect** (§4.1) |
| `a_covar_wid_increments` | a window id that did not advance by exactly one between consecutive normal results |
| `a_covar_wid_restarts_after_flush` | the first result after a flush carrying a non-zero id. A flush that drains nothing still restarts the id, which is why the checker registers the raw `flush` request rather than watching `flushed` alone |
| `a_covar_no_result_while_disabled` | a disabled integrator producing anything but the flush that drains what it accumulated while enabled |
| `a_covar_halves_in_step` | `covar_engine` (inline) — a pair's real and imaginary accumulators disagreeing about when a window closes, which would otherwise surface as a silently mismatched complex result |
| `a_power_range` | `power_calc` (inline) — a power outside `[0, 2^31]`, i.e. the "saturation is impossible by construction" claim, checked every cycle instead of argued |
| `a_power_matches_pkg` | `power_calc` (inline) — the squaring against `fxp_pkg::fxp_mul_q15` on a shadow copy of the operands delayed to the same stage |

### 5.13 Beamforming assertion set (SPEC §14, issue #12)

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

### 5.14 CFAR assertion set (SPEC §14, issue #14)

`sim/assertions/cfar_assertions.sv` is instantiated by `rtl/cfar/cfar_core.sv` under
`` `ifndef SYNTHESIS`` — not bound from a test — so the detector's contract holds wherever it
is used: the unit-test top, a future pipeline integration, and any Quartus calibration
wrapper that no testbench ever drives. `cfar_window` carries three more inline, and
`stream_elastic_buffer`'s SPEC §5 protocol checker watches the detector's output stream,
which is what makes the per-beam sequence continuity of §6.4 a checked property rather than
a design intent.

| Assertion | Fires on |
|---|---|
| `a_cfar_threshold_matches_pkg` | the sized `CMP_W` datapath disagreeing with `cfar_pkg::cfar_over_threshold()` on the same operands. This is what makes "the RTL implements the comparison" a checked fact: a width one bit too narrow, a shift in the wrong direction, or the two sides' operands swapped all fail here immediately |
| `a_cfar_decision_exclusive` | a bin reported both detected and suppressed. The three outputs are computed from overlapping terms, so "they cannot both be true" is exactly the kind of claim that survives a refactor by luck |
| `a_cfar_supp_no_detect` | SPEC §7.7's requirement in its smallest form: a detection raised on a suppressed bin. Kept separate from exclusivity so a failure names the SPEC clause it broke |
| `a_cfar_detect_implies_evaluable` | a detection on a bin the block never evaluated — the disabled, incomplete-window and unusable-geometry paths, in one property |
| `a_cfar_out_never_blocked` | the output elastic buffer refusing a push, i.e. the credit bound of `cfar_core` §4 being over-committed. Without it a lost event surfaces thousands of cycles later as a missing beat; with it, at the cycle the bound broke |
| `a_cfar_cfg_frame_boundary` | the active configuration changing on any cycle other than the one after an admitted start-of-frame beat. This is the assertion that enforces "runtime parameter changes take effect at a frame boundary only" — the property a per-frame suppression count depends on for its meaning |
| `a_cfar_mask_count` | `cfar_window` (inline) — the reference masks selecting a different number of cells from the one the register plane asked for. Fires on EVERY cycle a guard-index off-by-one is present, not only on the cycles where the wrong cell happened to matter (§4.1, variant A) |
| `a_cfar_bands_disjoint` | `cfar_window` (inline) — the two reference bands overlapping each other, or either of them containing the cell under test. A guard count of zero must still keep the cell out of its own reference window |
| `a_cfar_guards_valid` | `cfar_window` (inline) — the claim that lets the guard cells go unchecked: whenever both reference bands are complete, every slot between the outermost reference cells is valid too |

### 5.15 History / corner-turn assertion set (SPEC §14, issue #15)

Two checkers, `sim/assertions/history_wr_assertions.sv` in `core_clk` and
`history_rd_assertions.sv` in `history_clk`, both instantiated by
`rtl/memory/history_core.sv` under `` `ifndef SYNTHESIS`` rather than bound from a test — so
the contract holds in the unit-test top, in a future pipeline integration, and in the Quartus
calibration wrapper that no testbench ever drives.

**Two checkers rather than one.** `scripts/cdc_inventory.py --strict` reports any
instantiated module with two clock-like ports and no `(* cdc_primitive *)` attribute, which
is the correct default; a checker straddling both domains would trip it, and tagging the
checker would put a crossing in the SPEC §8 inventory that does not exist in the hardware. An
inventory with an imaginary entry is worse than one with a missing entry.

| Assertion | Fires on |
|---|---|
| `a_history_occupancy_exact` | occupancy differing from `min(frames_done, depth)` on any cycle. Fails if the frame barrier ever published a frame an antenna had not finished, or if a saturation was written `>=` where it should be `>` |
| `a_history_readable_exact` | the readable bound differing from `min(frames_done, depth − 2)` |
| `a_history_readable_leaves_two_slots` | a readable set that does not leave two slots — one for the frame being written, one to absorb a frame of publication lag. A `depth − 1` bound is a real defect and one the collision counter *cannot see*, which is exactly why it is asserted rather than tested |
| `a_history_depth_in_range` | an active depth of zero |
| `a_history_apply_at_boundary` | SPEC §14's "bank changes outside safe boundaries": a depth change landing while any antenna is mid-frame. The change remaps every slot, so it may only happen between frames |
| `a_history_no_write_across_apply` | a write landing in the cycle after a depth change, i.e. a beat addressed by the old mapping arriving under the new one |
| `a_history_frames_done_step` | the frame counter jumping by more than one, or moving backwards other than on a depth change |
| `a_history_no_safe_collision` | SPEC §14's "illegal simultaneous read/write states": an in-range request addressing the slot being written, outside fault injection. **This is the assertion that licenses `no_rw_check` on every M20K in the subsystem** — without it the design would be relying on a read-during-write behaviour the memory does not define |
| `a_history_lane_onehot0` | more than one lane's banks read-enabled at once. The read half of SPEC §7.3's ban on a globally broadcast enable network: impossible to satisfy if one enable drives every lane |
| `a_history_lane_en_tracks_pipe` | a read enable without a request in flight, or a request in flight with no enable |
| `a_history_all_antennas_answer` | SPEC §14's "memory response without a request", in the form a corner turn needs it: a response formed while fewer than all `N_ANT` banks answered. A vector missing one antenna is exactly the failure SPEC §7.4 exists to prevent, and it is invisible in the output values |
| `a_history_out_never_blocked` | SPEC §14's "FIFO overflow": the output FIFO refusing a push, i.e. the credit reservation of `history_core` §8 being over-committed |
| `a_history_publication_fresh` | the published frame pointer falling more than one frame behind the write domain — the margin the readable bound is *sized against*. A deliberate simulation-only cross-domain probe, and it is here rather than in the C++ test because a configuration that broke it would break it as unexplained corruption at maximum frame offset, which is the least diagnosable failure this block has |
| `c_history_write_enables_differ` | (cover) a cycle in which some antennas are writing and others are not — impossible if one enable drives every bank. The write half of SPEC §7.3's ban on a broadcast enable network, checked as the consequence rather than as the net |
| `c_history_request_in_range`, `c_history_request_out_of_range` | (cover) both branches of the range check, so the error counter is proved reachable rather than merely present |
| `c_history_forced_collision` | (cover) a request that reaches the in-flight slot under `FORCE_UNSAFE`. The collision counter is unreachable by construction in correct operation, so this cover is the only evidence that it can fire at all |

### 5.16 Alignment-network assertion set (SPEC §14, issue #16)

`sim/assertions/align_assertions.sv`, instantiated by `rtl/align/align_net.sv` under
`` `ifndef SYNTHESIS ``, plus two properties inside `rtl/align/align_collect.sv`, one inside
`rtl/align/align_clos.sv`, and a `stream_protocol_checker` on the block's master interface.
Single clock, per issue #15's decision 14.

**What is here and what is not.** The C++ scoreboard checks *values*. These check what a
value comparison cannot localise, or cannot see at all — and the central one is the reason
the set exists.

| Assertion | Fires on |
|---|---|
| `a_align_route_correct` | a word presented on lane *l* whose own bin index says it belongs at a different beat position. **THE property of this issue.** A mis-routed word still produces a perfectly well-formed beat — `BIN_PAR` antenna vectors, right frame, right group — carrying two copies of one bin and none of another. The scoreboard catches that only because it happens to compare every sample; this catches it at the wire, on the cycle, in either architecture, and names the lane. It is deliberately checked *outside* both architectures |
| `a_align_in_held` | the network's slave side withdrawing `valid` before it was accepted. `align_clos`'s ready depends on its own inputs' valids, so a producer that withdrew a request after losing an arbitration would deadlock the switch rather than fail visibly |
| `a_align_in_dst_stable` | a destination index changing while its word is stalled |
| `a_align_idle_when_disabled` | a lane accepted while the block is disabled — which `align_top` relies on, since three of its four DUTs are disabled at all times |
| `a_clos_arrived_at_destination` | (inside `align_clos`) a word presented at output *i* that did not ask for *i*. The runtime companion to the elaboration-time `route_ok()` proof: that one shows the wiring is a permutation, this one shows no arbiter, stall or reset interaction ever moved a word off its route |
| `a_align_emit_open` | (inside `align_collect`) a beat emitted from an entry that was not open |
| `a_align_alloc_ptr` | (inside `align_collect`) an allocation whose entry index disagrees with the buffer's own tail — i.e. the arithmetic-index argument that replaces a CAM being false |
| elaboration: `route_ok()` | (inside `align_clos`) any `(source, destination)` pair the omega wiring does not deliver, checked over the whole `N × N` space at time 0. A permutation network whose shuffle is off by one rotation otherwise passes every test in which the destination happens to equal the source — and at `BIN_PAR = 2` that is every test there is |
| elaboration: `align_net` width checks | the output beat width disagreeing with `beamformer_pkg::bf_in_data_w`, or the bin and antenna-vector widths disagreeing with `history_pkg`. Two files, one contract, checked rather than believed |
| elaboration: `align_switch` latency note | the two architectures not being latency-matched at the chosen parameters. A **note**, not a fatal — a caller may want a mismatched point deliberately — but it can never go unrecorded |

The measured coverage this issue needs is deliberately *not* here: whether two lanes were
ever delivered in one cycle, and whether every lane was used, are throughput statements
about the two architectures that the pull request quotes, so they live on `align_net`'s
telemetry ports and `test_align` fails a run in which either is trivial.

**Proof that they fire.** See §4.1.y: one deliberate fault per architecture, each caught by
the property named above, both reverted.

### 5.17 Packet-network assertion set (SPEC §14, issue #18)

Every assertion below is inline in the module it describes, under `` `ifndef SYNTHESIS`` — not
bound from a test — so the fabric's contract holds wherever it is used: the unit-test top, a
future pipeline integration, and the SPEC §18 calibration wrappers that no testbench ever
drives. `sync_fifo`'s own overflow, underflow, occupancy-shadow and high-water proofs run
inside all 192 buffers of the elaborated fabric at the same time.

| Assertion | Module | Fires on |
|---|---|---|
| `a_pkt_len_matches` | `pkt_ingress` | SPEC §14 packet length consistency, at the PRODUCER: the declared length disagreeing with the flits actually framed — a short packet, a long one, or an EOF on a header that declared more than one flit |
| `a_pkt_len_legal` | `pkt_ingress` | a declared length outside 1..`PKT_MAX_FLITS` |
| `a_pkt_vc_stable` | `pkt_ingress` | the VC field moving mid packet — the "no VC-mixing mid-packet" property |
| `a_pkt_type_legal` | `pkt_ingress` | a reserved packet type. Reserved encodings are an error, not a don't-care |
| `a_pkt_no_nested_sof` | `pkt_ingress` | a start-of-packet beat arriving inside an open packet |
| `a_pkt_credit_bound` / `a_pkt_credit_no_underflow` | `pkt_ingress` | a credit counter above the credits the port was elaborated with, or a flit sent with none. The two halves of "credits are conserved", stated where they can be checked every cycle |
| `a_pkt_egress_parity` | `pkt_ingress` | an emitted flit with wrong parity, excluding one the fault hook was asked to corrupt — which it knows from a REGISTERED dirty flag, because `fi_flip` describes the cycle the flit was loaded and not the cycle it is observed |
| `a_sw_no_overrun` | `pkt_switch_stage` | an arriving flit finding no room. This is the credit scheme's whole claim, asserted at the buffer rather than argued for at the sender |
| `a_sw_parity` | `pkt_switch_stage` | a buffered flit with wrong parity. Per hop, which is the localisation claim per-flit parity is chosen for |
| `a_sw_vc_match` | `pkt_switch_stage` | a flit sitting in buffer (i,v) whose own VC tag is not v — the input demux is BY that field, so a mismatch means it moved in flight |
| `a_sw_credit_bound` / `a_sw_credit_held` | `pkt_switch_stage` | a downstream credit count above its elaborated maximum, or the fault hook holding more credits than the buffer can contain |
| `a_sw_grant_locked` | `pkt_switch_stage` | switch allocation granting an output VC that virtual-channel allocation never locked — the register between the two levels being bypassed |
| `a_sw_sa_onehot` | `pkt_switch_stage` | a switch grant that is not one-hot. The crossbar mux depends on it, so it is restated rather than assumed |
| `a_rr_grant_onehot` | `pkt_rr_arb` | a grant that is not one-hot |
| `a_rr_grant_requested` | `pkt_rr_arb` | a grant to a requester that did not request |
| `a_rr_grant_when_req` | `pkt_rr_arb` | no grant while somebody asked. Round robin's liveness half, which the starvation argument rests on |
| `a_rr_ptr_range` | `pkt_rr_arb` | the priority pointer leaving 0..N−1 |
| `a_egr_no_overrun` | `pkt_egress` | the egress buffer overrunning — the far end of the same credit claim |
| `a_egr_length` | `pkt_egress` | SPEC §14 packet length consistency, at the CONSUMER: a delivered packet's flit count disagreeing with its header, a body flit with no open packet, or a SOF inside one. A different statement from `a_pkt_len_matches`: eight switch stages of buffers, arbiters and crossbars lie between them |
| `a_egr_parity` | `pkt_egress` | a delivered flit failing parity |
| `a_egr_vc` | `pkt_egress` | a delivered flit's VC tag disagreeing with its packet's header |
| `a_egr_dest` | `pkt_egress` | a packet arriving at a port that is not its destination — the routing function checked at its only observable end |
| `a_egr_type` | `pkt_egress` | a delivered packet carrying a reserved type |

### 5.18 Proof that the packet assertions fire (issue #18)

`sim/tests/test_packet_assertions.cpp` drives the REAL fabric — the same
`sim/verilator/tops/packet_top.sv` the positive suite uses, with no deliberately-broken copy
of anything — through the SPEC §7.8 error-injection hooks, and requires each mode to provoke
the property it names:

| Mode | Injection | Must fire |
|---|---|---|
| 0 clean | ordinary traffic with stalls on both sides | nothing |
| 1 length | a header declaring four flits on a packet framed in two | `a_pkt_len_matches` AND `a_egr_length` |
| 2 parity | one payload bit flipped in flight | `a_sw_parity` |

**There is no violator module, and that is the difference from §5.2 and §5.6.** Those suites
need a knowingly wrong copy of the RTL because a correct stream stage cannot be made to
violate its own protocol from the outside. A packet fabric can: SPEC §7.8 asks for an
error-injection hook, the design has one, it is wired to the `PACKET_FAULT` register, and
injecting through the production path means the negative test ALSO proves the hook works —
with no second copy of the fabric to keep in step.

Mode 1 requiring BOTH labels is the point of the pass. The producer-side and consumer-side
length checks are separate statements about separate things, and a suite that accepted either
one would pass a fabric in which the transport-side check had been deleted.

Expected-failure semantics are as §5.2: `Verilated::fatalOnError(false)`, stdout captured per
mode at the file-descriptor level, the captured text searched for the label by name and then
reprinted so the transcript shows what fired. An unexpectedly clean mode is the failure.

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
| `make sim-medium` | implemented (issue #17) — builds `pipeline_top` at `PIPE_CONFIG=medium` and runs `test_pipeline_continuous`, `test_pipeline_random`, `test_pipeline_runtime_update` and `test_pipeline_metamorphic` once per seed in `SEEDS` |
| `make sim-random` | implemented (issue #17) — same fast build as `sim-medium`, runs `test_pipeline_random` at three backpressure profiles (light / heavy / bursty) with a randomized input gap |
| `make sim-stress` | implemented (issue #17) — SPEC §13.4 long stress, `STRESS_CYCLES=2000000` core cycles by default (env-tunable), sustained near-full throughput, periodic coefficient and weight-bank swaps every ~200 frames, no waveform on a passing run |
| `make sim-coverage` | implemented (issue #17) — builds `covar_top` and `cfar_top` with `--coverage`, merges the per-run `*.dat` into `results/simulation/coverage/coverage.dat` via `verilator_coverage --write`, and drops a `summary.csv` listing the merged runs. See DECISIONS.md 2026-07-27 for why the other five block tops are not included |
| `make sim-full-smoke` | TODO(issue #20) |

Unimplemented targets still fail loudly with `TODO(issue #N)` and a non-zero exit.

## 9. Phase 3 — Medium pipeline integration (issue #17)

The Phase-3 tests wire the seven block-verified DSP kernels
(PFB #10, FFT #11, history #15, alignment #16, beamformer #12, power/covariance
#13 and CFAR #14) into one pipeline elaborated as
`rtl/top/benchmark_sim_top.sv` (module `benchmark_pipeline_top`) and driven
through the SPEC §5 stream interfaces. `rtl/top/benchmark_pipeline_ctrl.sv`
gates PFB coefficient-bank and beamformer weight-bank swaps to the same
end-of-frame boundary on the PFB input; SPEC §13.2 "bank changes affect only
permitted frame boundaries" is a per-block property (verified in #10 and #12)
and the SAME-boundary rule is the pipeline-level property this controller
adds.

### Tests

`sim/tests/test_pipeline_continuous.cpp` — SPEC §13.1. Continuous frames,
end-to-end sequence-ID checking on the CFAR output, no backpressure profile.
The per-block `stream_protocol_checker` instances (bound inside every block
by the existing `ifndef SYNTHESIS` blocks) provide the per-hop seq
continuity; the test just asserts that every driven frame appears on the
CFAR output.

`sim/tests/test_pipeline_random.cpp` — SPEC §13.3. Same continuous
stimulus, but at three backpressure profiles (`light`, `heavy`, `bursty`
from `harness/random.h`) at the CFAR output side, plus a randomized
per-antenna input-gap ratio drawn from `[0, 0.30]`. The seed is printed by
`sim_main.cpp` (SPEC §13.3 "every test must print a reproducible seed"), so
a failing run replays with `+seed=<n>`.

`sim/tests/test_pipeline_runtime_update.cpp` — SPEC §7.1, §7.5, §13.2. Two
frames on bank 0, one inactive-bank program of both the PFB coefficients and
the beamformer weights, one `cfg_pipe_swap_req` pulse, two more frames on
bank 1. Passes if `stat_pipe_swap_count >= 1`, `stat_pipe_swap_overrun == 0`
and no assertion fires. The per-block `coeff_bank_checker` and
`beamformer_assertions` provide the mid-frame-corruption check (verified
in #10 and #12); the pipeline `a_swap_at_eof` inside
`benchmark_pipeline_ctrl.sv` provides the SAME-boundary check.

`sim/tests/test_pipeline_metamorphic.cpp` — SPEC §13.2 at pipeline level.
Runs five independent sessions on the same seed:
- **zero-in / zero-out**: driving all-zero samples yields
  `stat_cfar_det_count == 0`;
- **backpressure invariance**: light vs heavy profile give the same
  detection count on the same stimulus;
- **reset repeatability**: two runs from reset with the same stimulus give
  the same detection count;
- **antenna permutation**: swapping antennas 0 and 1 in the stimulus
  preserves the detection count (uniform weights so beam sums are
  symmetric — the numerical antenna-permutation equivalence is proved at
  the beamformer level in #12).

Zero-in / zero-out is checked against `stat_cfar_det_count` (SPEC §7.7
event count), not against `m_valid` — the CFAR emits per-frame markers
regardless, and only actual detections are counted.

`sim/tests/test_pipeline_stress.cpp` — SPEC §13.4. Runs `STRESS_CYCLES`
core cycles (default 2M, env-tunable) with sustained near-full throughput
(5 % gap probability on the input), heavy backpressure on the CFAR output,
periodic coefficient and weight-bank swaps every ~200 frames, counter-wrap
coverage from the long run, and no waveform dump on a passing run.

A passing run reads `stat_pipe_swap_count >= 1`, drains cleanly, and
produces no assertion failure.

### Coverage

`sim-coverage` builds `covar_top` and `cfar_top` with `--coverage` (line +
toggle + user), runs the per-block regression once each, and merges the
`.dat` files into `results/simulation/coverage/coverage.dat` via
`verilator_coverage --write`. Structural coverage of the other five blocks
comes from `sim-tiny` — the same block-level tests at `--config tiny`,
which is where each block is unit-verified anyway. See DECISIONS.md
2026-07-27 for why the pipeline top and the larger block tops do not run
under `--coverage`.

### Integration scope narrowings (Phase-3 only)

The Phase-3 pipeline top consumes only the first sample of each beamformer
beat — (beam 0, bin 0) — feeds it into ONE `power_calc`, and does NOT
instantiate a covariance engine. That is a deliberate narrowing whose
justification is DECISIONS.md 2026-07-27 Decision 7. What is cut:

* per-(beam, bin) power fan-out (BIN_PAR × BEAM_PAR = 2 × 4 = 8 samples
  per beat; only sample 0 is tapped);
* covariance integration (the `covar_top` block, verified independently
  in #13, is not present in the integrated pipeline).

The streaming behaviour (backpressure, sof/eof/seq propagation,
frame-boundary bank swaps) is fully exercised on the tapped path, and the
arithmetic and control of the missing blocks are unit-verified in #13
and #14. The full-scale AGMF039 elaboration in Phase 5 (issue #20) is
required to resolve this narrowing: it must fan the beamformer beat out
per (beam, bin), instantiate one `covar_top` per pair, and feed a
per-(beam, bin) CFAR grid. The Phase-3 metamorphic and stress runs
accept this narrowing as scope; the Phase-5 acceptance gate will not.

## 10. Synthetic-scene injection gate (issue #44)

Issue #44 turns the per-block stimulus (impulses, tones, DC, random) into
a *radar scene*: a multi-antenna IQ time series with named targets sitting
in an AWGN floor, and a range-Doppler picture the reader can recognise.

**Part 1 (merged, PR #45)** — `gen_target_iq.py` writes the Q1.15 IQ file
+ `scenario.json` ground truth; `range_doppler.py` renders the
reference-chain range-Doppler map per antenna and prints a peak table.
The gate is `make scenario SCENARIO=three_targets SEED=1`; a target
whose range/Doppler peak sits within ±1 bin of ground truth PASSES.
See `docs/range_doppler.md` for the axis definitions.

**Part 2 (this issue)** — `test_pipeline_scenario` (built by
`sim/tests/test_pipeline_scenario.cpp`) injects the same IQ through
`benchmark_pipeline_top` and checks the CFAR detection stream against
ground truth. The gate is `make sim-scenario` on `SEEDS='1 2 3'`.

### Test flow

1. Load `scenario.iq` and `scenario.json` via the C++ loader
   (`sim/verilator/harness/iq_loader.{h,cpp}` — the counterpart of
   `range_doppler.py:load_iq`).
2. Configure the pipeline: CFAR mode CA, guard = 1/1, ref = 8/8,
   alpha = 8.0 (UQ8.8 = 0x0800); PFB bank-1 = pass-through and
   beamformer bank-1 = uniform 0x1000 weights, via
   `Session::program_and_swap_to_active_banks`.
3. Queue every one of the scenario's `HISTORY_FRAMES = 16` frames on
   all four antennas.
4. Single-cycle-step the core clock; on each cycle sample the CFAR
   output stream (`m_valid && m_ready`) and decode DETECT events from
   the low-order bits of `m_event_data` (kind at [0:1], bin at
   [2:17], frame_id at [18:33] — see `rtl/packages/cfar_pkg.sv` for
   the full event layout).
5. For every scenario target, check that at least one DETECT event
   landed within ±1 CFAR bin of the target's expected CFAR bin
   (`fft_bin // BIN_PAR`, tapped parity only). Every DETECT NOT within
   any target's window counts as a false alarm.
6. Print a ground-truth-vs-detected table like `range_doppler.py`'s
   peak table, and pass iff:
   * every target detected within ±1 CFAR bin, AND
   * false-alarm count ≤ 6 across all frames, AND
   * `Session::errors().count() == 0` (the pipeline's SPEC 5 stream /
     SPEC 8 CDC / SPEC 14 assertion set stays quiet), AND
   * the input queue drains and every driven frame's `m_eof` beat is
     observed.

Tolerances, alpha choice, and the beam-check limitation are the
subject of DECISIONS.md 2026-07-27 "Scenario-injection sim test
tolerances (issue #44 part 2)".

### Scenario constraints (Phase-3 narrowings)

Because the Phase-3 pipeline taps ONE sample per beamformer beat —
(beam 0, bin 0), with `BIN_PAR = 2` — the CFAR sees only the EVEN FFT
bins, and beam discrimination is not observable with uniform beamformer
weights. So Part 2 introduces a new built-in scenario:

* `three_targets_even` — three targets at FFT bins 40, 96, 160
  (mapping to CFAR bins 20, 48, 80), all at `angle_idx = 0`, and at
  20/12/6 dB SNR. This is the default scenario `sim-scenario` runs.

The original `three_targets` (bins 32, 67, 96; angles 1, 2, 3) remains
the picture-gate scenario for Part 1 — its bins and angles exercise
axes the reference chain can see but the Phase-3 tap cannot.

Phase 5 (issue #20) is the follow-up that removes both narrowings: a
per-(beam, bin) fan-out and per-beam CFAR restore full beam and bin
discrimination in RTL, at which point `three_targets` becomes a
sim-injection scenario too.

### Runtime

`make sim-scenario` builds `test_pipeline_scenario` once and runs it on
each seed in `SEEDS`. Wall time on the reference host: ~20 s build +
< 1 s per run, so three seeds fit under one minute total — well inside
the 5-minute budget for the injection gate.
