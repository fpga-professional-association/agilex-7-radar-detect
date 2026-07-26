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

The SPEC §7.3 time-frequency history: FFT frames in, beamformer vectors out, with the
transpose between them done by the memory's own banking rather than by a network. Write
side in `core_clk`, read side in `history_clk` (SPEC §8).

| Path | Parameters | Issue | Function |
|---|---|---|---|
| `rtl/packages/history_pkg.sv` | — | #15 | The address algebra, the response layout and the geometry predicate, once. `hist_geom_t`, `hist_stored_bin` / `hist_lane_of_bin` / `hist_beat_of_bin`, `hist_bitrev`, `hist_meta_pack` / `hist_meta_unpack`, and the M20K projection helper `hist_m20k_per_bank`. Integer type is `hist_uint_t`, not `uint_t` (issue #10 decision 9). |
| `rtl/memory/history_bank.sv` | `WIDTH`, `DEPTH`, `IN_REG`, `OUT_REG`, `STORAGE` (`auto`/`m20k`/`mlab`/`regs`) | #15 | One independently addressed bank: simple dual port, write clock and read clock independent, registers on both faces (SPEC §23), one `ramstyle` literal per named generate branch. Knows nothing about frames or antennas, which is what lets the SPEC §18 sweep compile it alone. Read latency 3. |
| `rtl/memory/history_core.sv` | `N_ANT`, `FFT_SIZE`, `LANES`, `FRAMES_MAX`, `SAMPLE_W`, `INPUT_BIT_REVERSED`, `STORAGE`, `SYNC_STAGES`, field geometries | #15 | The subsystem: `N_ANT × LANES` banks, per-antenna write sequencers, the frame barrier, the rotating slot pointer with overwrite-oldest, the registered read fanout, the three CDC crossings and the six counters. Write side never stalls; read latency 6 with no backpressure. |
| `rtl/control/reg_block_history.sv` | `IDX_W`, geometry (checks only) | #15 | The SPEC §9 window at `0xA000`. Thirteen registers: controls, programmable depth, rotation status, hardware-reported geometry, six counters and a W1C fault vector. |

Simulation-only companions:

| Path | Issue | Function |
|---|---|---|
| `sim/assertions/history_assertions.sv` | #15 | The SPEC §14 property set. Instantiated inside `history_core` under `` `ifndef SYNTHESIS ``, not bound, so it holds in the calibration wrapper too. Includes the two covers that make SPEC §7.3's "no globally broadcast address and enable network" checkable rather than merely asserted. |
| `sim/verilator/tops/history_top.sv` | #15 | Unit-test top: three geometries behind one port set, selected by `dut_sel`. |
| `quartus/calibration/history_bank_wrap.sv`, `history_core_wrap.sv` | #15 | SPEC §18 item 8 wrappers. Linted by `make lint` through `files_history.f`; never in a simulation top. |

#### The corner turn, as algebra (NORMATIVE)

Write order and read order disagree, and that disagreement is the whole problem:

```text
WRITE   one antenna at a time, frequency-sequential.
        In a cycle, antenna a delivers LANES samples of its own FFT frame.
READ    one frequency bin at a time, antenna-parallel.
        In a cycle, the consumer wants bin b of EVERY antenna at once.
```

The subsystem does not solve this with a transpose buffer or a crossbar. It chooses the
**bank dimension to be the one the read needs in parallel** — the antenna — so the memory
performs the turn:

```text
    BANK(a, l)  =  a * LANES + l           a = antenna, l = arrival lane
    ADDR(s, k)  =  s * M + k               s = frame slot, k = beat index
                                           M = BEATS_PER_FRAME = FFT_SIZE / LANES
```

`FRAMES_MAX` and `M` are both powers of two, so `ADDR` is the concatenation `{s, k}` — no
multiplier, no adder.

Consequences, and they are the design:

* a write touches one bank per lane, and those banks belong to one antenna. Two antennas
  share no bank, so **writes are collision-free by construction rather than by
  arbitration**, and the ingest is full rate with `s_ready` tied high;
* a read of bin `b` enables one lane's bank in **every** antenna — `N_ANT` banks — and each
  returns the same bin for a different antenna. That is the antenna vector, in one cycle,
  with no multiplexer and no transpose;
* the other `(LANES-1) × N_ANT` banks are idle during that read. Read bandwidth is one bin
  per cycle against a write bandwidth of `LANES` bins per cycle per antenna. Up to `LANES`
  bins could be served per cycle if they fell on distinct lanes; that headroom is real,
  recorded, and deliberately not spent here (see the read contract below).

**Lane assignment is positional, not arithmetic.** `l` is the sample's position in the
arriving beat, not `bin mod LANES`. This is exactly what `rtl/fft/fft_core.sv` hands over:

```text
    beat k, slot q  =  X[ m + q * (FFT_SIZE / LANES) ]  =  X[ q * M + m ]
        m = k                      when the FFT's reorder stage is present
        m = bitrev_{log2 M}(k)     when it is skipped (REORDER = 0)
```

Issue #11 chose to pair bins half a spectrum apart so its own reorder buffer could be two
banks read at one address. This block inherits the same gift in a stronger form: **the slot
index is the high bits of the bin and the beat index is the low bits**, so

```text
    bin      b  =  l * M + m
    lane     l  =  b / M          a bit slice, not a divider
    position m  =  b % M          a bit slice, not a modulo
    beat     k  =  m,  or  bitrev_{log2 M}(m)
```

Every one of those is a wire permutation on a power-of-two geometry. The corner turn costs
no arithmetic on either side.

#### Bit-reversal absorption

`INPUT_BIT_REVERSED = 1` lets the upstream FFT run with `REORDER = 0`. It changes the read
address decode from `b % M` to `bitrev(b % M)` — a rewiring — and changes the write side not
at all, because the write side never needs a bin index. Issue #11's own sweep priced its
reorder stage at **+170 ALMs, +4 M20K, +7 MLAB, −7.6 MHz and one frame of latency**
(DECISIONS.md, issue #11 finding 4); absorbing it here deletes all of that and adds nothing.
Both settings are verified against the model. The recommendation to issue #17, which owns
both blocks, is `REORDER = 0` upstream and `INPUT_BIT_REVERSED = 1` here.

#### Rotation, occupancy and the readable set

Frame `f` lives in slot `f mod DEPTH`, `DEPTH` register-programmable over `1..FRAMES_MAX`.
A frame is complete only when **every** antenna has finished it, so the published pointer is
`frames_done = min over antennas`, computed as a barrier (N_ANT equality comparators,
advanced once per frame) rather than as a minimum tree.

```text
    occupancy      =  min(frames_done, DEPTH)
    overwrite_cnt  =  max(frames_done - DEPTH, 0)
    readable       =  min(frames_done, DEPTH - 2)
```

The overwrite policy is **overwrite-oldest, unconditionally**: a history buffer that stalled
its own ingest would back-pressure the FFT and ultimately the front end, which SPEC §7.3
forbids by asking for continuous writes. What the block owes instead is exact bookkeeping,
and it delivers it — the C++ model asserts all three numbers at every instant.

`readable` is **two** slots short of the depth, not one, and the second slot is the
interesting one. The first is the frame being written. The second absorbs one frame of
**publication lag**: the reader works from a pointer that crossed a handshake, so between the
writer finishing frame `F` and the read domain seeing `F+1`, the writer is already filling
`slot(F+1)`. A `depth-1` bound would let a maximum-offset request address exactly that slot
— and the collision counter would not see it, because the collision test uses the same stale
pointer. Excluding one further slot moves the maximum-offset request to `slot(F+2)`, which
needs two frame completions to reach. `a_history_publication_fresh` checks that the one-frame
margin holds. The price is one frame slot; a programmed depth of 1 or 2 therefore leaves
nothing readable, which is legal and reported.

#### The read contract (NORMATIVE — issue #16 depends on this literally)

**Request**, `history_clk`, valid/ready:

| Field | Width | Meaning |
|---|---|---|
| `rd_req_bin` | `HIST_PORT_W` = 16 | Natural frequency-bin index, `0 .. FFT_SIZE-1`. Anything else is answered with `HIST_FLAG_OUT_OF_RANGE` and the error counter advanced. |
| `rd_req_frame_off` | 16 | Frames back from the newest **complete** frame. `0` = newest, valid over `0 .. readable-1`. |

`frame_off` is relative, not absolute, on purpose: an absolute frame number would force every
consumer to track the write side's progress and would make every request racy against
rotation.

**Response**, `history_clk`, a SPEC §5 stream. Every response is a complete one-beat frame
(`sof = eof = 1`); `seq` is the block's own response counter and advances by exactly one per
response. The `data` field is

```text
    data = { meta , ant[N-1] , ... , ant[1] , ant[0] }
```

with antenna 0 in the **low** bits and each antenna's sample packed as
`fxp_pkg::fxp_complex_t` — `{im, re}`, real in the low half. A consumer slices antenna `a` at
`a * 2 * SAMPLE_W` and needs no knowledge of `history_pkg` to read a sample. `meta` sits
**above** the antenna vector, so widening the antenna count moves no antenna's offset:

```text
    meta = { flags , frame_id , frame_off , bin }        bin at the bottom
    flags = { stale , collision , out_of_range }         out_of_range at bit 0
```

packed by `hist_meta_pack()` / `hist_meta_unpack()`. `frame_id` is the **absolute** frame
number served, resolved when the request was accepted — a consumer needs it to detect that a
rotation overtook a long-lived request, which `frame_off` alone cannot express. The flags are
also mirrored into the stream's `user` field, so a monitor that only decodes the SPEC §5
bundle can still see them.

Metadata travels inside `data` rather than on `user`/`stream_id` because it does not fit
them (`bin` alone is 10 bits at `FFT_SIZE = 1024` against `STREAM_MAX_USER_W = 8`), and on
the stream rather than on a sideband because SPEC §5 requires one interface at every module
boundary. The cost is `hist_meta_w()` bits that the beamformer eventually discards; issue #16
strips them when it assembles beamformer vectors, which it must do anyway because it
re-groups bins.

**Ordering** is request order, always: the read path is a fixed-latency pipeline with an
elastic output, so there is no reordering mechanism to go wrong and no tag to match.
**Backpressure** is unrestricted — a consumer may stall indefinitely and nothing about the
returned values changes, which `test_history`'s backpressure-invariance pass checks by
requiring a byte-identical response sequence at four stall profiles.

**One bin per cycle** is what the port serves. Assembling the `BIN_PAR × N_ANT` beat
`rtl/beamformer/beamformer.sv` consumes is issue #16's job; this port produces the
`BIN_PAR = 1` case of that beat, plus metadata, which is the shape `beamformer_pkg`'s own
header calls "exactly what issue #16's frequency alignment network produces".

#### No globally broadcast address or enable network (SPEC §7.3, §23)

* **Write:** there is no shared write address at all. Antenna `a` owns its beat counter, its
  slot register and its address; the address fans out to that antenna's `LANES` banks and
  nowhere else. Fanout is `LANES`, independent of `N_ANT`.
* **Read:** one logical address per cycle is shared by `N_ANT` banks — that is what a corner
  turn *is* — and it is distributed as a two-level registered tree: `history_core` registers
  it once per antenna, and every `history_bank` registers address and enable again on its own
  input. No register in the design drives every bank.
* **Enable:** only the addressed lane is enabled, so `LANES-1` of every `LANES` banks are
  held still on any read cycle. The enable is not a broadcast even logically.

The assertion set checks the observable consequences: `a_history_lane_onehot0` (at most one
lane enabled) and `c_history_write_enables_differ` (a cycle in which the antennas disagree
about writing, which one shared enable could not produce).

### 3.4a Frequency-bin alignment network (`rtl/align/`, issue #16)

SPEC §7.4. The layer between the history's one-bin-per-cycle read port and the
beamformer's `BIN_PAR × N_ANT` input beat. It preserves antenna, frequency-bin and frame
identity, supports backpressure, detects missing and duplicated samples, and avoids one
giant unregistered multiplexer — and it exists in **two interchangeable architectures**,
because SPEC §7.4 requires two to be built and compared.

#### What is left for this block to do, given #15 (NORMATIVE — read this first)

The naive reading of SPEC §7.4 is "transpose antenna-sequential FFT output into
bin-parallel antenna vectors". **That transpose is not here, and it is not here because
§3.4 already did it, in memory, for free.** `history_pkg` chooses the bank dimension to be
the antenna, so a read of bin *b* enables one bank per antenna and returns the whole
antenna vector in one cycle with no multiplexer at all. The antenna axis arrives already
aligned.

What is *not* solved by that, and what this block is, is the **bin-parallel marshalling
layer**:

* **issue** `BIN_PAR` read requests per cycle across `BIN_PAR` independent history read
  ports. §3.4 records that its port is deliberately one bin wide and that the headroom to
  widen it exists; this block spends that headroom by instantiating the port `BIN_PAR`
  times rather than by widening it, which leaves #15's correctness argument untouched;
* **route** each response to the beat position it belongs to. The port a bin was requested
  on is *not* the position it occupies in the beat (see the schedule below), so this is a
  genuine `BIN_PAR × BIN_PAR` permutation that changes every beat — and it is the thing
  the two architectures implement differently;
* **reassemble** responses that arrive skewed, because `BIN_PAR` independent history
  instances have independent occupancies and independent stalls;
* **detect** a response that never arrives or arrives twice, which nothing upstream can do.

#### The schedule, and why the routing is not the identity

A **group** is one output beat: `BIN_PAR` consecutive bins of one frame. A **sweep** is one
whole frame, `FFT_SIZE / BIN_PAR` groups, emitted as one SPEC §5 frame. Because `BIN_PAR`
is a power of two,

```text
    lane  j = bin % BIN_PAR = bin[LANE_W-1:0]        a bit slice
    group g = bin / BIN_PAR = bin[BIN_W-1:LANE_W]    a bit slice
```

If lane *j* were always requested on port *j*, the network would be `BIN_PAR` wires and the
architecture comparison would be vacuous. It is not, and the reason is physical: #15's
banking makes the memory lane of a bin the *high* bits of the bin index, so a fixed
assignment would send a fixed residue class of bins to each port forever, pinning each port
to one subset of memory lanes at a fixed duty cycle. The schedule therefore **rotates**:

```text
    port(g, j) = (j + g) mod BIN_PAR
```

so over `BIN_PAR` consecutive groups every port sees every beat position, and the inverse
map — which lane a response arriving on port *p* belongs to — is a different cyclic
permutation on every group.

#### The routing key is the response's own identity, not a side-channel tag

The obvious mechanism is a per-port FIFO of issued tags, popped one per response. It is
**rejected**, and the reason is the failure mode SPEC §7.4 exists to catch: a tag FIFO is
only correct while responses and tags stay in step, so the first dropped or duplicated
response silently mis-labels every response after it. The detector would be the thing that
breaks first.

The key is instead recomputed from the response's own metadata, which §3.4 already carries
inside `data`:

```text
    lane      j   = meta.bin[LANE_W-1:0]
    group     g   = meta.bin[BIN_W-1:LANE_W]
    entry   gid   = g mod GROUPS = g[GID_W-1:0]      (GROUPS is a power of two)
```

and the reassembly entry independently stores the `(group, frame_off, frame_id)` it was
allocated for. Consequences, and they are why the mechanism was chosen: a response that
never arrives is not mis-labelled as anything, it simply never sets its lane's present bit;
a response that arrives twice hits a lane whose present bit is already set, whatever the
skew; a response whose key does not match is an **orphan**, counted and dropped rather than
written over a live beat; and **no ordering assumption at all** is made about the response
streams, so a future out-of-order memory would not invalidate the network.

`frame_id` is part of the key and is carried through the routing network at its full 32
bits — about 6% of the routed word — because it is the only field that can answer "is every
antenna vector in this beat from the *same* frame". `frame_off` cannot: it is relative to
the newest complete frame, so two responses that both asked for offset 1 are from different
absolute frames if a rotation happened between them. Every lane of a beat must agree; the
first arrival fixes the value, and when several arrive in the same cycle before it is fixed
the lowest-numbered lane is the reference.

#### What an incomplete group emits

A group whose responses do not all arrive within `TIMEOUT_CYCLES` **cycles of progress** is
resolved rather than waited on forever. "Of progress" is load-bearing: the age counters
advance only in cycles where the block could have retired a beat, so a stalled consumer
never manufactures a missing-sample report.

The obvious policy — drop the beat — is wrong, because SPEC §5 is normative too: deleting a
beat breaks sequence continuity, and deleting the beat that carried `eof` leaves the frame
open forever. **The beat is emitted, the data is not**: absent lanes are zeroed (the
default), `ALGN_USER_MISSING` is set in the SPEC §5 `user` field, `stat_missing_count`
advances by the exact number of absent lanes, and `sequence`, `sof` and `eof` are exactly
what they would have been. `cfg_partial_pass = 1` keeps whatever did arrive, for diagnosis;
both settings are modelled and both are tested.

#### The `user` field of an output beat (NORMATIVE)

Four bits, LSB first, so a consumer that decodes only the SPEC §5 bundle can tell a
trustworthy beat from a repaired one: `MISSING` (0), `DUPLICATE` (1), `ORPHAN` (2), `HIST`
(3, the OR of §3.4's own response flags over the beat). `|user[3:0]` is "something was wrong
with this beat". The block's sticky `stat_fault` word is the same four bits in the same
order.

#### Modules

| Path | Parameters | Issue | Function |
|---|---|---|---|
| `rtl/align/align_pkg.sv` | — | #16 | Geometry, the schedule, the routing-key algebra, the routed-word layout, the `user` encoding, the architecture selector and the latency arithmetic. The one place any of them is defined. |
| `rtl/align/align_xbar.sv` | `N`, `DATA_W`, `MUX_STAGES` | #16 | **Architecture 1, direct registered crossbar.** One round-robin arbiter per output over every input, one registered mux tree per output over every input. `MUX_STAGES = 2` splits each mux into two levels of at most `ceil(sqrt(N)):1`, which is how SPEC §7.4's "no giant unregistered multiplexer" is met structurally rather than by argument. An output that stalls freezes its whole column, which is lossless by construction. |
| `rtl/align/align_clos.sv` | `N`, `DATA_W` | #16 | **Architecture 2, multistage omega network.** `log2(N)` stages of `N/2` two-by-two switches, perfect shuffle between stages, self-routing on one address bit per stage, per-switch round-robin arbitration between its own two inputs. Every link is a register, so the latency is `log2(N)`. The wiring is proved at elaboration over the whole `N × N` space and again at run time on every delivered word. |
| `rtl/align/align_switch.sv` | `N`, `DATA_W`, `NET_SEL`, `MUX_STAGES` | #16 | The one interface behind which the two are interchangeable. Nothing else in the design names either module. Checks the two architectures' latencies match and reports it when they do not. |
| `rtl/align/align_collect.sv` | the geometry, `TIMEOUT_CYCLES`, the SPEC §5 field widths, `OUT_DEPTH` | #16 | The reassembly buffer and the SPEC §7.4 detector. Common to both architectures and containing no knowledge of either, which is what makes the comparison a comparison. |
| `rtl/align/align_net.sv` | the geometry plus `NET_SEL`, `MUX_STAGES` | #16 | The block: scheduler, ingress decode, `align_switch`, `align_collect`, telemetry. Single clock (`history_clk`), so it adds no crossing to the SPEC §8 inventory — checked, not asserted. |
| `sim/verilator/tops/align_top.sv` | none | #16 | Verification top holding **four** elaborations: both architectures at `BIN_PAR = 4` and at `BIN_PAR = 8`, latency-matched at each, behind one port set. |
| `sim/assertions/align_assertions.sv` | `BIN_PAR`, `LANE_W`, `NET_DATA_W`, `BIN_W`, `VEC_W` | #16 | The SPEC §14 property set. `a_align_route_correct` is the central one: a word presented on lane *l* must be a word whose own bin index says it belongs at beat position *l*. |
| `quartus/calibration/align_sw_wrap.sv` | the geometry plus `NET_SEL`, `MUX_STAGES` | #16 | SPEC §18 wrapper for the **routing fabric alone** — the thing the two architectures are. |
| `quartus/calibration/align_net_wrap.sv` | as `align_net` | #16 | SPEC §18 wrapper for the **whole block**, which prices the part both builds share. |

#### Which architecture the design uses (MEASURED — SPEC §7.4)

**`ALGN_NET_CLOS`, the multistage omega network.** Both are built, both are verified by the
same suite, and both were compiled at two widths on `AGMF039R47B1E1VC`; the full table and
its caveats are in DECISIONS.md (issue #16). At the full-scale routing width — 8 lanes ×
16 antennas, a 566-bit routed word, both architectures at latency 3:

| | direct crossbar | multistage omega |
|---|---|---|
| ALMs | 18 492 | **13 946** (−24.6%) |
| ALM registers | 33 502 | **22 976** (−31.4%) |
| Fmax | 296.5 MHz | **≥ 624.6 MHz** |
| peak long-haul / short interconnect demand | 109% / 103% | **76% / 0%** |
| sustained throughput | 0.875 beats/cycle | 0.875 beats/cycle |

The congestion column is the mechanism: the crossbar's estimated interconnect demand exceeds
100% in its worst region, the router detours, and 2.128 ns of its critical path is wire
against 0.834 ns of logic. At 296 MHz it misses both the SPEC §2 450 MHz target and the
SPEC §8 400 MHz `history_clk`; the omega clears both. It blocks about 1.7× as often and
sustains exactly the same throughput anyway, because the reassembly buffer absorbs it.

`NET_SEL` is left at 0 — the SPEC §7.4 *reference* architecture — so that this issue's
default is the thing being compared against rather than its own conclusion; issue #17 sets
it to 1 when it instantiates the block in the pipeline. The crossbar stays in the tree
because §7.4 requires the comparison to be reproducible, and because a second architecture
behind one interface is what makes a later change cheap.

**Two measured defects issue #17 must fix before either form meets 400 MHz**, neither a
property of a topology and both in logic common to the two builds: the detector's verdict
and its counter increment share a cycle (11 levels of logic from the fabric's output
register into the duplicate counter), and `cfg_enable` is a single register driving most of
the block — a SPEC §23 chip-wide control net, to be replaced by the registered fanout §3.4
already demonstrates. DECISIONS.md findings 6 and 7 carry the numbers and the one-line
changes.

#### Flow control and the sustained rate

The scheduler issues all `BIN_PAR` requests of a group in one cycle or none of them, when
the block is enabled, a reassembly entry is free, and every request port can take a
request. The sustained rate is therefore **one beat per cycle — `BIN_PAR` bins per cycle —**
and every departure from it is one of those three conditions failing, which is what
`stat_issue_stall_count` counts.

`cfg_run` is the sweep gate and stops the block **at the next frame boundary**, never
mid-frame; a sweep in progress ignores it. It is separate from `cfg_enable` because
conflating them is a deadlock: `cfg_enable` low also stops the block accepting responses,
so a block disabled with work in flight would strand its own entries and report them as
missing samples.

The lane ports into the reassembly buffer are always ready, and that is a deadlock argument
rather than an optimisation: every word arriving on a lane belongs to an entry that is
already open, so refusing it could not free anything. Backpressure is applied one level
upstream, at group allocation, where refusing genuinely does bound the work in flight.

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

#### CFAR detector (`rtl/cfar/`, issue #14)

SPEC §7.7: a configurable one-dimensional CFAR detector over frequency bins with, at
minimum, cell averaging, a programmable guard-cell count, a programmable reference-cell
count, a programmable threshold multiplier, edge handling, detection metadata, and
detection suppression under invalid or incomplete windows.

```text
                      cfg: enable, mode, out_mode, guard_lead/lag,
                           ref_lead/lag, alpha        (latched at start-of-frame)
                                        |
  power stream ──> cfar_window ──> (S_lead, S_lag, N, cell, valid) ──> compare ──> event
  (1 bin/beat,     2D+1 slots,          |                              C·N·2^F     stream
   POWER_W,        masked sums          |                              > A·S       (sparse
   framed)         + validity           └── greatest-of side select                 or dense)
                                                                          |
                                                          elastic buffer ─┘
```

| Path | Parameters | Issue | Function |
|---|---|---|---|
| `rtl/packages/cfar_pkg.sv` | none (functions + widths) | #14 | The block's widths, the threshold multiplier's fixed-point format (unsigned Q8.8), the normative detection-event bit layout with its pack/unpack pair, and `cfar_over_threshold()` — the division-free comparison itself. Takes `CFAR_POWER_W` from `covar_pkg` *by reference*, so a change to SPEC §3's `POWER_W` moves the detector with it. Names its integer type `cfar_uint_t`, per DECISIONS.md (issue #10, decision 9). |
| `rtl/cfar/cfar_window.sv` | `POWER_W`, `MAX_GUARD`, `MAX_REF`, `BIN_W`, `SUM_W` | #14 | The sliding window: a `2D+1`-slot shift register (`D = MAX_GUARD + MAX_REF`) with a per-slot validity bit, two runtime-masked reference sums, and the completeness test. Owns the window GEOMETRY and nothing else — no threshold, no framing, no stream. |
| `rtl/cfar/cfar_core.sv` | `MAX_GUARD`, `MAX_REF`, `OUT_DEPTH`, stream geometry | #14 | The detector: SPEC §5 stream in and out, the frame state machine with its end-of-frame flush, the frame-boundary configuration latch and clamp, the four-stage arithmetic pipeline, the per-frame and cumulative counters, and the sticky fault bits. |
| `rtl/control/reg_block_cfar.sv` | `IDX_W` | #14 | The software half: the 0x6000 CFAR-settings window and the `STATUS_CLEAR` strobe. Checks its generated reset values and field widths against `cfar_pkg` at elaboration. |

Simulation-only companions:

| Path | Parameters | Issue | Function |
|---|---|---|---|
| `sim/verilator/tops/cfar_top.sv` | `MAX_GUARD_A/B`, `MAX_REF_A/B` | #14 | Verification top: the configured geometry plus a second elaboration at `MAX_GUARD = 0`, `MAX_REF = 3`, sharing one stimulus port with an observation mux. Exports the event both unpacked (field ports) and packed (three 64-bit words) so the test can unpack it independently. |
| `sim/assertions/cfar_assertions.sv` | `POWER_W`, `SUM_W`, `CMP_W`, `NTOT_W`, `ACT_W` | #14 | The SPEC §14 property set, instantiated inside `cfar_core`; see VERIFICATION_PLAN.md §5.13. |

**The comparison is division-free and exact.** The noise mean is never computed. Writing
`S` for the reference sum, `N` for the reference-cell count, `C` for the cell under test and
`A` for the integer in the alpha register (`A = alpha · 2^F`, `F = 8`):

```text
C > alpha·S/N   <=>   C·N·2^F  >  A·S
```

Both sides are exact integer products of quantities the datapath already holds, so the
decision is a total order on integers and the RTL and the C++ model agree bit for bit by
construction rather than by comparison. Two closed forms fall out and are directed tests: an
identically-zero spectrum detects nothing at any alpha, and a perfectly flat spectrum
detects nothing at alpha = 1.0 exactly (the comparison is strict).

**alpha is unsigned Q8.8, not Q1.15.** SPEC §6 fixes Q1.15 for samples and coefficients, and
alpha is neither: Q1.15 covers only `[−1, 1)` and a CFAR multiplier is essentially always
greater than one — the textbook design point `alpha = N(Pfa^(−1/N) − 1)` is ≈ 21.9 for 16
reference cells at `Pfa = 1e−6`. Q8.8 covers `[0, 255.996]` in steps of 1/256, keeps the
16-bit width the rest of the numeric plane uses, and quantises the threshold three orders of
magnitude finer than the statistical spread of the integrated powers being thresholded.

**Edge policy: suppress.** A bin whose complete programmed window does not lie inside the
frame raises no detection and is counted as suppressed — not evaluated against a shortened
window, not against mirrored data. Shrinking gives the edge bins a different reference count
and therefore a different false-alarm rate, which is precisely what a *constant*-false-alarm
detector must not have; mirroring lets a target near bin 0 raise its own threshold and
correlates the reference cells. The cost is stated rather than hidden: the first and last
`guard + reference` bins of every frame yield no detections, and the count is reported per
frame in the summary event and cumulatively in `CFAR_SUP_COUNT`.

**Cell averaging and greatest-of share one comparator.** Greatest-of is
`C > alpha·max(S_lead/N_lead, S_lag/N_lag)`, which is a *single* threshold test once the
larger mean is identified — and identifying it is one cross-multiply of a sum by a 6-bit
count. Selecting the side first also makes the emitted event self-consistent: the
`noise_sum` and `ref_count` it carries are the ones the decision actually used, so a
consumer that re-runs the comparison on the event's own fields reproduces the detector's
answer exactly.

**Configuration takes effect at a frame boundary, and only there.** The whole window is
latched into an active copy at the admitted start-of-frame beat. This is deliberately
stricter than the covariance engine's window-boundary rule (issue #13, decision 6): the
reference window spans `2D+1` bins, so a mid-frame change would be evaluated against cells
admitted under the old geometry for the following `D` bins, and a frame boundary is the only
instant at which the window is empty. A count above the elaborated maximum is clamped and
flagged rather than wrapped.

**Framing costs `D` cycles per frame.** A bin becomes the cell under test `D` advances after
it is admitted, so every frame ends with `D` phantom advances that push the tail through,
then a pipeline drain, then exactly one summary event carrying `end_of_frame`. `s_ready` is
driven from the *next* state, so no beat is accepted between `end_of_frame` and the summary
— which makes "a start-of-frame beat cannot arrive while a frame is open" structural rather
than an error case. Overlapping the flush with the next frame's input needs a second window
bank and a per-slot frame tag; it is a real optimisation and it is a SPEC §18 measurement
away, not an assumption.

### 3.6 Packet fabric (`rtl/packet/`)

The SPEC §7.8 event aggregator and packet network, in `packet_clk`. Populated by issue #18.
Sixteen ingress adapters, two stages of four radix-4 switches wired as a butterfly, sixteen
egress reassembly points, four virtual channels, `PACKET_W`-bit flits. The detection-event
payload it carries is normative as of issue #14; the packet format that wraps it is §6.4
below.

| Module | Role |
|---|---|
| `../packages/packet_pkg.sv` | normative packet format: the 36-bit header layout, the flit layout and its odd-parity rule, the flit-isation arithmetic, the legality predicates, and the butterfly wiring and routing functions. Every offset in the design and in the C++ model resolves through it |
| `pkt_rr_arb.sv` | the one arbiter: masked-priority round robin with a registered pointer that advances only when the caller CONSUMED the grant. Both arbitration levels of the switch are instances of it |
| `pkt_ingress.sv` | per-source adapter. Frames a message stream into flits, prepends the header, assigns the per-(source, VC) sequence number, buffers per VC, and drives the credit-controlled link. Checks the declared length against the framed flit count (SPEC §14) |
| `pkt_switch_stage.sv` | one RADIX x RADIX buffered switch: per-(port, VC) `sync_fifo`s, virtual-channel allocation, a REGISTER, switch allocation, credit counters both ways, the overtake fairness metric, and the credit-return fault hook. **The SPEC §18 item 9 calibration unit** |
| `pkt_egress.sv` | per-destination reassembly point: per-VC buffers, a per-VC-enabled output port, and five sticky checks — parity, length, VC-tag agreement, destination, packet type — re-derived from the flits that actually arrived |
| `pkt_fabric.sv` | the butterfly: N ingress, STAGES x (N/RADIX) switches, N egress, the wiring, the local credit loops, the fault-injection routing and the per-stage telemetry aggregation |

**Two arbitration levels separated by a register.** SPEC §7.8 forbids an unregistered
monolithic crossbar and asks for pipelined arbitration. The failure mode it is aiming at is an
iSLIP-style request/grant/accept loop resolved combinationally, whose cone grows with
RADIX x N_VC and which no amount of Hyper-Register retiming can break because the loop closes
inside one cycle (SPEC §23: "treat feedback-loop latency as an architectural constraint").
Here the VC allocator's result reaches the switch allocator only through the lock register, so
the longest arbitration cone is ONE `pkt_rr_arb` and the two levels retime independently. The
cost is one cycle of latency per hop on a packet's FIRST flit only; the lock persists for the
rest of the packet, so flits 2..L are switched one per cycle with no re-arbitration.

**Every credit loop is one hop long.** Ingress to stage 0, stage s to stage s+1, last stage to
egress: flits forward, a registered credit pulse back, both ends adjacent. No backward signal
crosses more than one hop and no combinational path runs from an egress consumer's `ready` to
an ingress producer's `ready`, which is what makes the fabric's timing independent of its
depth. The buffer-dependency graph is acyclic because every flit moves strictly forward, so
the network is deadlock-free without VC remapping or escape channels.

**What a virtual channel isolates, and what it does not.** An output VC is locked to one input
for the duration of a packet; the output PORT is not locked, so a channel with no credit drops
out of the switch allocation and the others keep the link busy. That is the SPEC §7.8 purpose
of virtual channels and it holds inside the fabric. It does NOT extend to an ingress port's
own message interface, which is serial: a producer half-way through handing over a packet on a
jammed channel cannot offer a different one. That is head-of-line blocking at the producer, it
is real, and the fix — if a later integration needs one — is a per-VC message interface per
port, not a change to the fabric.

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

As of issue #15 two of them carry real design logic:

| Domain | Constraint | What is in it |
|---|---|---|
| `core_clk` | 450 MHz | the whole processing datapath: PFB, FFT, beamformer, covariance, CFAR, and the WRITE side of the history (frame sequencers, rotation policy, the SPEC §9 history window) |
| `history_clk` | 400 MHz | the READ side of the history: request decode, the registered read fanout, the banks' read ports, the response stream and its three counters |
| `cfg_clk` | 100 MHz | coefficient and weight programming (issues #10, #12) |

The remaining domains are constrained in `quartus/constraints/clocks.sdc` and are populated
by later issues (`packet_clk` by #18, `memory_clk` by #24, `telemetry_clk` by #19).

The 450:400 ratio is 9:8, and `sim/tests/test_history.cpp` sweeps exactly that ratio and its
inverse alongside the shared table's gross ratios — a pointer crossing is least likely to be
accidentally safe at a ratio close to, but not equal to, one.

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
| `beamformer_top` | `sim/verilator/files_beamformer.f` | 47 | 0 |
| `history_top` | `sim/verilator/files_history.f` | 40 | 0 |

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

The history subsystem (issue #15) is the first block whose seam is between two PROCESSING
domains rather than between configuration and core, and it is the first appearance of
`history_clk`:

| Crossing | Mechanism | Direction | Payload |
|---|---|---|---|
| frame-pointer publication | `cdc_handshake` (four-phase) | core → history | `{force_unsafe, readable, depth, done_slot, frames_done}` as ONE transfer |
| counter clear | `cdc_pulse` (toggle) | core → history | 1-bit event |
| read-side counters | `cdc_handshake` (four-phase) | history → core | `{errors, collisions, reads}`, 96 bits, one transfer |
| the banks themselves | `history_bank_sdp`, **zero stages** | core → history | 32-bit words, `N_ANT × LANES` instances |

**The publication bundle is a handshake and not a Gray pointer**, which is worth stating
because a Gray pointer is the obvious choice and is wrong here. What the read side needs is
not one counter but a CONSISTENT SET. Gray coding guarantees only that a value sampled
mid-change resolves to the old or the new value of *that* counter; it says nothing about two
counters sampled together. A reader that took `done_slot` from after a depth change and
`depth` from before it would compute a slot belonging to neither configuration, silently.
`cdc_handshake` moves the whole bundle as one payload that never passes through a
synchroniser — the case SPEC §8's multibit prohibition explicitly carves out.

**The banks are tagged with `cdc_stages = "0"`, and that is the honest value.** A
`history_bank` contains no synchroniser; nothing in it makes it safe to read a word while it
is being written. What makes the design safe is the tagged pointer crossing above and the
readable-set bound derived from it. The inventory therefore shows a zero-stage bulk path
guarded by a tagged pointer crossing, which is the actual architecture rather than a
reassuring omission.

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

Two normative definitions live here. The DETECTION EVENT the CFAR detector emits
(`rtl/packages/cfar_pkg.sv`, issue #14) is the network's primary payload; the PACKET FORMAT
that wraps it, the virtual-channel rules, the topology and the flow control
(`rtl/packages/packet_pkg.sv`, issue #18) are how it travels. This section is the prose for
both, payload first.

#### The detection-event contract

A detection event is a **176-bit payload on a SPEC §5 stream**, plus the bundle's own
metadata. The payload width is CONFIGURATION-INDEPENDENT by construction: every field width
below is a constant of `cfar_pkg`, none is an elaboration parameter, because a packet format
that changed with the FFT size would have to be renegotiated at every SPEC §11 size.

```text
MSB                                                                          LSB
+-----------+-----------+-------+-------+-------+---------+----------+-----+------+
| noise_sum | cut_power |  sup  |  det  | alpha | ref_cnt | frame_id | bin | kind |
+-----------+-----------+-------+-------+-------+---------+----------+-----+------+
     47          40         16      16      16        7        16      16     2
```

| Field | Bits | Meaning |
|---|---|---|
| `kind` | 2 | `0` DETECT, `1` BIN, `2` SUPPRESSED, `3` SUMMARY |
| `bin` | 16 | frequency-bin index within the frame; on a SUMMARY, the frame LENGTH in bins |
| `frame_id` | 16 | the input stream's `seq` at the frame's start-of-frame beat |
| `ref_cnt` | 7 | number of reference cells the decision used (0 on SUPPRESSED and SUMMARY) |
| `alpha` | 16 | the threshold multiplier in force, unsigned Q8.8 |
| `det` | 16 | SUMMARY only: detections in this frame |
| `sup` | 16 | SUMMARY only: bins suppressed in this frame |
| `cut_power` | 40 | the cell under test's power, SPEC §3 `POWER_W` |
| `noise_sum` | 47 | the reference SUM the decision used (0 on SUPPRESSED and SUMMARY) |

**Stream metadata.** `stream_id` carries the BEAM identity (SPEC §5: `stream_id` is the
stream's identity, and a beam is what a CFAR instance is bound to). `seq` is the detector's
own per-beat counter, maintained **per beam** so that
`sim/assertions/stream_protocol_checker.sv`'s per-`stream_id` continuity property holds and
a consumer can detect real loss; a single global counter would report a false discontinuity
at every frame boundary once two beams interleave. `sof` marks the first emitted beat of a
frame and `eof` marks the SUMMARY.

**Framing rule.** Exactly one SUMMARY event is emitted per input frame, and it is the beat
carrying `end_of_frame`. A frame with no detections is therefore a well-formed one-beat
output frame with both `sof` and `eof` set — so the aggregator never has to distinguish
"no detections" from "frame lost", and `CFAR_FRAME_COUNT` and the number of `eof` beats are
the same number.

**Two output modes.** In EVENTS mode only DETECT events are emitted, plus the SUMMARY: the
operational mode, whose output rate is the detection rate rather than the bin rate. In DENSE
mode every bin is emitted as DETECT, BIN or SUPPRESSED, plus the same SUMMARY: the debug and
snapshot mode (issue #19), which makes the whole per-bin decision observable without a second
data path.

**Self-verifying by construction.** `(cut_power, noise_sum, ref_cnt, alpha)` are exactly the
four operands of the detector's comparison, so a consumer — the aggregator, a packet decoder,
or a host — can re-run `cut_power · ref_cnt · 2^8 > alpha · noise_sum` on the event's own
fields and reproduce the detector's answer bit for bit, with no division and no floating
point. That is why `alpha` rides in the event rather than being read from the register plane:
an event stays verifiable after the register changes.

**The noise estimate is a sum and a count, not a quotient.** The detector never divides
(§3.5), and adding a divider purely to fill in a metadata field would put the only inexact
operation in the block on the reporting path. A consumer that wants the mean computes
`noise_sum / ref_cnt` at whatever precision it needs; a consumer that wants to CHECK the
detection does not need the mean at all.

#### The packet format (issue #18)

`rtl/packages/packet_pkg.sv` is the definition; this is its prose. A **packet** is 1 to 32
flits. The first is the HEADER flit and carries no payload; the rest carry the payload,
`PACKET_W` bits at a time, least significant word first.

A **flit** is what the fabric moves in one cycle:

```text
MSB                                                     LSB
+-----------------------+-----+-----+------+--------+
|         data          | eof | sof |  vc  | parity |
+-----------------------+-----+-----+------+--------+
       PACKET_W            1     1     2       1
```

The CONTROL bits are at the bottom and the variable-width data field at the top — the inverse
of the `stream_pkg` rule, for the same reason stated the other way round: here it is the
control fields whose offsets must not move when `PACKET_W` changes between SPEC §11 sizes,
because every checker, every buffer tap and the C++ mirror address them by constant offset.

The **header** occupies the low 36 bits of the header flit's data field:

```text
MSB                                                              LSB
+---------+--------+--------+--------+--------+--------+
|   seq   | length |  type  |   vc   |  src   |  dest  |
+---------+--------+--------+--------+--------+--------+
    16        6        3        2        5        4      = 36 bits
```

| Field | Bits | Meaning |
|---|---|---|
| `dest` | 4 | egress port, 16 destinations |
| `src` | 5 | ingress port, 32 sources — SPEC §7.8 says "16 or more", and aggregation fans IN, so the source field is deliberately one binade wider than the destination field |
| `vc` | 2 | virtual channel, `N_VC = 4` |
| `type` | 3 | `0` detection, `1` power summary, `2` covariance summary, `3` error, `4` counter snapshot, `5` raw capture; `6` and `7` reserved and checkable |
| `length` | 6 | TOTAL flits INCLUDING the header, 1..32 |
| `seq` | 16 | packet sequence number per (source, VC) |

Every width above is a constant of `packet_pkg`, none is an elaboration parameter — the same
argument `cfar_pkg` makes for its 176-bit event, and the reason a captured packet decodes
identically at every SPEC §11 size. `PACKET_FORMAT` in the register plane reports the same
numbers so software needs no build-time header at all.

**Length is TOTAL, not payload-only,** because the invariant a checker wants to state is "the
number of flits between SOF and EOF inclusive equals the header's length field", and a
payload-only field makes that statement an arithmetic identity with an off-by-one in it. It is
checked twice: at the ingress against what the source declared, and at the egress against what
the network delivered. Those are different statements — eight switch stages of buffers,
arbiters and crossbars lie between them.

**Flit-isation.** `payload_flits = ceil(bits / PACKET_W)`, `total = 1 + payload_flits`. A
zero-payload packet is legal and is one flit carrying both SOF and EOF: an error event or a
counter-snapshot marker is a header and nothing else. A 176-bit detection event is 4 flits at
`PACKET_W = 64` and 2 at 512.

**Parity per flit, not a CRC per packet.** One odd parity bit over each flit's own data and
control bits. The reasons are structural: a per-flit check is verifiable AT EVERY HOP, so a
corruption is localised to a hop and a channel rather than merely detected at reassembly; it
is combinational and stateless, roughly `PACKET_W/3` ALMs per checked point, with no per-(input,
VC) CRC accumulator at every hop — which is what a packet CRC across deliberately interleaved
flits would need; and the dominant on-die failure this benchmark can express (a stuck bit, a
mis-wired mux, a flit written into the wrong VC) flips a small number of bits in one flit.

Odd rather than even parity, so an all-zero word — what an undriven or reset link presents —
is NOT a legal flit: "the link is dead" and "the link is carrying an empty flit" become
different observations.

**What parity does not catch is stated rather than discovered.** An EVEN number of bit errors
in one flit passes. Parity is therefore not the only integrity mechanism: the per-(source, VC)
sequence number catches loss, duplication and reordering regardless of content, the length
field catches truncation and extension, and the egress scoreboard compares every payload word.
`sim/tests/test_packet.cpp` injects a one-bit flip (parity fires) and a two-bit flip (parity is
silent, the payload comparison fires), so the limit is a measured property of the design.

#### Virtual channels and ordering (issue #18)

Four channels. Ordering is guaranteed **within a (source, VC, destination) triple** and is not
claimed across VCs — two packets from one source to one destination on different channels may
arrive in either order, which is what a virtual channel is for. The guarantee comes from two
facts and needs no reorder buffer: destination-tag routing over the butterfly gives every
triple exactly ONE path, and an output VC is locked to one input for the whole of a packet so
its flits stay contiguous on that path.

#### Topology: an R-ary butterfly, and why not a crossbar (issue #18)

`N = RADIX**STAGES` ports; the nominal network is 16 ports as two stages of radix 4. Stage `s`
routes on destination digit `STAGES-1-s`, most significant first. At stage `s` a switch is
named by the port index with that digit deleted, and a port's position inside it is that digit;
`pkt_bfly_insert()` puts the digit back, and the same function maps a switch output to the next
stage's wire, so the topology is ONE function rather than two tables that can disagree.

The rejected alternative is the obvious one, and SPEC §7.8 rejects it in words ("Do not build
one unregistered, monolithic crossbar"). The routability argument is why the words are there: a
16x16 crossbar at 512-bit flits is 256 crosspoints, each a 517-bit-wide mux input, with all 16
output muxes reaching all 16 inputs — 16 x 16 x 517 = 132 k wires converging on 16 points. On
Agilex 7 that is a routing-congestion problem before it is an ALM problem. The two-stage
radix-4 butterfly is 8 switches of 16 crosspoints: 128 crosspoints, each mux reaching 4 inputs,
and the inter-stage wiring is a FIXED PERMUTATION of 16 point-to-point flit buses rather than
an all-to-all. Same bisection, half the crosspoints, and — the part that matters for HyperFlex
— a registered hop between the halves.

A fat tree was the other candidate and is not built. It buys path diversity, which buys nothing
here: the traffic is aggregation (many sources, few sinks), and adaptive routing would destroy
the in-order-per-triple property that makes the egress checkable with a sequence number instead
of a reorder buffer. Determinism is worth more than diversity for this workload.

#### Flow control: credits, not ready (issue #18)

SPEC §7.8 allows either. Credits are used because a returned `ready` would be a combinational
path from a downstream buffer's full flag, across a port boundary, into an upstream output mux
— precisely the ready chain SPEC §5 forbids and SPEC §23 asks to be broken with elastic
buffers. A credit counter replaces it with a registered pulse in the opposite direction:
nothing downstream is in an upstream sender's timing cone at all. Every counter resets to the
downstream buffer's depth, decrements on a send and increments on a returned credit; a flit is
sent only when the count is non-zero, so no buffer can overflow, and both bounds are asserted
on every cycle in the RTL rather than argued for here.

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
| `power_calc` | `PIPE_STAGES` (1–3), default 2 | 1 sample/cycle, no backpressure | #13 |
| `integrator` | 1 (the result registers on the closing edge) | 1 sample/cycle, no backpressure | #13 |
| `cfar_window` | 1 register + `D` **advances** (`D = MAX_GUARD + MAX_REF`) | 1 bin/advance | #14 |
| `cfar_core` | `D` advances + 4 pipeline registers + the output elastic buffer | 1 bin/cycle within a frame; `D + 5` dead cycles per frame boundary | #14 |

The CFAR detector's latency is counted the way the FFT's is — partly in **advances** and
partly in cycles — for the same reason and with the same consequence. A bin cannot be
evaluated until its leading reference cells have arrived, which is `D` advances after it is
admitted, and advances happen only on an admitted beat or on a flush step. The per-frame
overhead is therefore `D` phantom advances plus the pipeline drain plus the summary beat,
which at the SPEC §11 tiny geometry (64 bins, `D = 10`) is about a quarter of the frame
period. That is the block's largest throughput claim and it is a measured consequence of the
window depth rather than of the implementation; the optimisation that removes it is a second
window bank, and taking it is a SPEC §18 decision.

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
