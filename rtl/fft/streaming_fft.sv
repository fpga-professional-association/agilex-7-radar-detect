// -----------------------------------------------------------------------------
// streaming_fft — the SPEC 7.2 streaming FFT as a SPEC 5 stream block.
//
// fft_core is the transform. This module is everything that makes it a citizen
// of the design: the elastic boundary, the frame tracking, the position tag the
// core needs, the optional bit-reversal reorder, and the flow control that lets
// a fixed-latency arithmetic pipeline live behind a ready/valid interface.
//
//   s_* --> [elastic] --> [ fft_core ] --> [reorder] --> [ output FIFO ] --> m_*
//              in           valid-tagged      opt.          credit-backed
//                           fixed latency
//            metadata ------------------------> [ metadata FIFO ] ----^
//
// -----------------------------------------------------------------------------
// 1. Flow control: why the core is never stalled
// -----------------------------------------------------------------------------
// The obvious way to put a DSP pipeline behind a ready/valid interface is a
// clock enable on every register, driven by the downstream ready. This design
// deliberately does not do that, for two reasons that are not matters of taste:
//
//   * SPEC 23 says, in order: "Avoid one chip-wide clock enable", "Pipeline
//     enables before broad distribution", "Keep pipeline stages latency-
//     insensitive", "Break ready/valid feedback with elastic buffers". A
//     ready-driven enable on every DSP and every memory in the transform is the
//     first of those, verbatim.
//   * rtl/common/complex_multiplier.sv — the SPEC 6 kernel this FFT multiplies
//     with, verified and calibrated by issue #9 — has NO clock enable on its
//     datapath, by an explicit decision recorded in its own header: putting
//     m_ready on the enable of every DSP register is what its pipeline shape was
//     chosen to avoid. Stalling the FFT internally would mean either changing
//     that kernel, invalidating its calibration, or not using it.
//
// So the core is a VALID-TAGGED, GAP-TOLERANT pipeline. Each stage's registers
// advance on a local, pipelined beat-valid; a cycle with no beat simply does not
// advance the delay feedback. Nothing downstream can stop it once a beat is in.
//
// Backpressure is therefore applied at the INPUT, by a credit counter that
// reserves an output-FIFO slot for every beat admitted:
//
//     credit = OUT_DEPTH - (beats admitted - beats delivered)
//     admit a beat only while credit > 0
//
// which bounds (FIFO occupancy + beats in flight) by OUT_DEPTH at all times.
// The number of beats in flight is exactly the pipeline's latency, so the FIFO
// is sized from fft_pkg::fft_total_latency() plus OUT_SLACK — derived, not
// guessed, and the slack is what sustains full throughput while the consumer is
// keeping up. That FIFO is the price of the two bullet points above and it is
// stated plainly in DECISIONS.md rather than buried: roughly one M20K for the
// 64-point / 2-SPC configuration.
//
// -----------------------------------------------------------------------------
// 2. Frames and metadata
// -----------------------------------------------------------------------------
// One frame is FFT_SIZE samples, i.e. M = FFT_SIZE/SAMPLES_PER_CYCLE beats,
// start_of_frame on the first and end_of_frame on the last. `idx_q` is the
// beat's position in its frame and is what fft_core's control is read from; it
// is RESET by start_of_frame and CHECKED against it, so a producer that
// mis-frames is a named assertion failure rather than a silently wrong spectrum.
//
// The output is a transform of the whole frame, so no output beat "is" a
// particular input beat. The metadata is nevertheless carried through
// positionally — output beat k of a frame carries the metadata of input beat k
// of that frame — through a FIFO pushed on admission and popped on delivery.
// That convention is what keeps stream_id, the sequence number and the frame
// flags meaningful end to end, so the SPEC 5 loss/ordering checks and the issue
// #8 sequence checker work across the FFT exactly as they do across a FIFO.
//
// A FIFO rather than a delay line, on purpose: the core's latency is a fixed
// number of BEATS but not a fixed number of CYCLES (its delay feedbacks advance
// on beats while its multipliers free-run), so a shift register would have to
// reproduce the core's internal structure to stay aligned. A FIFO pushed by
// admission and popped by delivery is aligned by construction, and the assertion
// below — the popped start_of_frame must coincide with position 0 out of the
// core — is what turns fft_pkg's latency arithmetic into a checked fact.
//
// -----------------------------------------------------------------------------
// 3. Output order and the REORDER parameter
// -----------------------------------------------------------------------------
//   REORDER = 0   beat j carries X[bitrev(j)] and X[bitrev(j) + N/2]
//   REORDER = 1   beat j carries X[j]         and X[j + N/2]
//
// Both are bit-exact against the reference model, which applies the same
// permutation from the same parameter. Reordering costs one frame of latency and
// two banks of FFT_SIZE/SAMPLES_PER_CYCLE beats; the corner-turn memory of issue
// #15 addresses its write side arbitrarily and can absorb the permutation for
// nothing, so the parameter exists to let that decision be made when #15 lands
// rather than being pre-empted here. See fft_reorder.sv and DECISIONS.md.
//
// -----------------------------------------------------------------------------
// 4. Flush
// -----------------------------------------------------------------------------
// The pipeline is indexed by sample position, not by time: a frame's output
// requires fft_total_latency() FURTHER beats to be admitted before it emerges.
// In continuous operation — which is what a radar front end is — that is
// invisible. A test that drives a finite number of frames must drive that many
// more beats to see the last of them, and sim/tests/test_fft.cpp does.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module streaming_fft
  import fxp_pkg::*;
  import stream_pkg::*;
  import fft_pkg::*;
#(
    parameter int unsigned FFT_SIZE          = 64,
    parameter int unsigned SAMPLES_PER_CYCLE = 2,

    // One bit per butterfly sub-stage; see fft_pkg section 4. All-ones is the
    // 1/N scaled schedule and cannot overflow.
    parameter int unsigned SCALE_SCHED       = 32'hFFFF_FFFF,

    // 1: emit bins in natural beat order. 0: leave them bit-reversed.
    parameter int unsigned REORDER           = 1,

    // SPEC 5 metadata geometry. DATA_W is derived, not a parameter: it is
    // SAMPLES_PER_CYCLE complex Q1.15 samples and nothing else.
    parameter int unsigned STREAM_ID_W       = 2,
    parameter int unsigned SEQ_W             = 16,
    parameter int unsigned USER_W            = 4,

    // Twiddle multiplier configuration (issue #9 measured defaults).
    parameter string       TW_VARIANT        = "MULT4",
    parameter int unsigned TW_PIPE           = 4,
    parameter int unsigned TW_ROM_OUT_REG    = 1,

    // SPEC 18 memory-geometry axes.
    parameter string       MEM_STYLE         = "DEFAULT",
    parameter string       TW_STYLE          = "AUTO",
    parameter string       REORDER_STYLE     = "AUTO",
    parameter string       FIFO_STORAGE      = "mlab",

    // Input elastic buffer depth, and free slots reserved above the pipeline's
    // own latency in the output FIFO.
    parameter int unsigned IN_DEPTH          = 4,
    parameter int unsigned OUT_SLACK         = 8,

    parameter int unsigned FLAG_COUNT_W      = 32,

    // DERIVED, NOT A KNOB. SystemVerilog has no way to declare a localparam
    // between the parameter list and the port list, and the payload width is
    // needed by both, so it is a parameter with a derived default. Overriding it
    // is a $fatal at elaboration: the SPEC 5 layout is stream_pkg's to define,
    // not an instantiation's.
    parameter int unsigned PAYLOAD_W_DERIVED =
        int'(stream_payload_w(stream_geom(SAMPLES_PER_CYCLE*32,
                                          STREAM_ID_W, SEQ_W, USER_W)))
) (
    input  wire  clk,
    input  wire  rst_n,

    // SPEC 5 slave side.
    input  wire                         s_valid,
    output wire                         s_ready,
    input  wire [PAYLOAD_W_DERIVED-1:0] s_payload,

    // SPEC 5 master side.
    output wire                         m_valid,
    input  wire                         m_ready,
    output wire [PAYLOAD_W_DERIVED-1:0] m_payload,

    // SPEC 6 saturation reporting, per butterfly sub-stage (see fft_core).
    input  wire                             flags_clear,
    output wire [$clog2(FFT_SIZE)-1:0][1:0] stage_flags,
    output wire                             any_ovf,
    output wire [FLAG_COUNT_W-1:0]          ovf_events
);

  // ---------------------------------------------------------------------------
  // Geometry — all of it derived, none of it repeated
  // ---------------------------------------------------------------------------
  localparam int unsigned P      = SAMPLES_PER_CYCLE;
  localparam int unsigned M      = FFT_SIZE / P;
  localparam int unsigned N_LANE = $clog2(M);
  localparam int unsigned DATA_W = P * 32;

  localparam stream_geom_t GEOM =
      stream_geom(DATA_W, STREAM_ID_W, SEQ_W, USER_W);
  localparam int unsigned PAYLOAD_W = int'(stream_payload_w(GEOM));
  localparam int unsigned DATA_LSB  = int'(stream_data_lsb(GEOM));
  localparam int unsigned META_W    = DATA_LSB;   // data is the top field
  localparam int unsigned SOF_LSB   = int'(stream_sof_lsb(GEOM));
  localparam int unsigned EOF_LSB   = int'(stream_eof_lsb(GEOM));

  localparam int unsigned ROM_LAT   = 1 + TW_ROM_OUT_REG;
  localparam int unsigned CORE_LAT  =
      int'(fft_core_latency(fft_uint_t'(FFT_SIZE), fft_uint_t'(P),
                            fft_uint_t'(ROM_LAT), fft_uint_t'(TW_PIPE)));
  localparam int unsigned TOTAL_LAT =
      int'(fft_total_latency(fft_uint_t'(FFT_SIZE), fft_uint_t'(P),
                             fft_uint_t'(ROM_LAT), fft_uint_t'(TW_PIPE),
                             REORDER != 0));

  // Sized from the latency, not chosen: every beat in flight must have a slot.
  //
  // Rounded up to a multiple of eight. Two reasons, and neither is cosmetic: a
  // memory-backed FIFO is built out of words, so a granular depth is what the
  // Fitter can actually pack; and a multiple of eight is even, which matters
  // because a depth of exactly 2^k - 1 makes the occupancy counter's bound the
  // all-ones code and turns sync_fifo's own `count_q <= DEPTH` assertion into a
  // tautology — measured: the 64-point REORDER = 0 configuration lands on 63
  // exactly, and Verilator reports the assertion as a constant comparison.
  localparam int unsigned OUT_DEPTH  = ((TOTAL_LAT + OUT_SLACK + 7) / 8) * 8;
  localparam int unsigned META_DEPTH = ((TOTAL_LAT + 2 + 7) / 8) * 8;
  localparam int unsigned CREDIT_W   = $clog2(OUT_DEPTH + 1);

`ifndef SYNTHESIS
  initial begin
    // The two latencies must agree with each other: the total is the core plus
    // the reorder buffer and nothing else. Written as a check rather than as a
    // second expression, so a change to either function is caught here.
    if (TOTAL_LAT != (CORE_LAT +
        ((REORDER != 0) ? int'(fft_reorder_latency(fft_uint_t'(FFT_SIZE), fft_uint_t'(P)))
                        : 0))) begin
      $fatal(1, "streaming_fft: fft_total_latency=%0d but core=%0d + reorder=%0d",
             TOTAL_LAT, CORE_LAT,
             (REORDER != 0) ? fft_reorder_latency(fft_uint_t'(FFT_SIZE), fft_uint_t'(P)) : 0);
    end
    if (!fft_size_ok(fft_uint_t'(FFT_SIZE), fft_uint_t'(P))) begin
      $fatal(1, "streaming_fft: FFT_SIZE=%0d / SAMPLES_PER_CYCLE=%0d is not legal",
             FFT_SIZE, P);
    end
    if (!fft_spc_supported(fft_uint_t'(P))) begin
      $fatal(1, "streaming_fft: SAMPLES_PER_CYCLE=%0d is not verified by issue #11",
             P);
    end
    if (!stream_geom_ok(GEOM)) begin
      $fatal(1, "streaming_fft: stream geometry (data %0d, id %0d, seq %0d, user %0d) exceeds stream_pkg's bounds",
             DATA_W, STREAM_ID_W, SEQ_W, USER_W);
    end
    if (REORDER > 1) begin
      $fatal(1, "streaming_fft: REORDER=%0d is not 0 or 1", REORDER);
    end
    if (OUT_SLACK < 2) begin
      $fatal(1, "streaming_fft: OUT_SLACK=%0d is too small to sustain throughput",
             OUT_SLACK);
    end
    if (PAYLOAD_W_DERIVED != PAYLOAD_W) begin
      $fatal(1, "streaming_fft: PAYLOAD_W_DERIVED=%0d was overridden; stream_pkg says %0d",
             PAYLOAD_W_DERIVED, PAYLOAD_W);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Input elastic buffer — the SPEC 5 ready break
  //
  // s_ready is this buffer's registered ready and is a function of its own
  // occupancy only, so nothing downstream — not m_ready, not the credit counter
  // — reaches the slave interface combinationally.
  // ---------------------------------------------------------------------------
  logic                 ebi_valid, ebi_ready;
  logic [PAYLOAD_W-1:0] ebi_payload;
  logic [$clog2(IN_DEPTH+1)-1:0] ebi_occ;

  stream_elastic_buffer #(
      .PAYLOAD_W   (PAYLOAD_W),
      .DEPTH       (IN_DEPTH),
      .DATA_W      (DATA_W),
      .STREAM_ID_W (STREAM_ID_W),
      .SEQ_W       (SEQ_W),
      .USER_W      (USER_W)
  ) u_eb_in (
      .clk       (clk),
      .rst_n     (rst_n),
      .s_valid   (s_valid),
      .s_ready   (s_ready),
      .s_payload (s_payload),
      .m_valid   (ebi_valid),
      .m_ready   (ebi_ready),
      .m_payload (ebi_payload),
      .occupancy (ebi_occ)
  );

  // ---------------------------------------------------------------------------
  // Admission and credit
  // ---------------------------------------------------------------------------
  logic                out_pop;      // a beat leaves the output FIFO
  logic [CREDIT_W-1:0] credit_q;
  logic                admit;

  assign admit     = ebi_valid && (credit_q != CREDIT_W'(0));
  assign ebi_ready = admit;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      credit_q <= CREDIT_W'(OUT_DEPTH);
    end else if (admit && !out_pop) begin
      credit_q <= credit_q - CREDIT_W'(1);
    end else if (out_pop && !admit) begin
      credit_q <= credit_q + CREDIT_W'(1);
    end
  end

  // ---------------------------------------------------------------------------
  // Frame position
  // ---------------------------------------------------------------------------
  logic              in_sof, in_eof;
  logic [DATA_W-1:0] in_data;
  logic [META_W-1:0] in_meta;

  assign in_sof  = ebi_payload[SOF_LSB];
  assign in_eof  = ebi_payload[EOF_LSB];
  assign in_data = ebi_payload[DATA_LSB +: DATA_W];
  assign in_meta = ebi_payload[META_W-1:0];

  logic [N_LANE-1:0] idx_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      idx_q <= '0;
    end else if (admit) begin
      // start_of_frame RESETS the position as well as being checked against it,
      // so a producer that resynchronises after an error resynchronises the FFT.
      // The beat being admitted IS position 0 in that case, so the next one is 1.
      if (in_sof)                        idx_q <= N_LANE'(1);
      else if (idx_q == N_LANE'(M - 1))  idx_q <= '0;
      else                               idx_q <= idx_q + N_LANE'(1);
    end
  end

  logic [N_LANE-1:0] idx_now;
  assign idx_now = in_sof ? '0 : idx_q;

  // ---------------------------------------------------------------------------
  // Metadata FIFO — pushed on admission, popped on delivery
  // ---------------------------------------------------------------------------
  logic              meta_pop;
  logic              meta_valid;
  logic              meta_push_ready;
  logic [META_W-1:0] meta_out;
  logic              meta_ovf_sticky, meta_unf_sticky;
  logic              meta_full, meta_empty, meta_afull, meta_aempty;
  logic [$clog2(META_DEPTH+1)-1:0] meta_occ, meta_hw;

  sync_fifo #(
      .WIDTH      (META_W),
      .DEPTH      (META_DEPTH),
      .SHOW_AHEAD (1'b1),
      .STORAGE    (FIFO_STORAGE)
  ) u_meta_fifo (
      .clk              (clk),
      .rst_n            (rst_n),
      .s_valid          (admit),
      .s_ready          (meta_push_ready),
      .s_data           (in_meta),
      .m_valid          (meta_valid),
      .m_ready          (meta_pop),
      .m_data           (meta_out),
      .occupancy        (meta_occ),
      .full             (meta_full),
      .empty            (meta_empty),
      .almost_full      (meta_afull),
      .almost_empty     (meta_aempty),
      .high_water       (meta_hw),
      .overflow_sticky  (meta_ovf_sticky),
      .underflow_sticky (meta_unf_sticky),
      .sticky_clear     (1'b0)
  );

  // ---------------------------------------------------------------------------
  // The transform
  // ---------------------------------------------------------------------------
  logic              core_vld, core_warm;
  logic [DATA_W-1:0] core_data;
  logic [N_LANE-1:0] core_idx;

  fft_core #(
      .FFT_SIZE          (FFT_SIZE),
      .SAMPLES_PER_CYCLE (P),
      .SCALE_SCHED       (SCALE_SCHED),
      .TW_VARIANT        (TW_VARIANT),
      .TW_PIPE           (TW_PIPE),
      .TW_ROM_OUT_REG    (TW_ROM_OUT_REG),
      .MEM_STYLE         (MEM_STYLE),
      .TW_STYLE          (TW_STYLE),
      .FLAG_COUNT_W      (FLAG_COUNT_W)
  ) u_core (
      .clk         (clk),
      .rst_n       (rst_n),
      .flags_clear (flags_clear),
      .vld_in      (admit),
      .din         (in_data),
      .idx_in      (idx_now),
      .vld_out     (core_vld),
      .dout        (core_data),
      .idx_out     (core_idx),
      .warm_out    (core_warm),
      .stage_flags (stage_flags),
      .any_ovf     (any_ovf),
      .ovf_events  (ovf_events)
  );

  // ---------------------------------------------------------------------------
  // Optional bit-reversal reorder
  // ---------------------------------------------------------------------------
  logic              post_vld, post_warm;
  logic [DATA_W-1:0] post_data;
  logic [N_LANE-1:0] post_idx;

  if (REORDER != 0) begin : g_reorder
    fft_reorder #(
        .N_LANE (N_LANE),
        .WIDTH  (DATA_W),
        .STYLE  (REORDER_STYLE)
    ) u_reorder (
        .clk      (clk),
        .rst_n    (rst_n),
        .vld_in   (core_vld),
        .din      (core_data),
        .idx_in   (core_idx),
        .warm_in  (core_warm),
        .vld_out  (post_vld),
        .dout     (post_data),
        .idx_out  (post_idx),
        .warm_out (post_warm)
    );
  end else begin : g_no_reorder
    assign post_vld  = core_vld;
    assign post_data = core_data;
    assign post_idx  = core_idx;
    assign post_warm = core_warm;
  end

  // ---------------------------------------------------------------------------
  // Delivery
  // ---------------------------------------------------------------------------
  logic deliver;
  assign deliver  = post_vld && post_warm;
  assign meta_pop = deliver;

  logic [PAYLOAD_W-1:0] out_payload;
  assign out_payload = {post_data, meta_out};

  logic out_push_ready;
  logic out_ovf_sticky, out_unf_sticky;
  logic out_full, out_empty, out_afull, out_aempty;
  logic [$clog2(OUT_DEPTH+1)-1:0] out_occ, out_hw;

  sync_fifo #(
      .WIDTH      (PAYLOAD_W),
      .DEPTH      (OUT_DEPTH),
      .SHOW_AHEAD (1'b0),
      .STORAGE    (FIFO_STORAGE)
  ) u_out_fifo (
      .clk              (clk),
      .rst_n            (rst_n),
      .s_valid          (deliver),
      .s_ready          (out_push_ready),
      .s_data           (out_payload),
      .m_valid          (m_valid),
      .m_ready          (m_ready),
      .m_data           (m_payload),
      .occupancy        (out_occ),
      .full             (out_full),
      .empty            (out_empty),
      .almost_full      (out_afull),
      .almost_empty     (out_aempty),
      .high_water       (out_hw),
      .overflow_sticky  (out_ovf_sticky),
      .underflow_sticky (out_unf_sticky),
      .sticky_clear     (1'b0)
  );

  assign out_pop = m_valid && m_ready;

  // ---------------------------------------------------------------------------
  // FIFO status that this block does not route onward
  //
  // sync_fifo exports a full status set for the telemetry plane (SPEC 9, issue
  // #8), which will read the occupancy and the high-water mark of both FIFOs
  // when the plane is wired to the datapath (issue #19). Until then they are
  // gathered here rather than left as empty port connections, so that "this
  // output is deliberately not used yet" is written down. The `unused_` prefix
  // is the spelling Verilator's --unused-regexp recognises, so a genuinely
  // dropped signal anywhere else is still reported.
  //
  // The two FIFO flags the assertions below DO use — meta_full/meta_empty and
  // out_full — are not in here. `out_empty` is: with the registered output stage
  // (SHOW_AHEAD = 0) it describes the storage ARRAY, and a beat held in the
  // output register is legitimately visible on m_valid while the array reads
  // empty, so it says nothing about the interface and asserting on it would be
  // wrong rather than merely redundant.
  // ---------------------------------------------------------------------------
  logic unused_fifo_status;
  assign unused_fifo_status = ^{ebi_occ, meta_occ, meta_hw, meta_afull,
                                meta_aempty, out_occ, out_hw, out_afull,
                                out_aempty, out_empty};

  // ---------------------------------------------------------------------------
  // Assertions
  //
  // These are the properties the whole design rests on, and every one of them is
  // a fact about arithmetic done in fft_pkg rather than about this file:
  //
  //   * frames really are M beats, and start_of_frame really is position 0;
  //   * the metadata and the transform stay in step — the popped
  //     start_of_frame lands exactly on output position 0. This is THE check
  //     that fft_total_latency() is the right number: if the latency arithmetic
  //     were off by one beat, this fires on the second frame;
  //   * the credit scheme really does reserve a slot, so neither FIFO overflows
  //     and the metadata FIFO is never popped empty.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  logic [31:0] in_beats_q;
  always_ff @(posedge clk) begin
    if (!rst_n) in_beats_q <= 32'd0;
    else if (admit) in_beats_q <= (in_eof ? 32'd0 : (in_beats_q + 32'd1));
  end

  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (admit) begin
        a_fft_sof_at_position_zero : assert (in_sof == (in_beats_q == 32'd0))
          else $error("streaming_fft: start_of_frame at beat %0d of the frame",
                      in_beats_q);
        a_fft_eof_at_last_position : assert (in_eof == (in_beats_q == 32'(M - 1)))
          else $error("streaming_fft: end_of_frame at beat %0d, expected %0d",
                      in_beats_q, M - 1);
      end

      if (deliver) begin
        a_fft_meta_available : assert (meta_valid)
          else $error("streaming_fft: delivered a beat with an empty metadata FIFO");
        a_fft_meta_frame_aligned : assert (meta_out[SOF_LSB] == (post_idx == '0))
          else $error("streaming_fft: metadata sof=%0b at output position %0d — the latency arithmetic is wrong",
                      meta_out[SOF_LSB], post_idx);
        a_fft_out_fifo_has_room : assert (out_push_ready)
          else $error("streaming_fft: output FIFO refused a beat; the credit scheme is broken");
      end

      if (admit) begin
        a_fft_meta_fifo_has_room : assert (meta_push_ready && !meta_full)
          else $error("streaming_fft: metadata FIFO refused a beat");
        a_fft_out_fifo_not_full : assert (!out_full)
          else $error("streaming_fft: admitted a beat with the output FIFO full; the credit scheme is broken");
      end

      if (deliver) begin
        a_fft_meta_not_empty : assert (!meta_empty)
          else $error("streaming_fft: delivered a beat with the metadata FIFO empty");
      end

      a_fft_no_fifo_errors : assert (!meta_ovf_sticky && !meta_unf_sticky &&
                                     !out_ovf_sticky && !out_unf_sticky)
        else $error("streaming_fft: a FIFO reported overflow/underflow (meta %0b/%0b out %0b/%0b)",
                    meta_ovf_sticky, meta_unf_sticky,
                    out_ovf_sticky, out_unf_sticky);
    end
  end

  // The full SPEC 14 protocol property set on the master interface. The elastic
  // buffer carries its own on the slave side.
  stream_protocol_checker #(
      .PAYLOAD_W   (PAYLOAD_W),
      .DATA_W      (DATA_W),
      .STREAM_ID_W (STREAM_ID_W),
      .SEQ_W       (SEQ_W),
      .USER_W      (USER_W)
  ) u_chk_m (
      .clk     (clk),
      .rst_n   (rst_n),
      .valid   (m_valid),
      .ready   (m_ready),
      .payload (m_payload)
  );
`endif

endmodule : streaming_fft

`default_nettype wire
