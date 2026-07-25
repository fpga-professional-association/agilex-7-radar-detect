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

### 3.5 DSP kernels (`rtl/pfb/`, `rtl/fft/`, `rtl/beamformer/`, `rtl/covariance/`, `rtl/cfar/`)

TODO — populated by issues #9–#14.

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

TODO — populated by issue #6; regenerated as an inventory report by later issues.

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

TODO — populated per block by the implementing issues; consolidated by issue #17 and
issue #20.
