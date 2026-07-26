# Architecture

Structural description of the Agilex 7 wideband processing benchmark: the block
decomposition, the module inventory, the clock domains and their crossings, and the
interfaces between blocks. This document is the navigational map from
[SPEC.md](SPEC.md) requirements to the RTL under `rtl/`. It records what was actually
built, not what was proposed; every entry must correspond to committed RTL. Rationale
for choices lives in [DECISIONS.md](DECISIONS.md), numerical formats in
[NUMERICS.md](NUMERICS.md).

> **Status: filling in.** Nothing below is invented ahead of the RTL that justifies it;
> each section is filled by the issue named in its pointer. Filled so far: §3.1 packages
> (#4, #5), §3.2 stream infrastructure (#5), §6.1 streaming protocol (#5).

## 1. System block diagram

TODO — populated by issue #17 (medium pipeline integration) and extended by issue #20
(full-scale elaboration). Data flow per SPEC §3:
ADC sources → polyphase FIR banks → streaming FFTs → time-frequency history →
frequency-bin alignment → beamforming → power/covariance → CFAR → event packet network
→ abstract memory interface.

## 2. Top-level variants

TODO — populated by issues #2 (`benchmark_sim_top`), #3 (`benchmark_fabric_top`), and
#24 (`benchmark_device_top`). See SPEC §4.

## 3. Module inventory

One row per RTL module: path, parameters, owning issue, brief function.

TODO — each implementing issue appends its own modules.

### 3.1 Packages (`rtl/packages/`)

| Path | Parameters | Issue | Function |
|---|---|---|---|
| `rtl/packages/fxp_pkg.sv` | none (localparams only) | #4 | The single shared fixed-point package (SPEC §6): Q1.15 / Q2.30 types and the complex type, signed saturation, round-to-nearest-even and round-half-up, truncation, the round-then-saturate composites, Q1.15 scalar and complex multiply, the accumulator-width growth rule, and `fxp_flags_t` saturation flags. Normative prose: [NUMERICS.md](NUMERICS.md). |
| `rtl/packages/stream_pkg.sv` | none (localparams and functions only) | #5 | The single shared stream package (SPEC §5): the bundle's field set, the normative field order and offsets, `stream_geom_t` / `stream_fields_t` / `stream_payload_t`, `stream_pack()` / `stream_unpack()`, and the primitives' structural latencies. Prose: §6.1 below. |

Register-map types are added by issue #7.

Two packages deliberately live with their block rather than here, because exactly one
block uses each: `rtl/fft/fft_pkg.sv` (issue #11) and `rtl/beamformer/beamformer_pkg.sv`
(issue #12). `rtl/packages/` holds the packages more than one block shares.

Two modules belong to the same contract although they live elsewhere:

| Path | Parameters | Issue | Function |
|---|---|---|---|
| `rtl/common/fxp_sticky_flags.sv` | `COUNT_W` | #4 | The sanctioned saturation-flag collector: sticky `{sat_pos, sat_neg}` plus a saturating event counter, synchronous clear, clear wins over a simultaneous event. |
| `sim/verilator/tops/fxp_probe_top.sv` | none | #4 | Simulation-only probe exposing every `fxp_pkg` function to the C++ numerics cross-check. Not design RTL; never instantiated by a design top. |

### 3.2 Common and stream infrastructure (`rtl/common/`, `rtl/stream/`)

| Path | Parameters | Issue | Function |
|---|---|---|---|
| `rtl/stream/stream_skid_buffer.sv` | `PAYLOAD_W`, optional field geometry | #5 | Single-stage fully-decoupling register slice: two beats of storage, one beat per cycle, registered `valid`/payload forward AND registered `ready` backward, so a ready path through it crosses zero module boundaries. Latency 1. |
| `rtl/stream/stream_elastic_buffer.sv` | `PAYLOAD_W`, `DEPTH >= 2`, optional field geometry | #5 | Parameterised-depth elastic buffer in distributed registers with an exported occupancy. Registered `ready` asserted exactly when a slot will be free next cycle. `DEPTH = 2` is the two-deep register slice. Latency 1, full throughput at any depth. |
| `rtl/stream/stream_pipe.sv` | `PAYLOAD_W`, `STAGES`, `OUT_DEPTH` (default `STAGES+2`), optional field geometry | #5 | Latency insertion with no clock enable and no ready chain: a credit gate feeds `STAGES` free-running register stages into an output elastic buffer, so the delay line never stalls and Quartus is free to retime it. Latency `STAGES+1`. |
| `rtl/common/stream_loopback.sv` | `DATA_W`, `STREAM_ID_W`, `SEQ_W`, `USER_W`, `ELASTIC_DEPTH` | #2, rebuilt by #5 | SPEC §19 Phase 0 pass-through, now `skid -> elastic -> skid` over the canonical primitives with no storage of its own. Packs and unpacks the SPEC §5 bundle at the harness boundary and exports the packed payload for the C++ packing cross-check. Latency 3. |
| `rtl/common/fxp_sticky_flags.sv` | `COUNT_W` | #4 | Saturation-flag collector; see §3.1. |

Simulation-only companions, listed here because they belong to the same contract:

| Path | Issue | Function |
|---|---|---|
| `sim/assertions/stream_sva.svh` | #5 | The SPEC §5 / §14 property text, once: handshake stability, valid-held, reset-clears-valid, no-X, and per-`stream_id` framing and sequence continuity. |
| `sim/assertions/stream_protocol_checker.sv` | #5 | The property set as an instantiable and bindable module. Instantiated by every primitive under `` `ifndef SYNTHESIS ``. |
| `sim/verilator/tops/stream_prims_top.sv` | #5 | Unit-test top: the three primitives in four configurations as four independent streams. |
| `sim/verilator/tops/stream_violator.sv`, `stream_violator_top.sv` | #5 | Deliberately protocol-violating stage with the checker bound onto it, for the negative test. Never in a design file list. |

### 3.3 CDC primitives (`rtl/cdc/`)

TODO — populated by issue #6.

### 3.4 Memory and corner turn (`rtl/memory/`)

TODO — populated by issue #15.

### 3.5 DSP kernels (`rtl/common/`, `rtl/pfb/`, `rtl/fft/`, `rtl/beamformer/`, `rtl/covariance/`, `rtl/cfar/`)

The first Phase 2 kernel lives under `rtl/common/` rather than in one of the block
directories, because it belongs to all of them: the FIR lane, the PFB, the FFT butterfly
and the beamforming dot product are each built out of it, and none of them owns it.

| Path | Parameters | Issue | Function |
|---|---|---|---|
| `rtl/common/complex_multiplier.sv` | `VARIANT` (`"MULT4"` / `"MULT3"`), `PIPE_STAGES` 1–5, `ROUND_OUT` | #9 | The SPEC §6 complex product in both required forms, bit-identical. Exact 33-bit Q3.30 output always; rounded Q1.15 output with `fxp_flags_t` saturation flags when `ROUND_OUT = 1`. Fixed-latency valid pipeline, no ready. Latency == `PIPE_STAGES`. |

Simulation-only and synthesis-only companions, listed here because they belong to the same
contract:

| Path | Parameters | Issue | Function |
|---|---|---|---|
| `sim/verilator/tops/cmult_top.sv` | none | #9 | Verification top holding the whole parameter space at once: both variants at every legal `PIPE_STAGES`, plus the `ROUND_OUT = 0` pair. One stimulus port, an observation mux, and a parameter echo the test reads the latency expectation from. |
| `sim/assertions/cmult_assertions.sv` | `PIPE_STAGES`, `ROUND_OUT`, `PROD_W` | #9 | The SPEC §14 property set for a matched MULT4/MULT3 pair; see VERIFICATION_PLAN.md §5.9. |
| `quartus/calibration/cmult_wrap.sv` | `VARIANT_SEL`, `PIPE_STAGES`, `ROUND_OUT` | #9 | Synthesis wrapper for the SPEC §18 calibration sweep: one boundary register layer on each side of the kernel, so the measured paths are register-to-register fabric paths rather than I/O paths. Not simulation RTL, but listed in `files_cmult.f` so `make lint` covers it. |

**Interface shape, and why it has no `ready`.** The multiplier is a fixed-latency
arithmetic kernel, not a stream stage: `valid_in` in, `valid_out` `PIPE_STAGES` cycles
later, no backpressure. Backpressure is a block-level concern and is provided by the
SPEC §5 primitives in `rtl/stream/` when the kernel is wrapped into a lane. Putting a ready
chain here would put `m_ready` on the enable of every DSP register, which is exactly what
SPEC §23 warns against and what would stop Quartus retiming the pipeline. The datapath
registers are consequently free-running and unreset; only the valid chain is reset — "reset
validity, not every datapath bit".

**Pipeline shape.** Five register locations, switched on in a fixed priority order —
operands, multiplier outputs, post-adder, results, pre-adders — so that latency equals
`PIPE_STAGES` exactly for both variants at every legal value. The order puts the two
registers a DSP block owns natively first, so at `PIPE_STAGES = 2` the whole multiply sits
inside the block and the fabric sees only the post-adder. The full table and its rationale
are in the module header and in DECISIONS.md (issue #9).

#### Polyphase FIR bank (`rtl/pfb/`, issue #10)

The first block directory to be populated, and the first consumer of the complex
multiplier. One `pfb_bank` per antenna; the antenna dimension is a top-level concern and
deliberately does not appear inside it.

| Path | Parameters | Issue | Function |
|---|---|---|---|
| `rtl/packages/pfb_pkg.sv` | — | #10 | Accumulator width, the **beat/cycle latency split**, the delay-line storage threshold, the coefficient index mapping. One place, so the lane, the bank, the register plane and the C++ model cannot disagree. |
| `rtl/pfb/delay_line.sv` | `WIDTH`, `N_TAPS`, `TAP_STRIDE`, `STYLE` (`"AUTO"`/`"SRL"`/`"MEM"`) | #10 | Parameterised delay, gated by `en` so it advances once per **sample** rather than once per clock. `taps[i]` is the input delayed by `(i+1)*TAP_STRIDE` enabled cycles. |
| `rtl/pfb/coeff_bank.sv` | `PHASES`, `TAPS`, `SYNC_STAGES`, `ALLOW_UNSAFE_SWAP` | #10 | Dual coefficient banks for the WHOLE polyphase bank, the cfg→core seam built from the issue #6 primitives, and the frame-aligned swap. |
| `rtl/pfb/fir_lane.sv` | `TAPS`, `MULT_PIPE_STAGES`, `MULT_VARIANT`, `ACC_STYLE` (`"TREE"`/`"SYSTOLIC"`), `DELAY_STYLE` | #10 | One complex FIR lane. `TAPS` `complex_multiplier` instances at `ROUND_OUT = 0`, accumulated at `pfb_acc_w(TAPS)` bits, quantised **once** at the output. |
| `rtl/pfb/pfb_bank.sv` | the lane parameters plus `PHASES`, the SPEC §5 metadata geometry, `TELEM_COUNT_W` | #10 | `PHASES` lanes behind one SPEC §5 stream interface, with a credit gate, the metadata alignment path, the output elastic buffer and the SPEC §9 telemetry. |
| `rtl/control/reg_block_coeff.sv` | `IDX_W` | #10 | The software half: the 0x5000 coefficient window, the COEFF_DATA write strobe and the SWAP_REQ pulse. |
| `rtl/control/reg_block_covar.sv` | `IDX_W` | #13 | The 0x9000 integration-settings window (SPEC §9 group "Integration settings", implemented nowhere before this issue): window length, exponential mode and shift, per-pair enable mask, pair-table programming port, the FLUSH pulse, and the accumulator-protection status coming back. |

Simulation-only and synthesis-only companions:

| Path | Issue | Function |
|---|---|---|
| `sim/verilator/tops/pfb_top.sv` | #10 | Two complete banks — TREE and SYSTOLIC — driven from one stimulus port in lockstep, plus one `coeff_bank` elaborated with `ALLOW_UNSAFE_SWAP = 1` outside the datapath so the frame-boundary assertion can be provoked by name. |
| `sim/assertions/pfb_assertions.sv`, `sim/assertions/coeff_bank_checker.sv` | #10 | The SPEC §14 property sets; see VERIFICATION_PLAN.md §5.10. |
| `quartus/calibration/fir_wrap.sv`, `pfb8_wrap.sv` | #10 | Synthesis wrappers for SPEC §18 items 2 and 3. |

**The decomposition.** A beat carries `SAMPLES_PER_CYCLE` consecutive complex samples. A
prototype filter `h` of length `PHASES*TAPS` is split phase-wise, `h_p[k] = h[k*PHASES + p]`,
and branch `p` filters the decimated substream `x_p[m] = x[m*PHASES + p]`. The branches do
**not** share history: this is the critically-decimated polyphase front end, not one long
filter evaluated at `PHASES` samples per cycle.

**Beats and cycles — the alignment contract.** A FIR history is indexed by sample, so the
delay line carries `en`. Anything that combines values from **different beats** must
therefore also advance once per beat. That splits a lane's latency in two, and the two
halves are not interchangeable:

| `ACC_STYLE` | latency (beats) | latency (cycles) | delay line | accumulator |
|---|---|---|---|---|
| `TREE` (default) | 0 | `MULT_PIPE + ceil(log2 TAPS) + 1` | `TAPS-1` stages, stride 1 | balanced adder tree in fabric |
| `SYSTOLIC` | `TAPS-1` | `MULT_PIPE + 2` | `2*(TAPS-1)` stages, stride 2 | linear cascade, DSP-chainin shape |

A consumer aligns metadata with a result by delaying it `pfb_lat_beats()` **beats** and then
`pfb_lat_cycles()` **cycles**, in that order. Doing it in either unit alone is correct only
on a gapless stream. `pfb_bank` does exactly that, and the random-backpressure pass in
`sim/tests/test_pfb_bank.cpp` is what makes it falsifiable.

**Flow control.** The interior is a fixed-latency valid pipeline with no `ready` at all — a
ready chain would land on the clock enable of every DSP register (SPEC §23). Backpressure is
absorbed at the boundary by a credit gate of `pfb_inflight_beats() + 2` credits feeding an
output elastic buffer of the same depth, so the buffer can never overflow and the interior
never has to stall. `s_ready` is a flip-flop whose input depends only on this block's own
credit counter.

**Numerics.** Every multiplier runs at `ROUND_OUT = 0`, so each tap contributes its exact
33-bit partial sums and its rounding network does not exist. The `TAPS` partial sums are
accumulated at `fxp_mac_q15_acc_w(2*TAPS)` bits — a width at which the accumulation provably
cannot overflow — and the result is rounded and saturated exactly once, at the lane output.
There is no intermediate saturation anywhere in a lane, which is also why the adder tree and
the cascade are bit-identical rather than merely close.

#### Streaming FFT (`rtl/fft/`, issue #11)

SPEC §7.2. A parameterised radix-2² single-path delay-feedback FFT, verified at
`FFT_SIZE = 64`, `SAMPLES_PER_CYCLE = 2` and elaborated in the same build at 256 points.

Parallelism is a **decimation-in-time lane split**, not a wider SDF path. The beat already
carries its samples in time order, so lane *p* is exactly the subsequence `x[P*n + p]`; each
lane runs an ordinary `M = N/P` point radix-2² SDF core, and log2(P) radix-2 DIT merge
levels reassemble them. The split costs nothing and the merge is one complex multiply plus
one butterfly per beat. DECISIONS.md (issue #11, decision 1) records the alternatives and
why they were rejected.

```text
beat t = x[2t], x[2t+1]
      |                +--------------------------+
      +-- lane 0 ----->| 32-point radix-2^2 SDF   |--> E[bitrev(j)] --+
      |   (evens)      +--------------------------+                  |  DIT merge
      |                +--------------------------+                  +-> X[m], X[m+N/2]
      +-- lane 1 ----->| 32-point radix-2^2 SDF   |--> O[bitrev(j)] --+   (x W_N^m)
          (odds)       +--------------------------+
```

| Path | Parameters | Issue | Function |
|---|---|---|---|
| `rtl/fft/generated/fft_twiddle_pkg.sv` | none | #11 | **Generated and committed.** The master twiddle table, `W_1024^e` in Q1.15, and its digest. Produced by `model/python/gen_fft_twiddles.py`; `make fft-check` fails if it drifts. Deliberately not computed at elaboration time — DECISIONS.md (issue #11, decision 5). |
| `rtl/fft/fft_pkg.sv` | none (functions only) | #11 | The single definition of the FFT's structure: delay-line lengths, butterfly types, which sub-stages carry a multiplier, the twiddle exponent of every position, bit reversal, the scaling schedule and the latency accounting. `model/cpp/fft/fft_ref.hpp` is its line-for-line C++ mirror. |
| `rtl/fft/fft_delay_line.sv` | `WIDTH`, `DEPTH`, `STYLE` | #11 | The delay feedback: `q` is `d` delayed by exactly `DEPTH` **enabled** cycles. Circular memory read one entry ahead of the write pointer, so read and write addresses are never equal. `STYLE` forces M20K/MLAB/logic for the SPEC §18 memory-geometry axis; the design default is `"DEFAULT"`, the **measured** rule in `fft_pkg` — a small feedback goes to LUT-RAM, because the sweep found the tool's own choice puts it in an M20K whose internal path then caps the whole block at 330 MHz. A simulation-only shadow shift register checks the pointer arithmetic every cycle. |
| `rtl/fft/fft_bf2.sv` | `IDX_W`, `DELAY`, `IS_BF2II`, `SHIFT`, `MEM_STYLE` | #11 | One BF2I / BF2II sub-stage: a radix-2 butterfly around a delay feedback, with BF2II's trivial `-j`. One `fxp_round_sat` per output. Emits `idx_out = idx_in - DELAY` and a warmth bit that qualifies its saturation flags. |
| `rtl/fft/fft_twiddle_rom.sv` | `KIND` (`"R22"`/`"DIT"`), `ADDR_W`, `L2L`/`N_LANE`/`LEVEL`, `OUT_REG`, `STYLE` | #11 | The coefficient memory, addressed by the sample **position**: every exponent and every bit reversal is resolved at elaboration, so the hardware is an address register and a memory. Latency `1 + OUT_REG`. |
| `rtl/fft/fft_radix22_stage.sv` | `IDX_W`, `N_LANE`, `S`, `SHIFT_A`, `SHIFT_B`, `HAS_TWIDDLE`, `TW_VARIANT`, `TW_PIPE`, `TW_ROM_OUT_REG`, `MEM_STYLE`, `TW_STYLE` | #11 | One complete radix-2² stage: BF2I, BF2II and the `complex_multiplier` that closes the group, with a beat-enabled alignment chain to the ROM and a free-running chain matching the multiplier. The SPEC §18 item 4 calibration unit. |
| `rtl/fft/fft_sdf_path.sv` | `N_LANE`, `SCALE_SCHED`, twiddle/memory options | #11 | One lane's whole `2^N_LANE` point transform: `N_LANE/2` radix-2² groups plus, when `N_LANE` is odd, the trailing lone BF2I with delay 1. Asserts its multiplier count against `fft_lane_mults()`. |
| `rtl/fft/fft_dit_merge.sv` | `N_LANE`, `LEVEL`, `SHIFT`, twiddle options | #11 | One radix-2 decimation-in-time merge level: `W*O`, then `E ± W*O` with one quantisation. No memory. `LEVEL = 0` is the only level issue #11 verifies. |
| `rtl/fft/fft_reorder.sv` | `N_LANE`, `WIDTH`, `STYLE` | #11 | Bit-reversed to natural **beat** order, double buffered. Permutes beats only — both slots move together and no sample changes lane. Costs one frame of latency and two banks. |
| `rtl/fft/fft_core.sv` | `FFT_SIZE`, `SAMPLES_PER_CYCLE`, `SCALE_SCHED`, twiddle/memory options, `FLAG_COUNT_W` | #11 | The transform with no stream protocol attached: the lanes, the merge, and one `fxp_sticky_flags` per butterfly sub-stage of the whole transform. |
| `rtl/fft/streaming_fft.sv` | `FFT_SIZE`, `SAMPLES_PER_CYCLE`, `SCALE_SCHED`, `REORDER`, SPEC §5 field widths, twiddle/memory options, `IN_DEPTH`, `OUT_SLACK` | #11 | The SPEC §5 block: elastic input boundary, frame tracking and the position tag, the core, the optional reorder, the metadata FIFO and the credit-backed output FIFO. |

Simulation-only and synthesis-only companions:

| Path | Parameters | Issue | Function |
|---|---|---|---|
| `sim/verilator/tops/fft_top.sv` | none | #11 | Verification top holding five elaborations at once: the 64-point reference, the same with the output left bit-reversed, two saturating schedules, and a 256-point instance. Packs and unpacks the SPEC §5 bundle so the C++ side sees plain fields. |
| `quartus/calibration/fft_stage_wrap.sv` | `N_LANE`, `S`, `SHIFT_A/B`, `HAS_TWIDDLE`, `VARIANT_SEL`, `TW_PIPE`, `TW_ROM_OUT_REG`, `MEM_SEL`, `TW_SEL` | #11 | SPEC §18 item 4 wrapper: one radix-2² stage between boundary registers. |
| `quartus/calibration/fft_core_wrap.sv` | `FFT_SIZE`, `SAMPLES_PER_CYCLE`, `SCALE_SCHED`, `REORDER`, `VARIANT_SEL`, `TW_PIPE`, `TW_ROM_OUT_REG`, `MEM_SEL`, `TW_SEL`, `REORDER_SEL`, `FIFO_SEL` | #11 | SPEC §18 item 5 wrapper: the whole `streaming_fft` block between boundary registers. |

**Beat layout (normative).** Input beat *t* slot *p* is `x[SPC*t + p]` — samples in time
order. Output beat *j* carries `X[m]` and `X[m + N/2]`, with `m = bitrev(j)` when
`REORDER = 0` and `m = j` when `REORDER = 1`. Pairing bins half a spectrum apart is what
makes the reorder a pure beat permutation; see DECISIONS.md (issue #11, decision 9).

**Flow control, and why the core has no stall.** The core is a valid-tagged, gap-tolerant
pipeline: each stage advances on a local, pipelined beat-valid, and a cycle with no beat
does not advance the delay feedback. Nothing downstream can stop a beat once it is in.
Backpressure is applied at the **input**, by a credit counter that reserves an output slot
for every beat admitted, so (FIFO occupancy + beats in flight) is bounded by the FIFO depth
— and that depth is `fft_pkg::fft_total_latency() + OUT_SLACK`, derived from the pipeline
rather than chosen. The reasons (SPEC §23, and `complex_multiplier`'s deliberately
enable-free datapath) and the cost are in DECISIONS.md (issue #11, decision 7).

A consequence worth knowing at the block boundary: the pipeline is indexed by sample
position, not by time, so a frame's output requires `fft_total_latency()` **further beats**
to be admitted before it emerges. In continuous operation that is invisible; a finite test
must flush, and `sim/tests/test_fft.cpp` does.

Issue #15 consumes this block and decides whether `REORDER` is worth its frame of
latency.

#### Beamforming matrix (`rtl/beamformer/`, issue #12)

SPEC §7.5. `Y[b][f] = sum over antennas a of X[a][f] * W[b][a]` — parameterised in
antennas, beams, bins per beat and beams per cycle, with double-buffered weights, a
pipelined accumulation tree and explicit saturation reporting. **This is the design's
dominant DSP consumer**: every other kernel's DSP count is a fraction of it.

```text
one beat = BIN_PAR aligned antenna vectors        (issue #16 produces this alignment)

  s_payload.data                                       weight_bank (2 banks)
  +--------------------------------------+             +--------------------+
  | bin 0: X[0..N_ANT-1]                 |             | W[b][a], beam-major|
  | bin 1: X[0..N_ANT-1]                 |             +---------+----------+
  | ...                                  |                       | group mux
  +------------------+-------------------+                       v
                     |  hold register (also the multiplex source)
                     v
        +------------+-------------------------------------------+
        |  BIN_PAR x BEAM_PAR  bf_dot                            |
        |    N_ANT complex_multiplier (ROUND_OUT = 0, exact)     |
        |    balanced adder tree at bf_acc_w(N_ANT) bits         |
        |    ONE fxp_round_sat to Q1.15 + saturation flags       |
        +------------+-------------------------------------------+
                     v
        one output beat = BEAM_PAR beams x BIN_PAR bins of ONE beam group
```

##### The input contract (NORMATIVE)

A beat's `data` field carries **`BIN_PAR` consecutive frequency bins, each as the complete
vector of `N_ANT` complex Q1.15 samples for that bin**, bin-major and antenna-minor:

```text
data[(j*N_ANT + a) * 2*SAMPLE_W  +:  2*SAMPLE_W]   =   X[antenna a][bin_base + j]
    j in [0, BIN_PAR)     a in [0, N_ANT)          packed {im, re}, Q1.15
```

With `BIN_PAR = 1` this is exactly "one beat is one bin's antenna vector".

**The word *aligned* is the whole contract.** Every antenna's sample in a beat must be the
**same frequency bin of the same frame**. A beamformer sums across the antenna dimension,
so a beat in which antenna 3 is one bin behind the others produces a result that is not a
beam and is *not detectably wrong from the output alone*. Producing that alignment is
issue #16's frequency alignment network, and it is the reason that issue exists. This block
assumes it and states the assumption, because an assumption that lives only in a diagram is
an assumption nobody checks.

What the block does **not** assume, and therefore does not require of #16:

* **no particular bin order.** `bin_base` is positional, not decoded: bin *j* of the beat is
  bin *j* of the beat, and the frame's mapping from beat index to absolute bin index is a
  frame-level convention carried by the sequence number.
* **no relationship between frame length and any parameter.** Frames are delimited by
  `start_of_frame` / `end_of_frame` exactly as SPEC §5 says.

The output beat is the transpose of that nesting, because the output's slow axis is the beam
where the input's is the bin:

```text
data[(k*BIN_PAR + j) * 2*SAMPLE_W  +:  2*SAMPLE_W]  =  Y[group*BEAM_PAR + k][bin_base + j]
```

**Payload widths.** `BIN_PAR * N_ANT * 32` in, `BIN_PAR * BEAM_PAR * 32` out. The input beat
is the widest interface in the design: 1024 bits at the 2-bin, 16-antenna slice the SPEC §18
calibration compiles, and 4096 bits at the `full_agmf039` 8-bin, 16-antenna configuration.
`stream_pkg::STREAM_MAX_DATA_W` was raised from 256 to **1024** by this issue for that
reason, and deliberately not to 4096; see DECISIONS.md (issue #12, decision 5).

##### Modules

| Path | Parameters | Issue | Function |
|---|---|---|---|
| `rtl/beamformer/beamformer_pkg.sv` | none (functions only) | #12 | The single definition of the block's geometry and arithmetic: `bf_acc_w()` (accumulator width, from `fxp_pkg`'s own policy), the adder-tree geometry and register count, the latency accounting, the time-multiplex factor and its power-of-two rule, the beam-major weight index, and the two payload widths. `model/cpp/beamformer/beamformer_model.hpp` is its C++ mirror and the test checks the two against each other before anything else runs. |
| `rtl/beamformer/bf_dot.sv` | `N_ANT`, `MULT_PIPE_STAGES`, `MULT_VARIANT`, `ADD_REG_EVERY` | #12 | One beam x one bin complex dot product: `N_ANT` `complex_multiplier` instances at `ROUND_OUT = 0`, a balanced binary adder tree at `bf_acc_w(N_ANT)` bits with a register every `ADD_REG_EVERY` levels, and **one** `fxp_round_sat` to Q1.15 with direction-resolved flags. Also exports the exact accumulator for issue #13. Fixed-latency valid pipeline, no ready. The SPEC §18 item 6 calibration unit. |
| `rtl/beamformer/weight_bank.sv` | `N_BEAMS`, `N_ANT`, `SYNC_STAGES`, `ALLOW_UNSAFE_SWAP` | #12 | The double-buffered `N_BEAMS x N_ANT` weight store with a frame-aligned swap. **Instantiates `rtl/pfb/coeff_bank.sv`** rather than reimplementing a dual-bank store, a clock-domain seam and a swap state machine; it adds the beamformer's bounds, the beam-major index contract and a beamformer-named status surface. Swap granularity is the **whole array**, never per beam. |
| `rtl/beamformer/beamformer.sv` | `N_ANT`, `N_BEAMS`, `BIN_PAR`, `BEAM_PAR`, `MULT_PIPE_STAGES`, `MULT_VARIANT`, `ADD_REG_EVERY`, SPEC §5 field widths, `SYNC_STAGES`, `TELEM_COUNT_W` | #12 | The SPEC §5 block: the credit-gated elastic input boundary, the hold register that is also the time-multiplex source, the weight bank and its beam-group mux, the `BIN_PAR x BEAM_PAR` engine, the metadata path, the output elastic buffer, the SPEC §9 telemetry, and the SPEC §7.5 reported-throughput ports. |

Simulation-only and synthesis-only companions:

| Path | Parameters | Issue | Function |
|---|---|---|---|
| `sim/verilator/tops/beamformer_top.sv` | none | #12 | Verification top holding **three** matrices in one elaboration — the reference engine, the same engine with `BEAM_PAR` halved so the beams are time multiplexed, and the same engine with two adders per register stage — all admitting the same beats, plus two standalone 16-antenna dot products and one weight bank with the frame-boundary rule disabled. |
| `sim/assertions/beamformer_assertions.sv` | `N_DOT`, `OUT_DEPTH`, `CRED_W`, `BEAM_MUX`, `GRP_W` | #12 | The SPEC §14 property set: the credit argument and the time-multiplex contract. See VERIFICATION_PLAN.md §5.13. |
| `quartus/calibration/bf_dot_wrap.sv` | `N_ANT`, `MULT_PIPE_STAGES`, `VARIANT_SEL`, `ADD_REG_EVERY` | #12 | SPEC §18 item 6 wrapper: one 16-antenna dot product between boundary registers. |
| `quartus/calibration/bf_matrix_wrap.sv` | `N_ANT`, `N_BEAMS`, `BIN_PAR`, `BEAM_PAR`, `MULT_PIPE_STAGES`, `ADD_REG_EVERY`, `VARIANT_SEL` | #12 | SPEC §18 item 7 wrapper: a 2-bin x 4-beam x 16-antenna slice of the matrix — the same arithmetic as one complete beam at 8 bins per cycle — between boundary registers, with `BEAM_MUX = 2` so the multiplex machinery is in the measured design. |

##### Time multiplexing, in parameters and in reported throughput

SPEC §7.5: *"Do not silently reduce throughput to meet utilization. Any time multiplexing
must be visible in parameters and reported throughput."*

When `BEAM_PAR < N_BEAMS` the remaining beams are computed on later cycles from the same
held input beat, in `BEAM_MUX = N_BEAMS / BEAM_PAR` groups:

```text
input  beats accepted per cycle  =  1 / BEAM_MUX
output beats produced per cycle  =  1
bins  per input  beat            =  BIN_PAR
beams per output beat            =  BEAM_PAR
sustained bins per cycle         =  BIN_PAR / BEAM_MUX
arithmetic throughput            =  BIN_PAR * BEAM_PAR beam-bins per cycle   (invariant)
```

The last line is the one that matters: multiplexing trades **input rate for engine reuse**
and changes nothing else. All six numbers are exported on the block's `tput_*` ports and are
read back through `WEIGHT_PARALLELISM` / `WEIGHT_THROUGHPUT` in the register map, so the
throughput claim is a readback rather than a comment. `beamformer_assertions` additionally
checks the admission rate on live traffic, so a build that admitted faster than the engine
can serve fails rather than silently dropping beams.

`BEAM_MUX` is a power of two, checked at elaboration, because that buys the output sequence
number: `seq_out = {seq_in, group}` is a free concatenation, is continuous beat-to-beat
(which `stream_protocol_checker` requires), and is invertible by slicing.

##### Output metadata convention

Output beat *k* is not "the same beat as" any input beat once `BEAM_MUX > 1`, so the mapping
is a stated convention rather than an implied one — the same situation issue #11 faced for
the FFT:

| field | value |
|---|---|
| `stream_id` | unchanged |
| `seq` | `{seq_in, group}`; identical to `seq_in` when `BEAM_MUX = 1` |
| `start_of_frame` | set on **group 0** of an input beat carrying `start_of_frame` |
| `end_of_frame` | set on the **last group** of an input beat carrying `end_of_frame` |
| `user` | **the beam group index**: the beams in this beat are `[group*BEAM_PAR, (group+1)*BEAM_PAR)` |

`user` carries the group rather than forwarding the input's `user` because SPEC §12.5's
transaction identity names `beam` as a dimension and this is the only field it can live in;
the bin dimension is positional within the beat and needs no field.

##### Flow control, numerics and the weight swap

* **Elastic at the boundary, fixed latency inside.** The interior is a valid-tagged pipeline
  with no ready at all — a ready chain into a `bf_dot` would land `m_ready` on the clock
  enable of every DSP register in the largest DSP array in the design. `s_ready` is a
  flip-flop whose input depends only on this block's own credit counter and hold state, and
  an input beat is admitted only when **`BEAM_MUX` output slots** are reserved. Reserving
  all of them at once is what makes the reservation sound: an input beat is an
  all-or-nothing commitment to `BEAM_MUX` outputs.
* **One quantisation, at the end.** Every multiplier runs at `ROUND_OUT = 0`; the `N_ANT`
  exact 33-bit partial products are summed at `bf_acc_w(N_ANT)` bits — 37 for 16 antennas —
  a width at which the accumulation provably cannot overflow, and the result is rounded and
  saturated exactly once. There is therefore **no intermediate saturation**, integer
  addition is associative, and `ADD_REG_EVERY` is a pure cost parameter: the tree's shape
  cannot change its answer. Issue #9 measured what the alternative costs — a rounding
  network is about 100 ALMs and roughly half the achievable clock, so rounding per antenna
  would buy sixteen of them and double the quantisation noise.
* **Latency is pure cycles.** There is no sample history anywhere in a beamformer, so every
  register combines same-beat values and free-runs. Unlike `pfb_pkg`, `beamformer_pkg` has
  no beat-measured latency at all; a consumer delays metadata by `bf_lat_cycles()` cycles
  and nothing else.
* **The weight swap is aligned to the ISSUE, not the admission.** With `BEAM_MUX > 1` a new
  beat is admitted on the same cycle as the *last group of the previous beat is issued*, so
  driving the bank from the admission swaps the matrix one cycle early and gives the
  previous frame's final beat its last `BEAM_PAR` beams from the next frame's weights. That
  was a real defect, found by the multiplexed DUT; see DECISIONS.md (issue #12, decision 4).

Issue #13 consumes this block's output (and its exact-accumulator port); issue #16 produces
its input; issue #20 freezes `BIN_PAR` and `BEAM_PAR` against the SPEC §18 measurements.


#### Power and covariance (`rtl/covariance/`, issue #13)

SPEC §7.6: `Power = I² + Q²` per sample, a configurable cross-power
`Rxy = X · conj(Y)` over selected antenna or beam pairs, both integrated over a
programmable window with boundary metadata, accumulator protection, optional exponential
averaging, per-pair runtime enable and deterministic reset/flush.

```text
                                       cfg: window_len, mode, exp_k, enable, flush
                                                    |
  sample ──> power_calc ──POWER_W──> integrator ────┴──> acc / window_id / count /
             (I²+Q²)                 (Σ or IIR)              flushed / truncated / sat

  src[0..N_SRC-1] ─┬─> mux(pair.x) ─> complex_multiplier ─> p_im ──> integrator ─> Rxy.re
  (one beat)       └─> mux(pair.y) ─> (b = {re:y.im,      ─> −p_re ─> integrator ─> Rxy.im
                          swapped)      im:y.re})
```

| Path | Parameters | Issue | Function |
|---|---|---|---|
| `rtl/packages/covar_pkg.sv` | none (functions + widths) | #13 | The block's widths and its window arithmetic: `COVAR_POWER_W = 40`, the per-term bound, the integration mode enum, and `covar_acc_w_required()` / `covar_window_max_exact()` — equation `N ≤ 2^(w−32) − 1` in both directions. The rounding and saturation *rules* stay in `fxp_pkg`; this package never duplicates them. Names its integer type `covar_uint_t`, per DECISIONS.md (issue #10, decision 9). |
| `rtl/covariance/power_calc.sv` | `PIPE_STAGES` 1–3, `TAG_W` | #13 | `I² + Q²`, exact, in `[0, 2^31]`, presented in a signed `POWER_W` field. Two 16×16 squares and their sum as ONE combinational expression between two registers, so the pair maps to a single DSP in sum-of-two-multipliers mode. No saturation flag, because saturation is impossible by construction; the impossibility is asserted every cycle instead. Latency == `PIPE_STAGES`. |
| `rtl/covariance/integrator.sv` | `DATA_W`, `ACC_W`, `WINDOW_W`, `SAT_COUNT_W` | #13 | One signed accumulator: block sum or exponential average, programmable window latched at a boundary, window-boundary metadata (`window_id`, `sample_count`, `flushed`, `truncated`), `fxp_sat` protection with an `fxp_sticky_flags` collector, and the deterministic flush. Instantiated once per power channel and twice per covariance pair. |
| `rtl/covariance/covar_engine.sv` | `N_SRC`, `N_PAIRS`, `CMULT_VARIANT`, `CMULT_PIPE_STAGES`, `ACC_W`, `WINDOW_W`, `SEL_W` | #13 | `N_PAIRS` cross-power channels over a parallel source vector, each one `complex_multiplier` (`ROUND_OUT = 0`) plus two integrators. Per-pair runtime enable gates the accumulation, never the multiply. |
| `rtl/control/reg_block_covar.sv` | `IDX_W` | #13 | The software half: the 0x9000 integration-settings window, the FLUSH pulse and the pair-table WRITE strobe. Checks its generated reset values against `covar_pkg` at elaboration. |

Simulation-only companions:

| Path | Parameters | Issue | Function |
|---|---|---|---|
| `sim/verilator/tops/covar_top.sv` | `N_SRC`, `N_PAIRS` (from `config_pkg`) | #13 | Verification top: `power_calc`, an integrator behind it, a bare integrator on a direct data port, a second bare integrator elaborated at `ACC_W = 34` so its exact-window bound is reached in four samples, and the engine with a pair observation mux. Source vector and pair table are written one entry at a time, which keeps every port ≤ 32 bits at every SPEC §11 size. |
| `sim/assertions/covar_assertions.sv` | `WINDOW_W`, `ACC_W` | #13 | The SPEC §14 window-metadata property set, instantiated inside every `integrator`; see VERIFICATION_PLAN.md §5.12. |

**Why `POWER_W` is 40.** It is 32 + 8, and both halves are forced. One term — a power or
one component of a conjugate product — satisfies `|v| ≤ 2^31` and therefore needs 32 signed
bits (the extreme `I = Q = −32768` gives exactly `2^31`). A signed *w*-bit accumulator sums
`N` such terms without ever clamping iff `N ≤ 2^(w−32) − 1`, so 40 bits buys **255 samples
of provably exact integration**. At 256 the bound is missed by one LSB and only by the
single all-extreme input sequence — which is a directed test, not a hypothesis. Longer
windows are legal, clamp rather than wrap, and set a sticky flag.

**Conjugation without a negation.** `conj(Y)` cannot be formed by negating `y.im`: `−32768`
is a legal Q1.15 value whose negation does not fit 16 bits, so the extreme corner would be
silently wrong. The engine instead feeds the multiplier `b = {re: y.im, im: y.re}` and
reads `Rxy.re = p_im`, `Rxy.im = −p_re`. The negation moves to the exact 33-bit product
port, where it cannot overflow for any input, and the issue #9 kernel is used unmodified.

**Input contract: parallel sources, not time-multiplexed pairs.** Everything upstream —
the alignment network and the beamforming matrix — already produces all channels for one
instant in the same beat, so a serialised pair stream would need a re-serialiser and would
cap the input rate at one vector per enabled pair. At the SPEC §11 medium size the full
upper triangle is 10 pairs = 40 DSPs against a 10× throughput gain. The trade stops being
one-sided at full scale (136 pairs = 544 DSPs), where `MULT3` and a pruned pair list are
the levers, and both are already parameters.

**Where configuration takes effect.** The window length, mode, exponential shift and
per-pair enable latch at a *window boundary* — a close, a flush, or an idle cycle in which
no window is open and none is opening. The pair *selectors* latch only on reset and flush,
because the multiplier pipeline means in-flight products would otherwise be misattributed
across a re-pointing. Re-pointing a pair is therefore: write the table, pulse `FLUSH`.

**Flow control.** No `ready` in or out and no clock enable on the datapath, matching
`complex_multiplier` and `power_calc`. Gaps in `valid_in` are therefore invariant — the
same beats in the same order give byte-identical results dense or sparse — and the output
rate never exceeds the input rate, so nothing needs to back-pressure. Elasticity, when a
consumer needs it, is a `rtl/stream/` primitive placed after the block.

### 3.6 Packet fabric (`rtl/packet/`)

TODO — populated by issue #18.

### 3.7 Control plane (`rtl/control/`)

The SPEC §9 register plane, in `cfg_clk`. Populated by issue #7. The counters window landed
with #8 as `rtl/common/telemetry_block.sv` — it is the counters block of this plane, but it
lives under `rtl/common/` because it is instantiated beside the datapath it measures rather
than beside the plane it answers, and when the two are in different domains it is the register
interface that crosses, not the counters. Snapshot/debug lands with #19.

| Module | Role |
|---|---|
| `reg_if_pkg.sv` | normative definition of the portable 32-bit interface: widths, transaction types, the malformed-request test, the response-timing constants. Vendor neutral — no APB or Avalon-MM assumption anywhere in it |
| `generated/regmap_pkg.sv` | the register map as data: window geometry, register addresses and indices, field slices, and the per-bit reset/writable/W1C/pulse/hardware masks. Generated by `scripts/gen_regmap.py` from `control/regmap.json` |
| `reg_csr_block.sv` | the one hand-written access-type engine: byte-enable masking, W1C against a simultaneous hardware set, write-1-pulse, hardware-driven read data, refusal of a write to a read-only register. Parameterised entirely by the generated tables |
| `reg_block_id.sv` | identification: magic, register-map version, plane geometry, implemented-block bitmap |
| `reg_block_build_params.sv` | the elaboration parameters, read from `config_pkg`, plus an FNV-1a checksum over them that the harness recomputes |
| `reg_block_ctrl.sv` | per-block enable (level out) and soft reset (one-cycle pulse out), global enable/flush/soft-reset, and a hardware-computed status word |
| `reg_block_fault.sv` | SPEC §24 fault injection: an arming mask, one-shot triggers gated by it, sticky W1C status and a saturating counter |
| `reg_block_scratch.sv` | software scratch, including one half-writable register; exists to test the fabric against something with no other behaviour |
| `reg_fabric.sv` | one master port onto N block windows: decode, broadcast, response selection, and the watchdog that guarantees every transaction ends |

`sim/assertions/reg_if_checker.sv` is instantiated inside `reg_fabric` under
`ifndef SYNTHESIS`; `sim/verilator/tops/control_top.sv` is the unit-test top and also
attaches a second fabric to a deliberately dead block, so the watchdog escape is exercised.

The register map itself — every block, register and field — is documented in
[`docs/regmap.md`](docs/regmap.md), generated from `control/regmap.json`.

### 3.8 Tops (`rtl/top/`)

TODO — populated by issues #3, #17, #20, #24.

## 4. Clock domains

Logical domains defined by SPEC §8 (`core_clk`, `history_clk`, `packet_clk`,
`memory_clk`, `cfg_clk`, `telemetry_clk`) with their benchmark constraint targets.

TODO — populated by issue #6 (domain definition and CDC primitives) and issue #3
(SDC constraint capture).

## 5. Clock-domain crossings

CDC inventory: every crossing, its mechanism (async FIFO / synchronizer / handshake),
and the assertion that guards it, per SPEC §8.

The inventory is **generated, not written**: `make cdc-inventory` elaborates a file list with
`verilator --xml-only` and joins the instance tree against the `(* cdc_primitive *)`
attributes in `rtl/`. `--strict` fails when any instantiated module with two or more
clock-like ports carries no attribute, which is what keeps the report complete as the design
grows rather than complete on the day it was written.

Two tops are covered as of issue #10:

| Top | File list | Crossings | Unknown |
|---|---|---|---|
| `cdc_prims_top` | `sim/verilator/files_cdc.f` | 24 | 0 |
| `pfb_top` | `sim/verilator/files_pfb.f` | 32 | 0 |

The polyphase build is the first **design** block with a configuration-to-core seam of its
own. `coeff_bank` and `pfb_bank` are tagged as composites — the same arrangement
`rtl/cdc/stream_cdc.sv` uses over `async_fifo` — so the report lists the composite and the
real synchronizers nested under it:

| Crossing | Mechanism | Direction | Payload |
|---|---|---|---|
| coefficient write | `cdc_handshake` (four-phase) | cfg → core | `{bank, address, data}` as ONE transfer |
| bank-swap request | `cdc_pulse` (toggle) | cfg → core | 1-bit event, with an overrun flag |
| active bank / swap pending / write reject | `cdc_sync2`, one instance **per bit** | core → cfg | 1 bit each |

The address and the data cross as a single handshake payload on purpose: crossing them as
independent synchronised buses is exactly the multibit crossing SPEC §8 prohibits, and would
let one bit of an address be sampled from a different cycle than its data.

## 6. Interfaces

### 6.1 Streaming protocol

Ready/valid streaming interface per SPEC §5. Defined by
[`rtl/packages/stream_pkg.sv`](rtl/packages/stream_pkg.sv) (issue #5); rationale and the
alternatives rejected are in [DECISIONS.md](DECISIONS.md) 2026-07-26.

**The bundle.** Three ports per interface: `valid`, `ready`, and one packed payload
vector carrying every SPEC §5 field except the handshake.

```text
MSB                                                          LSB
+--------+-----+-----+-----------+---------+--------+
|  data  | sof | eof | stream_id |   seq   |  user  |
+--------+-----+-----+-----------+---------+--------+
```

`user` sits at bit 0 and `data` at the top, so widening `data` — the field most likely to
change between size configurations — moves no other field's offset and a payload captured
in a waveform stays readable across a resize. The field order in this diagram is
normative; `stream_pkg`'s offset functions are its executable form, and nothing anywhere
recomputes an offset by hand.

**Transport.** Packed vector, not a SystemVerilog interface: Verilator 5.020 cannot pass
an interface through a top-level module port, and that port is exactly where the C++
harness attaches. `stream_geom_t` carries the four field widths into `stream_pack()` /
`stream_unpack()`, which are the only sanctioned way to move between the packed vector and
the named-field view.

**Field naming.** The SPEC §5 `sequence` field is spelled `seq` everywhere — it is the
only spelling legal as a struct member, a variable and a port. `benchmark_fabric_top`
(issue #3) still uses `in_sequence` / `out_sequence` and is the one documented exception.

**Elastic-buffer placement rule.** SPEC §5 forbids a combinational `ready` chain crossing
more than one module boundary, and SPEC §23 asks for ready/valid feedback to be broken
with elastic buffers. Both primitives that store beats — `stream_skid_buffer` and
`stream_elastic_buffer` — drive `ready` from a flip-flop whose input depends only on their
own state, so a ready path through either crosses **zero** boundaries. The rule for the
design:

* every block boundary in the datapath gets a decoupler on the way in and on the way out
  (`skid -> work -> skid`, or a shallow elastic buffer where stall tolerance is wanted);
* a boundary that needs only decoupling never gets a FIFO — memory-backed and
  clock-crossing FIFOs are issue #6 and a different cost class;
* latency inserted for floorplan or retiming reasons goes through `stream_pipe`, which
  adds registers without adding an enable or a ready path.

**Assertion coverage.** Every primitive instantiates `stream_protocol_checker` on its
master interface inside `` `ifndef SYNTHESIS ``, so any design built from them is checked
at every stage boundary in the fast simulation build (SPEC §14). The checker also attaches
by `bind` for modules that carry no assertions of their own. The property list, what
Verilator actually enforces, and the negative test that proves each assertion fires are in
[VERIFICATION_PLAN.md](VERIFICATION_PLAN.md) §5.

### 6.2 Register/control interface

SPEC §9's eight signals, defined normatively in `rtl/control/reg_if_pkg.sv` (issue #7):

```text
address[15:0]      byte address, word aligned
write_data[31:0]
read_data[31:0]
write_enable
read_enable
byte_enable[3:0]
ready
error
```

One outstanding transaction. The master holds the request stable until it observes `ready`;
`ready` is asserted for exactly one cycle per accepted request, with `read_data` and `error`
valid in that cycle and driven inert outside it; the master drops the request in the cycle
after. Every access completes in exactly two cycles — one to decode, one in the addressed
block — and no path runs combinationally from `address` to `read_data`.

Everything is answered, nothing stalls. Both enables at once, an unaligned address, a write
with no byte enables set, an address outside every window, an address inside a window but
past the block's last register, and a write to a read-only register all complete with
`ready=1, error=1` and no side effect. If a block fails to answer at all, the fabric's
watchdog completes the transaction with `error=1` after `REG_WATCHDOG_CYCLES`.

Address space: 16 bits, one 4 KiB window per block, each aligned to its own size, so the
decode is an address-bit compare. Windows are assigned in `control/regmap.json` and
documented in [`docs/regmap.md`](docs/regmap.md); the windows for groups that later issues
implement (coefficients and bank select #10/#12, CFAR and integration #14, snapshot/debug #19)
are reserved now and answer `error=1` until then. The counters window at `0x7000` was reserved
by #7 and implemented by #8.

Vendor neutrality is a property of the fabric, not a convention: nothing in `rtl/control/`
names APB or Avalon-MM. An adapter for either is a separate module that speaks this protocol
on its back side.

Domain: `cfg_clk` throughout. Enables leave the plane as levels and resets as one-cycle
pulses — the inputs a level synchroniser and a toggle synchroniser respectively want — and
the crossings themselves belong to the issue #6 CDC primitives.

### 6.3 Abstract memory interface

TODO — populated by issue #19; HBM2e binding by issue #24.

### 6.4 Event packet format and virtual channels

TODO — populated by issue #18.

## 7. Parameterization and elaboration

How `config/*.json` (tiny / medium / large / full_agmf039) drives a single RTL codebase
per SPEC §11.

TODO — populated by issue #2 (config plumbing into the build) and issue #20.

## 8. Latency and throughput budget

| Block | Latency (cycles) | Throughput | Issue |
|---|---|---|---|
| `stream_skid_buffer` | 1 | 1 beat/cycle | #5 |
| `stream_elastic_buffer` | 1 | 1 beat/cycle at any `DEPTH >= 2` | #5 |
| `stream_pipe` | `STAGES + 1` | 1 beat/cycle for `OUT_DEPTH >= STAGES + 2` | #5 |
| `stream_loopback` | 3 | 1 beat/cycle | #2, #5 |
| `complex_multiplier` | `PIPE_STAGES` (1–5) | 1 operand pair/cycle, no backpressure | #9 |
| `fir_lane` (`TREE`) | `MULT_PIPE + ceil(log2 TAPS) + 1` cycles, 0 beats | 1 sample/cycle, no backpressure | #10 |
| `fir_lane` (`SYSTOLIC`) | `MULT_PIPE + 2` cycles **and** `TAPS-1` beats | 1 sample/cycle, no backpressure | #10 |
| `pfb_bank` | the lane's, plus 1 cycle for the output elastic buffer | 1 beat/cycle sustained | #10 |
| `fft_bf2` | 1 register + `DELAY` **positions** | 1 beat/enabled cycle | #11 |
| `fft_radix22_stage` | 2 registers + `D_A + D_B` positions, plus `ROM_LAT + TW_PIPE` when it carries a multiplier | 1 beat/enabled cycle | #11 |
| `fft_dit_merge` | `ROM_LAT + TW_PIPE + 1` | 1 beat/enabled cycle | #11 |
| `fft_reorder` | `M + 1` beats (`M = FFT_SIZE/SAMPLES_PER_CYCLE`) | 1 beat/enabled cycle | #11 |
| `streaming_fft` | `fft_pkg::fft_total_latency()` beats — **88** at 64 points / 2 SPC with `REORDER = 1`, **55** without | 1 beat/cycle while credits allow | #11 |
| `bf_dot` | `MULT_PIPE + ceil(clog2(N_ANT) / ADD_REG_EVERY) + 1` cycles, 0 beats — **9** at 16 antennas with a register per tree level, **7** with one per two levels | 1 operand set/cycle, no backpressure | #12 |
| `beamformer` | the dot product's, plus 1 cycle for the input hold register, plus 1 for the output elastic buffer | **`BIN_PAR / BEAM_MUX` bins per cycle**; one input beat accepted every `BEAM_MUX = N_BEAMS/BEAM_PAR` cycles and one output beat produced per cycle. Arithmetic throughput is `BIN_PAR * BEAM_PAR` beam-bins/cycle and is invariant under the multiplex. Reported on the `tput_*` ports and readable through `WEIGHT_THROUGHPUT`. | #12 |

The FFT's latency is counted in **beats**, not cycles, and the distinction is load-bearing:
its delay feedbacks advance on beats while its multipliers free-run, so a gap on the input
does not translate into a fixed cycle offset. The two contributions are kept apart in
`fft_pkg` — a *position* offset from the delay lines (`M-1` per lane) and a *time* latency
from the pipeline registers — and their sum is what sizes the metadata FIFO and the output
FIFO. `streaming_fft` asserts on every delivered beat that the popped `start_of_frame`
coincides with position 0 out of the core, so the number is checked rather than assumed, and
`sim/tests/test_fft.cpp` reads it back from the RTL's own `cfg_latency` echo.

`complex_multiplier`'s latency is exactly its parameter, by construction and for both
variants — the register-location priority order is chosen so that the enables sum to
`PIPE_STAGES`. It is measured from the RTL rather than assumed: `sim/tests/test_cmult.cpp`
drives one isolated beat into each elaborated instance, counts edges to `valid_out`, and
compares against the `cfg_pipe_stages` the top echoes back from the instance's own
parameter. A block composing this kernel can therefore treat the number as a contract.

`fir_lane`'s latency is **two numbers, not one**, and the units are not interchangeable: see
§3.5. `sim/tests/test_pfb_bank.cpp` checks both against the RTL's own `cfg_lat_*` echo before
it checks anything else, and then scoreboards every output beat **by sequence number**, so a
result delivered against the wrong metadata fails on content rather than passing quietly.

A `SYSTOLIC` lane also has a **warm-up**: its first `TAPS-1` beats produce partial cascades
and are suppressed, so a finite burst yields `TAPS-1` fewer output beats with the remainder
still in flight. That is the ordinary drain behaviour of a filter whose latency is measured
in samples; the output *sequence* is identical to the tree's.

TODO — remaining blocks populated by the implementing issues; consolidated by issue #17 and
issue #20.
