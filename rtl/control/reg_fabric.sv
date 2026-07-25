// -----------------------------------------------------------------------------
// reg_fabric — one master port onto N block windows (SPEC.md 9, issue #7).
//
// The whole interconnect of the register plane: address decode, request
// qualification, response selection, and the guarantee that every transaction
// ends. Blocks attach through the flat per-block arrays below; the master sees
// only the SPEC 9 signal list.
//
// Decode
// ------
// Uniform windows (one size for every block, a power of two, each aligned to its
// own size) reduce the decode to an address-bit compare per block and make the
// window a constant-time test rather than a range subtraction. The generator
// enforces uniformity in control/regmap.json, so the RTL may assume it. Windows
// are supplied as a flat vector of bases, in the same order as every per-block
// port array, from regmap_pkg::REGMAP_IMPL_BASE.
//
// The word index inside the window is the same expression for every block —
// address[WINDOW_W-1:2] — so it is computed once here and broadcast, together
// with write_data and byte_enable. A block sees a request only through its own
// `blk_sel` bit, which is high for exactly one cycle per transaction.
//
// Response contract (reg_if_pkg documents the protocol; this is the machinery)
// ---------------------------------------------------------------------------
// A request is accepted when the fabric is idle. From that cycle:
//
//   * a well-formed, mapped request drives the block's select for one cycle and
//     the fabric waits for that block's `ready`. Every block in rtl/control/
//     responds in exactly one cycle, so the master sees `ready` one cycle after
//     the request — REG_ACCESS_LATENCY.
//   * a malformed or unmapped request is answered by the fabric itself, one
//     cycle after the request, with error=1 and read_data=0. No block sees it.
//   * if a block does not respond within REG_WATCHDOG_CYCLES, the fabric ends
//     the transaction itself with error=1 and returns to idle.
//
// The watchdog is why "the fabric never hangs" is a property rather than a hope.
// It cannot fire for the blocks in this design — their response is a register,
// not a handshake — which is exactly the point: it covers the block that has not
// been written yet, the one behind a future clock crossing, and the one whose
// author assumed a bus that stalls politely. sim/verilator/tops/control_top.sv
// instantiates a second fabric against a deliberately dead block so the escape
// is a tested path and not a comment.
//
// Ready/error semantics, precisely:
//   ready is high for exactly one cycle per accepted request and never
//     otherwise;
//   error is meaningful only in that cycle and is driven low elsewhere, so
//     sampling it any other time cannot invent a failure;
//   read_data is valid in that cycle for a read, and zero for a write, an error
//     or an unmapped access.
// -----------------------------------------------------------------------------

`default_nettype none

module reg_fabric
  import reg_if_pkg::*;
#(
    // Blocks attached to this fabric.
    parameter int unsigned N_BLOCKS = 1,
    // Window size per block, as a power of two, expressed as its width in
    // address bits: WINDOW_W = $clog2(window bytes).
    parameter int unsigned WINDOW_W = 12,
    // Window base addresses, flat: block b at [b*REG_ADDR_W +: REG_ADDR_W].
    parameter logic [N_BLOCKS*REG_ADDR_W-1:0] BLOCK_BASE = '0,
    // Cycles to wait for a block before completing the access with error=1.
    parameter int unsigned WATCHDOG_CYCLES = REG_WATCHDOG_CYCLES
) (
    input  wire                      clk,
    input  wire                      rst_n,

    // ---- master port (SPEC 9 signal list) ----
    input  wire [REG_ADDR_W-1:0]     address,
    input  wire [REG_DATA_W-1:0]     write_data,
    input  wire [REG_STRB_W-1:0]     byte_enable,
    input  wire                      write_enable,
    input  wire                      read_enable,
    output wire [REG_DATA_W-1:0]     read_data,
    output wire                      ready,
    output wire                      error,

    // ---- block ports ----
    output wire [N_BLOCKS-1:0]       blk_sel,
    output wire                      blk_write_enable,
    output wire                      blk_read_enable,
    output wire [WINDOW_W-3:0]       blk_index,
    output wire [REG_DATA_W-1:0]     blk_write_data,
    output wire [REG_STRB_W-1:0]     blk_byte_enable,
    input  wire [N_BLOCKS*REG_DATA_W-1:0] blk_read_data,
    input  wire [N_BLOCKS-1:0]       blk_ready,
    input  wire [N_BLOCKS-1:0]       blk_error
);

  // The word index is WINDOW_W-2 bits wide, which is why `blk_index` is declared
  // [WINDOW_W-3:0] above: a port width cannot reference a body localparam.
  localparam int unsigned WD_W = (WATCHDOG_CYCLES <= 1) ? 1 : $clog2(WATCHDOG_CYCLES + 1);

  // ---------------------------------------------------------------------------
  // Request qualification and window decode
  // ---------------------------------------------------------------------------
  wire req       = reg_req_active(write_enable, read_enable);
  wire malformed = reg_req_malformed(address[1:0], byte_enable, write_enable, read_enable);

  logic [N_BLOCKS-1:0] hit;
  for (genvar b = 0; b < N_BLOCKS; b++) begin : g_decode
    localparam logic [REG_ADDR_W-1:0] BASE_B = BLOCK_BASE[b*REG_ADDR_W +: REG_ADDR_W];
    // Uniform, self-aligned windows: membership is the high address bits.
    assign hit[b] = (address[REG_ADDR_W-1:WINDOW_W] == BASE_B[REG_ADDR_W-1:WINDOW_W]);
  end

  wire any_hit = |hit;

  // ---------------------------------------------------------------------------
  // Transaction state
  // ---------------------------------------------------------------------------
  logic                busy_q;
  logic [N_BLOCKS-1:0] sel_q;     // which block owns the outstanding request
  logic                err_q;     // the fabric already knows this one fails
  logic                read_q;    // it was a read
  logic [WD_W-1:0]     wd_q;

  wire accept = req && !busy_q;
  wire route  = accept && !malformed && any_hit;

  wire blk_resp = |(sel_q & blk_ready);
  wire wd_fire  = busy_q && (wd_q >= WD_W'(WATCHDOG_CYCLES));
  wire done     = busy_q && (err_q || blk_resp || wd_fire);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      busy_q <= 1'b0;
      sel_q  <= '0;
      err_q  <= 1'b0;
      read_q <= 1'b0;
      wd_q   <= '0;
    end else if (!busy_q) begin
      busy_q <= req;
      sel_q  <= route ? hit : '0;
      err_q  <= req && (malformed || !any_hit);
      read_q <= req && read_enable && !malformed;
      wd_q   <= '0;
    end else begin
      if (done) begin
        busy_q <= 1'b0;
        sel_q  <= '0;
        err_q  <= 1'b0;
        read_q <= 1'b0;
        wd_q   <= '0;
      end else begin
        wd_q <= wd_q + WD_W'(1);
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Block-facing broadcast. Selects are one cycle wide by construction: `route`
  // is only ever true in an accept cycle, and an accept cannot happen while the
  // fabric is busy.
  // ---------------------------------------------------------------------------
  assign blk_sel          = hit & {N_BLOCKS{route}};
  assign blk_write_enable = write_enable;
  assign blk_read_enable  = read_enable;
  assign blk_index        = address[WINDOW_W-1:2];
  assign blk_write_data   = write_data;
  assign blk_byte_enable  = byte_enable;

  // ---------------------------------------------------------------------------
  // Response selection
  // ---------------------------------------------------------------------------
  logic [REG_DATA_W-1:0] rd_mux;
  logic                  err_mux;
  always_comb begin
    rd_mux  = '0;
    err_mux = 1'b0;
    for (int unsigned b = 0; b < N_BLOCKS; b++) begin
      if (sel_q[b]) begin
        rd_mux  = rd_mux | blk_read_data[b*REG_DATA_W +: REG_DATA_W];
        err_mux = err_mux | blk_error[b];
      end
    end
  end

  wire failed = err_q || wd_fire || err_mux;

  assign ready     = done;
  assign error     = done && failed;
  assign read_data = (done && read_q && !failed) ? rd_mux : '0;

  // ---------------------------------------------------------------------------
  // Protocol assertions (SPEC 14). Simulation only; the checker watches both
  // sides — the master's stability obligation and the fabric's response
  // obligations — so a harness that violates the protocol it is testing is
  // reported rather than believed.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  reg_if_checker #(
      .WATCHDOG_CYCLES (WATCHDOG_CYCLES)
  ) u_checker (
      .clk          (clk),
      .rst_n        (rst_n),
      .address      (address),
      .write_data   (write_data),
      .byte_enable  (byte_enable),
      .write_enable (write_enable),
      .read_enable  (read_enable),
      .read_data    (read_data),
      .ready        (ready),
      .error        (error),
      .busy         (busy_q)
  );
`endif

endmodule : reg_fabric

`default_nettype wire
