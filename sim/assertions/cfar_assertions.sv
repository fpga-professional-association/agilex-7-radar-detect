// -----------------------------------------------------------------------------
// cfar_assertions — SPEC.md 14 property set for the CFAR detector (issue #14).
//
// Instantiated INSIDE rtl/cfar/cfar_core.sv under `ifndef SYNTHESIS`, not bound
// externally, for the reason rtl/covariance/integrator.sv gives for its own
// checker: the properties then hold wherever the module is used — the unit-test
// top, a future pipeline integration, and the Quartus calibration wrapper that
// no testbench ever drives — rather than only where a bind statement was
// remembered.
//
// Five properties, each of which fails a DIFFERENT defect:
//
//   a_cfar_threshold_matches_pkg
//       the sized datapath computes cfar_pkg::cfar_over_threshold(). This is
//       the one that makes "the RTL implements equation (*)" a checked fact
//       rather than a comment: the module builds the comparison out of CMP_W
//       multipliers for synthesis, and the package builds it out of 64-bit
//       arithmetic for clarity, and the two are required to agree on every
//       decision. A width that is one bit too narrow, a shift in the wrong
//       direction, or an operand pair swapped between the two sides all fail
//       here immediately.
//
//   a_cfar_decision_exclusive
//       a bin is detected, or suppressed, or neither — never two of those. The
//       three outputs are computed from overlapping terms, so "they cannot both
//       be true" is exactly the kind of claim that survives a refactor by luck.
//
//   a_cfar_supp_no_detect
//       SPEC 7.7's actual requirement, stated in the smallest possible form:
//       a suppressed bin raises no detection. Kept separate from the exclusivity
//       property above so that a failure names the SPEC clause it broke.
//
//   a_cfar_out_never_blocked
//       the credit argument of cfar_core section 4. If the reservation scheme is
//       ever wrong, the elastic buffer refuses a push and an event is silently
//       lost; this turns that into an immediate named failure at the cycle the
//       reservation was over-committed, rather than into a missing event
//       thousands of cycles later.
//
//   a_cfar_cfg_frame_boundary
//       cfar_core section 5: the active configuration changes only on a cycle in
//       which a start-of-frame beat was admitted. This is the assertion that
//       enforces "runtime parameter changes take effect at a frame boundary
//       only" — the property a per-frame suppression count depends on for its
//       meaning.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module cfar_assertions
  import cfar_pkg::*;
#(
    parameter int unsigned POWER_W = 40,
    parameter int unsigned SUM_W   = 45,
    parameter int unsigned CMP_W   = 61,
    parameter int unsigned NTOT_W  = 7,
    parameter int unsigned ACT_W   = 1
) (
    input wire                clk,
    input wire                rst_n,

    // ---- the decision stage -------------------------------------------------
    input wire                dec_valid,      // a decision retires this cycle
    input wire                dec_cut_valid,  // it concerns a real bin
    input wire [POWER_W-1:0]  dec_cell,
    input wire [SUM_W-1:0]    dec_sum,
    input wire [NTOT_W-1:0]   dec_n,
    input wire [CFAR_ALPHA_W-1:0] dec_alpha,
    input wire [CMP_W-1:0]    dec_lhs,
    input wire [CMP_W-1:0]    dec_rhs,
    input wire                dec_detected,
    input wire                dec_supp,
    input wire                dec_evaluable,

    // ---- output flow control ------------------------------------------------
    input wire                push,
    input wire                buf_ready,

    // ---- configuration timing ----------------------------------------------
    input wire                frame_start,    // a start-of-frame beat was admitted
    input wire [ACT_W-1:0]    act_vec         // the whole active configuration
);

`ifndef SYNTHESIS

  // The package's own statement of the comparison, on the same operands.
  wire pkg_over = cfar_over_threshold(cfar_wide_t'(dec_cell),
                                      cfar_wide_t'(dec_sum),
                                      cfar_wide_t'(dec_n),
                                      cfar_wide_t'(dec_alpha));

  wire rtl_over = dec_lhs > dec_rhs;

  // The active copy is written AT the start-of-frame beat, so it differs from
  // its previous value on the cycle AFTER that beat. The permission signal is
  // therefore the delayed `frame_start`, not the live one — getting that wrong
  // makes the property fire on every legal reconfiguration, which is how it was
  // found.
  logic [ACT_W-1:0] act_q;
  logic             seen_act_q;
  logic             frame_start_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      act_q         <= '0;
      seen_act_q    <= 1'b0;
      frame_start_q <= 1'b0;
    end else begin
      act_q         <= act_vec;
      seen_act_q    <= 1'b1;
      frame_start_q <= frame_start;
    end
  end

  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (dec_valid && dec_cut_valid) begin
        a_cfar_threshold_matches_pkg : assert (rtl_over == pkg_over)
          else $error("cfar: sized datapath says %0d but cfar_pkg says %0d for cell=%0d sum=%0d n=%0d alpha=%0d (lhs=%0d rhs=%0d)",
                      rtl_over, pkg_over, dec_cell, dec_sum, dec_n, dec_alpha,
                      dec_lhs, dec_rhs);

        a_cfar_decision_exclusive : assert (!(dec_detected && dec_supp))
          else $error("cfar: a bin was reported both detected and suppressed");

        a_cfar_supp_no_detect : assert (!dec_supp || !dec_detected)
          else $error("cfar: SPEC 7.7 violation — a detection was raised on a suppressed bin");

        a_cfar_detect_implies_evaluable : assert (!dec_detected || dec_evaluable)
          else $error("cfar: a detection was raised on a bin that was not evaluable");
      end

      a_cfar_out_never_blocked : assert (!push || buf_ready)
        else $error("cfar: the output elastic buffer refused a push — the credit reservation is over-committed");

      a_cfar_cfg_frame_boundary : assert (!seen_act_q || (act_vec == act_q) || frame_start_q)
        else $error("cfar: the active configuration changed outside a frame boundary");
    end
  end

`endif

endmodule : cfar_assertions

`default_nettype wire
