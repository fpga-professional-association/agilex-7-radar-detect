// -----------------------------------------------------------------------------
// cfar_window — the sliding reference window of the SPEC.md 7.7 CFAR detector
// (issue #14).
//
// A shift register over the frequency-bin power stream, plus the two masked
// reference sums and the validity tracking that rtl/cfar/cfar_core.sv turns into
// a detection decision. This module owns the GEOMETRY of the window and nothing
// else: no threshold, no multiplier, no framing state machine, no output stream.
// Splitting it out is what makes "the reference cells are the right cells" a
// property that can be tested and asserted on its own.
//
// -----------------------------------------------------------------------------
// 1. Layout — index 0 is the newest bin, so LEADING cells are BELOW the cell
//    under test
// -----------------------------------------------------------------------------
// Bins arrive in increasing frequency order, one per admitted beat. Slot 0 holds
// the bin admitted this cycle and slot k holds the bin admitted k advances ago,
// so slot index runs BACKWARDS in frequency:
//
//     slot        0      1     ...    D-1     D     D+1   ...   2D
//     bin       n      n-1          n-D+1   n-D   n-D-1        n-2D
//                                            ^
//                                            cell under test (CUT)
//
// with D = cfar_pkg::cfar_half_window(MAX_GUARD, MAX_REF) = MAX_GUARD + MAX_REF
// and 2D+1 slots in total. The CUT sits at slot D, permanently: a bin becomes
// the cell under test exactly D advances after it is admitted, which is the
// smallest delay at which its LEADING reference cells — the ones at HIGHER
// frequency, hence LOWER slot index — can all have arrived. That delay is the
// structural reason the detector cannot be a pure feed-forward function of the
// current beat, and it is why the core has to flush D phantom advances at the
// end of every frame (cfar_core.sv section 3).
//
// For a runtime geometry (G_lead, R_lead) on the leading side and
// (G_lag, R_lag) on the lagging side, measuring offset from the CUT:
//
//     leading reference cells   slots D - (G_lead + R_lead) .. D - (G_lead + 1)
//     leading guard cells       slots D - G_lead            .. D - 1
//     CUT                       slot  D
//     lagging guard cells       slots D + 1                 .. D + G_lag
//     lagging reference cells   slots D + (G_lag + 1)       .. D + (G_lag+R_lag)
//
// Both extremes are inside the array because the core clamps G and R to
// MAX_GUARD and MAX_REF before they get here.
//
// -----------------------------------------------------------------------------
// 2. Masked sum over every slot, not a variable-offset selection
// -----------------------------------------------------------------------------
// The reference sum is formed by testing EVERY slot against the two bands and
// summing the ones that fall inside, rather than by selecting R cells starting
// at a runtime offset. The two are the same arithmetic; the difference is what
// the runtime configuration drives.
//
// A variable-offset selection puts a (2D+1)-to-1 multiplexer in front of every
// one of the R adder inputs, and the multiplexer select is the guard count — a
// register-plane value on the critical path of the widest datapath in the block.
// The masked form puts a two-bound COMPARATOR on each slot instead, and the
// comparator output only gates an adder input. The comparators are 7-bit and
// off the datapath; the multiplexers would have been 40-bit and on it.
//
// Cost: the adder tree is always 2D+1 wide rather than 2R wide. At the SPEC 11
// tiny geometry (MAX_GUARD = 2, MAX_REF = 8) that is 21 40-bit adds per side
// pair per cycle, which is small. It does NOT stay small at full scale, and the
// honest statement of the alternative is: a RUNNING sum, updated by one add and
// one subtract per advance, is O(1) instead of O(D). It is not used here for a
// reason that is about correctness rather than area — a running sum carries
// state across bins, so a geometry change, a frame boundary or an edge-suppressed
// bin has to unwind that state exactly, and every one of those is a case where
// the sum can silently drift from the cells it claims to be over. The masked
// tree recomputes from the register file every cycle and therefore has no state
// to drift. Adopting the running form is a SPEC 18 measurement away, and the
// gate for it is this module's own tests continuing to pass against the same
// C++ model.
//
// -----------------------------------------------------------------------------
// 3. Validity, and why the guard cells are not checked
// -----------------------------------------------------------------------------
// Every slot carries a `valid` bit meaning "this slot holds a real bin OF THE
// CURRENT FRAME". `clear` drops every bit at a frame boundary, and the core
// shifts in invalid phantom entries while flushing, so validity within the array
// is always a CONTIGUOUS band. A window is complete when every slot the two
// reference masks select is valid — which is what `refs_ok_*` reports.
//
// The guard cells are deliberately NOT part of that test, and it costs nothing:
// they lie strictly between the CUT and the outer reference cells, validity is
// contiguous, and the CUT and the outer reference cells are both checked. A
// separate guard-validity term would be a second expression for a condition the
// first one already implies — and a second expression is a second thing to get
// wrong. The property is asserted rather than argued (a_cfar_guards_valid).
//
// -----------------------------------------------------------------------------
// 4. What is registered and what is not
// -----------------------------------------------------------------------------
// The slot array is registered; the masks, the sums and the validity reduction
// are combinational, and the core registers them (SPEC 23: registers on both
// sides of a wide arithmetic operation). Only the `valid` bits are reset —
// SPEC 23, "reset validity, not every datapath bit" — so the power and bin-index
// storage carries no reset fanout at all. A slot's contents are meaningless
// until its valid bit says otherwise, which is exactly what a reset would have
// been establishing.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module cfar_window
  import cfar_pkg::*;
#(
    // Power-stream width (SPEC 3 POWER_W, through covar_pkg).
    parameter int unsigned POWER_W = CFAR_POWER_W,

    // Elaborated maxima. The runtime guard and reference counts are clamped to
    // these by the core; they set the array length and therefore the number of
    // bins suppressed at each frame edge.
    parameter int unsigned MAX_GUARD = 2,
    parameter int unsigned MAX_REF   = 8,

    // Frequency-bin index width.
    parameter int unsigned BIN_W = CFAR_BIN_W,

    // Internal reference-sum width for THIS elaboration (cfar_pkg section 3).
    // A parameter rather than a body localparam only because a port width cannot
    // reference one; it is never overridden, and the elaboration check below
    // fails the build if it is.
    parameter int unsigned SUM_W = int'(cfar_sum_w(cfar_uint_t'(MAX_REF)))
) (
    input  wire                          clk,
    input  wire                          rst_n,

    // ---- window control -----------------------------------------------------
    // clear   drop every slot: a frame boundary, or a software flush.
    // advance shift one slot. `in_valid` says whether the entering slot holds a
    //         real bin; the core drives it low for the phantom advances that
    //         push a frame's tail through to the CUT position.
    input  wire                          clear,
    input  wire                          advance,
    input  wire                          in_valid,
    input  wire [POWER_W-1:0]            in_cell,
    input  wire [BIN_W-1:0]              in_bin,

    // ---- active geometry (latched and clamped by the core) ------------------
    input  wire [CFAR_GUARD_CNT_W-1:0]   cfg_guard_lead,
    input  wire [CFAR_GUARD_CNT_W-1:0]   cfg_guard_lag,
    input  wire [CFAR_REF_CNT_W-1:0]     cfg_ref_lead,
    input  wire [CFAR_REF_CNT_W-1:0]     cfg_ref_lag,

    // ---- combinational view of the window as it stands right now ------------
    output wire                          cut_valid,
    output wire [POWER_W-1:0]            cut_cell,
    output wire [BIN_W-1:0]              cut_bin,

    output wire [SUM_W-1:0]              sum_lead,
    output wire [SUM_W-1:0]              sum_lag,
    output wire                          refs_ok_lead,
    output wire                          refs_ok_lag,

    // ---- observation --------------------------------------------------------
    // Number of slots each mask actually selected. Equal to the configured count
    // by construction; exported so a test can prove it rather than assume it.
    output wire [CFAR_REF_CNT_W:0]       obs_n_lead,
    output wire [CFAR_REF_CNT_W:0]       obs_n_lag
);

  // ---------------------------------------------------------------------------
  // Geometry
  // ---------------------------------------------------------------------------
  localparam int unsigned D_HALF = int'(cfar_half_window(cfar_uint_t'(MAX_GUARD),
                                                         cfar_uint_t'(MAX_REF)));
  localparam int unsigned N_SLOT = int'(cfar_window_slots(cfar_uint_t'(MAX_GUARD),
                                                          cfar_uint_t'(MAX_REF)));

  // Width of the slot-offset comparisons. It must hold a slot offset (below
  // 2*D_HALF + 2) AND every bit of the two register fields, even in an
  // elaboration whose maxima do not need them all: truncating an unused high bit
  // of `cfg_guard_lead` would make an out-of-range write alias onto a legal
  // geometry instead of being clamped, and Verilator reports the dropped bits
  // (UNUSEDSIGNAL) — which is how this was found, on the MAX_GUARD = 0
  // elaboration in sim/verilator/tops/cfar_top.sv.
  localparam int unsigned OFS_SLOT_W  = $clog2(2 * D_HALF + 2);
  localparam int unsigned OFS_FIELD_W = ((CFAR_GUARD_CNT_W > CFAR_REF_CNT_W)
                                             ? CFAR_GUARD_CNT_W : CFAR_REF_CNT_W) + 1;
  localparam int unsigned OFS_W = (OFS_SLOT_W > OFS_FIELD_W) ? OFS_SLOT_W : OFS_FIELD_W;

  typedef logic [OFS_W-1:0] ofs_t;

`ifndef SYNTHESIS
  initial begin
    if (MAX_REF < 1) begin
      $fatal(1, "cfar_window: MAX_REF=%0d must be at least 1 — a detector with no reference cells has no noise estimate",
             MAX_REF);
    end
    if (MAX_GUARD > ((1 << CFAR_GUARD_CNT_W) - 1)) begin
      $fatal(1, "cfar_window: MAX_GUARD=%0d cannot be expressed in the %0d-bit register field",
             MAX_GUARD, CFAR_GUARD_CNT_W);
    end
    if (MAX_REF > ((1 << CFAR_REF_CNT_W) - 1)) begin
      $fatal(1, "cfar_window: MAX_REF=%0d cannot be expressed in the %0d-bit register field",
             MAX_REF, CFAR_REF_CNT_W);
    end
    if (POWER_W != int'(cfar_power_w())) begin
      $fatal(1, "cfar_window: POWER_W=%0d disagrees with cfar_pkg::cfar_power_w()=%0d",
             POWER_W, int'(cfar_power_w()));
    end
    if (SUM_W != int'(cfar_sum_w(cfar_uint_t'(MAX_REF)))) begin
      $fatal(1, "cfar_window: SUM_W=%0d was overridden; cfar_pkg says %0d for MAX_REF=%0d",
             SUM_W, int'(cfar_sum_w(cfar_uint_t'(MAX_REF))), MAX_REF);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // The slot array. Only `valid` is reset (section 4).
  // ---------------------------------------------------------------------------
  logic [N_SLOT-1:0]              valid_q;
  logic [N_SLOT-1:0][POWER_W-1:0] cell_q;
  logic [N_SLOT-1:0][BIN_W-1:0]   bin_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      valid_q <= '0;
    end else begin
      // `clear` and `advance` can be asserted together — that is exactly the
      // admitted start-of-frame beat — and the order below is what makes that
      // case mean "the previous frame's cells are gone AND this frame's first
      // bin is in slot 0". A later assignment to the same bit wins.
      if (clear) begin
        valid_q <= '0;
      end else if (advance) begin
        for (int unsigned k = 1; k < N_SLOT; k++) begin
          valid_q[k] <= valid_q[k-1];
          cell_q[k]  <= cell_q[k-1];
          bin_q[k]   <= bin_q[k-1];
        end
      end

      if (advance) begin
        valid_q[0] <= in_valid;
        cell_q[0]  <= in_cell;
        bin_q[0]   <= in_bin;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Band masks (section 1). One two-bound comparator per slot; the slot offset
  // is a constant, so only the two bounds come from the register plane.
  // ---------------------------------------------------------------------------
  ofs_t g_lead, g_lag, r_lead, r_lag;
  assign g_lead = ofs_t'(cfg_guard_lead);
  assign g_lag  = ofs_t'(cfg_guard_lag);
  assign r_lead = ofs_t'(cfg_ref_lead);
  assign r_lag  = ofs_t'(cfg_ref_lag);

  logic [N_SLOT-1:0] mask_lead, mask_lag;

  // Declared outside the always_comb: a declaration inside an unnamed
  // procedural block is legal SystemVerilog but is not accepted uniformly, and
  // this design is built by two tools (DECISIONS.md, issue #10 decision 9 — lint
  // clean is not the same as synthesizable).
  ofs_t off;

  always_comb begin
    mask_lead = '0;
    mask_lag  = '0;
    // `off` is a loop temporary, and the slot at the cell-under-test position
    // assigns it on no path — which Verilator reports as an inferred latch
    // (found on the full_agmf039 elaboration). Initialising it before the loop
    // is the fix; the value it holds after the loop is never read.
    off       = '0;
    for (int unsigned k = 0; k < N_SLOT; k++) begin
      if (k < D_HALF) begin
        // Leading side: higher frequency, lower slot index.
        off = ofs_t'(D_HALF - k);
        mask_lead[k] = (off > g_lead) && (off <= (g_lead + r_lead));
      end else if (k > D_HALF) begin
        // Lagging side: lower frequency, higher slot index.
        off = ofs_t'(k - D_HALF);
        mask_lag[k] = (off > g_lag) && (off <= (g_lag + r_lag));
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Masked sums, masked validity, and the selected-cell counts
  // ---------------------------------------------------------------------------
  logic [SUM_W-1:0]        sum_lead_c, sum_lag_c;
  logic                    bad_lead_c, bad_lag_c;
  logic [CFAR_REF_CNT_W:0] n_lead_c, n_lag_c;

  always_comb begin
    sum_lead_c = '0;
    sum_lag_c  = '0;
    bad_lead_c = 1'b0;
    bad_lag_c  = 1'b0;
    n_lead_c   = '0;
    n_lag_c    = '0;
    for (int unsigned k = 0; k < N_SLOT; k++) begin
      if (mask_lead[k]) begin
        sum_lead_c = sum_lead_c + SUM_W'(cell_q[k]);
        n_lead_c   = n_lead_c + (CFAR_REF_CNT_W+1)'(1);
        if (!valid_q[k]) bad_lead_c = 1'b1;
      end
      if (mask_lag[k]) begin
        sum_lag_c = sum_lag_c + SUM_W'(cell_q[k]);
        n_lag_c   = n_lag_c + (CFAR_REF_CNT_W+1)'(1);
        if (!valid_q[k]) bad_lag_c = 1'b1;
      end
    end
  end

  assign sum_lead     = sum_lead_c;
  assign sum_lag      = sum_lag_c;
  assign refs_ok_lead = !bad_lead_c;
  assign refs_ok_lag  = !bad_lag_c;
  assign obs_n_lead   = n_lead_c;
  assign obs_n_lag    = n_lag_c;

  assign cut_valid = valid_q[D_HALF];
  assign cut_cell  = cell_q[D_HALF];
  assign cut_bin   = bin_q[D_HALF];

  // ---------------------------------------------------------------------------
  // Simulation-only proofs (SPEC 14)
  //
  // a_cfar_mask_count   the mask selects exactly as many slots as the register
  //                     plane asked for. This is the property an off-by-one in
  //                     the guard-cell comparison breaks first, and it breaks it
  //                     on EVERY cycle rather than only on the cycles where the
  //                     wrong cell happened to matter — which is what makes the
  //                     fault-injection experiment in VERIFICATION_PLAN.md
  //                     immediate rather than statistical.
  // a_cfar_bands_disjoint
  //                     no slot is in both bands, and neither band contains the
  //                     cell under test. A guard count of zero must still keep
  //                     the CUT out of its own reference window.
  // a_cfar_guards_valid section 3's claim: whenever both reference bands are
  //                     complete, every slot between the outermost reference
  //                     cells is valid too — so the guard cells never need
  //                     their own check.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  logic [CFAR_REF_CNT_W:0] exp_n_lead, exp_n_lag;
  assign exp_n_lead = (CFAR_REF_CNT_W+1)'(cfg_ref_lead);
  assign exp_n_lag  = (CFAR_REF_CNT_W+1)'(cfg_ref_lag);

  // Every slot strictly between the outermost selected cells of the two bands.
  logic        span_ok;
  int unsigned span_lo, span_hi;

  always_comb begin
    span_lo = D_HALF;
    span_hi = D_HALF;
    for (int unsigned k = 0; k < N_SLOT; k++) begin
      if (mask_lead[k] && (k < span_lo)) span_lo = k;
      if (mask_lag[k] && (k > span_hi)) span_hi = k;
    end
    span_ok = 1'b1;
    for (int unsigned k = 0; k < N_SLOT; k++) begin
      if ((k >= span_lo) && (k <= span_hi) && !valid_q[k]) span_ok = 1'b0;
    end
  end

  always_ff @(posedge clk) begin
    if (rst_n) begin
      a_cfar_mask_count : assert ((n_lead_c == exp_n_lead) && (n_lag_c == exp_n_lag))
        else $error("cfar_window: masks selected %0d/%0d cells but the geometry asks for %0d/%0d",
                    n_lead_c, n_lag_c, exp_n_lead, exp_n_lag);

      a_cfar_bands_disjoint : assert (((mask_lead & mask_lag) == '0) &&
                                      !mask_lead[D_HALF] && !mask_lag[D_HALF])
        else $error("cfar_window: the reference bands overlap each other or the cell under test");

      a_cfar_guards_valid : assert (!(refs_ok_lead && refs_ok_lag && cut_valid) || span_ok)
        else $error("cfar_window: both reference bands are complete but a cell between them is not");
    end
  end
`endif

endmodule : cfar_window

`default_nettype wire
