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

Issues #12–#14 populate the remaining block directories; issue #15 consumes this one and
decides whether `REORDER` is worth its frame of latency.

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
