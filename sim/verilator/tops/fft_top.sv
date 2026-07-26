// -----------------------------------------------------------------------------
// fft_top — the streaming-FFT verification top (issue #11, SPEC 13.1).
//
// Holds five elaborations of rtl/fft/streaming_fft.sv in one build, so that the
// properties the FFT has to have are same-build facts rather than comparisons of
// separate runs:
//
//   index  FFT_SIZE  REORDER  SCALE_SCHED  what it is there to prove
//   -----  --------  -------  -----------  ---------------------------------
//     0        64       1      all ones     the reference configuration
//     1        64       0      all ones     the output permutation, by data
//     2        64       1      none         saturation everywhere
//     3        64       1      0b000011     saturation from sub-stage 2 on —
//                                           the case the PER-STAGE flags exist
//                                           to distinguish from index 2
//     4       256       1      all ones     the SAME RTL at another size
//
// Index 4 is the parameterisation proof the issue asks for: 256 points means
// seven sub-stages per lane instead of five, three twiddle multipliers instead
// of two, and a different trailing radix-2 stage — all from the same modules,
// with no second implementation. It is elaborated in every build, so "the
// parameterisation still works" is checked by `make lint` as well as by the test.
//
// Routing, not replication of stimulus. All five DUTs share one stimulus port
// set; `dut_sel` routes valid/ready to one of them and muxes its output back.
// The others see valid low and are idle. Unlike the complex multiplier, the FFT
// is a frame machine whose frame length depends on FFT_SIZE, so driving all five
// at once would mean five different frame schedules on one bus — the mux is the
// honest arrangement here.
//
// FIELDS, NOT A PACKED PAYLOAD. The SPEC 5 bundle is packed and unpacked HERE,
// through stream_pkg::stream_pack / stream_unpack, and the C++ side sees plain
// 16-bit fields. Two reasons: the harness does not have to reimplement the
// payload layout (which would be a second definition of it — the thing
// stream_pkg exists to prevent), and the pack/unpack path is exercised by every
// beat of every FFT test rather than only by the stream unit tests.
//
// Simulation only. Not in files.f, never in a Quartus source list; the DUT
// itself is in files.f and in quartus/calibration/.
// -----------------------------------------------------------------------------

`default_nettype none

module fft_top
  import fxp_pkg::*;
  import stream_pkg::*;
  import fft_pkg::*;
(
    input  wire         clk,
    input  wire         rst_n,

    // Which DUT the stimulus is routed to. Out-of-range selects DUT 0.
    input  wire [7:0]   dut_sel,

    // ---- stimulus (SPEC 5 fields, packed inside) ---------------------------
    input  wire         s_valid,
    output wire         s_ready,
    input  wire [15:0]  s_re0,
    input  wire [15:0]  s_im0,
    input  wire [15:0]  s_re1,
    input  wire [15:0]  s_im1,
    input  wire         s_sof,
    input  wire         s_eof,
    input  wire [1:0]   s_id,
    input  wire [15:0]  s_seq,
    input  wire [3:0]   s_user,

    // ---- observation --------------------------------------------------------
    output wire         m_valid,
    input  wire         m_ready,
    output wire [15:0]  m_re0,
    output wire [15:0]  m_im0,
    output wire [15:0]  m_re1,
    output wire [15:0]  m_im1,
    output wire         m_sof,
    output wire         m_eof,
    output wire [1:0]   m_id,
    output wire [15:0]  m_seq,
    output wire [3:0]   m_user,

    // ---- saturation reporting ----------------------------------------------
    input  wire         flags_clear,
    output wire [9:0][1:0] stage_flags,
    output wire         any_ovf,
    output wire [31:0]  ovf_events,

    // ---- the selected DUT's elaboration parameters, and the grid's shape ----
    output wire [7:0]   cfg_n_dut,
    output wire [15:0]  cfg_fft_size,
    output wire [7:0]   cfg_spc,
    output wire [7:0]   cfg_stages,
    output wire [7:0]   cfg_reorder,
    output wire [31:0]  cfg_scale_sched,
    output wire [15:0]  cfg_latency,
    output wire [15:0]  cfg_frame_beats,
    output wire [7:0]   cfg_tw_pipe,
    output wire [7:0]   cfg_rom_lat
);

  // ---------------------------------------------------------------------------
  // Grid. Mirrored in sim/tests/test_fft.cpp, which checks its mirror against
  // the cfg_* echo for every index before anything else runs.
  // ---------------------------------------------------------------------------
  localparam int unsigned N_DUT = 5;
  localparam int unsigned SPC   = 2;

  localparam int unsigned TW_PIPE        = 4;
  localparam int unsigned TW_ROM_OUT_REG = 1;
  localparam int unsigned ROM_LAT        = 1 + TW_ROM_OUT_REG;

  localparam int unsigned DUT_SIZE  [N_DUT] = '{64, 64, 64, 64, 256};
  localparam int unsigned DUT_SCHED [N_DUT] =
      '{32'hFFFF_FFFF, 32'hFFFF_FFFF, 32'h0000_0000, 32'h0000_0003,
        32'hFFFF_FFFF};
  localparam int unsigned DUT_REORD [N_DUT] = '{1, 0, 1, 1, 1};

  // SPEC 5 metadata geometry, the same for every DUT so one bus serves all.
  localparam int unsigned ID_W   = 2;
  localparam int unsigned SEQ_W  = 16;
  localparam int unsigned USER_W = 4;
  localparam int unsigned DATA_W = SPC * 32;

  localparam stream_geom_t GEOM = stream_geom(DATA_W, ID_W, SEQ_W, USER_W);
  localparam int unsigned PAYLOAD_W = int'(stream_payload_w(GEOM));

  localparam int unsigned MAX_STAGES = 10;

  // ---------------------------------------------------------------------------
  // Stimulus packing (SPEC 5). One place, one function.
  // ---------------------------------------------------------------------------
  logic [PAYLOAD_W-1:0] s_payload;

  always_comb begin
    stream_fields_t f;
    f           = '0;
    f.data      = STREAM_MAX_DATA_W'({s_im1, s_re1, s_im0, s_re0});
    f.sof       = s_sof;
    f.eof       = s_eof;
    f.stream_id = STREAM_MAX_ID_W'(s_id);
    f.seq       = STREAM_MAX_SEQ_W'(s_seq);
    f.user      = STREAM_MAX_USER_W'(s_user);
    s_payload   = PAYLOAD_W'(stream_pack(GEOM, f));
  end

  // ---------------------------------------------------------------------------
  // The grid
  // ---------------------------------------------------------------------------
  logic [$clog2(N_DUT)-1:0] sel;
  assign sel = (dut_sel < 8'(N_DUT)) ? dut_sel[$clog2(N_DUT)-1:0] : '0;

  logic [N_DUT-1:0]                  d_sready, d_mvalid, d_ovf;
  logic [N_DUT-1:0][PAYLOAD_W-1:0]   d_mpayload;
  logic [N_DUT-1:0][MAX_STAGES-1:0][1:0] d_flags;
  logic [N_DUT-1:0][31:0]            d_events;

  for (genvar i = 0; i < int'(N_DUT); i++) begin : g_dut
    localparam int unsigned NST = $clog2(DUT_SIZE[i]);

    logic                  sv, mr, sr, mv;
    logic [PAYLOAD_W-1:0]  mp;
    logic [NST-1:0][1:0]   sf;
    logic                  ov;
    logic [31:0]           ev;

    assign sv = s_valid && (sel == $clog2(N_DUT)'(i));
    assign mr = m_ready && (sel == $clog2(N_DUT)'(i));

    streaming_fft #(
        .FFT_SIZE          (DUT_SIZE[i]),
        .SAMPLES_PER_CYCLE (SPC),
        .SCALE_SCHED       (DUT_SCHED[i]),
        .REORDER           (DUT_REORD[i]),
        .STREAM_ID_W       (ID_W),
        .SEQ_W             (SEQ_W),
        .USER_W            (USER_W),
        .TW_PIPE           (TW_PIPE),
        .TW_ROM_OUT_REG    (TW_ROM_OUT_REG)
    ) u_dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .s_valid     (sv),
        .s_ready     (sr),
        .s_payload   (s_payload),
        .m_valid     (mv),
        .m_ready     (mr),
        .m_payload   (mp),
        .flags_clear (flags_clear),
        .stage_flags (sf),
        .any_ovf     (ov),
        .ovf_events  (ev)
    );

    assign d_sready[i]   = sr;
    assign d_mvalid[i]   = mv;
    assign d_mpayload[i] = mp;
    assign d_ovf[i]      = ov;
    assign d_events[i]   = ev;

    // Pad the per-DUT flag vector into the common bus. Sub-stages this DUT does
    // not have read zero, which is what the test expects for them.
    for (genvar g = 0; g < int'(MAX_STAGES); g++) begin : g_pad
      if (g < int'(NST)) begin : g_real
        assign d_flags[i][g] = sf[g];
      end else begin : g_zero
        assign d_flags[i][g] = 2'b00;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Observation
  // ---------------------------------------------------------------------------
  stream_fields_t m_fields;
  assign m_fields = stream_unpack(GEOM, stream_payload_t'(d_mpayload[sel]));

  assign s_ready     = d_sready[sel];
  assign m_valid     = d_mvalid[sel];
  assign m_re0       = m_fields.data[15:0];
  assign m_im0       = m_fields.data[31:16];
  assign m_re1       = m_fields.data[47:32];
  assign m_im1       = m_fields.data[63:48];
  assign m_sof       = m_fields.sof;
  assign m_eof       = m_fields.eof;
  assign m_id        = m_fields.stream_id[ID_W-1:0];
  assign m_seq       = m_fields.seq[SEQ_W-1:0];
  assign m_user      = m_fields.user[USER_W-1:0];

  assign stage_flags = d_flags[sel];
  assign any_ovf     = d_ovf[sel];
  assign ovf_events  = d_events[sel];

  // ---------------------------------------------------------------------------
  // Parameter echo. The test measures the RTL's latency against cfg_latency and
  // checks its own mirror of the grid against these, so a drift between the two
  // is a named failure rather than a silently wrong comparison.
  // ---------------------------------------------------------------------------
  assign cfg_n_dut       = 8'(N_DUT);
  assign cfg_fft_size    = 16'(DUT_SIZE[sel]);
  assign cfg_spc         = 8'(SPC);
  assign cfg_stages      = 8'(fft_total_stages(fft_uint_t'(DUT_SIZE[sel])));
  assign cfg_reorder     = 8'(DUT_REORD[sel]);
  assign cfg_scale_sched = 32'(DUT_SCHED[sel]);
  assign cfg_latency     = 16'(fft_total_latency(fft_uint_t'(DUT_SIZE[sel]),
                                                 fft_uint_t'(SPC),
                                                 fft_uint_t'(ROM_LAT),
                                                 fft_uint_t'(TW_PIPE),
                                                 DUT_REORD[sel] != 0));
  assign cfg_frame_beats = 16'(fft_lane_len(fft_uint_t'(DUT_SIZE[sel]),
                                            fft_uint_t'(SPC)));
  assign cfg_tw_pipe     = 8'(TW_PIPE);
  assign cfg_rom_lat     = 8'(ROM_LAT);

  // ---------------------------------------------------------------------------
  // Elaboration sanity: the grid must actually cover what the test claims it
  // covers, or the coverage argument in VERIFICATION_PLAN.md is empty.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin
    automatic int unsigned n_reorder = 0;
    automatic int unsigned n_plain   = 0;
    automatic int unsigned n_sat     = 0;
    automatic int unsigned n_size    = 0;
    for (int unsigned i = 0; i < N_DUT; i++) begin
      if (DUT_REORD[i] != 0) n_reorder++; else n_plain++;
      if (DUT_SCHED[i] != 32'hFFFF_FFFF) n_sat++;
      if (DUT_SIZE[i] != DUT_SIZE[0]) n_size++;
    end
    if (n_reorder == 0 || n_plain == 0) begin
      $fatal(1, "fft_top: the grid does not cover both output orders");
    end
    if (n_sat < 2) begin
      $fatal(1, "fft_top: the grid needs two distinct saturating schedules to make the per-stage flags falsifiable");
    end
    if (n_size == 0) begin
      $fatal(1, "fft_top: the grid does not elaborate a second FFT_SIZE");
    end
  end
`endif

endmodule : fft_top

`default_nettype wire
