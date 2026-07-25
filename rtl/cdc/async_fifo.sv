// -----------------------------------------------------------------------------
// async_fifo — dual-clock FIFO with Gray-coded pointers (SPEC.md 8, 14, 23).
//
// SPEC 8: "Use asynchronous FIFOs for bulk CDC traffic" and "Use Gray-coded
// pointers for asynchronous FIFOs." This is that FIFO, and it is the bulk-CDC
// workhorse of the whole benchmark: every stream that changes clock domain does
// so through rtl/cdc/stream_cdc.sv, which is a thin wrapper on this module.
//
// Construction follows Cummings, SNUG 2002, "Simulation and Synthesis Techniques
// for Asynchronous FIFO Design" (style 1: pointers compared directly in the Gray
// domain, flags registered):
//
//   * pointers are $clog2(DEPTH)+1 bits — one bit more than the address — so
//     that "the pointers are equal" and "the pointers are a full lap apart" are
//     distinguishable, which is what separates empty from full;
//   * each pointer is held in binary (for addressing and for occupancy
//     arithmetic) and in Gray (for crossing), the Gray copy being the binary
//     *next* value encoded, so both registers update on the same edge and the
//     Gray register is never a stale encoding of the binary one;
//   * each domain sees the other's pointer through a two-flop synchronizer.
//     Synchronizing a multibit bus is legal here, and ONLY here, because the
//     value is Gray-coded: consecutive values differ in one bit, so a sample
//     taken while it changes resolves to the old value or the new one and never
//     to a third value that was never a real pointer. cdc_sync2 requires the
//     instantiator to state that claim (GRAY_CODED) and a cdc_gray_checker on
//     each pointer checks it every cycle rather than trusting it;
//   * `full` is derived in the write domain from the write pointer's *next*
//     Gray value against the synchronized read pointer with its top two bits
//     inverted; `empty` in the read domain from the read pointer's next Gray
//     value against the synchronized write pointer. Both flags are registered.
//
// Both flags are conservative in the safe direction, which is the property that
// makes the crossing correct rather than merely usually-correct: the write side
// sees a read pointer that is up to a synchronizer's worth of cycles stale, so
// it may believe the FIFO is fuller than it is and refuse a write it could have
// taken — it can never believe there is room when there is not. The read side is
// stale in the mirror direction and may believe the FIFO is emptier than it is.
// Neither staleness can produce loss or corruption; both cost throughput, which
// is why DEPTH must be sized against the round trip and not against the burst.
//
// RESET (the part asynchronous FIFOs get wrong)
// ---------------------------------------------
// A dual-clock FIFO has two resets and they are not independent. Reset one side
// only and its pointer goes to zero while the other side's does not: the FIFO
// then reports a fill level that corresponds to no data, and the read side walks
// through stale storage. That is silent corruption, not loss.
//
// The contract this module implements, and which DECISIONS.md records:
//
//   ASSERTION is common and simultaneous.  `wr_rst_n` and `rd_rst_n` are driven
//       from one system reset. Asserting one alone is a design error, and the
//       `a_reset_pointers_cleared` assertion below detects it.
//   RELEASE is per domain and synchronous to that domain's own clock. This is
//       the standard asynchronous-assert / synchronous-release arrangement, and
//       it is what the SPEC 12.2 harness's ResetSequencer does. Each domain
//       therefore leaves reset at a different absolute time.
//   The FIFO ITSELF BRIDGES THE SKEW. Each domain synchronizes a single "the
//       other domain is in reset" bit — through cdc_sync2, with a reset value of
//       1 so the safe interpretation survives its own reset — and refuses to
//       write or to read until the other side is out of reset. Both pointers are
//       therefore provably zero at the instant either side starts, whatever the
//       release skew.
//
// The alternative arrangements, and why not:
//   * fully synchronous reset in both domains with a common release: needs a
//     global synchronous release across asynchronous clocks, which is the thing
//     that cannot be built.
//   * asynchronous reset inside the FIFO: SPEC 23 rules out asynchronous resets
//     in performance-critical logic, and an asynchronous release into a Gray
//     counter is precisely the recovery hazard this scheme removes.
//   * no gating, "just reset them together": relies on release skew being zero,
//     which it is not, and fails silently rather than loudly when it is not.
//
// Reset scope is control state only (SPEC 23): pointers, flags, the hold
// synchronizers, the sticky error state and the output register's validity. The
// storage array has no reset.
//
// Depth must be a power of two: the Gray full/empty derivation is valid only
// when the pointer wraps exactly at the top of its binary range.
// -----------------------------------------------------------------------------

`default_nettype none

// Simulation-only: the SPEC 14 property macros. Guarded so a synthesis run never
// has to find the include path, and so the file list that feeds Quartus does not
// need +incdir+sim/assertions.
`ifndef SYNTHESIS
`include "cdc_sva.svh"
`endif

(* cdc_primitive = "async_fifo_gray", cdc_src_clk = "wr_clk", cdc_dst_clk = "rd_clk", cdc_width = "WIDTH", cdc_stages = "SYNC_STAGES" *)
module async_fifo #(
    parameter int unsigned WIDTH = 32,

    // Entries. Power of two, minimum 2 (checked at elaboration). Size it against
    // the synchronizer round trip — roughly 2 x SYNC_STAGES cycles of the slower
    // clock — plus the burst to be absorbed, not against the burst alone.
    parameter int unsigned DEPTH = 16,

    // Flip-flops per pointer synchronizer chain. Each stage is a cycle of extra
    // staleness on both flags, so this is a depth cost as well as a latency one.
    parameter int unsigned SYNC_STAGES = 2,

    // 1 (default): the read data path leaves the module through a flip-flop.
    //   Costs one read-domain cycle of latency and one further beat of storage;
    //   sustains one beat per cycle. Required for STORAGE="m20k", because the
    //   inferred M20K read port is registered.
    // 0: show-ahead. `rd_data` is a combinational read of the storage array.
    parameter bit OUT_REG = 1'b1,

    // Storage geometry; see rtl/common/sync_fifo.sv for the full note. The value
    // selects a literal `ramstyle` attribute rather than being substituted into
    // one, because Quartus wants a literal there and Verilator does not count an
    // attribute as a use of a parameter.
    parameter string STORAGE = "regs",

    // Write-side occupancy at or above which `wr_almost_full` asserts.
    parameter int unsigned ALMOST_FULL_THRESHOLD = (DEPTH > 1) ? (DEPTH - 1) : 1
) (
    // ---------------- write domain ----------------
    input  wire                       wr_clk,
    input  wire                       wr_rst_n,

    input  wire                       wr_valid,
    output wire                       wr_ready,
    input  wire [WIDTH-1:0]           wr_data,

    output wire                       wr_full,
    output wire                       wr_almost_full,

    // Conservative fill estimate as the WRITE side sees it: computed against a
    // read pointer that is up to SYNC_STAGES read cycles stale, so it never
    // reads low. This is the number a producer's credit scheme must use.
    output wire [$clog2(DEPTH+1)-1:0] wr_occupancy,
    output wire [$clog2(DEPTH+1)-1:0] wr_high_water,

    // Sticky: a write was committed while the FIFO was full. Unreachable in
    // correct operation (`a_no_overflow` proves it); a set flag is a defect.
    output wire                       wr_overflow_sticky,
    input  wire                       wr_sticky_clear,

    // ---------------- read domain ----------------
    input  wire                       rd_clk,
    input  wire                       rd_rst_n,

    output wire                       rd_valid,
    input  wire                       rd_ready,
    output wire [WIDTH-1:0]           rd_data,

    output wire                       rd_empty,

    // Conservative fill estimate as the READ side sees it: computed against a
    // write pointer that is up to SYNC_STAGES write cycles stale, so it never
    // reads high.
    output wire [$clog2(DEPTH+1)-1:0] rd_occupancy,
    output wire [$clog2(DEPTH+1)-1:0] rd_high_water,

    // Sticky: a read was committed while the FIFO was empty. Unreachable in
    // correct operation; a set flag is a defect.
    output wire                       rd_underflow_sticky,
    input  wire                       rd_sticky_clear
);

  localparam int unsigned ADDR_W = $clog2(DEPTH);
  localparam int unsigned PTR_W  = ADDR_W + 1;
  // For a power-of-two DEPTH this is exactly PTR_W; written as the occupancy
  // expression rather than reusing PTR_W so the intent of each width is visible
  // where it is used.
  localparam int unsigned OCC_W  = $clog2(DEPTH + 1);

`ifndef SYNTHESIS
  initial begin
    if (!cdc_pkg::cdc_depth_ok(cdc_pkg::uint_t'(DEPTH))) begin
      $fatal(1, "async_fifo: DEPTH=%0d is illegal; it must be a power of two and at least 2",
             DEPTH);
    end
    if (WIDTH < 1) begin
      $fatal(1, "async_fifo: WIDTH=%0d is illegal", WIDTH);
    end
    if (SYNC_STAGES < int'(cdc_pkg::cdc_sync_stages_min())) begin
      $fatal(1, "async_fifo: SYNC_STAGES=%0d is illegal; minimum is %0d",
             SYNC_STAGES, int'(cdc_pkg::cdc_sync_stages_min()));
    end
    if (STORAGE != "regs" && STORAGE != "mlab" && STORAGE != "m20k") begin
      $fatal(1, "async_fifo: STORAGE=\"%s\" is not one of regs, mlab, m20k", STORAGE);
    end
    if (STORAGE == "m20k" && !OUT_REG) begin
      $fatal(1, "async_fifo: STORAGE=\"m20k\" requires OUT_REG=1; an M20K read port is registered");
    end
    if (ALMOST_FULL_THRESHOLD < 1 || ALMOST_FULL_THRESHOLD > DEPTH) begin
      $fatal(1, "async_fifo: ALMOST_FULL_THRESHOLD=%0d is outside 1..DEPTH (DEPTH=%0d)",
             ALMOST_FULL_THRESHOLD, DEPTH);
    end
    if (int'(PTR_W) > int'(cdc_pkg::CDC_MAX_PTR_W)) begin
      $fatal(1, "async_fifo: DEPTH=%0d needs a %0d-bit pointer, beyond cdc_pkg's %0d-bit working type",
             DEPTH, PTR_W, int'(cdc_pkg::CDC_MAX_PTR_W));
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Gray helpers, narrowed to this instance's pointer width. cdc_pkg holds the
  // encoding; these two wrappers exist so the cast appears once per direction
  // instead of at every use site.
  // ---------------------------------------------------------------------------
  function automatic logic [PTR_W-1:0] to_gray(input logic [PTR_W-1:0] b);
    return PTR_W'(cdc_pkg::cdc_bin2gray(cdc_pkg::uint_t'(PTR_W),
                                        cdc_pkg::cdc_word_t'(b)));
  endfunction

  function automatic logic [PTR_W-1:0] to_bin(input logic [PTR_W-1:0] g);
    return PTR_W'(cdc_pkg::cdc_gray2bin(cdc_pkg::uint_t'(PTR_W),
                                        cdc_pkg::cdc_word_t'(g)));
  endfunction

  // The Gray value that means "a full lap ahead of this one": the top two bits
  // inverted. Cummings' full test compares the write pointer's next Gray value
  // against this transform of the synchronized read pointer, which is the same
  // comparison as "the binary pointers differ by exactly DEPTH" but performed
  // entirely in the Gray domain, where the synchronized value is trustworthy.
  function automatic logic [PTR_W-1:0] lap_ahead(input logic [PTR_W-1:0] g);
    logic [PTR_W-1:0] r;
    r          = g;
    r[PTR_W-1] = ~g[PTR_W-1];
    r[PTR_W-2] = ~g[PTR_W-2];
    return r;
  endfunction

  // ---------------------------------------------------------------------------
  // Cross-domain reset gating. See the RESET note in the header.
  // ---------------------------------------------------------------------------
  wire rd_in_reset_wsync;  // "the read domain is in reset", seen in wr_clk
  wire wr_in_reset_rsync;  // "the write domain is in reset", seen in rd_clk

  // RST_VALUE 1'b1: while a domain is in its own reset it must assume the other
  // one is too, so that the first thing it does on release is wait rather than
  // move a pointer.
  cdc_sync2 #(
      .WIDTH (1), .STAGES (SYNC_STAGES), .RST_VALUE (1'b1), .GRAY_CODED (1'b0)
  ) u_sync_rd_rst (
      .clk (wr_clk), .rst_n (wr_rst_n), .d (~rd_rst_n), .q (rd_in_reset_wsync)
  );

  cdc_sync2 #(
      .WIDTH (1), .STAGES (SYNC_STAGES), .RST_VALUE (1'b1), .GRAY_CODED (1'b0)
  ) u_sync_wr_rst (
      .clk (rd_clk), .rst_n (rd_rst_n), .d (~wr_rst_n), .q (wr_in_reset_rsync)
  );

  wire wr_hold = rd_in_reset_wsync;
  wire rd_hold = wr_in_reset_rsync;

  // ---------------------------------------------------------------------------
  // Storage. One named generate block per style so the `ramstyle` attribute is a
  // literal in each; all three are named g_store, so g_store.mem resolves to
  // whichever was elaborated.
  // ---------------------------------------------------------------------------
  if (STORAGE == "m20k") begin : g_store
    (* ramstyle = "M20K, no_rw_check" *) logic [WIDTH-1:0] mem [DEPTH];
  end else if (STORAGE == "mlab") begin : g_store
    (* ramstyle = "MLAB, no_rw_check" *) logic [WIDTH-1:0] mem [DEPTH];
  end else begin : g_store
    (* ramstyle = "logic" *) logic [WIDTH-1:0] mem [DEPTH];
  end

  // ---------------------------------------------------------------------------
  // Write domain
  // ---------------------------------------------------------------------------
  logic [PTR_W-1:0] wr_bin_q, wr_gray_q;
  logic             wr_full_q;
  logic [OCC_W-1:0] wr_high_q;
  logic             wr_ovf_q;

  wire [PTR_W-1:0] rd_gray_wsync;
  wire [PTR_W-1:0] rd_bin_wsync = to_bin(rd_gray_wsync);

  wire wr_ready_w = !wr_full_q && !wr_hold;
  wire wr_en      = wr_valid && wr_ready_w;

  wire [PTR_W-1:0] wr_bin_next  = wr_bin_q + PTR_W'(wr_en ? 1 : 0);
  wire [PTR_W-1:0] wr_gray_next = to_gray(wr_bin_next);

  // Conservative fill as the write side sees it. Both operands are PTR_W bits
  // and the difference is in 0..DEPTH, which is exactly the OCC_W range.
  wire [OCC_W-1:0] wr_occ_w = OCC_W'(wr_bin_q - rd_bin_wsync);

  always_ff @(posedge wr_clk) begin
    if (!wr_rst_n) begin
      wr_bin_q  <= PTR_W'(0);
      wr_gray_q <= PTR_W'(0);
      wr_full_q <= 1'b0;
      wr_high_q <= OCC_W'(0);
      wr_ovf_q  <= 1'b0;
    end else begin
      wr_bin_q  <= wr_bin_next;
      wr_gray_q <= wr_gray_next;
      // Registered full: computed from the value the pointer is about to take,
      // so the flag is correct on the very next cycle rather than one late.
      wr_full_q <= (wr_gray_next == lap_ahead(rd_gray_wsync));

      if (wr_sticky_clear) begin
        wr_high_q <= wr_occ_w;
        wr_ovf_q  <= 1'b0;
      end else begin
        if (wr_occ_w > wr_high_q) wr_high_q <= wr_occ_w;
        if (wr_en && wr_full_q)   wr_ovf_q  <= 1'b1;
      end
    end
  end

  // Payload store: never reset (SPEC 23).
  always_ff @(posedge wr_clk) begin
    if (wr_en) g_store.mem[wr_bin_q[ADDR_W-1:0]] <= wr_data;
  end

  // ---------------------------------------------------------------------------
  // Read domain
  // ---------------------------------------------------------------------------
  logic [PTR_W-1:0] rd_bin_q, rd_gray_q;
  logic             rd_empty_q;
  logic [OCC_W-1:0] rd_high_q;
  logic             rd_unf_q;

  wire [PTR_W-1:0] wr_gray_rsync;
  wire [PTR_W-1:0] wr_bin_rsync = to_bin(wr_gray_rsync);

  // The FIFO core's own read handshake, upstream of the optional output
  // register. `core_ready` is driven by whichever output arrangement was
  // elaborated.
  logic            core_ready;
  wire             core_valid = !rd_empty_q && !rd_hold;
  wire [WIDTH-1:0] core_data  = g_store.mem[rd_bin_q[ADDR_W-1:0]];
  wire             rd_en      = core_valid && core_ready;

  wire [PTR_W-1:0] rd_bin_next  = rd_bin_q + PTR_W'(rd_en ? 1 : 0);
  wire [PTR_W-1:0] rd_gray_next = to_gray(rd_bin_next);

  wire [OCC_W-1:0] rd_occ_w = OCC_W'(wr_bin_rsync - rd_bin_q);

  always_ff @(posedge rd_clk) begin
    if (!rd_rst_n) begin
      rd_bin_q   <= PTR_W'(0);
      rd_gray_q  <= PTR_W'(0);
      rd_empty_q <= 1'b1;
      rd_high_q  <= OCC_W'(0);
      rd_unf_q   <= 1'b0;
    end else begin
      rd_bin_q   <= rd_bin_next;
      rd_gray_q  <= rd_gray_next;
      rd_empty_q <= (rd_gray_next == wr_gray_rsync);

      if (rd_sticky_clear) begin
        rd_high_q <= rd_occ_w;
        rd_unf_q  <= 1'b0;
      end else begin
        if (rd_occ_w > rd_high_q) rd_high_q <= rd_occ_w;
        if (rd_en && rd_empty_q)  rd_unf_q  <= 1'b1;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Pointer synchronizers. The one place in the design where cdc_sync2 carries
  // more than one bit, and the GRAY_CODED claim is checked below.
  // ---------------------------------------------------------------------------
  cdc_sync2 #(
      .WIDTH (PTR_W), .STAGES (SYNC_STAGES), .RST_VALUE ('0), .GRAY_CODED (1'b1)
  ) u_sync_rd_ptr (
      .clk (wr_clk), .rst_n (wr_rst_n), .d (rd_gray_q), .q (rd_gray_wsync)
  );

  cdc_sync2 #(
      .WIDTH (PTR_W), .STAGES (SYNC_STAGES), .RST_VALUE ('0), .GRAY_CODED (1'b1)
  ) u_sync_wr_ptr (
      .clk (rd_clk), .rst_n (rd_rst_n), .d (wr_gray_q), .q (wr_gray_rsync)
  );

  // ---------------------------------------------------------------------------
  // Read output stage
  // ---------------------------------------------------------------------------
  if (OUT_REG) begin : g_out_reg
    logic             out_valid_q;
    logic [WIDTH-1:0] out_data_q;

    assign core_ready = !out_valid_q || rd_ready;

    always_ff @(posedge rd_clk) begin
      if (!rd_rst_n) begin
        out_valid_q <= 1'b0;
      end else if (core_ready) begin
        out_valid_q <= core_valid;
      end
    end

    // Payload register: no reset (SPEC 23). Written as a registered read of the
    // array with an enable, which is the shape Quartus infers as an M20K with a
    // registered read port.
    always_ff @(posedge rd_clk) begin
      if (core_ready) out_data_q <= core_data;
    end

    assign rd_valid = out_valid_q;
    assign rd_data  = out_data_q;
  end else begin : g_show_ahead
    assign core_ready = rd_ready;
    assign rd_valid   = core_valid;
    assign rd_data    = core_data;
  end

  // ---------------------------------------------------------------------------
  // Outputs
  // ---------------------------------------------------------------------------
  assign wr_ready            = wr_ready_w;
  assign wr_full             = wr_full_q;
  assign wr_almost_full      = (wr_occ_w >= OCC_W'(ALMOST_FULL_THRESHOLD)) || wr_full_q;
  assign wr_occupancy        = wr_occ_w;
  assign wr_high_water       = wr_high_q;
  assign wr_overflow_sticky  = wr_ovf_q;

  assign rd_empty            = rd_empty_q;
  assign rd_occupancy        = rd_occ_w;
  assign rd_high_water       = rd_high_q;
  assign rd_underflow_sticky = rd_unf_q;

  // ---------------------------------------------------------------------------
  // Assertions (SPEC 14: Gray-pointer one-bit transitions, FIFO overflow, FIFO
  // underflow, CDC handshake completion is cdc_handshake's).
  //
  // One Gray checker per pointer, each in the domain that OWNS that pointer.
  //
  // NOT on the synchronized copies, and the reason is the property itself: the
  // one-bit rule is about consecutive values of the pointer REGISTER, which is
  // what makes a sample taken mid-transition resolve to the old value or the
  // new one. The synchronized copy is that register sampled by a different
  // clock, so when the source clock is the faster of the two it legitimately
  // advances several Gray steps between two destination samples. A checker
  // there fails on correct RTL at every non-unity ratio — measured, at 2:1, on
  // the first version of this file — and a property that only holds at one
  // clock ratio is not the property SPEC 14 is asking for. What the crossing
  // actually depends on is that the value ENTERING each synchronizer is
  // Gray-coded, and that is exactly what these two instances check.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  cdc_gray_checker #(.WIDTH (PTR_W)) u_chk_wr_gray (
      .clk (wr_clk), .rst_n (wr_rst_n), .gray (wr_gray_q));

  cdc_gray_checker #(.WIDTH (PTR_W)) u_chk_rd_gray (
      .clk (rd_clk), .rst_n (rd_rst_n), .gray (rd_gray_q));

  // Pointer sanity, once per domain, each against the view that domain acts on.
  // A generate block per use because the macro declares fixed assertion names.
  if (1) begin : g_wr_ptr_sva
    `CDC_SVA_FIFO_PTR(wr_clk, wr_rst_n, wr_bin_q, rd_bin_wsync, DEPTH, PTR_W)
  end

  if (1) begin : g_rd_ptr_sva
    `CDC_SVA_FIFO_PTR(rd_clk, rd_rst_n, wr_bin_rsync, rd_bin_q, DEPTH, PTR_W)
  end

  // Reset contract. `hold` falls only when both domains are out of reset; at
  // that instant this domain's pointer must be zero. If only one side was reset,
  // the other side's pointer is not zero and this fires — which is the whole
  // detection mechanism for the "asserted one reset alone" design error.
  logic wr_hold_q, rd_hold_q;

  always_ff @(posedge wr_clk) begin
    if (!wr_rst_n) begin
      wr_hold_q <= 1'b1;
    end else begin
      wr_hold_q <= wr_hold;
      a_wr_reset_pointers_cleared : assert (!(wr_hold_q && !wr_hold) ||
                                            (wr_bin_q == PTR_W'(0)))
        else $error("async_fifo: write pointer is %0d, not 0, as the crossing leaves reset - the two resets were not asserted together",
                    wr_bin_q);
    end
  end

  always_ff @(posedge rd_clk) begin
    if (!rd_rst_n) begin
      rd_hold_q <= 1'b1;
    end else begin
      rd_hold_q <= rd_hold;
      a_rd_reset_pointers_cleared : assert (!(rd_hold_q && !rd_hold) ||
                                            (rd_bin_q == PTR_W'(0)))
        else $error("async_fifo: read pointer is %0d, not 0, as the crossing leaves reset - the two resets were not asserted together",
                    rd_bin_q);
    end
  end

  always_ff @(posedge wr_clk) begin
    if (wr_rst_n) begin
      a_no_overflow : assert (!(wr_en && wr_full_q))
        else $error("async_fifo: overflow - committed a write while full (DEPTH=%0d)", DEPTH);
      a_wr_occ_bound : assert (int'(wr_occ_w) <= int'(DEPTH))
        else $error("async_fifo: write-side fill estimate %0d exceeds DEPTH=%0d",
                    int'(wr_occ_w), DEPTH);
      a_no_wr_sticky : assert (!wr_ovf_q)
        else $error("async_fifo: the write-side overflow flag is set");
    end
  end

  always_ff @(posedge rd_clk) begin
    if (rd_rst_n) begin
      a_no_underflow : assert (!(rd_en && rd_empty_q))
        else $error("async_fifo: underflow - committed a read while empty");
      a_rd_occ_bound : assert (int'(rd_occ_w) <= int'(DEPTH))
        else $error("async_fifo: read-side fill estimate %0d exceeds DEPTH=%0d",
                    int'(rd_occ_w), DEPTH);
      a_no_rd_sticky : assert (!rd_unf_q)
        else $error("async_fifo: the read-side underflow flag is set");
    end
  end
`endif

endmodule : async_fifo

`default_nettype wire
