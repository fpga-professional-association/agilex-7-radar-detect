// -----------------------------------------------------------------------------
// pkt_slice_core — the measured entity of the SPEC 18 two-stage fabric-slice
// calibration (issue #18).
//
// Two rtl/packet/pkt_switch_stage.sv instances in series with the credit loop
// between them closed locally. A named module rather than two instances inside
// quartus/calibration/pkt_slice_wrap.sv, so that quartus/scripts/calibrate.tcl
// has one `u_kernel` entity row to extract — exactly as it does for every other
// calibration point. See pkt_slice_wrap.sv for why a two-stage slice is the
// right unit and what it deliberately does not price.
//
// Listed in sim/verilator/files_packet.f so `make lint` covers it.
// -----------------------------------------------------------------------------

`default_nettype none

module pkt_slice_core #(
    parameter int unsigned PACKET_W = 512,
    parameter int unsigned N_VC     = 4,
    parameter int unsigned RADIX    = 4,
    parameter int unsigned VC_DEPTH = 4,
    parameter int unsigned OUT_PIPE = 0
) (
    input  wire                          clk,
    input  wire                          rst_n,

    input  wire [RADIX-1:0]              in_valid,
    input  wire [RADIX*(PACKET_W+5)-1:0] in_flit,
    output wire [RADIX*N_VC-1:0]         in_credit_out,

    output wire [RADIX-1:0]              out_valid,
    output wire [RADIX*(PACKET_W+5)-1:0] out_flit,
    input  wire [RADIX*N_VC-1:0]         out_credit_in,

    input  wire [RADIX*N_VC-1:0]         fi_credit_kill_a,
    input  wire [RADIX*N_VC-1:0]         fi_credit_kill_b,
    input  wire                          tel_clear,

    output wire [31:0]                   tel_flits_a,
    output wire [31:0]                   tel_flits_b,
    output wire [31:0]                   tel_stall_a,
    output wire [31:0]                   tel_stall_b,
    output wire [15:0]                   tel_max_wait_a,
    output wire [15:0]                   tel_max_wait_b
);

  localparam int unsigned FLIT_W = PACKET_W + 5;
  localparam int unsigned OCC_W  = $clog2(VC_DEPTH + 1);

  // The inter-stage link: flits forward, credits back, both registered inside
  // the switches. This is the credit loop the point exists to price.
  wire [RADIX-1:0]        mid_valid;
  wire [RADIX*FLIT_W-1:0] mid_flit;
  wire [RADIX*N_VC-1:0]   mid_credit;

  wire [OCC_W-1:0] unused_hw_a, unused_hw_b;

  pkt_switch_stage #(
      .PACKET_W   (PACKET_W),
      .N_VC       (N_VC),
      .RADIX      (RADIX),
      .DEST_DIGIT (1),
      .VC_DEPTH   (VC_DEPTH),
      .CREDITS    (VC_DEPTH),
      .OUT_PIPE   (OUT_PIPE),
      .STORAGE    ("regs")
  ) u_stage_a (
      .clk            (clk),
      .rst_n          (rst_n),
      .in_valid       (in_valid),
      .in_flit        (in_flit),
      .in_credit_out  (in_credit_out),
      .out_valid      (mid_valid),
      .out_flit       (mid_flit),
      .out_credit_in  (mid_credit),
      .fi_credit_kill (fi_credit_kill_a),
      .tel_flits      (tel_flits_a),
      .tel_stall      (tel_stall_a),
      .tel_hiwater    (unused_hw_a),
      .tel_max_wait   (tel_max_wait_a),
      .tel_clear      (tel_clear)
  );

  pkt_switch_stage #(
      .PACKET_W   (PACKET_W),
      .N_VC       (N_VC),
      .RADIX      (RADIX),
      .DEST_DIGIT (0),
      .VC_DEPTH   (VC_DEPTH),
      .CREDITS    (VC_DEPTH),
      .OUT_PIPE   (OUT_PIPE),
      .STORAGE    ("regs")
  ) u_stage_b (
      .clk            (clk),
      .rst_n          (rst_n),
      .in_valid       (mid_valid),
      .in_flit        (mid_flit),
      .in_credit_out  (mid_credit),
      .out_valid      (out_valid),
      .out_flit       (out_flit),
      .out_credit_in  (out_credit_in),
      .fi_credit_kill (fi_credit_kill_b),
      .tel_flits      (tel_flits_b),
      .tel_stall      (tel_stall_b),
      .tel_hiwater    (unused_hw_b),
      .tel_max_wait   (tel_max_wait_b),
      .tel_clear      (tel_clear)
  );

  logic unused_status;
  assign unused_status = ^{unused_hw_a, unused_hw_b};

endmodule : pkt_slice_core

`default_nettype wire
