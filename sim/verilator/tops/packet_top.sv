// -----------------------------------------------------------------------------
// packet_top — packet-network verification top (issue #18, SPEC 13.1).
//
// Holds the WHOLE SPEC 7.8 fabric in one elaboration, on one clock, with flat
// vector ports so the C++ tests can drive every ingress port and observe every
// egress port on the same cycle. A failure in this build is unambiguously a
// packet-network failure — the same arrangement, for the same reason, as
// cmult_top, pfb_top, fft_top, covar_top, beamformer_top and cfar_top.
//
// ONE ELABORATION, THE NOMINAL SIZE. RADIX = 4, STAGES = 2, so N_PORTS = 16:
// SPEC 7.8's "16 or more ingress ports", four virtual channels, and PACKET_W
// from config/<name>.json. This is the shape the topology arithmetic has to be
// right for — a single-stage elaboration would exercise the switch and nothing
// about the butterfly wiring, and a two-stage one exercises both the wiring and
// the per-hop credit loop.
//
// The geometry echo below is the same device cfar_top uses: every constant the
// C++ mirror in model/cpp/packet/packet_model.hpp depends on is exported as a
// port and checked before any stimulus runs, so a layout change in packet_pkg
// that the model did not follow is a named failure rather than a wrong
// comparison. Both the FLIT control offsets and the HEADER field offsets are
// echoed, because those are the two layouts the model reproduces.
//
// Simulation only. Not in files.f, never in a Quartus source list; the fabric
// itself is design RTL and is.
// -----------------------------------------------------------------------------

`default_nettype none

module packet_top
  import packet_pkg::*;
#(
    // Flit payload width, from the generated configuration package.
    parameter int unsigned PACKET_W = config_pkg::PACKET_W,

    // Virtual channels, a SPEC 3 invariant.
    parameter int unsigned N_VC = config_pkg::N_VIRTUAL_CHANS,

    parameter int unsigned RADIX     = 4,
    parameter int unsigned STAGES    = 2,
    parameter int unsigned VC_DEPTH  = 4,
    parameter int unsigned END_DEPTH = 8,
    parameter int unsigned OUT_PIPE  = 0
) (
    input  wire                                     clk,
    input  wire                                     rst_n,

    // ---- ingress message interfaces ----------------------------------------
    input  wire [(RADIX**STAGES)-1:0]               s_valid,
    output wire [(RADIX**STAGES)-1:0]               s_ready,
    input  wire [(RADIX**STAGES)*PACKET_W-1:0]      s_data,
    input  wire [(RADIX**STAGES)-1:0]               s_sof,
    input  wire [(RADIX**STAGES)-1:0]               s_eof,
    input  wire [(RADIX**STAGES)*PKT_DEST_W-1:0]    s_dest,
    input  wire [(RADIX**STAGES)*PKT_TYPE_W-1:0]    s_type,
    input  wire [(RADIX**STAGES)*PKT_VC_W-1:0]      s_vc,
    input  wire [(RADIX**STAGES)*PKT_LEN_W-1:0]     s_len,

    // ---- egress flit interfaces --------------------------------------------
    output wire [(RADIX**STAGES)-1:0]               m_valid,
    input  wire [(RADIX**STAGES)-1:0]               m_ready,
    output wire [(RADIX**STAGES)*(PACKET_W+5)-1:0]  m_flit,
    input  wire [(RADIX**STAGES)*N_VC-1:0]          m_vc_en,

    // ---- fault injection ----------------------------------------------------
    input  wire [(RADIX**STAGES)*2-1:0]             fi_flip,
    input  wire [STAGES*(RADIX**STAGES)*N_VC-1:0]   fi_credit_kill,

    // ---- telemetry ----------------------------------------------------------
    output wire [(RADIX**STAGES)*32-1:0]            tel_ing_packets,
    output wire [(RADIX**STAGES)*32-1:0]            tel_egr_packets,
    output wire [STAGES*32-1:0]                     tel_stage_flits,
    output wire [STAGES*32-1:0]                     tel_stage_stall,
    output wire [STAGES*16-1:0]                     tel_stage_maxwait,
    output wire [STAGES*8-1:0]                      tel_stage_hiwater,
    output wire [(RADIX**STAGES)*4-1:0]             ing_err,
    output wire [(RADIX**STAGES)*5-1:0]             egr_err,
    input  wire                                     tel_clear,

    // ---- geometry echo ------------------------------------------------------
    output wire [15:0] cfg_packet_w,
    output wire [7:0]  cfg_n_vc,
    output wire [7:0]  cfg_radix,
    output wire [7:0]  cfg_stages,
    output wire [15:0] cfg_n_ports,
    output wire [15:0] cfg_flit_w,
    output wire [7:0]  cfg_hdr_w,
    output wire [7:0]  cfg_dest_w,
    output wire [7:0]  cfg_src_w,
    output wire [7:0]  cfg_vc_w,
    output wire [7:0]  cfg_type_w,
    output wire [7:0]  cfg_len_w,
    output wire [7:0]  cfg_seq_w,
    output wire [7:0]  cfg_max_flits,
    output wire [7:0]  cfg_flit_parity_lsb,
    output wire [7:0]  cfg_flit_vc_lsb,
    output wire [7:0]  cfg_flit_sof_lsb,
    output wire [7:0]  cfg_flit_eof_lsb,
    output wire [7:0]  cfg_flit_data_lsb,
    output wire [7:0]  cfg_hdr_dest_lsb,
    output wire [7:0]  cfg_hdr_src_lsb,
    output wire [7:0]  cfg_hdr_vc_lsb,
    output wire [7:0]  cfg_hdr_type_lsb,
    output wire [7:0]  cfg_hdr_len_lsb,
    output wire [7:0]  cfg_hdr_seq_lsb,
    output wire [15:0] cfg_detect_payload_w,
    output wire [7:0]  cfg_detect_flits,
    output wire [7:0]  cfg_vc_depth,
    output wire [7:0]  cfg_end_depth
);

`ifndef SYNTHESIS
  initial begin
    // The configuration cross-check pkt_fabric deliberately does not carry
    // (see its elaboration block): this is the build that has a generated
    // configuration package, so this is where the two are compared.
    if (config_pkg::PACKET_W != int'(PACKET_W)) begin
      $fatal(1, "packet_top: config PACKET_W=%0d disagrees with the elaborated %0d",
             config_pkg::PACKET_W, PACKET_W);
    end
    if (config_pkg::N_VIRTUAL_CHANS != int'(PKT_N_VC)) begin
      $fatal(1, "packet_top: config N_VIRTUAL_CHANS=%0d disagrees with packet_pkg PKT_N_VC=%0d",
             config_pkg::N_VIRTUAL_CHANS, PKT_N_VC);
    end
    if (int'(cfar_pkg::CFAR_EVENT_W) != int'(pkt_detection_payload_w())) begin
      $fatal(1, "packet_top: the detection payload width disagrees with cfar_pkg");
    end
  end
`endif

  pkt_fabric #(
      .PACKET_W  (PACKET_W),
      .N_VC      (N_VC),
      .RADIX     (RADIX),
      .STAGES    (STAGES),
      .VC_DEPTH  (VC_DEPTH),
      .END_DEPTH (END_DEPTH),
      .OUT_PIPE  (OUT_PIPE),
      .STORAGE   ("regs")
  ) u_fabric (
      .clk               (clk),
      .rst_n             (rst_n),
      .s_valid           (s_valid),
      .s_ready           (s_ready),
      .s_data            (s_data),
      .s_sof             (s_sof),
      .s_eof             (s_eof),
      .s_dest            (s_dest),
      .s_type            (s_type),
      .s_vc              (s_vc),
      .s_len             (s_len),
      .m_valid           (m_valid),
      .m_ready           (m_ready),
      .m_flit            (m_flit),
      .m_vc_en           (m_vc_en),
      .fi_flip           (fi_flip),
      .fi_credit_kill    (fi_credit_kill),
      .tel_ing_packets   (tel_ing_packets),
      .tel_egr_packets   (tel_egr_packets),
      .tel_stage_flits   (tel_stage_flits),
      .tel_stage_stall   (tel_stage_stall),
      .tel_stage_maxwait (tel_stage_maxwait),
      .tel_stage_hiwater (tel_stage_hiwater),
      .ing_err           (ing_err),
      .egr_err           (egr_err),
      .tel_clear         (tel_clear)
  );

  // ---------------------------------------------------------------------------
  // Geometry echo
  // ---------------------------------------------------------------------------
  assign cfg_packet_w         = 16'(PACKET_W);
  assign cfg_n_vc             = 8'(N_VC);
  assign cfg_radix            = 8'(RADIX);
  assign cfg_stages           = 8'(STAGES);
  assign cfg_n_ports          = 16'(RADIX**STAGES);
  assign cfg_flit_w           = 16'(pkt_flit_w(pkt_uint_t'(PACKET_W)));
  assign cfg_hdr_w            = 8'(pkt_hdr_w());
  assign cfg_dest_w           = 8'(pkt_dest_w());
  assign cfg_src_w            = 8'(pkt_src_w());
  assign cfg_vc_w             = 8'(pkt_vc_w());
  assign cfg_type_w           = 8'(pkt_type_w());
  assign cfg_len_w            = 8'(pkt_len_w());
  assign cfg_seq_w            = 8'(pkt_seq_w());
  assign cfg_max_flits        = 8'(pkt_max_flits());
  assign cfg_flit_parity_lsb  = 8'(PKT_FLIT_PARITY_LSB);
  assign cfg_flit_vc_lsb      = 8'(PKT_FLIT_VC_LSB);
  assign cfg_flit_sof_lsb     = 8'(PKT_FLIT_SOF_LSB);
  assign cfg_flit_eof_lsb     = 8'(PKT_FLIT_EOF_LSB);
  assign cfg_flit_data_lsb    = 8'(PKT_FLIT_DATA_LSB);
  assign cfg_hdr_dest_lsb     = 8'(pkt_hdr_bit(PKT_HSEL_DEST));
  assign cfg_hdr_src_lsb      = 8'(pkt_hdr_bit(PKT_HSEL_SRC));
  assign cfg_hdr_vc_lsb       = 8'(pkt_hdr_bit(PKT_HSEL_VC));
  assign cfg_hdr_type_lsb     = 8'(pkt_hdr_bit(PKT_HSEL_TYPE));
  assign cfg_hdr_len_lsb      = 8'(pkt_hdr_bit(PKT_HSEL_LEN));
  assign cfg_hdr_seq_lsb      = 8'(pkt_hdr_bit(PKT_HSEL_SEQ));
  assign cfg_detect_payload_w = 16'(pkt_detection_payload_w());
  assign cfg_detect_flits     = 8'(pkt_detection_flits(pkt_uint_t'(PACKET_W)));
  assign cfg_vc_depth         = 8'(VC_DEPTH);
  assign cfg_end_depth        = 8'(END_DEPTH);

endmodule : packet_top

`default_nettype wire
