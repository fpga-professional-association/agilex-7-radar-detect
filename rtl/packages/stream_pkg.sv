// -----------------------------------------------------------------------------
// stream_pkg — the canonical streaming bundle (SPEC.md 5).
//
// SPEC 5 mandates one common synthesizable streaming interface used at every
// module boundary in the design:
//
//     valid / ready / data / start_of_frame / end_of_frame / stream_id /
//     sequence / user
//
// This package is the single definition of that bundle's *payload* half: the
// field set, the field order, the bit positions each field occupies in the
// packed payload vector, and the pack/unpack functions that are the only
// sanctioned way to move between the two views. Every module boundary in the
// design, the assertion checkers, and the C++ harness all resolve field
// positions through this file.
//
// THE RULE (the reason the file exists, stated the way SPEC 6 states its own)
// --------------------------------------------------------------------------
// No module may invent its own field order or its own concatenation. A module
// that writes `{data, sof, eof, id, seq, user}` inline is a defect even when the
// order happens to be right, because the next module will write it differently
// and the two will pass every test that only ever pairs them with themselves.
// Call stream_pack() / stream_unpack().
//
// Transport convention (DECISIONS.md 2026-07-26, decision 1)
// ----------------------------------------------------------
// The bundle travels as THREE ports — `valid`, `ready`, and one packed payload
// vector — not as a SystemVerilog interface. Measured reason: Verilator 5.020
// rejects an interface on a top-level module port
// ("%Error-UNSUPPORTED: Interfaced port on top level module", plus an internal
// error in V3LinkDot), and the SPEC 12.2 C++ harness drives the DUT exactly
// there. Structs and flat vectors work identically in Verilator and Quartus Pro.
// Full rationale and the alternatives rejected are in DECISIONS.md.
//
// Field naming: `seq`, not `sequence` (DECISIONS.md 2026-07-26, decision 2)
// ------------------------------------------------------------------------
// SPEC 5 names the field `sequence`, which is a SystemVerilog keyword and is
// therefore illegal as a struct member, a variable, or an unprefixed port. The
// project-wide spelling of the field is `seq`: it is the only spelling legal in
// every context, so one token names the field everywhere — in this package, in
// module ports (`s_seq` / `m_seq`), in the C++ mirror, and in the generated
// configuration. The one exception is `rtl/top/benchmark_fabric_top.sv`
// (issue #3), which predates this package and uses `in_sequence` /
// `out_sequence`; it is retired when that top is rebuilt on these primitives.
//
// Working types
// -------------
// Field widths are per-instance parameters, and SystemVerilog has no
// parameterised functions (IEEE 1800-2017 has no `function #(...)`), so the
// functions here work on maximum-width types and take the instance geometry as
// an argument — the same solution, for the same reason, that fxp_pkg uses for
// its 64-bit working type. `stream_geom_t` carries the four field widths;
// `stream_fields_t` is the unpacked view at maximum widths; `stream_payload_t`
// is the packed view at maximum width. A module's real payload vector is
// `stream_payload_w(GEOM)` bits wide and is produced by casting the function
// result down, which keeps the instance width visible in the RTL.
//
// Lint contract: linted by `make lint` on every run, clean under --Wall with no
// waiver.
// -----------------------------------------------------------------------------

`default_nettype none

package stream_pkg;

  // ---------------------------------------------------------------------------
  // Working types
  // ---------------------------------------------------------------------------

  // Unsigned 32-bit integer type, so widths and offsets can be cast explicitly
  // (`uint_t'(x)`); `int unsigned'(x)` is not legal cast syntax. Same device as
  // fxp_pkg::uint_t, deliberately spelled the same way.
  typedef int unsigned uint_t;

  // Maximum field widths. These are not design widths: they bound the working
  // type, exactly as fxp_pkg::FXP_WIDE_W bounds the numeric one. A configuration
  // that needs more must widen these and re-run the layout consistency check in
  // benchmark_sim_top, which is what makes the bound testable rather than
  // assumed.
  //
  // Sized from SPEC 11 full_agmf039 with headroom: DATA carries one complex
  // sample pair (2 x SAMPLE_W = 32) today and a wider beat later; STREAM_ID
  // covers 256 concurrent streams against 16 antennas at full scale; SEQ at 32
  // bits does not wrap inside any test this project runs (SPEC 13.4's long
  // stress test is bounded well below 4 G beats).
  localparam int unsigned STREAM_MAX_DATA_W = 64;
  localparam int unsigned STREAM_MAX_ID_W   = 8;
  localparam int unsigned STREAM_MAX_SEQ_W  = 32;
  localparam int unsigned STREAM_MAX_USER_W = 8;

  // start_of_frame + end_of_frame. Named rather than written as 2 so that the
  // payload-width arithmetic below states what it is counting.
  localparam int unsigned STREAM_FLAG_W = 2;

  localparam int unsigned STREAM_MAX_PAYLOAD_W =
      STREAM_MAX_DATA_W + STREAM_FLAG_W + STREAM_MAX_ID_W +
      STREAM_MAX_SEQ_W + STREAM_MAX_USER_W;

  // Packed view at maximum width. A real interface uses only the low
  // stream_payload_w(GEOM) bits.
  typedef logic [STREAM_MAX_PAYLOAD_W-1:0] stream_payload_t;

  // Unpacked view at maximum width. Declaration order is the packed field order
  // (data at the top, user at the bottom); the offset functions below are the
  // normative statement of that order, and this struct must agree with them —
  // stream_pack()/stream_unpack() are written against the functions, never
  // against the struct layout, so the two cannot silently diverge.
  typedef struct packed {
    logic [STREAM_MAX_DATA_W-1:0] data;
    logic                         sof;   // start_of_frame
    logic                         eof;   // end_of_frame
    logic [STREAM_MAX_ID_W-1:0]   stream_id;
    logic [STREAM_MAX_SEQ_W-1:0]  seq;
    logic [STREAM_MAX_USER_W-1:0] user;
  } stream_fields_t;

  // Per-instance geometry: the four parameterised field widths. Passed to every
  // function here, and normally held as a module localparam:
  //
  //     localparam stream_pkg::stream_geom_t GEOM =
  //         stream_pkg::stream_geom(DATA_W, STREAM_ID_W, SEQ_W, USER_W);
  //     localparam int unsigned PAYLOAD_W =
  //         int'(stream_pkg::stream_payload_w(GEOM));
  typedef struct packed {
    uint_t data_w;
    uint_t id_w;
    uint_t seq_w;
    uint_t user_w;
  } stream_geom_t;

  function automatic stream_geom_t stream_geom(input uint_t data_w,
                                               input uint_t id_w,
                                               input uint_t seq_w,
                                               input uint_t user_w);
    stream_geom_t g;
    g.data_w = data_w;
    g.id_w   = id_w;
    g.seq_w  = seq_w;
    g.user_w = user_w;
    return g;
  endfunction

  // True when every field fits its working-type bound and no field is empty.
  // Instances check this at elaboration; see stream_skid_buffer.sv for the
  // pattern.
  function automatic logic stream_geom_ok(input stream_geom_t g);
    return (g.data_w >= 1) && (g.data_w <= STREAM_MAX_DATA_W) &&
           (g.id_w   >= 1) && (g.id_w   <= STREAM_MAX_ID_W)   &&
           (g.seq_w  >= 1) && (g.seq_w  <= STREAM_MAX_SEQ_W)  &&
           (g.user_w >= 1) && (g.user_w <= STREAM_MAX_USER_W);
  endfunction

  // ---------------------------------------------------------------------------
  // Canonical field order  (NORMATIVE)
  //
  //   MSB                                                                 LSB
  //   +--------+-----+-----+-----------+---------+--------+
  //   |  data  | sof | eof | stream_id |   seq   |  user  |
  //   +--------+-----+-----+-----------+---------+--------+
  //
  // Rationale for the order: `user` at bit 0 and `data` at the top means that
  // widening `data` — the field most likely to change between configurations —
  // moves no other field's offset, so a payload captured in a waveform or a log
  // stays readable across a resize. The order also reproduces exactly the
  // concatenation the provisional issue #2 loopback used, so the change from
  // provisional to canonical is a change of mechanism, not of bits.
  //
  // Everything downstream — the assertion checkers, the C++ harness, the
  // generated configuration header — derives its offsets from these six
  // functions. Nothing recomputes them by hand.
  // ---------------------------------------------------------------------------

  // Field selector for stream_layout_bit(). `_END` is the bit one past the top
  // of the payload — i.e. the payload width — so that one function computes
  // every boundary in the layout from one expression chain.
  typedef enum int unsigned {
    STREAM_SEL_USER = 0,
    STREAM_SEL_SEQ  = 1,
    STREAM_SEL_ID   = 2,
    STREAM_SEL_EOF  = 3,
    STREAM_SEL_SOF  = 4,
    STREAM_SEL_DATA = 5,
    STREAM_SEL_END  = 6
  } stream_sel_e;

  // The one place the layout arithmetic exists. Every accessor below is a thin
  // wrapper on it, which is deliberate: a second expression for any boundary is
  // a second definition of the layout.
  function automatic uint_t stream_layout_bit(input stream_geom_t g,
                                              input stream_sel_e sel);
    case (sel)
      STREAM_SEL_USER: return 32'd0;
      STREAM_SEL_SEQ:  return g.user_w;
      STREAM_SEL_ID:   return g.user_w + g.seq_w;
      STREAM_SEL_EOF:  return g.user_w + g.seq_w + g.id_w;
      STREAM_SEL_SOF:  return g.user_w + g.seq_w + g.id_w + 32'd1;
      STREAM_SEL_DATA: return g.user_w + g.seq_w + g.id_w + 32'd2;
      STREAM_SEL_END:  return g.user_w + g.seq_w + g.id_w + 32'd2 + g.data_w;
      default:         return 32'd0;
    endcase
  endfunction

  function automatic uint_t stream_user_lsb(input stream_geom_t g);
    return stream_layout_bit(g, STREAM_SEL_USER);
  endfunction

  function automatic uint_t stream_seq_lsb(input stream_geom_t g);
    return stream_layout_bit(g, STREAM_SEL_SEQ);
  endfunction

  function automatic uint_t stream_id_lsb(input stream_geom_t g);
    return stream_layout_bit(g, STREAM_SEL_ID);
  endfunction

  function automatic uint_t stream_eof_lsb(input stream_geom_t g);
    return stream_layout_bit(g, STREAM_SEL_EOF);
  endfunction

  function automatic uint_t stream_sof_lsb(input stream_geom_t g);
    return stream_layout_bit(g, STREAM_SEL_SOF);
  endfunction

  function automatic uint_t stream_data_lsb(input stream_geom_t g);
    return stream_layout_bit(g, STREAM_SEL_DATA);
  endfunction

  // Total width of the packed payload for this geometry. This is the width of
  // every `*_payload` port in the design.
  function automatic uint_t stream_payload_w(input stream_geom_t g);
    return stream_layout_bit(g, STREAM_SEL_END);
  endfunction

  // ---------------------------------------------------------------------------
  // Pack / unpack
  // ---------------------------------------------------------------------------

  // `w` low bits set. w == 0 yields 0; w >= STREAM_MAX_PAYLOAD_W yields all ones.
  function automatic stream_payload_t stream_mask(input uint_t w);
    if (w == 32'd0) return '0;
    if (w >= uint_t'(STREAM_MAX_PAYLOAD_W)) return '1;
    return (stream_payload_t'(1) << w) - stream_payload_t'(1);
  endfunction

  // Fields -> packed payload. Fields wider than their geometry are truncated,
  // never wrapped into a neighbour: every field is masked before it is shifted.
  function automatic stream_payload_t stream_pack(input stream_geom_t g,
                                                  input stream_fields_t f);
    stream_payload_t p;
    p = '0;
    p = p | ((stream_payload_t'(f.user)      & stream_mask(g.user_w)) << stream_user_lsb(g));
    p = p | ((stream_payload_t'(f.seq)       & stream_mask(g.seq_w))  << stream_seq_lsb(g));
    p = p | ((stream_payload_t'(f.stream_id) & stream_mask(g.id_w))   << stream_id_lsb(g));
    p = p | (stream_payload_t'(f.eof)                                 << stream_eof_lsb(g));
    p = p | (stream_payload_t'(f.sof)                                 << stream_sof_lsb(g));
    p = p | ((stream_payload_t'(f.data)      & stream_mask(g.data_w)) << stream_data_lsb(g));
    return p;
  endfunction

  // Packed payload -> fields. Bits above stream_payload_w(g) are ignored; every
  // returned field is zero-extended from its geometry width, so a round trip
  // through pack/unpack is the identity on any value that fits the geometry.
  function automatic stream_fields_t stream_unpack(input stream_geom_t g,
                                                   input stream_payload_t p);
    stream_fields_t f;
    f           = '0;
    f.user      = STREAM_MAX_USER_W'((p >> stream_user_lsb(g)) & stream_mask(g.user_w));
    f.seq       = STREAM_MAX_SEQ_W'((p >> stream_seq_lsb(g))  & stream_mask(g.seq_w));
    f.stream_id = STREAM_MAX_ID_W'((p >> stream_id_lsb(g))    & stream_mask(g.id_w));
    f.eof       = p[stream_eof_lsb(g)];
    f.sof       = p[stream_sof_lsb(g)];
    f.data      = STREAM_MAX_DATA_W'((p >> stream_data_lsb(g)) & stream_mask(g.data_w));
    return f;
  endfunction

  // ---------------------------------------------------------------------------
  // Structural latency of the canonical primitives
  //
  // Exported as constants so that a consumer states its own latency by summing
  // the primitives it instantiates rather than by writing a number that drifts
  // when a primitive changes. `benchmark_sim_top` checks the sum against the
  // value the C++ harness was generated with, at time 0, on every run.
  //
  // Latency here means: cycles from the edge at which a beat is accepted on the
  // slave side to the edge at which it is presented on the master side, with no
  // backpressure on either side. Under backpressure there is no fixed latency
  // and SPEC 12.5 forbids assuming one.
  // ---------------------------------------------------------------------------

  // Exported as functions rather than as localparams on purpose: a package
  // localparam that a given build happens not to instantiate is reported as a
  // dead parameter by `verilator --lint-only --Wall`, and the design is meant to
  // be lintable one top at a time (files_stream.f, files_violator.f, files.f).
  // A function is available to every build and dead in none.

  function automatic uint_t stream_skid_latency();     // stream_skid_buffer
    return 32'd1;
  endfunction

  function automatic uint_t stream_elastic_latency();  // stream_elastic_buffer
    return 32'd1;
  endfunction

  // stream_pipe: STAGES free-running register stages plus its output elastic
  // buffer.
  function automatic uint_t stream_pipe_latency(input uint_t stages);
    return stages + stream_elastic_latency();
  endfunction

  // Width of an occupancy counter that must represent 0..depth inclusive.
  function automatic uint_t stream_occ_w(input uint_t depth);
    return uint_t'($clog2(depth + 32'd1));
  endfunction

endpackage : stream_pkg

`default_nettype wire
