// -----------------------------------------------------------------------------
// bin_serializer — the beamformer's beam-major beat into one beat per frequency
// bin (SPEC.md 7.6, 7.7; issue #17).
//
// Why the pipeline needs it
// -------------------------
// The beamformer emits `BIN_PAR` bins x `BEAM_PAR` beams per beat, beam-major
// and bin-minor (ARCHITECTURE.md §3.5, "Output metadata convention"). The two
// consumers downstream want the transpose of that nesting and at a different
// granularity:
//
//   * `covar_engine` takes a PARALLEL SOURCE VECTOR — every channel of one
//     instant in one beat (ARCHITECTURE.md §3.5, "Input contract: parallel
//     sources"). Its instant is a frequency bin, and its channels are the beams;
//   * `cfar_core` takes ONE BIN PER BEAT, in bin order, framed (§3.5, "Framing
//     costs D cycles per frame"). Its sliding reference window spans adjacent
//     bins, so a beat carrying two bins at once is not something it can consume
//     at all.
//
// Both want "all beams of one bin". This module produces exactly that: one input
// beat becomes `BIN_PAR` output beats, output beat `j` carrying
// `Y[beam][bin_base + j]` for every beam, beam index minor.
//
// It is a pure re-nesting. No arithmetic, no sample is created or destroyed, and
// the module is the one place in the pipeline where the beamformer's output
// layout is decoded — nothing downstream slices a beamformer beat.
//
// The rate, and why it costs nothing here
// ---------------------------------------
// `BIN_PAR` output beats per input beat means the input is accepted at most one
// cycle in `BIN_PAR`. That is not a throttle the pipeline notices: the whole
// back end already runs at one bin per cycle because the history serves one bin
// per cycle (rtl/top/history_rd_mux.sv §1), and `BIN_PAR` bins per beamformer
// beat arriving every `BIN_PAR` cycles is the same rate expressed differently.
// The serializer is rate-matched to its own source by construction.
//
// BEAM_MUX must be 1 (elaboration check)
// --------------------------------------
// With `BEAM_PAR < N_BEAMS` the beamformer time-multiplexes: a bin's beams are
// spread over `BEAM_MUX` consecutive output beats, and "all beams of one bin" is
// then not available in any single beat. Serialising a multiplexed stream needs
// a `BEAM_MUX x BIN_PAR x BEAM_PAR` reorder buffer, which is a real block with
// its own framing argument and its own tests.
//
// It is not built, because at every SPEC 11 size through `large` the beamformer
// is elaborated with `BEAM_PAR = N_BEAMS` and the multiplex factor is 1. The
// restriction is therefore a CHECK rather than a limitation, and it is a check
// rather than a silent assumption because the full-scale freeze (issue #20) is
// where `BEAM_PAR` is chosen against measured DSP counts and is exactly where a
// silent assumption would be discovered by a wrong answer.
//
// Framing and sequence
// --------------------
// `sof` lands on output beat 0 of an input beat carrying `sof`; `eof` on output
// beat `BIN_PAR-1` of an input beat carrying `eof`. `seq_out = {seq_in, j}` — a
// free concatenation because `BIN_PAR` is a power of two, continuous beat to
// beat (which `stream_protocol_checker` requires) and invertible by slicing. It
// is the same construction, for the same reason, that `beamformer_pkg` uses for
// its own beam-group index.
//
// Flow control
// ------------
// One holding register. `s_ready` is high only on the cycle the last output beat
// of the held input beat is accepted, so it is a function of this module's own
// counter and of `m_ready` — one boundary, which SPEC 5 allows. A consumer that
// wants the ready path broken outright puts a skid buffer after it; the pipeline
// does.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module bin_serializer
  import fxp_pkg::*;
  import stream_pkg::*;
#(
    parameter int unsigned N_BEAMS  = 4,
    parameter int unsigned BEAM_PAR = 4,
    parameter int unsigned BIN_PAR  = 2,

    parameter int unsigned STREAM_ID_W = 4,
    parameter int unsigned SEQ_W       = 16,
    parameter int unsigned USER_W      = 4,

    // DERIVED, never overridden.
    parameter int unsigned S_PAYLOAD_W =
        BIN_PAR * BEAM_PAR * 2 * fxp_pkg::FXP_SAMPLE_W +
        2 + STREAM_ID_W + SEQ_W + USER_W,
    parameter int unsigned M_PAYLOAD_W =
        N_BEAMS * 2 * fxp_pkg::FXP_SAMPLE_W +
        2 + STREAM_ID_W + SEQ_W + USER_W
) (
    input  wire                     clk,
    input  wire                     rst_n,

    input  wire                     s_valid,
    output wire                     s_ready,
    input  wire [S_PAYLOAD_W-1:0]   s_payload,

    output wire                     m_valid,
    input  wire                     m_ready,
    output wire [M_PAYLOAD_W-1:0]   m_payload,

    // The bin index within the frame of the beat currently on `m_*`. Not part of
    // the stream contract — the bin dimension is positional and the frame's
    // mapping is carried by `seq` — but exported because the covariance engine's
    // window boundaries and the CFAR frame length are both easier to reason
    // about with it visible in a waveform than derived from a sequence number.
    output wire [15:0]              obs_bin_index
);

  localparam int unsigned PAIR_W   = 2 * FXP_SAMPLE_W;
  localparam int unsigned S_DATA_W = BIN_PAR * BEAM_PAR * PAIR_W;
  localparam int unsigned M_DATA_W = N_BEAMS * PAIR_W;
  localparam int unsigned J_W      = (BIN_PAR <= 1) ? 1 : $clog2(BIN_PAR);

  localparam stream_geom_t S_GEOM =
      stream_geom(stream_pkg::uint_t'(S_DATA_W), stream_pkg::uint_t'(STREAM_ID_W),
                  stream_pkg::uint_t'(SEQ_W), stream_pkg::uint_t'(USER_W));
  localparam stream_geom_t M_GEOM =
      stream_geom(stream_pkg::uint_t'(M_DATA_W), stream_pkg::uint_t'(STREAM_ID_W),
                  stream_pkg::uint_t'(SEQ_W), stream_pkg::uint_t'(USER_W));

`ifndef SYNTHESIS
  initial begin
    if (BEAM_PAR != N_BEAMS) begin
      $fatal(1, "bin_serializer: BEAM_PAR=%0d != N_BEAMS=%0d. A time-multiplexed beamformer spreads one bin's beams over BEAM_MUX beats and this module reads them from one; see the header.",
             BEAM_PAR, N_BEAMS);
    end
    if (BIN_PAR < 1 || (BIN_PAR & (BIN_PAR - 1)) != 0) begin
      $fatal(1, "bin_serializer: BIN_PAR=%0d is not a power of two", BIN_PAR);
    end
    if (int'(S_PAYLOAD_W) != int'(stream_payload_w(S_GEOM))) begin
      $fatal(1, "bin_serializer: S_PAYLOAD_W=%0d but stream_pkg says %0d",
             S_PAYLOAD_W, int'(stream_payload_w(S_GEOM)));
    end
    if (int'(M_PAYLOAD_W) != int'(stream_payload_w(M_GEOM))) begin
      $fatal(1, "bin_serializer: M_PAYLOAD_W=%0d but stream_pkg says %0d",
             M_PAYLOAD_W, int'(stream_payload_w(M_GEOM)));
    end
    if (SEQ_W <= J_W) begin
      $fatal(1, "bin_serializer: SEQ_W=%0d leaves no room for the %0d-bit bin index",
             SEQ_W, J_W);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // The holding register
  // ---------------------------------------------------------------------------
  logic                   held_q;
  logic [S_PAYLOAD_W-1:0] hold_q;
  logic [J_W-1:0]         j_q;
  logic [15:0]            bin_q;

  wire last_j   = (j_q == J_W'(BIN_PAR - 1));
  wire pop      = held_q && m_ready;
  wire take     = !held_q && s_valid;

  assign s_ready = !held_q || (m_ready && last_j);

  stream_fields_t in_f;
  assign in_f = stream_unpack(S_GEOM, STREAM_MAX_PAYLOAD_W'(hold_q));

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      held_q <= 1'b0;
      j_q    <= '0;
      bin_q  <= '0;
    end else begin
      if (held_q) begin
        if (m_ready) begin
          if (last_j) begin
            held_q <= s_valid;
            j_q    <= '0;
          end else begin
            j_q <= j_q + J_W'(1);
          end
          // The bin counter restarts at every frame boundary rather than free
          // running, so it is the bin index inside the frame the CFAR detectors
          // are about to see and not a beat counter that happens to agree.
          bin_q <= (in_f.eof && last_j) ? 16'd0 : (bin_q + 16'd1);
        end
      end else begin
        held_q <= s_valid;
        j_q    <= '0;
      end
    end
  end

  // Payload storage: not reset (SPEC 23), gated by `held_q`.
  always_ff @(posedge clk) begin
    if (take || (held_q && m_ready && last_j && s_valid)) hold_q <= s_payload;
  end

  // ---------------------------------------------------------------------------
  // The re-nesting
  //
  // Input  index: (k*BIN_PAR + j)   beam-major, bin-minor  (beamformer_pkg)
  // Output index: k                 one bin, beam-minor
  // ---------------------------------------------------------------------------
  logic [M_DATA_W-1:0] out_data;

  always_comb begin
    out_data = '0;
    for (int unsigned k = 0; k < N_BEAMS; k++) begin
      out_data[k*PAIR_W +: PAIR_W] =
          in_f.data[(k*BIN_PAR + int'(j_q)) * PAIR_W +: PAIR_W];
    end
  end

  wire [M_PAYLOAD_W-1:0] out_payload = M_PAYLOAD_W'(stream_pack(M_GEOM, '{
      data      : {{(STREAM_MAX_DATA_W - M_DATA_W){1'b0}}, out_data},
      sof       : in_f.sof && (j_q == '0),
      eof       : in_f.eof && last_j,
      stream_id : in_f.stream_id,
      seq       : STREAM_MAX_SEQ_W'({in_f.seq[STREAM_MAX_SEQ_W-1-J_W:0], j_q}),
      user      : in_f.user
  }));

  assign m_valid       = held_q;
  assign m_payload     = out_payload;
  assign obs_bin_index = bin_q;

`ifndef SYNTHESIS
  stream_protocol_checker #(
      .PAYLOAD_W   (M_PAYLOAD_W),
      .DATA_W      (M_DATA_W),
      .STREAM_ID_W (STREAM_ID_W),
      .SEQ_W       (SEQ_W),
      .USER_W      (USER_W)
  ) u_chk (
      .clk     (clk),
      .rst_n   (rst_n),
      .valid   (m_valid),
      .ready   (m_ready),
      .payload (out_payload)
  );

  // Every input beat produces exactly BIN_PAR output beats. Stated as a cover
  // rather than only as an assertion because the interesting failure is the
  // module never reaching the last sub-beat at all.
  c_binser_full_group:
    cover property (@(posedge clk) disable iff (!rst_n) pop && last_j);

  a_binser_no_pop_when_empty:
    assert property (@(posedge clk) disable iff (!rst_n) m_valid |-> held_q)
      else $error("bin_serializer: m_valid without a held beat");
`endif

  // `pop` and `take` are the two named handshake events; `take` is read by the
  // payload register's enable and `pop` by the assertions above. Both are
  // referenced, so neither needs a waiver.

endmodule : bin_serializer

`default_nettype wire
