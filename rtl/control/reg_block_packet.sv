// -----------------------------------------------------------------------------
// reg_block_packet — the packet-network window (SPEC.md 7.8, 9; issue #18).
//
// Window 0xB000. The software half of rtl/packet/: the elaborated topology and
// the packet format reported by hardware, the two SPEC 9 fault-injection hooks,
// the sticky reassembly errors from both ends of the network, and the per-stage
// and per-port telemetry coming back the other way.
//
// WHAT THIS BLOCK DOES AND DOES NOT DO
// ------------------------------------
// It owns the register storage, the decode and the TEL_CLEAR strobe. It does NOT
// own any fabric semantics: routing, arbitration, credit accounting and
// reassembly checking all live in rtl/packet/ and stay there, so a fabric
// instantiated without a register plane — which is exactly what
// sim/verilator/tops/packet_top.sv and the SPEC 18 calibration wrappers do —
// behaves identically. The `cfg_*` port group is a plain configuration bus into
// the fabric's fault-injection inputs, and `hw_*` is its telemetry coming back.
//
// The GEOMETRY and FORMAT registers are reported by hardware rather than being
// constants in the map, for the reason the coefficient and CFAR windows report
// theirs: PACKET_W is a SPEC 11 sized parameter and the port count follows the
// elaborated radix and stage count, so a register map that baked them in would
// be a different map at every configuration. The FORMAT fields are constants of
// packet_pkg and are reported anyway, so that software decoding a captured
// packet needs no build-time header at all.
//
// THE OBSERVATION WINDOW. PACKET_FLITS, PACKET_STALLS, PACKET_WATERMARK,
// PACKET_PKT_IN and PACKET_PKT_OUT report ONE stage and ONE port, named by
// PACKET_OBSERVE. The counters themselves free-run in hardware for every stage
// and every port; only the read is multiplexed, and the multiplexer lives in the
// block that owns the fabric rather than here — this block simply exports the
// selector and consumes the selected values. Sixteen ports times two counters
// times 32 bits is 1 kbit of register space to avoid moving a five-bit selector.
//
// rtl/control/generated/regmap_pkg.sv supplies every mask and index; nothing here
// is a literal. The generated field widths are additionally checked against
// rtl/packages/packet_pkg.sv at elaboration, so the register map and the RTL
// cannot drift apart silently — control/regmap.json and packet_pkg.sv are two
// files, and two files drift.
//
// Lint contract: clean under `--Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module reg_block_packet
  import reg_if_pkg::*;
  import regmap_pkg::*;
#(
    parameter int unsigned IDX_W = REGMAP_WINDOW_W - 2
) (
    input  wire                                clk,
    input  wire                                rst_n,

    input  wire                                sel,
    input  wire                                write_enable,
    input  wire                                read_enable,
    input  wire [IDX_W-1:0]                    index,
    input  wire [REG_DATA_W-1:0]               write_data,
    input  wire [REG_STRB_W-1:0]               byte_enable,

    output wire [REG_DATA_W-1:0]               read_data,
    output wire                                ready,
    output wire                                error,

    // ---- to rtl/packet/ ----------------------------------------------------
    output wire                                cfg_enable,
    output wire                                cfg_tel_clear,     // one-cycle pulse
    output wire [1:0]                          cfg_flip_mask,
    output wire [4:0]                          cfg_flip_port,
    output wire                                cfg_kill_en,
    output wire [3:0]                          cfg_kill_stage,
    output wire [4:0]                          cfg_kill_port,
    output wire [1:0]                          cfg_kill_vc,
    output wire [4:0]                          cfg_observe_port,
    output wire [3:0]                          cfg_observe_stage,

    // ---- from rtl/packet/ ---------------------------------------------------
    input  wire [7:0]                          hw_n_ports,
    input  wire [7:0]                          hw_n_vc,
    input  wire [7:0]                          hw_radix,
    input  wire [7:0]                          hw_stages,
    input  wire [15:0]                         hw_packet_w,
    input  wire [15:0]                         hw_flit_w,
    input  wire [7:0]                          hw_hdr_w,
    input  wire [7:0]                          hw_max_flits,
    input  wire [7:0]                          hw_seq_w,
    input  wire [3:0]                          hw_dest_w,
    input  wire [3:0]                          hw_src_w,
    // Sticky error set inputs, in the register's own bit order:
    //   [3:0] ingress  length, type, vc, length-range
    //   [8:4] egress   parity, length, vc, dest, type
    input  wire [8:0]                          hw_err,
    input  wire [31:0]                         hw_flits,
    input  wire [31:0]                         hw_stalls,
    input  wire [15:0]                         hw_max_wait,
    input  wire [7:0]                          hw_hiwater,
    input  wire [31:0]                         hw_pkt_in,
    input  wire [31:0]                         hw_pkt_out,

    // Storage, observable without going through the read mux.
    output wire [REGMAP_PACKET_N_REGS*32-1:0]  csr,
    output wire [REGMAP_PACKET_N_REGS*32-1:0]  pulse
);

  localparam int unsigned NR = REGMAP_PACKET_N_REGS;

  // ---------------------------------------------------------------------------
  // Hardware-driven fields and the W1C set inputs
  //
  // Every field is written through its own generated LSB rather than as one
  // concatenation, so a field that moves in control/regmap.json moves here with
  // it instead of silently landing on its neighbour. That is the idiom
  // reg_block_cfar recommends and this block copies.
  // ---------------------------------------------------------------------------
  logic [NR*32-1:0] hw_value;
  logic [NR*32-1:0] hw_set;

  always_comb begin
    hw_value = '0;

    hw_value[REGMAP_PACKET_PACKET_STATUS_INDEX*32 +
             REGMAP_PACKET_PACKET_STATUS_N_PORTS_LSB +:
             REGMAP_PACKET_PACKET_STATUS_N_PORTS_WIDTH] = hw_n_ports;
    hw_value[REGMAP_PACKET_PACKET_STATUS_INDEX*32 +
             REGMAP_PACKET_PACKET_STATUS_N_VC_LSB +:
             REGMAP_PACKET_PACKET_STATUS_N_VC_WIDTH] = hw_n_vc;
    hw_value[REGMAP_PACKET_PACKET_STATUS_INDEX*32 +
             REGMAP_PACKET_PACKET_STATUS_RADIX_LSB +:
             REGMAP_PACKET_PACKET_STATUS_RADIX_WIDTH] = hw_radix;
    hw_value[REGMAP_PACKET_PACKET_STATUS_INDEX*32 +
             REGMAP_PACKET_PACKET_STATUS_STAGES_LSB +:
             REGMAP_PACKET_PACKET_STATUS_STAGES_WIDTH] = hw_stages;

    hw_value[REGMAP_PACKET_PACKET_GEOMETRY_INDEX*32 +
             REGMAP_PACKET_PACKET_GEOMETRY_PACKET_W_LSB +:
             REGMAP_PACKET_PACKET_GEOMETRY_PACKET_W_WIDTH] = hw_packet_w;
    hw_value[REGMAP_PACKET_PACKET_GEOMETRY_INDEX*32 +
             REGMAP_PACKET_PACKET_GEOMETRY_FLIT_W_LSB +:
             REGMAP_PACKET_PACKET_GEOMETRY_FLIT_W_WIDTH] = hw_flit_w;

    hw_value[REGMAP_PACKET_PACKET_FORMAT_INDEX*32 +
             REGMAP_PACKET_PACKET_FORMAT_HDR_W_LSB +:
             REGMAP_PACKET_PACKET_FORMAT_HDR_W_WIDTH] = hw_hdr_w;
    hw_value[REGMAP_PACKET_PACKET_FORMAT_INDEX*32 +
             REGMAP_PACKET_PACKET_FORMAT_MAX_FLITS_LSB +:
             REGMAP_PACKET_PACKET_FORMAT_MAX_FLITS_WIDTH] = hw_max_flits;
    hw_value[REGMAP_PACKET_PACKET_FORMAT_INDEX*32 +
             REGMAP_PACKET_PACKET_FORMAT_SEQ_W_LSB +:
             REGMAP_PACKET_PACKET_FORMAT_SEQ_W_WIDTH] = hw_seq_w;
    hw_value[REGMAP_PACKET_PACKET_FORMAT_INDEX*32 +
             REGMAP_PACKET_PACKET_FORMAT_DEST_W_LSB +:
             REGMAP_PACKET_PACKET_FORMAT_DEST_W_WIDTH] = hw_dest_w;
    hw_value[REGMAP_PACKET_PACKET_FORMAT_INDEX*32 +
             REGMAP_PACKET_PACKET_FORMAT_SRC_W_LSB +:
             REGMAP_PACKET_PACKET_FORMAT_SRC_W_WIDTH] = hw_src_w;

    hw_value[REGMAP_PACKET_PACKET_FLITS_INDEX*32 +: 32]   = hw_flits;
    hw_value[REGMAP_PACKET_PACKET_STALLS_INDEX*32 +: 32]  = hw_stalls;
    hw_value[REGMAP_PACKET_PACKET_PKT_IN_INDEX*32 +: 32]  = hw_pkt_in;
    hw_value[REGMAP_PACKET_PACKET_PKT_OUT_INDEX*32 +: 32] = hw_pkt_out;

    hw_value[REGMAP_PACKET_PACKET_WATERMARK_INDEX*32 +
             REGMAP_PACKET_PACKET_WATERMARK_MAX_WAIT_LSB +:
             REGMAP_PACKET_PACKET_WATERMARK_MAX_WAIT_WIDTH] = hw_max_wait;
    hw_value[REGMAP_PACKET_PACKET_WATERMARK_INDEX*32 +
             REGMAP_PACKET_PACKET_WATERMARK_HIWATER_LSB +:
             REGMAP_PACKET_PACKET_WATERMARK_HIWATER_WIDTH] = hw_hiwater;

    // Sticky errors. Hardware sets, software clears by writing 1
    // (reg_csr_block resolves a simultaneous set and clear in favour of the set,
    // which is what stops a read-then-clear from losing an event).
    hw_set = '0;
    hw_set[REGMAP_PACKET_PACKET_ERROR_INDEX*32 +
           REGMAP_PACKET_PACKET_ERROR_ING_LENGTH_LSB]    = hw_err[0];
    hw_set[REGMAP_PACKET_PACKET_ERROR_INDEX*32 +
           REGMAP_PACKET_PACKET_ERROR_ING_TYPE_LSB]      = hw_err[1];
    hw_set[REGMAP_PACKET_PACKET_ERROR_INDEX*32 +
           REGMAP_PACKET_PACKET_ERROR_ING_VC_LSB]        = hw_err[2];
    hw_set[REGMAP_PACKET_PACKET_ERROR_INDEX*32 +
           REGMAP_PACKET_PACKET_ERROR_ING_LEN_RANGE_LSB] = hw_err[3];
    hw_set[REGMAP_PACKET_PACKET_ERROR_INDEX*32 +
           REGMAP_PACKET_PACKET_ERROR_EGR_PARITY_LSB]    = hw_err[4];
    hw_set[REGMAP_PACKET_PACKET_ERROR_INDEX*32 +
           REGMAP_PACKET_PACKET_ERROR_EGR_LENGTH_LSB]    = hw_err[5];
    hw_set[REGMAP_PACKET_PACKET_ERROR_INDEX*32 +
           REGMAP_PACKET_PACKET_ERROR_EGR_VC_LSB]        = hw_err[6];
    hw_set[REGMAP_PACKET_PACKET_ERROR_INDEX*32 +
           REGMAP_PACKET_PACKET_ERROR_EGR_DEST_LSB]      = hw_err[7];
    hw_set[REGMAP_PACKET_PACKET_ERROR_INDEX*32 +
           REGMAP_PACKET_PACKET_ERROR_EGR_TYPE_LSB]      = hw_err[8];
  end

  wire [NR*32-1:0] csr_i;
  wire [NR*32-1:0] pulse_i;

  reg_csr_block #(
      .N_REGS     (NR),
      .IDX_W      (IDX_W),
      .RESET_VAL  (REGMAP_PACKET_RESET),
      .WMASK      (REGMAP_PACKET_WMASK),
      .W1C_MASK   (REGMAP_PACKET_W1CMASK),
      .PULSE_MASK (REGMAP_PACKET_PULSEMASK),
      .HW_MASK    (REGMAP_PACKET_HWMASK)
  ) u_csr (
      .clk          (clk),
      .rst_n        (rst_n),
      .sel          (sel),
      .write_enable (write_enable),
      .read_enable  (read_enable),
      .index        (index),
      .write_data   (write_data),
      .byte_enable  (byte_enable),
      .read_data    (read_data),
      .ready        (ready),
      .error        (error),
      .hw_value     (hw_value),
      .hw_set       (hw_set),
      .csr          (csr_i),
      .pulse        (pulse_i)
  );

  assign csr   = csr_i;
  assign pulse = pulse_i;

  // ---------------------------------------------------------------------------
  // Field extraction. Every offset comes from the generated map.
  // ---------------------------------------------------------------------------
  localparam int unsigned CTRL_BIT  = REGMAP_PACKET_PACKET_CTRL_INDEX*32;
  localparam int unsigned FAULT_BIT = REGMAP_PACKET_PACKET_FAULT_INDEX*32;
  localparam int unsigned OBS_BIT   = REGMAP_PACKET_PACKET_OBSERVE_INDEX*32;

  assign cfg_enable    = csr_i[CTRL_BIT + REGMAP_PACKET_PACKET_CTRL_ENABLE_LSB];
  assign cfg_tel_clear = pulse_i[CTRL_BIT + REGMAP_PACKET_PACKET_CTRL_TEL_CLEAR_LSB];

  assign cfg_flip_mask  = csr_i[FAULT_BIT + REGMAP_PACKET_PACKET_FAULT_FLIP_MASK_LSB +:
                                REGMAP_PACKET_PACKET_FAULT_FLIP_MASK_WIDTH];
  assign cfg_flip_port  = csr_i[FAULT_BIT + REGMAP_PACKET_PACKET_FAULT_FLIP_PORT_LSB +:
                                REGMAP_PACKET_PACKET_FAULT_FLIP_PORT_WIDTH];
  assign cfg_kill_en    = csr_i[FAULT_BIT + REGMAP_PACKET_PACKET_FAULT_KILL_EN_LSB];
  assign cfg_kill_stage = csr_i[FAULT_BIT + REGMAP_PACKET_PACKET_FAULT_KILL_STAGE_LSB +:
                                REGMAP_PACKET_PACKET_FAULT_KILL_STAGE_WIDTH];
  assign cfg_kill_port  = csr_i[FAULT_BIT + REGMAP_PACKET_PACKET_FAULT_KILL_PORT_LSB +:
                                REGMAP_PACKET_PACKET_FAULT_KILL_PORT_WIDTH];
  assign cfg_kill_vc    = csr_i[FAULT_BIT + REGMAP_PACKET_PACKET_FAULT_KILL_VC_LSB +:
                                REGMAP_PACKET_PACKET_FAULT_KILL_VC_WIDTH];

  assign cfg_observe_port  = csr_i[OBS_BIT + REGMAP_PACKET_PACKET_OBSERVE_PORT_LSB +:
                                   REGMAP_PACKET_PACKET_OBSERVE_PORT_WIDTH];
  assign cfg_observe_stage = csr_i[OBS_BIT + REGMAP_PACKET_PACKET_OBSERVE_STAGE_LSB +:
                                   REGMAP_PACKET_PACKET_OBSERVE_STAGE_WIDTH];

  // ---------------------------------------------------------------------------
  // The generated field widths must agree with the RTL's own package. Checked at
  // elaboration rather than by inspection — control/regmap.json and
  // rtl/packages/packet_pkg.sv are two files, and two files drift.
  //
  // These are REPORTING checks: a field too narrow to hold the value it exists
  // to report would publish a truncated number that a packet decoder would then
  // parse with, which is worse than not reporting it at all.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin
    if (int'(packet_pkg::pkt_hdr_w()) >=
        (1 << REGMAP_PACKET_PACKET_FORMAT_HDR_W_WIDTH)) begin
      $fatal(1, "reg_block_packet: PACKET_FORMAT.HDR_W (%0d bits) cannot report a %0d-bit header",
             REGMAP_PACKET_PACKET_FORMAT_HDR_W_WIDTH, int'(packet_pkg::pkt_hdr_w()));
    end
    if (int'(packet_pkg::pkt_max_flits()) >=
        (1 << REGMAP_PACKET_PACKET_FORMAT_MAX_FLITS_WIDTH)) begin
      $fatal(1, "reg_block_packet: PACKET_FORMAT.MAX_FLITS cannot report %0d flits",
             int'(packet_pkg::pkt_max_flits()));
    end
    if (int'(packet_pkg::pkt_dest_w()) >=
        (1 << REGMAP_PACKET_PACKET_FORMAT_DEST_W_WIDTH)) begin
      $fatal(1, "reg_block_packet: PACKET_FORMAT.DEST_W cannot report %0d",
             int'(packet_pkg::pkt_dest_w()));
    end
    if (int'(packet_pkg::pkt_src_w()) >=
        (1 << REGMAP_PACKET_PACKET_FORMAT_SRC_W_WIDTH)) begin
      $fatal(1, "reg_block_packet: PACKET_FORMAT.SRC_W cannot report %0d",
             int'(packet_pkg::pkt_src_w()));
    end
    if (int'(packet_pkg::pkt_max_packet_w()) >=
        (1 << REGMAP_PACKET_PACKET_GEOMETRY_PACKET_W_WIDTH)) begin
      $fatal(1, "reg_block_packet: PACKET_GEOMETRY.PACKET_W cannot report the maximum flit payload");
    end
    // The fault hook's channel selector must be able to name every virtual
    // channel the packet format defines; a narrower field would silently alias
    // one channel onto another and the injection would land somewhere else.
    if ((1 << REGMAP_PACKET_PACKET_FAULT_KILL_VC_WIDTH) <
        int'(packet_pkg::pkt_n_vc())) begin
      $fatal(1, "reg_block_packet: PACKET_FAULT.KILL_VC is %0d bits but there are %0d virtual channels",
             REGMAP_PACKET_PACKET_FAULT_KILL_VC_WIDTH, int'(packet_pkg::pkt_n_vc()));
    end
    if (REGMAP_PACKET_PACKET_FAULT_FLIP_PORT_WIDTH != int'(packet_pkg::pkt_src_w())) begin
      $fatal(1, "reg_block_packet: PACKET_FAULT.FLIP_PORT is %0d bits but the source field is %0d",
             REGMAP_PACKET_PACKET_FAULT_FLIP_PORT_WIDTH, int'(packet_pkg::pkt_src_w()));
    end
  end
`endif

endmodule : reg_block_packet

`default_nettype wire
