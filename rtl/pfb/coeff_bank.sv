// -----------------------------------------------------------------------------
// coeff_bank — dual coefficient banks with a frame-aligned swap (SPEC.md 7.1).
//
// SPEC 7.1 requires, in four lines that between them define this module:
//
//     * Coefficients held in dual coefficient banks.
//     * Coefficient updates occur through the configuration domain.
//     * Active coefficient bank may change only at a safe frame boundary.
//     * No global reset should unnecessarily reset large datapath arrays.
//
// ONE BANK FOR THE WHOLE POLYPHASE BANK, NOT ONE PER LANE
// -------------------------------------------------------
// This module holds the coefficients of EVERY phase: PHASES x TAPS complex
// coefficients, twice over. A per-lane instance would replicate the clock-domain
// crossing, the swap state machine and the frame-boundary logic once per lane,
// and would make "the banks swapped together" a property of eight independent
// state machines agreeing rather than a property of one. SPEC 7.1's "shared dual
// coefficient banks" is the same statement. rtl/pfb/pfb_bank.sv instantiates one
// of these and hands each lane its own PHASES-major slice.
//
// THE CLOCK-DOMAIN SEAM (SPEC 8, issue #6 primitives)
// ---------------------------------------------------
// The datapath runs on core_clk; the register plane writes on cfg_clk. Those are
// different domains in the real system (SPEC 8), so the seam is REAL RTL here
// even though the simulation tops in this issue tie both ports to one clock:
//
//   writes           cdc_handshake — the whole {bank, address, data} word
//                    crosses as one four-phase transfer, so no bit of an
//                    address can be sampled from a different cycle than its
//                    data. This is exactly the case SPEC 8's multibit
//                    prohibition exists for and exactly why cdc_handshake
//                    exists.
//   swap request     cdc_pulse — an event, not a level. `cfg_swap_busy` refuses
//                    a second request while one is in flight rather than
//                    silently coalescing two swaps into one.
//   status back      cdc_sync2, one instance per BIT. active_bank, swap_pending
//                    and wr_reject are three independent single-bit flags and
//                    are crossed as three synchronizers, never as a three-bit
//                    bus: a bus would be a multibit crossing whose transient
//                    combinations are meaningless.
//
// Tying cfg_clk to core_clk in a simulation top does not bypass any of this: the
// handshake still takes its full four-phase round trip, so the tests exercise
// the same flow control the real system will.
//
// WRITES ARE REFUSED ON THE ACTIVE BANK
// -------------------------------------
// A write whose target bank IS the active bank is DROPPED and sets the sticky
// `wr_reject` flag. It is not merged, not deferred and not applied.
//
// The alternative — allowing it — makes a coefficient set change under a frame
// that is already being filtered, which is precisely what double buffering is
// for, and it makes the "inactive-bank write has no effect" property
// unstateable. Refusing it turns a software ordering bug into a visible flag
// instead of a numerical result nobody can explain later.
//
// Two properties follow, and both are assertions rather than comments
// (sim/assertions/pfb_assertions.sv):
//
//   a_coeff_swap_at_sof     the bank IN USE changes ONLY on a cycle carrying an
//                           admitted start-of-frame beat — and on that cycle it
//                           is already the new bank, so the whole frame is
//                           filtered with one coefficient set.
//   a_coeff_stable_between  the active bank's CONTENTS never change except on
//                           the cycle the active bank changes. This is the
//                           inactive-bank-write-has-no-effect property, stated
//                           as a property of the output rather than of the
//                           write logic, so it holds however the write logic is
//                           later rewritten.
//
// STORAGE AND RESET (SPEC 23)
// ---------------------------
// 2 x PHASES x TAPS x 32 bits of registers, NEVER reset. A reset fanout across
// 8192 bits (the nominal 8x16 geometry) would pin every one of them out of
// Hyper-Register retiming and buy nothing: coefficients are meaningless until
// software writes them, so there is no state a reset could restore. Power-up
// content is zero, set by an `initial` — a declaration, not a reset network —
// so that a simulation starts defined and a device powers up with a null filter
// rather than with whatever the fabric held.
//
// Only the control state resets: the active-bank register, the pending flag and
// the sticky reject flag.
//
// ALLOW_UNSAFE_SWAP
// -----------------
// Zero in every design instance. One ONLY in the negative-test instance inside
// sim/verilator/tops/pfb_top.sv, where it makes the swap take effect the moment
// the request arrives instead of at the next start of frame — which is the
// violation a_coeff_swap_at_sof exists to catch. An assertion nothing can
// provoke is an assertion nobody has tested; this parameter is what makes that
// one falsifiable. See sim/tests/test_pfb_bank.cpp, mode `illegal-swap`.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

// (* cdc_primitive *) — scripts/cdc_inventory.py reads the attribute block below
// and reports this module as a crossing in the SPEC 8 inventory. It is a
// COMPOSITE, exactly as rtl/cdc/stream_cdc.sv is: the real synchronizers are the
// cdc_handshake, cdc_pulse and cdc_sync2 instances inside, and the inventory
// lists those too, nested under this entry. Tagging the composite is what stops
// a two-clock module from being reported as an unclassified crossing.
//
// cdc_width is the coefficient word (2 x FXP_SAMPLE_W). The write crossing
// actually carries 1 + $clog2(PHASES*TAPS) + 32 bits and says so in its own
// entry; this one names the payload the module exists to move.
(* cdc_primitive = "coeff_bank_dual", cdc_src_clk = "cfg_clk", cdc_dst_clk = "core_clk", cdc_width = "32", cdc_stages = "SYNC_STAGES" *)
module coeff_bank
  import fxp_pkg::*;
  import pfb_pkg::*;
#(
    // Polyphase geometry. PHASES*TAPS coefficients per bank, addressed
    // phase-major (pfb_pkg::pfb_coeff_index), which is the order
    // scripts/generate_coefficients.py writes its files in.
    parameter int unsigned PHASES = 8,
    parameter int unsigned TAPS   = 16,

    // Flip-flops per synchronizer chain, forwarded to every issue #6 primitive
    // below (cdc_pkg::cdc_sync_stages_default()).
    parameter int unsigned SYNC_STAGES = 2,

    // Negative-test escape hatch. See the header. NEVER 1 in a design instance.
    parameter bit ALLOW_UNSAFE_SWAP = 1'b0
) (
    // ---- configuration domain ----------------------------------------------
    input  wire                              cfg_clk,
    input  wire                              cfg_rst_n,

    // One coefficient per transfer. Accepted on the cycle
    // `cfg_wr_valid && cfg_wr_ready`; the payload need be held for that cycle
    // only, after which the crossing owns it.
    input  wire                              cfg_wr_valid,
    output wire                              cfg_wr_ready,
    input  wire                              cfg_wr_bank,
    input  wire [$clog2(PHASES*TAPS)-1:0]    cfg_wr_addr,
    input  wire [2*FXP_SAMPLE_W-1:0]         cfg_wr_data,   // {im, re}, Q1.15

    // Swap request: a one-cycle strobe. Refused while `cfg_swap_busy` is high.
    input  wire                              cfg_swap_req,
    output wire                              cfg_swap_busy,
    output wire                              cfg_swap_overrun,

    // Status, synchronised back into the configuration domain.
    output wire                              cfg_active_bank,
    output wire                              cfg_swap_pending,
    output wire                              cfg_wr_reject,

    // ---- core (datapath) domain --------------------------------------------
    input  wire                              core_clk,
    input  wire                              core_rst_n,

    // A sample beat is admitted into the datapath this cycle, and whether that
    // beat is a start of frame. Together they define the safe swap point.
    input  wire                              core_beat,
    input  wire                              core_sof,

    output wire                              core_active_bank,
    output wire                              core_swap_pending,

    // The active bank, phase-major: coefficient (p, t) is at
    // pfb_coeff_index(TAPS, p, t) * 32 +: 32, packed {im, re}.
    output wire [PHASES*TAPS*2*FXP_SAMPLE_W-1:0] coeff_o
);

  localparam int unsigned COEFF_W  = 2 * FXP_SAMPLE_W;              // 32
  localparam int unsigned N_COEFF  = PHASES * TAPS;
  localparam int unsigned ADDR_W   = $clog2(N_COEFF);
  localparam int unsigned XFER_W   = 1 + ADDR_W + COEFF_W;
  localparam int unsigned N_BANKS  = int'(pfb_n_banks());

`ifndef SYNTHESIS
  initial begin
    if (PHASES < 1 || PHASES > int'(pfb_max_phases())) begin
      $fatal(1, "coeff_bank: PHASES=%0d outside [1, %0d]", PHASES, pfb_max_phases());
    end
    if (TAPS < 1 || TAPS > int'(pfb_max_taps())) begin
      $fatal(1, "coeff_bank: TAPS=%0d outside [1, %0d]", TAPS, pfb_max_taps());
    end
    // ADDR_W would be zero for a single coefficient, which is not a legal port
    // width. A one-coefficient bank is not a filter, so this costs nothing.
    if (N_COEFF < 2) begin
      $fatal(1, "coeff_bank: PHASES*TAPS=%0d; at least 2 coefficients are required",
             N_COEFF);
    end
    if (ALLOW_UNSAFE_SWAP) begin
      $display("coeff_bank: WARNING ALLOW_UNSAFE_SWAP=1 — the frame-boundary rule is disabled; this must be a negative-test instance only");
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // cfg -> core: the write crossing
  // ---------------------------------------------------------------------------
  logic [XFER_W-1:0] cfg_xfer;
  assign cfg_xfer = {cfg_wr_bank, cfg_wr_addr, cfg_wr_data};

  logic              wr_valid;
  logic [XFER_W-1:0] wr_xfer;

  // Named sinks rather than `()`: an empty pin connection is a lint warning
  // (PINCONNECTEMPTY) and, more usefully, a named wire says which outputs this
  // module deliberately does not export. `s_busy` is exactly !cfg_wr_ready, so
  // it earns no port of its own. Same convention as rtl/cdc/stream_cdc.sv.
  logic cdc_wr_busy_unused;

  cdc_handshake #(
      .WIDTH       (XFER_W),
      .SYNC_STAGES (SYNC_STAGES)
  ) u_wr_cdc (
      .src_clk   (cfg_clk),
      .src_rst_n (cfg_rst_n),
      .s_valid   (cfg_wr_valid),
      .s_ready   (cfg_wr_ready),
      .s_data    (cfg_xfer),
      .s_busy    (cdc_wr_busy_unused),
      .dst_clk   (core_clk),
      .dst_rst_n (core_rst_n),
      .d_valid   (wr_valid),
      .d_data    (wr_xfer)
  );

  logic                wr_bank;
  logic [ADDR_W-1:0]   wr_addr;
  logic [COEFF_W-1:0]  wr_data;
  assign {wr_bank, wr_addr, wr_data} = wr_xfer;

  // ---------------------------------------------------------------------------
  // cfg -> core: the swap request
  // ---------------------------------------------------------------------------
  logic swap_pulse;

  cdc_pulse #(
      .SYNC_STAGES (SYNC_STAGES)
  ) u_swap_cdc (
      .src_clk          (cfg_clk),
      .src_rst_n        (cfg_rst_n),
      .src_pulse        (cfg_swap_req),
      .src_busy         (cfg_swap_busy),
      .src_overrun      (cfg_swap_overrun),
      .src_sticky_clear (1'b0),
      .dst_clk          (core_clk),
      .dst_rst_n        (core_rst_n),
      .dst_pulse        (swap_pulse)
  );

  // ---------------------------------------------------------------------------
  // Swap control (core domain)
  //
  // A request sets `pending`. The swap itself happens at the next admitted
  // start-of-frame beat and not before — that is the SPEC 7.1 "safe frame
  // boundary", and it is the whole reason the pending flag exists rather than
  // the pulse flipping the bank directly.
  //
  // A second request while one is pending is harmless (pending is already set)
  // and cannot happen anyway: cdc_pulse refuses a source pulse while one is in
  // flight, and cfg_swap_pending is visible to software.
  // ---------------------------------------------------------------------------
  logic pending_q;
  logic active_q;
  logic reject_q;
  logic swap_now;
  logic bank_sel;

  if (ALLOW_UNSAFE_SWAP) begin : g_unsafe_swap
    // Negative test only: the frame boundary is ignored entirely.
    assign swap_now = pending_q;
  end else begin : g_safe_swap
    assign swap_now = pending_q && core_beat && core_sof;
  end

  // THE BANK IN USE FOR THE CURRENT BEAT, and why it is not just `active_q`.
  //
  // SPEC 7.1 aligns the swap to a frame boundary, and the only reading of that
  // which does what a user expects is: the FIRST beat of the new frame is
  // already filtered with the new coefficients. A registered active-bank alone
  // cannot do that — it updates at the end of the start-of-frame cycle, so the
  // start-of-frame beat itself would still see the old bank and the frame would
  // be filtered with two different filters.
  //
  // So the coefficient read selects `bank_sel`, which is `active_q` on every
  // ordinary cycle and the INCOMING bank on the swap cycle. The cost is a
  // two-gate combinational cone (pending & beat & sof, then an XOR) ahead of the
  // coefficient mux select; the mux itself is the wide thing and it was always
  // there. The SPEC 18 sweep prices it.
  assign bank_sel = active_q ^ swap_now;

  always_ff @(posedge core_clk) begin
    if (!core_rst_n) begin
      pending_q <= 1'b0;
      active_q  <= 1'b0;
    end else begin
      if (swap_pulse)    pending_q <= 1'b1;
      else if (swap_now) pending_q <= 1'b0;

      active_q <= bank_sel;
    end
  end

  // A write aimed at the bank currently IN USE is dropped and flagged. Tested
  // against `bank_sel` rather than `active_q` so that the swap cycle is covered
  // too: on that cycle the incoming bank is already being read, and a write
  // landing on it would move the active coefficients without a bank change —
  // exactly what a_coeff_stable_between forbids.
  //
  // The flag describes the writes since the last completed swap, so a
  // programming episode that ends in a swap starts the next one clean.
  logic wr_to_active;
  assign wr_to_active = wr_valid && (wr_bank == bank_sel);

  always_ff @(posedge core_clk) begin
    if (!core_rst_n)        reject_q <= 1'b0;
    else if (swap_now)      reject_q <= 1'b0;
    else if (wr_to_active)  reject_q <= 1'b1;
  end

  // ---------------------------------------------------------------------------
  // Storage. Never reset; zero at power-up by declaration. See the header.
  // ---------------------------------------------------------------------------
  logic [N_BANKS-1:0][N_COEFF-1:0][COEFF_W-1:0] mem;

  // Loop initialiser rather than `mem = '0` -- the latter draws a
  // WIDTHCONCAT warning above 8 kbit replication on Verilator 5.020.
  // Harmless power-up zeroing, same semantics.
  initial begin
    for (int unsigned b = 0; b < N_BANKS; b++) begin
      for (int unsigned a = 0; a < N_COEFF; a++) begin
        mem[b][a] = '0;
      end
    end
  end

  always_ff @(posedge core_clk) begin
    if (wr_valid && !wr_to_active) begin
      mem[wr_bank][wr_addr] <= wr_data;
    end
  end

  assign coeff_o = mem[bank_sel];

  // ---------------------------------------------------------------------------
  // core -> cfg: status. Three independent single-bit synchronizers; see the
  // header for why this is not one three-bit crossing.
  // ---------------------------------------------------------------------------
  cdc_sync2 #(.WIDTH(1), .STAGES(SYNC_STAGES), .RST_VALUE(1'b0)) u_sync_active (
      .clk (cfg_clk), .rst_n (cfg_rst_n), .d (active_q),  .q (cfg_active_bank));

  cdc_sync2 #(.WIDTH(1), .STAGES(SYNC_STAGES), .RST_VALUE(1'b0)) u_sync_pending (
      .clk (cfg_clk), .rst_n (cfg_rst_n), .d (pending_q), .q (cfg_swap_pending));

  cdc_sync2 #(.WIDTH(1), .STAGES(SYNC_STAGES), .RST_VALUE(1'b0)) u_sync_reject (
      .clk (cfg_clk), .rst_n (cfg_rst_n), .d (reject_q),  .q (cfg_wr_reject));

  // The bank the CURRENT beat is being filtered with — which is what a
  // downstream consumer and the checker both need. The configuration side sees
  // the settled register instead (below), because a cfg read that landed on a
  // swap cycle would otherwise report a value that was true for one cycle.
  assign core_active_bank  = bank_sel;
  assign core_swap_pending = pending_q;

  // ---------------------------------------------------------------------------
  // SPEC 14 property set. Instantiated here rather than bound from a test, so
  // the frame-boundary rule is checked in every build that uses this module.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  coeff_bank_checker #(
      .COEFF_BITS (N_COEFF * COEFF_W)
  ) u_chk (
      .clk         (core_clk),
      .rst_n       (core_rst_n),
      .beat        (core_beat),
      .sof         (core_sof),
      .active_bank (bank_sel),
      .coeff       (coeff_o)
  );
`endif

endmodule : coeff_bank

`default_nettype wire
