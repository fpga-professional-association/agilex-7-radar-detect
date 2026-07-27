// -----------------------------------------------------------------------------
// adc_source — the SPEC.md 3 synthetic ADC sources (issue #17).
//
// "Synthetic ADC Sources" is the first box of the SPEC 3 pipeline diagram, and
// it is a design block rather than a testbench: `benchmark_fabric_top` has no
// pins to receive samples on, so the thing that feeds the polyphase banks in the
// Quartus benchmark has to be RTL. This is it — one programmable generator per
// antenna, driven from the register plane, producing SPEC 5 streams that are
// indistinguishable to everything downstream from a real converter's.
//
// 1. What it generates
// --------------------
// Five modes, selected by `cfg_mode`. Every one of them produces a RAW complex
// Q1.15 value which is then scaled by a programmable Q1.15 `cfg_gain`, so the
// amplitude control is one code path rather than five:
//
//   ADC_MODE_ZERO    0   raw = 0.               The SPEC 13.2 zero-in/zero-out
//                                               stimulus.
//   ADC_MODE_IMPULSE 1   raw = +full scale on sample 0 of each frame, 0
//                                               elsewhere. The SPEC 13.2 impulse
//                                               response, and the chain-through
//                                               test's stimulus.
//   ADC_MODE_CONST   2   raw = +full scale.     DC; lands in bin 0.
//   ADC_MODE_TONE    3   raw = exp(-j2*pi*k*n/FFT_SIZE), from the committed
//                                               twiddle table. One frequency
//                                               bin, exactly.
//   ADC_MODE_LFSR    4   raw = two Q1.15 halves of a maximal-length 32-bit
//                                               LFSR. Reproducible pseudo-random
//                                               stimulus with no host in the
//                                               loop.
//
// The scaling is `fxp_pkg::fxp_mul_q15_rs` on each component independently, NOT
// a complex multiply: a complex gain would rotate the tone and correlate the
// two halves of the random mode, and neither is wanted. `cfg_gain = 0x7FFF` is
// unity to within one LSB (Q1.15 cannot represent 1.0 — NUMERICS.md), which is
// the same "unit weight" caveat `beamformer_pkg`'s own helpers carry.
//
// 2. The tone, and why it lands in exactly one bin
// ------------------------------------------------
// `TONE_TAB[e] = exp(-j2*pi*e/FFT_SIZE)`, built at elaboration by decimating
// `fft_twiddle_pkg`'s committed 1024-entry master table by `1024/FFT_SIZE`.
// Using the FFT's OWN table rather than a second generated one is what makes the
// tone exact rather than approximately exact: the generator and the transform
// quantise the same unit circle the same way, so a tone at step `k` produces a
// spectral line at one bin and the rest of the spectrum is the table's own
// quantisation floor and nothing else.
//
// Sample `n` of antenna `a` is `TONE_TAB[(k*n + a*cfg_ant_step) mod FFT_SIZE]`,
// and the phase is RESET AT EVERY START OF FRAME. Resetting rather than running
// free is deliberate: it makes every frame of a run byte-identical, which is
// what lets the SPEC 13.2 reset-repeatability and delay-invariance properties be
// checked by comparing frames to each other instead of to a stored vector.
//
// `cfg_ant_step` is the per-antenna phase increment and is what makes the
// beamformer's job real. With `ant_step = s` the antenna vector at every bin is
// a uniform linear array's response to a plane wave, so a beam weighted with the
// conjugate progression sums coherently and every other beam does not. A source
// that gave every antenna the same samples would let a broken alignment network
// pass every beamforming test.
//
// THE BIN THE TONE LANDS IN IS `(FFT_SIZE - k) mod FFT_SIZE`, not `k`. The table
// is `exp(-j2*pi*e/N)` (the forward transform's kernel, `fft_twiddle_pkg`
// header) and the transform correlates against the same kernel, so a stimulus of
// `W^(kn)` peaks where `W^(mn)` matches `W^(-kn)` — at `m = N-k`. This is stated
// here because it is the kind of sign convention that costs an afternoon; the
// C++ model states it too and `test_pipeline_directed` checks the peak is where
// both of them say.
//
// 3. Framing, flow control and skew
// ---------------------------------
// One frame is `FFT_SIZE` samples = `M = FFT_SIZE/LANES` beats, `sof` on beat 0
// and `eof` on beat `M-1` — the framing `streaming_fft` asserts and
// `history_core` requires. `seq` is a free-running per-antenna beat counter and
// `stream_id` is the antenna index.
//
// EVERY ANTENNA RUNS ITS OWN COUNTERS AND ITS OWN FLOW CONTROL. They are not
// advanced in lockstep, and that is the point: a downstream stall that reaches
// one antenna and not another produces exactly the inter-antenna frame skew that
// `history_core`'s barrier and `stat_skew_count` exist to survive, and a design
// that only ever saw synchronised antennas would have that path untested. The
// generated VALUES are a function of the antenna's own sample index alone, so
// skew changes when a sample is delivered and never what it is.
//
// `cfg_run` closes the tap AT A FRAME BOUNDARY. A frame in progress finishes;
// dropping `cfg_run` mid-frame never truncates one, because a truncated frame is
// a permanent bin shift in `history_core` (its framing fault) rather than a
// missing beat. `cfg_enable` low idles the block outright and is the register
// plane's per-block enable.
//
// The output is a plain valid/payload register with `m_ready` as its enable, so
// the source holds payload and metadata stable while stalled (SPEC 5) and there
// is no combinational path from `m_ready` into anything but that enable.
//
// 4. What it is NOT
// -----------------
// Not a channel model: no noise, no multipath, no Doppler. A CFAR detection test
// wants an injected target on a controlled floor, and "controlled floor" here
// means the LFSR mode at a programmed gain, whose statistics the test computes
// rather than assumes. Adding Gaussian noise would need a Box-Muller or a CLT
// sum in the datapath to buy a floor the test would then have to characterise
// anyway.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module adc_source
  import fxp_pkg::*;
  import stream_pkg::*;
  import fft_twiddle_pkg::*;
#(
    // SPEC 11 geometry.
    parameter int unsigned N_ANT    = 4,
    parameter int unsigned LANES    = 2,   // == SAMPLES_PER_CYCLE
    parameter int unsigned FFT_SIZE = 256,

    // SPEC 5 field geometry. DATA_W is derived: LANES complex samples.
    parameter int unsigned STREAM_ID_W = 4,
    parameter int unsigned SEQ_W       = 16,
    parameter int unsigned USER_W      = 4,

    parameter int unsigned TELEM_W = 32,

    // DERIVED. A port width must be a parameter expression; overriding this is
    // an elaboration error, exactly as in pfb_bank and beamformer.
    parameter int unsigned PAYLOAD_W =
        LANES * 2 * fxp_pkg::FXP_SAMPLE_W + 2 + STREAM_ID_W + SEQ_W + USER_W
) (
    input  wire                       clk,
    input  wire                       rst_n,

    // ---- configuration (core domain; crossed from the register plane by
    //      rtl/top/cfg_bundle_cdc.sv) ----
    input  wire                       cfg_enable,
    input  wire                       cfg_run,
    input  wire [2:0]                 cfg_mode,
    input  wire [2*FXP_SAMPLE_W-1:0]  cfg_gain,        // {im, re}; only re is used
    input  wire [15:0]                cfg_tone_step,   // k, in FFT bins
    input  wire [15:0]                cfg_ant_step,    // per-antenna phase step
    input  wire [31:0]                cfg_lfsr_seed,
    input  wire                       cfg_lfsr_reseed, // one-cycle pulse
    input  wire                       cfg_counter_clear,

    // ---- one SPEC 5 master port per antenna, flattened ----
    output wire [N_ANT-1:0]           m_valid,
    input  wire [N_ANT-1:0]           m_ready,
    output wire [N_ANT*PAYLOAD_W-1:0] m_payload,

    // ---- telemetry (SPEC 9) ----
    output wire [TELEM_W-1:0]         stat_beat_count,
    output wire [TELEM_W-1:0]         stat_frame_count,
    output wire [TELEM_W-1:0]         stat_stall_count,

    // ---- elaborated geometry echo, for the same reason align_net exports its
    //      own: a number in a pull request should be readable out of the design.
    output wire [7:0]                 obs_lanes,
    output wire [15:0]                obs_beats_per_frame
);

  // ---------------------------------------------------------------------------
  // Geometry
  // ---------------------------------------------------------------------------
  localparam int unsigned M        = FFT_SIZE / LANES;          // beats per frame
  localparam int unsigned BEAT_W   = (M <= 1) ? 1 : $clog2(M);
  localparam int unsigned PHASE_W  = $clog2(FFT_SIZE);
  localparam int unsigned DATA_W   = LANES * 2 * FXP_SAMPLE_W;
  localparam int unsigned TW_DECIM = FFT_TW_N / FFT_SIZE;

  localparam stream_geom_t GEOM =
      stream_geom(stream_pkg::uint_t'(DATA_W), stream_pkg::uint_t'(STREAM_ID_W),
                  stream_pkg::uint_t'(SEQ_W), stream_pkg::uint_t'(USER_W));

  // Mode encoding. Named constants rather than bare numbers because the C++
  // model, the register map and this file all have to agree on five values.
  localparam logic [2:0] ADC_MODE_ZERO    = 3'd0;
  localparam logic [2:0] ADC_MODE_IMPULSE = 3'd1;
  localparam logic [2:0] ADC_MODE_CONST   = 3'd2;
  localparam logic [2:0] ADC_MODE_TONE    = 3'd3;
  localparam logic [2:0] ADC_MODE_LFSR    = 3'd4;

  // ---------------------------------------------------------------------------
  // A maximal-length 32-bit Galois LFSR, the CRC-32 primitive polynomial in
  // reversed form. Period 2^32-1 — longer than the SPEC 13.4 stress run, so the
  // stimulus never repeats within one pass.
  //
  // Declared at module scope, before every use, so the C++ model has exactly one
  // recurrence to mirror and no tool has to resolve a forward reference.
  // ---------------------------------------------------------------------------
  localparam logic [31:0] LFSR_TAPS = 32'hEDB8_8320;

  function automatic logic [31:0] lfsr_next(input logic [31:0] s);
    return s[0] ? ((s >> 1) ^ LFSR_TAPS) : (s >> 1);
  endfunction

  // Per-antenna seed decorrelation.
  //
  // Every antenna advances its own LFSR by LANES per beat, so with one shared
  // seed antenna a's sample n and antenna b's sample n would be the SAME NUMBER
  // — the array would see a plane wave arriving from broadside with no phase
  // gradient at all, and a beamformer fed identical antennas produces the same
  // answer whether the alignment network works or not. Mixing the antenna index
  // into the seed with the golden-ratio constant gives each antenna an
  // uncorrelated walk of the same maximal-length sequence, at the cost of one
  // constant XOR per antenna at load time.
  //
  // The result is forced away from zero because zero is the absorbing state, and
  // it is forced rather than rejected because a load has nowhere to report a
  // refusal to.
  localparam logic [31:0] LFSR_GOLDEN = 32'h9E37_79B9;

  function automatic logic [31:0] lfsr_mix(input logic [31:0] s, input int unsigned a);
    logic [31:0] m;
    m = s ^ (LFSR_GOLDEN * 32'(a));
    return (m == 32'h0) ? 32'h1 : m;
  endfunction

`ifndef SYNTHESIS
  initial begin
    if (int'(PAYLOAD_W) != int'(stream_payload_w(GEOM))) begin
      $fatal(1, "adc_source: PAYLOAD_W=%0d but stream_pkg says %0d - do not override it",
             PAYLOAD_W, int'(stream_payload_w(GEOM)));
    end
    if (FFT_SIZE < 4 || (FFT_SIZE & (FFT_SIZE - 1)) != 0) begin
      $fatal(1, "adc_source: FFT_SIZE=%0d is not a power of two >= 4", FFT_SIZE);
    end
    if (LANES == 0 || (LANES & (LANES - 1)) != 0 || LANES >= FFT_SIZE) begin
      $fatal(1, "adc_source: LANES=%0d must be a power of two below FFT_SIZE=%0d",
             LANES, FFT_SIZE);
    end
    if (FFT_TW_N % FFT_SIZE != 0) begin
      $fatal(1, "adc_source: FFT_SIZE=%0d does not divide the master twiddle table (%0d)",
             FFT_SIZE, FFT_TW_N);
    end
    if (N_ANT == 0 || N_ANT > (1 << STREAM_ID_W)) begin
      $fatal(1, "adc_source: N_ANT=%0d does not fit STREAM_ID_W=%0d", N_ANT, STREAM_ID_W);
    end
    if (SEQ_W < BEAT_W) begin
      $fatal(1, "adc_source: SEQ_W=%0d cannot carry a beat index of %0d bits", SEQ_W, BEAT_W);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // The tone table
  //
  // Built at elaboration from the committed master table, by the same idiom
  // rtl/fft/fft_twiddle_rom.sv uses: a pure function of the parameters and of
  // fft_twiddle_pkg, evaluated once into a localparam. Nothing here evaluates a
  // trigonometric function, so the generator cannot drift from the transform.
  // ---------------------------------------------------------------------------
  typedef logic [31:0] tone_tab_t [FFT_SIZE];

  function automatic tone_tab_t build_tone_tab();
    build_tone_tab = '{default: 32'h0};
    for (int unsigned e = 0; e < FFT_SIZE; e++) begin
      build_tone_tab[e] = fft_tw_word(e * TW_DECIM);
    end
  endfunction

  localparam tone_tab_t TONE_TAB = build_tone_tab();

  // Gain is one Q1.15 real number. The imaginary half of `cfg_gain` is carried
  // on the register-plane word for symmetry with every other complex register
  // and is deliberately not used here; see the header (a complex gain would
  // rotate the tone).
  wire [FXP_SAMPLE_W-1:0] unused_gain_im = cfg_gain[2*FXP_SAMPLE_W-1:FXP_SAMPLE_W];
  wire signed [FXP_SAMPLE_W-1:0] gain = fxp16_t'(cfg_gain[FXP_SAMPLE_W-1:0]);

  // Both step registers are 16 bits for symmetry with every other register-plane
  // word; only the low `PHASE_W` bits can name a distinct phase, and a larger
  // value is the same phase modulo FFT_SIZE rather than an error. The discarded
  // halves are named so `--Wall` reports a genuinely dead signal and not this
  // deliberate truncation.
  wire [15:PHASE_W]  unused_tone_step_hi = cfg_tone_step[15:PHASE_W];
  wire [15:PHASE_W]  unused_ant_step_hi  = cfg_ant_step[15:PHASE_W];
  wire [PHASE_W-1:0] tone_step = cfg_tone_step[PHASE_W-1:0];
  wire [PHASE_W-1:0] ant_step  = cfg_ant_step[PHASE_W-1:0];

  // ---------------------------------------------------------------------------
  // Per-antenna generators
  // ---------------------------------------------------------------------------
  logic [N_ANT-1:0] fire;
  logic [N_ANT-1:0] frame_end;
  logic [N_ANT-1:0] stalled;

  for (genvar a = 0; a < int'(N_ANT); a++) begin : g_ant

    // Constant per-antenna phase offset. `a` is a genvar, so `a * ant_step` is a
    // constant-coefficient multiply — shifts and adds, not a DSP block.
    wire [PHASE_W-1:0] ant_phase0 = PHASE_W'(PHASE_W'(a) * ant_step);

    logic [BEAT_W-1:0]    beat_q;    // beat index within the frame
    logic [PHASE_W-1:0]   phase_q;   // tone phase of lane 0 of this beat
    logic [31:0]          lfsr_q;
    logic                 open_q;    // a frame is in progress
    logic                 valid_q;
    logic [PAYLOAD_W-1:0] payload_q;
    logic [SEQ_W-1:0]     seq_q;

    // A beat may be produced when the register plane allows it and the output
    // register is free. `cfg_run` is consulted only to OPEN a frame: a frame in
    // progress runs to its `eof` beat whatever `cfg_run` does (header 3).
    wire out_free = !valid_q || m_ready[a];
    wire may_run  = cfg_enable && (open_q || cfg_run);
    wire adv      = may_run && out_free;

    wire is_sof = !open_q;
    wire is_eof = (beat_q == BEAT_W'(M - 1));

    assign fire[a]      = adv;
    assign frame_end[a] = adv && is_eof;
    // A stall is a cycle in which the block wanted to produce a beat and could
    // not. A cycle in which it is deliberately idle is not a stall, for the same
    // reason align_net's `stat_issue_stall_count` excludes them.
    assign stalled[a]   = may_run && !out_free;

    // -------------------------------------------------------------------------
    // The sample words of this beat
    //
    // Combinational from the counters, registered into the output. Lane `l`
    // carries sample `beat_q*LANES + l`, which is what fft_core and
    // history_pkg's `hist_stored_bin` both assume of an arriving beat.
    // -------------------------------------------------------------------------
    logic [DATA_W-1:0] data_next;

    always_comb begin
      logic [PHASE_W-1:0] ph;
      logic [31:0]        lf;
      fxp_complex_t       raw;
      fxp_complex_t       scaled;

      data_next = '0;
      for (int unsigned l = 0; l < LANES; l++) begin
        // Lane l's tone phase: lane 0's plus l steps. The multiply is by the
        // loop constant `l`, so it is a shift-add and not a multiplier.
        ph = PHASE_W'(phase_q + PHASE_W'(PHASE_W'(l) * tone_step) + ant_phase0);

        // The LFSR advances once per SAMPLE, so lane l of this beat is the
        // register state advanced l times. Unrolled here rather than held in l
        // registers so that the generated value is a function of the sample
        // index and of nothing else.
        lf = lfsr_q;
        for (int unsigned s = 0; s < l; s++) lf = lfsr_next(lf);

        raw = '{im: 16'sd0, re: 16'sd0};
        case (cfg_mode)
          ADC_MODE_IMPULSE: if (is_sof && l == 0) raw = '{im: 16'sd0, re: fxp_q15_max()};
          ADC_MODE_CONST:   raw = '{im: 16'sd0, re: fxp_q15_max()};
          ADC_MODE_TONE:    raw = fxp_complex_t'(TONE_TAB[ph]);
          ADC_MODE_LFSR:    raw = '{im: fxp16_t'(lf[31:16]), re: fxp16_t'(lf[15:0])};
          ADC_MODE_ZERO:    ;   // the SPEC 13.2 zero-in stimulus, stated rather
                                // than defaulted so the encoding is complete
          default: ;            // every unassigned code reads as ZERO
        endcase

        scaled = '{im: fxp_mul_q15_rs(raw.im, gain),
                   re: fxp_mul_q15_rs(raw.re, gain)};
        data_next[l*32 +: 32] = {scaled.im, scaled.re};
      end
    end

    // The packed beat. Split out of the always_ff so the pack call is one
    // expression a reader can check against stream_pkg's field order.
    wire [PAYLOAD_W-1:0] packed_next = PAYLOAD_W'(stream_pack(GEOM, '{
        data      : {{(STREAM_MAX_DATA_W - DATA_W){1'b0}}, data_next},
        sof       : is_sof,
        eof       : is_eof,
        stream_id : STREAM_MAX_ID_W'(a),
        seq       : STREAM_MAX_SEQ_W'(seq_q),
        user      : '0
    }));

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
      logic [31:0] lf_beat;

      if (!rst_n) begin
        beat_q  <= '0;
        phase_q <= '0;
        lfsr_q  <= lfsr_mix(32'h1, a);
        open_q  <= 1'b0;
        valid_q <= 1'b0;
        seq_q   <= '0;
      end else begin
        if (cfg_lfsr_reseed) begin
          // `lfsr_mix` folds the antenna index in and forces the result away
          // from the absorbing state; see its definition above.
          lfsr_q <= lfsr_mix(cfg_lfsr_seed, a);
        end else if (adv) begin
          lf_beat = lfsr_q;
          for (int unsigned s = 0; s < LANES; s++) lf_beat = lfsr_next(lf_beat);
          lfsr_q <= lf_beat;
        end

        if (adv) begin
          valid_q <= 1'b1;
          seq_q   <= seq_q + SEQ_W'(1);

          if (is_eof) begin
            beat_q  <= '0;
            phase_q <= '0;             // phase resets every frame (header 2)
            open_q  <= 1'b0;
          end else begin
            beat_q  <= beat_q + BEAT_W'(1);
            phase_q <= PHASE_W'(phase_q + PHASE_W'(PHASE_W'(LANES) * tone_step));
            open_q  <= 1'b1;
          end
        end else if (m_ready[a]) begin
          valid_q <= 1'b0;
        end
      end
    end

    // Payload is not reset: SPEC 23 asks for validity to be reset, not the
    // datapath. `valid_q` gates every consumer.
    always_ff @(posedge clk) begin
      if (adv) payload_q <= packed_next;
    end

    assign m_valid[a]                          = valid_q;
    assign m_payload[a*PAYLOAD_W +: PAYLOAD_W] = payload_q;

`ifndef SYNTHESIS
    // SPEC 5: a source holds payload and metadata stable while stalled.
    stream_protocol_checker #(
        .PAYLOAD_W   (PAYLOAD_W),
        .DATA_W      (DATA_W),
        .STREAM_ID_W (STREAM_ID_W),
        .SEQ_W       (SEQ_W),
        .USER_W      (USER_W)
    ) u_chk (
        .clk     (clk),
        .rst_n   (rst_n),
        .valid   (valid_q),
        .ready   (m_ready[a]),
        .payload (payload_q)
    );
`endif
  end

  // ---------------------------------------------------------------------------
  // Telemetry (SPEC 9)
  // ---------------------------------------------------------------------------
  localparam int unsigned CNT_INCR_W = (N_ANT <= 1) ? 1 : ($clog2(N_ANT) + 1);

  function automatic logic [CNT_INCR_W-1:0] popcount_n(input logic [N_ANT-1:0] v);
    popcount_n = '0;
    for (int unsigned i = 0; i < N_ANT; i++) begin
      popcount_n = popcount_n + CNT_INCR_W'(v[i]);
    end
  endfunction

  wire               unused_b_snapv, unused_f_snapv, unused_s_snapv;
  wire               unused_b_wrapp, unused_f_wrapp, unused_s_wrapp;
  wire               unused_b_wrapd, unused_f_wrapd, unused_s_wrapd;
  wire [TELEM_W-1:0] unused_b_snap,  unused_f_snap,  unused_s_snap;

  perf_counter #(.WIDTH(TELEM_W), .INCR_W(CNT_INCR_W), .SATURATE(1'b1)) u_cnt_beat (
      .clk (clk), .rst_n (rst_n), .enable (1'b1),
      .event_i (|fire), .incr (popcount_n(fire)),
      .clear (cfg_counter_clear), .snapshot (1'b0),
      .count (stat_beat_count), .snap (unused_b_snap), .snap_valid (unused_b_snapv),
      .wrap_pulse (unused_b_wrapp), .wrapped (unused_b_wrapd)
  );

  perf_counter #(.WIDTH(TELEM_W), .INCR_W(CNT_INCR_W), .SATURATE(1'b1)) u_cnt_frame (
      .clk (clk), .rst_n (rst_n), .enable (1'b1),
      .event_i (|frame_end), .incr (popcount_n(frame_end)),
      .clear (cfg_counter_clear), .snapshot (1'b0),
      .count (stat_frame_count), .snap (unused_f_snap), .snap_valid (unused_f_snapv),
      .wrap_pulse (unused_f_wrapp), .wrapped (unused_f_wrapd)
  );

  perf_counter #(.WIDTH(TELEM_W), .INCR_W(CNT_INCR_W), .SATURATE(1'b1)) u_cnt_stall (
      .clk (clk), .rst_n (rst_n), .enable (1'b1),
      .event_i (|stalled), .incr (popcount_n(stalled)),
      .clear (cfg_counter_clear), .snapshot (1'b0),
      .count (stat_stall_count), .snap (unused_s_snap), .snap_valid (unused_s_snapv),
      .wrap_pulse (unused_s_wrapp), .wrapped (unused_s_wrapd)
  );

  assign obs_lanes           = 8'(LANES);
  assign obs_beats_per_frame = 16'(M);

endmodule : adc_source

`default_nettype wire
