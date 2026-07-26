// -----------------------------------------------------------------------------
// fft_core_wrap — synthesis wrapper for the SPEC 18 full-FFT calibration
// (issue #11, SPEC 18 item 5: "One full FFT").
//
// Wraps the WHOLE deliverable block — rtl/fft/streaming_fft.sv, i.e. the
// transform plus the elastic boundary, the frame tracking, the optional
// bit-reversal reorder and the credit-backed output FIFO — in boundary
// registers, so the sweep measures the block a system integrates rather than an
// arithmetic core that could not be integrated as it stands.
//
// That choice is deliberate and is the reason the two calibration projects
// exist rather than one: fft_stage_calib prices the ARITHMETIC AND MEMORY of one
// radix-2^2 stage in isolation, and this one prices the WHOLE BLOCK. The
// difference between the two — after multiplying the stage by the structure —
// is the buffering cost of making a fixed-latency pipeline into a SPEC 5 stream
// block, which is exactly the number DECISIONS.md needs to justify that choice.
// quartus/scripts/calibrate.tcl additionally records the per-entity utilisation
// row for u_kernel, so the split is in the evidence rather than in an argument.
//
// Same boundary-register and virtual-pin arrangement as cmult_wrap and
// fft_stage_wrap; the SPEC 5 bundle is packed and unpacked here so that the
// port list is plain fields and does not change shape with the parameters.
//
// Integer parameters only, for the reason cmult_wrap gives.
//
// Listed in sim/verilator/files_fft.f so `make lint` covers it.
// -----------------------------------------------------------------------------

`default_nettype none

module fft_core_wrap
  import fxp_pkg::*;
  import stream_pkg::*;
#(
    parameter int unsigned FFT_SIZE          = 64,
    parameter int unsigned SAMPLES_PER_CYCLE = 2,
    parameter int unsigned SCALE_SCHED       = 32'hFFFF_FFFF,
    parameter int unsigned REORDER           = 1,

    // 0 = complex_multiplier "MULT4", 1 = "MULT3".
    parameter int unsigned VARIANT_SEL       = 0,
    parameter int unsigned TW_PIPE           = 4,
    parameter int unsigned TW_ROM_OUT_REG    = 1,

    // 0 = AUTO (no attribute, the tool chooses), 1 = M20K, 2 = MLAB,
    // 3 = LOGIC, 4 = DEFAULT (the project rule measured by this sweep;
    // see fft_pkg "Delay-feedback placement").
    parameter int unsigned MEM_SEL           = 0,
    parameter int unsigned TW_SEL            = 0,
    parameter int unsigned REORDER_SEL       = 0,

    // 0 = "regs", 1 = "mlab", 2 = "m20k" for the metadata and output FIFOs.
    parameter int unsigned FIFO_SEL          = 1
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        s_valid,
    output wire        s_ready,
    input  wire [15:0] s_re0,
    input  wire [15:0] s_im0,
    input  wire [15:0] s_re1,
    input  wire [15:0] s_im1,
    input  wire        s_sof,
    input  wire        s_eof,
    input  wire [7:0]  s_id,
    input  wire [15:0] s_seq,
    input  wire [7:0]  s_user,

    output wire        m_valid,
    input  wire        m_ready,
    output wire [15:0] m_re0,
    output wire [15:0] m_im0,
    output wire [15:0] m_re1,
    output wire [15:0] m_im1,
    output wire        m_sof,
    output wire        m_eof,
    output wire [7:0]  m_id,
    output wire [15:0] m_seq,
    output wire [7:0]  m_user,

    input  wire        flags_clear,
    output wire [19:0] stage_flags,
    output wire        any_ovf,
    output wire [31:0] ovf_events
);

  localparam string VARIANT = (VARIANT_SEL == 1) ? "MULT3" : "MULT4";
  localparam string MEM_STYLE =
      (MEM_SEL == 1) ? "M20K" : (MEM_SEL == 2) ? "MLAB" :
      (MEM_SEL == 3) ? "LOGIC" : (MEM_SEL == 4) ? "DEFAULT" : "AUTO";
  localparam string TW_STYLE =
      (TW_SEL == 1) ? "M20K" : (TW_SEL == 2) ? "MLAB" :
      (TW_SEL == 3) ? "LOGIC" : "AUTO";
  localparam string REORDER_STYLE =
      (REORDER_SEL == 1) ? "M20K" : (REORDER_SEL == 2) ? "MLAB" :
      (REORDER_SEL == 3) ? "LOGIC" : "AUTO";
  localparam string FIFO_STORAGE =
      (FIFO_SEL == 2) ? "m20k" : (FIFO_SEL == 1) ? "mlab" : "regs";

  localparam int unsigned ID_W   = 2;
  localparam int unsigned SEQ_W  = 16;
  localparam int unsigned USER_W = 4;
  localparam int unsigned DATA_W = SAMPLES_PER_CYCLE * 32;
  localparam int unsigned NSTAGE = $clog2(FFT_SIZE);

  localparam stream_geom_t GEOM = stream_geom(DATA_W, ID_W, SEQ_W, USER_W);
  localparam int unsigned PAYLOAD_W = int'(stream_payload_w(GEOM));

  // ---------------------------------------------------------------------------
  // Boundary input registers, then the SPEC 5 packing
  // ---------------------------------------------------------------------------
  logic        sv_q, sof_q, eof_q;
  logic [63:0] sdata_q;
  logic [7:0]  sid_q, suser_q;
  logic [15:0] sseq_q;

  always_ff @(posedge clk) begin
    if (!rst_n) sv_q <= 1'b0;
    else        sv_q <= s_valid;
  end

  always_ff @(posedge clk) begin
    sdata_q <= {s_im1, s_re1, s_im0, s_re0};
    sof_q   <= s_sof;
    eof_q   <= s_eof;
    sid_q   <= s_id;
    sseq_q  <= s_seq;
    suser_q <= s_user;
  end

  logic [PAYLOAD_W-1:0] s_payload;

  always_comb begin
    stream_fields_t f;
    f           = '0;
    f.data      = STREAM_MAX_DATA_W'(sdata_q);
    f.sof       = sof_q;
    f.eof       = eof_q;
    f.stream_id = STREAM_MAX_ID_W'(sid_q);
    f.seq       = STREAM_MAX_SEQ_W'(sseq_q);
    f.user      = STREAM_MAX_USER_W'(suser_q);
    s_payload   = PAYLOAD_W'(stream_pack(GEOM, f));
  end

  // ---------------------------------------------------------------------------
  // The block under calibration. The instance MUST be named u_kernel; see
  // fft_stage_wrap.
  // ---------------------------------------------------------------------------
  logic                 k_sready, k_mvalid;
  logic [PAYLOAD_W-1:0] k_mpayload;
  logic [NSTAGE-1:0][1:0] k_flags;
  logic                 k_ovf;
  logic [31:0]          k_events;
  logic                 mr_q;

  streaming_fft #(
      .FFT_SIZE          (FFT_SIZE),
      .SAMPLES_PER_CYCLE (SAMPLES_PER_CYCLE),
      .SCALE_SCHED       (SCALE_SCHED),
      .REORDER           (REORDER),
      .STREAM_ID_W       (ID_W),
      .SEQ_W             (SEQ_W),
      .USER_W            (USER_W),
      .TW_VARIANT        (VARIANT),
      .TW_PIPE           (TW_PIPE),
      .TW_ROM_OUT_REG    (TW_ROM_OUT_REG),
      .MEM_STYLE         (MEM_STYLE),
      .TW_STYLE          (TW_STYLE),
      .REORDER_STYLE     (REORDER_STYLE),
      .FIFO_STORAGE      (FIFO_STORAGE)
  ) u_kernel (
      .clk         (clk),
      .rst_n       (rst_n),
      .s_valid     (sv_q),
      .s_ready     (k_sready),
      .s_payload   (s_payload),
      .m_valid     (k_mvalid),
      .m_ready     (mr_q),
      .m_payload   (k_mpayload),
      .flags_clear (flags_clear),
      .stage_flags (k_flags),
      .any_ovf     (k_ovf),
      .ovf_events  (k_events)
  );

  // ---------------------------------------------------------------------------
  // Boundary output registers
  // ---------------------------------------------------------------------------
  stream_fields_t m_fields;
  assign m_fields = stream_unpack(GEOM, stream_payload_t'(k_mpayload));

  logic        sr_q, mv_q, msof_q, meof_q, ovf_q;
  logic [63:0] mdata_q;
  logic [7:0]  mid_q, muser_q;
  logic [15:0] mseq_q;
  logic [19:0] flags_q;
  logic [31:0] events_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      sr_q <= 1'b0;
      mv_q <= 1'b0;
      mr_q <= 1'b0;
    end else begin
      sr_q <= k_sready;
      mv_q <= k_mvalid;
      mr_q <= m_ready;
    end
  end

  always_ff @(posedge clk) begin
    mdata_q  <= m_fields.data[63:0];
    msof_q   <= m_fields.sof;
    meof_q   <= m_fields.eof;
    mid_q    <= 8'(m_fields.stream_id[ID_W-1:0]);
    mseq_q   <= m_fields.seq[SEQ_W-1:0];
    muser_q  <= 8'(m_fields.user[USER_W-1:0]);
    flags_q  <= 20'(k_flags);
    ovf_q    <= k_ovf;
    events_q <= k_events;
  end

  assign s_ready     = sr_q;
  assign m_valid     = mv_q;
  assign m_re0       = mdata_q[15:0];
  assign m_im0       = mdata_q[31:16];
  assign m_re1       = mdata_q[47:32];
  assign m_im1       = mdata_q[63:48];
  assign m_sof       = msof_q;
  assign m_eof       = meof_q;
  assign m_id        = mid_q;
  assign m_seq       = mseq_q;
  assign m_user      = muser_q;
  assign stage_flags = flags_q;
  assign any_ovf     = ovf_q;
  assign ovf_events  = events_q;

endmodule : fft_core_wrap

`default_nettype wire
