// -----------------------------------------------------------------------------
// bf_dot — one beam x one bin complex dot product (SPEC.md 6, 7.5, 23; issue #12).
//
//     Y = sum over antennas a of X[a] * W[b][a]        (complex, Q1.15 operands)
//
// N_ANT complex multipliers from rtl/common/complex_multiplier.sv feeding a
// pipelined balanced adder tree, accumulated at full precision, quantised ONCE
// at the output through fxp_pkg. It is the SPEC 18 item 6 calibration kernel
// ("one beamforming dot product") and the unit rtl/beamformer/beamformer.sv
// replicates BIN_PAR x BEAM_PAR times.
//
// -----------------------------------------------------------------------------
// 1. Numerics — one quantisation, and where it is
// -----------------------------------------------------------------------------
// Every complex_multiplier runs with ROUND_OUT = 0, so each antenna contributes
// its EXACT 33-bit partial sums (p_re, p_im) and its rounding network does not
// exist. The N_ANT partial sums are accumulated at
// beamformer_pkg::bf_acc_w(N_ANT) = fxp_pkg::fxp_mac_q15_acc_w(2*N_ANT) bits —
// 37 bits for 16 antennas — a width at which the accumulation PROVABLY cannot
// overflow, and the result is rounded and saturated exactly once, at the module
// output, by fxp_pkg::fxp_round_sat.
//
// This is not a stylistic preference. Issue #9's calibration measured what a
// rounding network costs: MULT4 at four stages is 102.0 kernel ALMs and 715 MHz
// with ROUND_OUT = 1 against 1.2 kernel ALMs and >= 1302 MHz with ROUND_OUT = 0.
// Rounding per antenna would therefore cost sixteen rounding networks instead of
// one, would double the quantisation noise, and would not match the C++ model.
// See DECISIONS.md (issue #9, decision 9).
//
// Two consequences worth stating because they are load-bearing:
//
//   * There is NO intermediate saturation anywhere in the tree, so integer
//     addition is associative and the tree's answer does not depend on its
//     shape. That is what makes ADD_REG_EVERY a pure cost parameter (section 2)
//     rather than a numerical one.
//   * There is no `>>> 15` and no `+ 16384` in this file. Every quantisation is
//     a call into fxp_pkg (the standing rule at the top of
//     rtl/packages/fxp_pkg.sv); what this module does directly is exact integer
//     addition, which is not quantisation.
//
// OUTPUT FORMAT: Q1.15, WITH SATURATION, AND WHY THAT IS THE RIGHT ANSWER
// ----------------------------------------------------------------------
// The output is fxp_pkg::fxp_complex_t — Q1.15 per component, the SPEC 6 sample
// format, saturating with direction-resolved flags. It is deliberately NOT a
// wider "beam sample" format, and the reason is that the alternative loses more
// than it gains:
//
//   * SPEC 6 fixes ONE sample format for the whole datapath. Everything
//     downstream of the beamformer — the power/covariance engine (#13), CFAR
//     (#14), the packet payload — is written against Q1.15 complex. A wider beam
//     sample would make the beamformer the one block whose output nothing else
//     can consume without a converter, and the converter would round anyway.
//   * The dot product of Q1.15 operands over N antennas has magnitude up to
//     N * 1.0, so Q1.15 output IS reachable-and-exceedable and saturation IS a
//     real event. SPEC 7.5 asks for exactly that: "saturation and overflow
//     reporting". The programming contract is that a weight row is normalised
//     (sum of |W[b][a]| <= 1 keeps the sum inside Q1.15 for any legal input);
//     a row that is not normalised produces a clamped sample and a flag,
//     which is a diagnosable condition rather than a wrapped one.
//   * Clamping, never wrapping: a wrapped overflow turns a strong beam into a
//     strong beam of the opposite sign, which CFAR cannot distinguish from a
//     real target. The flags are direction-resolved (fxp_pkg's convention)
//     because persistent positive saturation is a gain-staging error while
//     alternating saturation is oscillation.
//
// The FULL-PRECISION accumulator is also exported (`acc_re` / `acc_im`,
// bf_acc_w(N_ANT) bits, exact, never saturating). Nothing in this issue consumes
// it, but issue #13's power engine computes |Y|^2 and would otherwise square a
// value that has already been rounded and clamped. Exporting the exact port
// costs nothing when it is unused — it is the same wire the quantiser reads —
// and it is the difference between a clean interface for the next kernel and a
// second copy of this module.
//
// -----------------------------------------------------------------------------
// 2. The adder tree and its pipelining parameter
// -----------------------------------------------------------------------------
// A BALANCED BINARY TREE, not a serial chain. clog2(N_ANT) levels, N_ANT-1
// adders per output component; a chain would be N_ANT-1 adders deep and would
// put the whole accumulation on one combinational path or need N_ANT registers
// to break it.
//
// ADD_REG_EVERY selects how many levels share a register: a register is placed
// after level l when l is a multiple of ADD_REG_EVERY, and always after the last
// level so the tree output is registered. beamformer_pkg::bf_tree_regs()
// computes the resulting stage count and this module asserts at elaboration that
// the pipeline it BUILT has exactly that many stages, so the advertised latency
// and the constructed one cannot drift apart.
//
//   N_ANT = 16, ADD_REG_EVERY = 1   4 registered levels, 1 adder per stage
//   N_ANT = 16, ADD_REG_EVERY = 2   2 registered levels, 2 adders per stage
//
// Which one Agilex 7 and Quartus Pro 26.1 prefer is a MEASUREMENT, not an
// argument: the SPEC 18 sweep (quartus/calibration/bf_dot_calib.qsf,
// scripts/run_calibration.py --kernel bf_dot) compiles both and records ALMs,
// registers, Hyper-Registers and restricted Fmax. DECISIONS.md carries the
// outcome. Until that data existed the default was 1, for the honest reason that
// a register per level is the structure whose cost is predictable without
// knowing what the retimer will do with it.
//
// -----------------------------------------------------------------------------
// 3. Flow control and reset (SPEC 23, SPEC 5)
// -----------------------------------------------------------------------------
// NO `ready`, and the internal pipeline is NEVER stalled. This is a fixed-latency
// arithmetic kernel, exactly as complex_multiplier and fir_lane are, for exactly
// the same reason: a ready chain here would land `m_ready` on the clock enable of
// every DSP register in the matrix — SPEC 23's "avoid one chip-wide clock
// enable", verbatim. Backpressure is the block's concern and is absorbed at the
// rtl/beamformer/beamformer.sv boundary by a credit scheme and an elastic
// buffer.
//
// Reset validity, not every datapath bit (SPEC 23). The products, the tree nodes
// and the output register have no reset and no clock enable; only the valid tag
// resets. A beat's outputs are meaningful when `valid_out` is high and are
// don't-care otherwise, which is what leaves the datapath free for
// Hyper-Register retiming.
//
// -----------------------------------------------------------------------------
// 4. Simulation-only proof
// -----------------------------------------------------------------------------
// A FLAT sum of the tree's own leaves, delayed by exactly the tree's register
// depth, is compared against the tree's output on every valid cycle
// (`a_bf_tree_matches_flat_sum`). Both sides start from the same level-0 values,
// so they must be bit-identical; any mis-wired level, any wrong register stride,
// any off-by-one in the leaf padding shows up immediately rather than as a wrong
// beam sample thousands of beats later. It costs one ACC_W-bit shift register
// per component in simulation and nothing in synthesis.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module bf_dot
  import fxp_pkg::*;
  import beamformer_pkg::*;
#(
    // Antennas summed by this dot product. SPEC 7.5: "up to 16 antennas".
    parameter int unsigned N_ANT = 16,

    // complex_multiplier PIPE_STAGES; equals that module's latency. 4 is the
    // issue #9 calibrated default (DECISIONS.md, issue #9 decision 9).
    parameter int unsigned MULT_PIPE_STAGES = 4,

    // "MULT4" (four real multiplies) or "MULT3" (Karatsuba). Bit-identical
    // outputs; issue #9 measured MULT4 cheaper and faster on this device.
    parameter string MULT_VARIANT = "MULT4",

    // Adder-tree pipelining stride. See section 2.
    parameter int unsigned ADD_REG_EVERY = 1,

    // DERIVED. Never override: a port width must be a parameter expression and
    // SystemVerilog gives a port list no view of a localparam, so the
    // accumulator arithmetic is repeated here once.
    // beamformer_pkg::bf_acc_w() remains the normative statement of it and the
    // elaboration check below compares the two — an override, or a change to
    // the accumulator policy, fails at time 0 rather than silently truncating
    // every sum.
    //
    // bf_acc_w(N) = FXP_PROD_W + clog2(2N) and clog2(2N) = clog2(N) + 1 for
    // every N >= 1, which is the form a parameter expression can state.
    parameter int unsigned BF_ACC_W =
        fxp_pkg::FXP_PROD_W + 1 + $clog2(N_ANT)
) (
    input  wire                                clk,
    input  wire                                rst_n,

    // A beat is present this cycle. Never stalled; see section 3.
    input  wire                                valid_in,

    // The bin's antenna vector and this beam's weight row, both antenna-minor:
    // antenna a at a*32 +: 32, packed {im, re}, Q1.15. The weights come from
    // rtl/beamformer/weight_bank.sv; they are never a constant.
    input  wire [N_ANT*2*FXP_SAMPLE_W-1:0]     x,
    input  wire [N_ANT*2*FXP_SAMPLE_W-1:0]     w,

    output wire                                valid_out,

    // The beam sample: Q1.15 complex, rounded once and saturated. See section 1.
    output wire fxp_complex_t                  y,

    // Direction-resolved saturation flags for that single quantisation.
    output wire fxp_flags_t                    flags_re,
    output wire fxp_flags_t                    flags_im,
    output wire                                ovf,

    // The EXACT accumulator, before any quantisation. Never saturates. Provided
    // for issue #13's power engine; see section 1.
    output wire signed [BF_ACC_W-1:0]          acc_re,
    output wire signed [BF_ACC_W-1:0]          acc_im
);

  // ---------------------------------------------------------------------------
  // Geometry. BF_ACC_W is a PARAMETER-visible expression because a port width
  // must be one and SystemVerilog gives a port list no view of a localparam;
  // the elaboration check below compares it against beamformer_pkg's own
  // function, which is the normative statement, so the two cannot drift.
  // ---------------------------------------------------------------------------
  localparam int unsigned PAIR_W    = 2 * FXP_SAMPLE_W;                    // 32
  localparam int unsigned PROD_W    = int'(bf_prod_w());                   // 33
  localparam int unsigned ACC_W     = int'(bf_acc_w(bf_uint_t'(N_ANT)));
  localparam int unsigned LEVELS    = int'(bf_tree_levels(bf_uint_t'(N_ANT)));
  localparam int unsigned NPAD      = int'(bf_tree_leaves(bf_uint_t'(N_ANT)));
  localparam int unsigned TREE_REGS =
      int'(bf_tree_regs(bf_uint_t'(N_ANT), bf_uint_t'(ADD_REG_EVERY)));

  // Free-running register stages after the multiplier: the registered tree
  // levels plus the module's output register.
  localparam int unsigned POST_STAGES = TREE_REGS + 1;

  localparam int unsigned LATENCY =
      int'(bf_dot_lat(bf_uint_t'(N_ANT), bf_uint_t'(MULT_PIPE_STAGES),
                      bf_uint_t'(ADD_REG_EVERY)));

  // True when level `l` (1-based) ends in a register. Written once, used by both
  // the generate below and the count check above it, so the structure and the
  // advertised depth are the same statement.
  function automatic logic level_is_registered(input int unsigned l);
    return ((l % ADD_REG_EVERY) == 0) || (l == LEVELS);
  endfunction

  function automatic int unsigned built_tree_regs();
    int unsigned n;
    n = 0;
    for (int unsigned l = 1; l <= LEVELS; l++) begin
      if (level_is_registered(l)) n = n + 1;
    end
    return n;
  endfunction

`ifndef SYNTHESIS
  initial begin
    if (N_ANT < 1 || N_ANT > int'(bf_max_antennas())) begin
      $fatal(1, "bf_dot: N_ANT=%0d outside [1, %0d]", N_ANT, bf_max_antennas());
    end
    if (!bf_reg_every_ok(bf_uint_t'(ADD_REG_EVERY))) begin
      $fatal(1, "bf_dot: ADD_REG_EVERY=%0d outside [1, 4]", ADD_REG_EVERY);
    end
    // The port-width expression and the package must agree. They are computed
    // two different ways on purpose: the port cannot call a function, so if the
    // accumulator policy ever changes this catches the drift at time 0 rather
    // than as a silently truncated sum.
    if (BF_ACC_W != ACC_W) begin
      $fatal(1, "bf_dot: the BF_ACC_W port width is %0d but bf_acc_w(%0d)=%0d",
             BF_ACC_W, N_ANT, ACC_W);
    end
    // The accumulator must be wide enough that the sum of N_ANT exact 33-bit
    // partial sums cannot overflow. Restated as an inequality rather than
    // trusted from the package, because it is the assumption that makes "no
    // intermediate saturation" true and therefore the assumption that makes the
    // tree's shape numerically irrelevant.
    if (ACC_W < PROD_W + LEVELS) begin
      $fatal(1, "bf_dot: ACC_W=%0d is too narrow for %0d partial sums of %0d bits",
             ACC_W, N_ANT, PROD_W);
    end
    // The advertised latency must equal the number of register stages this
    // module actually builds. If either side is edited alone this fires at time
    // 0 rather than as a misaligned scoreboard entry.
    if (built_tree_regs() != TREE_REGS) begin
      $fatal(1, "bf_dot: the tree builds %0d registered levels but bf_tree_regs()=%0d",
             built_tree_regs(), TREE_REGS);
    end
    if (LATENCY != MULT_PIPE_STAGES + POST_STAGES) begin
      $fatal(1, "bf_dot: bf_dot_lat()=%0d but the pipeline builds %0d stages",
             LATENCY, MULT_PIPE_STAGES + POST_STAGES);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // N_ANT complex multipliers, exact output (ROUND_OUT = 0)
  //
  // prod[0] is the real component's partial sum, prod[1] the imaginary one —
  // the same [component][term] nesting rtl/pfb/fir_lane.sv uses, so the two
  // accumulation structures in this repository read the same way.
  // ---------------------------------------------------------------------------
  logic [1:0][N_ANT-1:0][PROD_W-1:0] prod;
  logic [N_ANT-1:0]                  mult_valid_all;

  for (genvar a = 0; a < int'(N_ANT); a++) begin : g_mult
    fxp_complex_t             xa, wa;
    logic                     v_a;
    logic signed [PROD_W-1:0] pr_a, pi_a;

    // ROUND_OUT = 0, so the rounded port and its flags are tied off inside the
    // multiplier and its whole rounding network is absent. Named sinks rather
    // than `()`: an empty pin connection is a lint warning (PINCONNECTEMPTY)
    // and, more usefully, a named wire says which outputs are deliberately not
    // used. This module rounds ONCE, at its own output.
    fxp16_t     y_re_unused, y_im_unused;
    fxp_flags_t flags_re_unused, flags_im_unused;
    logic       ovf_unused;

    assign xa = fxp_complex_t'(x[a*PAIR_W +: PAIR_W]);
    assign wa = fxp_complex_t'(w[a*PAIR_W +: PAIR_W]);

    complex_multiplier #(
        .VARIANT     (MULT_VARIANT),
        .PIPE_STAGES (MULT_PIPE_STAGES),
        .ROUND_OUT   (0)
    ) u_mult (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (valid_in),
        .a         (xa),
        .b         (wa),
        .valid_out (v_a),
        .p_re      (pr_a),
        .p_im      (pi_a),
        .y_re      (y_re_unused),
        .y_im      (y_im_unused),
        .flags_re  (flags_re_unused),
        .flags_im  (flags_im_unused),
        .ovf       (ovf_unused)
    );

    assign prod[0][a]        = pr_a;
    assign prod[1][a]        = pi_a;
    assign mult_valid_all[a] = v_a;
  end

  // Every multiplier is identical and identically stimulated, so their valids
  // are the same signal; antenna 0's is used and the rest feed the structural
  // check at the bottom rather than being dropped silently.
  logic mult_valid;
  assign mult_valid = mult_valid_all[0];

  // ---------------------------------------------------------------------------
  // Balanced adder tree, padded to a power of two so the structure is one
  // uniform loop; the padding leaves are constant zero and disappear.
  //
  // ONE SIGNAL PER LEVEL, not one array indexed by level, and that shape is
  // forced rather than chosen. Verilator's combinational-loop analysis works on
  // whole variables: with the whole tree in a single `node[c][l][i]` array, a
  // level that feeds the next one COMBINATIONALLY — which is exactly what
  // ADD_REG_EVERY > 1 asks for — makes the array appear to depend on itself and
  // the build fails with UNOPTFLAT. rtl/pfb/fir_lane.sv keeps one array only
  // because every one of its levels is registered, so the loop is always broken
  // by a flip-flop. Declaring each level inside its own generate scope makes the
  // dependency the acyclic chain it actually is, at the cost of one hierarchical
  // reference per level.
  //
  // Every bit of every level has exactly one continuous driver — the same
  // discipline rtl/pfb/fir_lane.sv and rtl/common/complex_multiplier.sv use — so
  // no node can pick up a second procedural writer as the module grows.
  // ---------------------------------------------------------------------------
  logic [1:0][NPAD-1:0][ACC_W-1:0] leaf;
  logic [1:0][ACC_W-1:0]           acc;

  for (genvar c = 0; c < 2; c++) begin : g_comp
    for (genvar i = 0; i < int'(NPAD); i++) begin : g_leaf
      if (i < int'(N_ANT)) begin : g_real
        logic signed [PROD_W-1:0] pv;
        assign pv         = signed'(prod[c][i]);
        assign leaf[c][i] = ACC_W'(pv);
      end else begin : g_pad
        assign leaf[c][i] = '0;
      end
    end
  end

  for (genvar l = 1; l <= int'(LEVELS); l++) begin : g_level
    localparam int unsigned NL = int'(NPAD) >> l;

    logic [1:0][NL-1:0][ACC_W-1:0] lvl;

    for (genvar c = 0; c < 2; c++) begin : g_comp
      for (genvar i = 0; i < int'(NL); i++) begin : g_node
        logic [ACC_W-1:0] sum_c;

        if (l == 1) begin : g_from_leaf
          assign sum_c = ACC_W'(signed'(leaf[c][2*i]) + signed'(leaf[c][2*i+1]));
        end else begin : g_from_prev
          assign sum_c = ACC_W'(signed'(g_level[l-1].lvl[c][2*i]) +
                                signed'(g_level[l-1].lvl[c][2*i+1]));
        end

        if (level_is_registered(l)) begin : g_reg
          logic [ACC_W-1:0] sum_q;
          always_ff @(posedge clk) begin
            sum_q <= sum_c;
          end
          assign lvl[c][i] = sum_q;
        end else begin : g_comb
          // Deliberately unregistered: ADD_REG_EVERY > 1 asks for two or more
          // adders between registers, and this is where that happens.
          assign lvl[c][i] = sum_c;
        end
      end
    end
  end

  for (genvar c = 0; c < 2; c++) begin : g_root
    if (LEVELS == 0) begin : g_single
      // One antenna: the "tree" is the product itself, and the module's latency
      // arithmetic already says so (bf_tree_regs returns 0).
      assign acc[c] = leaf[c][0];
    end else begin : g_tree
      assign acc[c] = g_level[LEVELS].lvl[c][0];
    end
  end

  // ---------------------------------------------------------------------------
  // The module's ONE quantisation, and its output register
  //
  // Flags describe the value being clamped — AFTER the round and BEFORE the
  // saturate — which is the order fxp_pkg fixes and the only order in which a
  // round-induced overflow is reportable at all.
  // ---------------------------------------------------------------------------
  fxp16_t     y_re_c, y_im_c;
  fxp_flags_t f_re_c, f_im_c;

  always_comb begin
    y_re_c = fxp16_t'(fxp_round_sat(fxp_wide_t'(signed'(acc[0])),
                                    FXP_PROD_SHIFT, FXP_SAMPLE_W));
    y_im_c = fxp16_t'(fxp_round_sat(fxp_wide_t'(signed'(acc[1])),
                                    FXP_PROD_SHIFT, FXP_SAMPLE_W));
    f_re_c = fxp_sat_flags(fxp_round(fxp_wide_t'(signed'(acc[0])),
                                     FXP_PROD_SHIFT), FXP_SAMPLE_W);
    f_im_c = fxp_sat_flags(fxp_round(fxp_wide_t'(signed'(acc[1])),
                                     FXP_PROD_SHIFT), FXP_SAMPLE_W);
  end

  fxp16_t            y_re_q, y_im_q;
  fxp_flags_t        f_re_q, f_im_q;
  logic [ACC_W-1:0]  acc_re_q, acc_im_q;

  always_ff @(posedge clk) begin
    y_re_q   <= y_re_c;
    y_im_q   <= y_im_c;
    f_re_q   <= f_re_c;
    f_im_q   <= f_im_c;
    acc_re_q <= acc[0];
    acc_im_q <= acc[1];
  end

  assign y        = '{im: y_im_q, re: y_re_q};
  assign flags_re = f_re_q;
  assign flags_im = f_im_q;
  assign ovf      = fxp_flags_any(f_re_q) | fxp_flags_any(f_im_q);
  assign acc_re   = signed'(acc_re_q);
  assign acc_im   = signed'(acc_im_q);

  // ---------------------------------------------------------------------------
  // Valid pipeline — the only reset state in the module (SPEC 23)
  // ---------------------------------------------------------------------------
  logic [POST_STAGES:0] vch;
  assign vch[0] = mult_valid;

  for (genvar s = 0; s < int'(POST_STAGES); s++) begin : g_valid
    logic v_q;
    always_ff @(posedge clk) begin
      if (!rst_n) v_q <= 1'b0;
      else        v_q <= vch[s];
    end
    assign vch[s+1] = v_q;
  end

  assign valid_out = vch[POST_STAGES];

  // ---------------------------------------------------------------------------
  // Simulation-only proofs. See section 4.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  // (a) Every multiplier in the dot product must agree about when its result is
  // valid. They are identical modules driven by one `valid_in`, so a
  // disagreement means the generate loop has been broken — which would
  // otherwise show up only as a wrong sum.
  always_ff @(posedge clk) begin
    if (rst_n) begin
      a_bf_mult_valid_uniform : assert (mult_valid_all == {N_ANT{mult_valid}})
        else $error("bf_dot: multiplier valids disagree (%b)", mult_valid_all);
    end
  end

  // (b) The tree computes the sum of its own leaves. A flat reduction of level 0
  // is delayed by exactly the tree's register depth and compared against the
  // tree output. Driven only by continuous assignments so every bit has one
  // driver, the same discipline the datapath uses.
  logic [1:0][ACC_W-1:0] flat_sum_c;

  always_comb begin
    for (int unsigned c = 0; c < 2; c++) begin
      flat_sum_c[c] = '0;
      for (int unsigned i = 0; i < NPAD; i++) begin
        flat_sum_c[c] = ACC_W'(signed'(flat_sum_c[c]) + signed'(leaf[c][i]));
      end
    end
  end

  logic [1:0][TREE_REGS:0][ACC_W-1:0] flat_ch;
  logic [TREE_REGS:0]                 flat_vld;

  assign flat_vld[0] = mult_valid;

  for (genvar c = 0; c < 2; c++) begin : g_flat_comp
    assign flat_ch[c][0] = flat_sum_c[c];
    for (genvar s = 0; s < int'(TREE_REGS); s++) begin : g_flat_stage
      logic [ACC_W-1:0] f_q;
      always_ff @(posedge clk) begin
        f_q <= flat_ch[c][s];
      end
      assign flat_ch[c][s+1] = f_q;
    end
  end

  for (genvar s = 0; s < int'(TREE_REGS); s++) begin : g_flat_vld
    logic fv_q;
    always_ff @(posedge clk) begin
      if (!rst_n) fv_q <= 1'b0;
      else        fv_q <= flat_vld[s];
    end
    assign flat_vld[s+1] = fv_q;
  end

  always_ff @(posedge clk) begin
    if (rst_n && flat_vld[TREE_REGS]) begin
      a_bf_tree_matches_flat_sum_re : assert (acc[0] == flat_ch[0][TREE_REGS])
        else $error("bf_dot: tree re %0d != flat sum %0d",
                    signed'(acc[0]), signed'(flat_ch[0][TREE_REGS]));
      a_bf_tree_matches_flat_sum_im : assert (acc[1] == flat_ch[1][TREE_REGS])
        else $error("bf_dot: tree im %0d != flat sum %0d",
                    signed'(acc[1]), signed'(flat_ch[1][TREE_REGS]));
    end
  end
`endif

endmodule : bf_dot

`default_nettype wire
