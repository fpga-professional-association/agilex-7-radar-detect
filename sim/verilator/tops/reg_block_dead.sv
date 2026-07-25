// -----------------------------------------------------------------------------
// reg_block_dead — a register block that never answers. Simulation only (#7).
//
// Speaks the reg_csr_block request interface and deliberately never asserts
// `ready`. It exists to prove that reg_fabric's watchdog is load-bearing: with
// this block attached, a transaction still completes — with error=1, after
// REG_WATCHDOG_CYCLES — instead of hanging the interface and, eventually, the
// simulation. "The fabric never hangs" is then a tested path rather than a claim
// in a comment.
//
// It is knowingly wrong, in the same sense sim/verilator/tops/stream_violator.sv
// is knowingly wrong, and for the same reason it lives under sim/ and appears in
// no design file list. It can never reach a synthesis build.
//
// The request fields are folded into a signature register so the module consumes
// everything it is given; the value is never observable, because `ready` is
// tied low and the fabric only forwards read data in a response cycle.
// -----------------------------------------------------------------------------

`default_nettype none

module reg_block_dead
  import reg_if_pkg::*;
#(
    parameter int unsigned IDX_W = 10
) (
    input  wire                  clk,
    input  wire                  rst_n,

    input  wire                  sel,
    input  wire                  write_enable,
    input  wire                  read_enable,
    input  wire [IDX_W-1:0]      index,
    input  wire [REG_DATA_W-1:0] write_data,
    input  wire [REG_STRB_W-1:0] byte_enable,

    output wire [REG_DATA_W-1:0] read_data,
    output wire                  ready,
    output wire                  error,

    // Requests this block has swallowed. Read by the test to confirm the access
    // really reached the block before the watchdog rescued the fabric.
    output wire [31:0]           swallowed
);

  logic [31:0] sig_q;
  logic [31:0] count_q;

  wire req = sel && (write_enable || read_enable);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      sig_q   <= 32'd0;
      count_q <= 32'd0;
    end else if (req) begin
      sig_q   <= write_data ^ {{(32 - IDX_W){1'b0}}, index}
                            ^ {{(32 - REG_STRB_W){1'b0}}, byte_enable};
      count_q <= count_q + 32'd1;
    end
  end

  assign read_data = sig_q;
  assign ready     = 1'b0;  // the whole point
  assign error     = 1'b0;
  assign swallowed = count_q;

endmodule : reg_block_dead

`default_nettype wire
