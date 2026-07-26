// -----------------------------------------------------------------------------
// history_bank_wrap — SPEC.md 18 item 8 calibration wrapper: "one M20K history
// bank" (issue #15).
//
// Registered pins in, one history_bank, registered pins out. Everything between
// the two register stages is what the sweep measures, and the instance is named
// `u_kernel` because quartus/scripts/calibrate.tcl matches `*u_kernel*` to pull
// the per-entity resource row and to decide whether the worst
// register-to-register path is inside the kernel or in the harness.
//
// -----------------------------------------------------------------------------
// WHAT THIS SWEEP IS ACTUALLY ASKING
// -----------------------------------------------------------------------------
// Not "how many M20Ks does a history bank cost" — that is arithmetic. The three
// questions worth Fitter time are:
//
//   1. HOW DOES QUARTUS PACK A GIVEN CAPACITY? An M20K holds 20 480 bits, but
//      only at the widths its modes support (512x40, 1Kx20, 2Kx10, and the
//      no-parity 512x32, 1Kx16, 2Kx8 forms). A history bank's natural word is
//      one complex sample, 32 bits, which fits 512x32 and wastes the parity
//      bits. The sweep asks the same capacity at three aspect ratios and reads
//      the block count back, because the answer decides the full-scale M20K
//      budget and SPEC 2 targets 55-80% M20K utilisation.
//
//   2. ARE THE INPUT AND OUTPUT REGISTERS ABSORBED INTO THE HARD BLOCK? SPEC 23
//      requires registers around M20Ks and SPEC 18 names "input and output
//      register choices" as an axis. If Quartus absorbs them, they cost no ALMs
//      and the memory path closes; if it does not, they cost ALM registers and
//      the path is a fabric path. The evidence is the critical path's endpoint
//      names — `ram_block*~reg*` means absorbed — which calibrate.tcl records as
//      `reg2reg_source` / `reg2reg_destination` for every point. Issue #11 found
//      exactly that signature in its delay-feedback lines, so the pattern to
//      look for is known.
//
//   3. WHERE IS THE MLAB/M20K CROSSOVER? A shallow bank in an M20K wastes a
//      block; a deep one in MLABs costs a great many ALMs. `MEM_SEL` forces each
//      style so the crossover is a measured number rather than fft_pkg's
//      extrapolated 64-word rule applied to a different shape.
//
// -----------------------------------------------------------------------------
// ONE CLOCK, DELIBERATELY, AND WHAT THAT COSTS
// -----------------------------------------------------------------------------
// history_bank has independent write and read clocks; this wrapper ties both to
// `clk`. That is a real simplification and it is stated rather than hidden.
//
// Why it is the right one: what the sweep measures is the memory's GEOMETRY, its
// register absorption and the delay of the path through it, none of which
// depends on whether the two clock nets are the same net. What it would cost to
// do otherwise is worse than what it buys: two asynchronous clocks on a
// virtual-pin harness means either a clock group (which SPEC 24 treats as a
// constraint to justify, not to reach for) or a reg2reg query that can return a
// cross-domain path and report a number that means nothing.
//
// What is therefore NOT measured here: whether the dual-clock form of the M20K
// costs anything the single-clock form does not. That belongs to the full-design
// fit (issue #21), where the real clocks exist, and it is written down here so
// that the omission is a known gap rather than an unnoticed one.
//
// Ports are sized independently of the parameters so the `.qsf`'s virtual-pin
// globs name the same pins at every point. Only the valid bit is reset, per
// SPEC 23: a wide synchronous clear would distort both the ALM count and the
// retiming result.
//
// Lint contract: linted by `make lint` through sim/verilator/files_history.f.
// -----------------------------------------------------------------------------

`default_nettype none

module history_bank_wrap #(
    // Stored word width, in bits.
    parameter int unsigned WIDTH = 32,

    // Stored words.
    parameter int unsigned DEPTH = 512,

    // Registers between the module face and the array, 0 or 1 each.
    parameter int unsigned IN_REG  = 1,
    parameter int unsigned OUT_REG = 1,

    // Storage style selector. An integer rather than a string because
    // `set_parameter` is only depended on for integers (the same device
    // fft_stage_wrap.sv uses for its MEM_SEL):
    //   0 auto   1 m20k   2 mlab   3 regs
    parameter int unsigned MEM_SEL = 0
) (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         vld_in,
    input  wire         wr_en_in,
    input  wire [15:0]  wr_addr_in,
    input  wire [63:0]  wr_data_in,
    input  wire         rd_en_in,
    input  wire [15:0]  rd_addr_in,

    output wire         vld_out,
    output wire         dv_out,
    output wire [63:0]  rd_data_out
);

  localparam int unsigned ADDR_W = (DEPTH > 1) ? $clog2(DEPTH) : 1;

  localparam string MEM_STYLE =
      (MEM_SEL == 1) ? "m20k" :
      (MEM_SEL == 2) ? "mlab" :
      (MEM_SEL == 3) ? "regs" : "auto";

  // ---- input registers ----
  logic              vin_q;
  logic              wen_q, ren_q;
  logic [ADDR_W-1:0] waddr_q, raddr_q;
  logic [WIDTH-1:0]  wdata_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      vin_q <= 1'b0;
      wen_q <= 1'b0;
      ren_q <= 1'b0;
    end else begin
      vin_q <= vld_in;
      wen_q <= wr_en_in;
      ren_q <= rd_en_in;
    end
  end

  always_ff @(posedge clk) begin
    waddr_q <= wr_addr_in[ADDR_W-1:0];
    raddr_q <= rd_addr_in[ADDR_W-1:0];
    wdata_q <= wr_data_in[WIDTH-1:0];
  end

  wire [WIDTH-1:0] rdata_w;
  wire             dv_w;

  history_bank #(
      .WIDTH   (WIDTH),
      .DEPTH   (DEPTH),
      .IN_REG  (IN_REG[0]),
      .OUT_REG (OUT_REG[0]),
      .STORAGE (MEM_STYLE)
  ) u_kernel (
      .wr_clk        (clk),
      .wr_rst_n      (rst_n),
      .wr_en         (wen_q),
      .wr_addr       (waddr_q),
      .wr_data       (wdata_q),
      .rd_clk        (clk),
      .rd_rst_n      (rst_n),
      .rd_en         (ren_q),
      .rd_addr       (raddr_q),
      .rd_data_valid (dv_w),
      .rd_data       (rdata_w)
  );

  // ---- output registers ----
  logic             vout_q, dvout_q;
  logic [WIDTH-1:0] rdata_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      vout_q  <= 1'b0;
      dvout_q <= 1'b0;
    end else begin
      vout_q  <= vin_q;
      dvout_q <= dv_w;
    end
  end

  always_ff @(posedge clk) begin
    rdata_q <= rdata_w;
  end

  assign vld_out     = vout_q;
  assign dv_out      = dvout_q;
  assign rd_data_out = 64'(rdata_q);

endmodule : history_bank_wrap

`default_nettype wire
