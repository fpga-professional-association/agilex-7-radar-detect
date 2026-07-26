// -----------------------------------------------------------------------------
// history_wr_assertions — SPEC.md 14 property set for the WRITE side of the
// time-frequency history and corner turn (issue #15), in `core_clk`.
//
// Instantiated INSIDE rtl/memory/history_core.sv under `ifndef SYNTHESIS`, not
// bound externally, for the reason rtl/covariance/integrator.sv gives for its
// own checker: the properties then hold wherever the module is used — the unit
// test top, a future pipeline integration, and the Quartus calibration wrapper
// that no testbench ever drives — rather than only where a bind statement was
// remembered.
//
// ONE CLOCK, and the read side has a checker of its own. That split is not
// cosmetic: scripts/cdc_inventory.py --strict reports any instantiated module
// with two clock-like ports and no `(* cdc_primitive *)` attribute, which is the
// correct default, and a checker straddling both domains would trip it. Tagging
// the checker instead would put a crossing in the SPEC 8 inventory that does not
// exist in the hardware, and an inventory with an imaginary entry is worse than
// one with a missing entry. Every other checker in sim/assertions/ takes a
// single `clk` for the same reason.
//
// SPEC 14 classes covered here:
//
//   "Frame-boundary consistency"          a_history_occupancy_exact,
//                                         a_history_readable_exact
//   "Bank changes outside safe boundaries" a_history_apply_at_boundary,
//                                         a_history_no_write_across_apply
//   "Invalid state-machine states"        a_history_frames_done_step
//
// AND ONE OF THE TWO SPEC 7.3 PROHIBITIONS MADE CHECKABLE. "Avoids a single
// globally broadcast address and enable network" is a statement about a NET, and
// an assertion sees values rather than fanout. What is checked instead is the
// consequence a broadcast design could not produce:
// `c_history_write_enables_differ` covers a cycle in which some antennas are
// writing and others are not, which is impossible if one enable drives every
// bank. A design that regressed to a broadcast net would fail the cover, not
// merely look different. (The read half of the prohibition is
// `a_history_lane_onehot0`, in the read-side checker.)
//
// The simulator this project uses, at 5.020, accepts no `##` cycle-delay
// sequences (rtl/covariance's checker records the same limit, and note that a
// comment beginning with the tool's own name is read as a pragma, which is why
// this sentence is phrased the long way round). Every temporal property here is
// written with `$past` and an implication. Property names are `a_history_*` /
// `c_history_*` because the negative tests require specific assertions to fire
// BY NAME.
//
// All ports are `input wire`: a checker observes and never drives.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module history_wr_assertions #(
    parameter int unsigned N_ANT   = 2,
    parameter int unsigned DEPTH_W = 3
) (
    input wire               clk,
    input wire               rst_n,

    input wire [DEPTH_W-1:0] depth_active,
    input wire [DEPTH_W-1:0] occupancy,
    input wire [DEPTH_W-1:0] readable_core,
    input wire [31:0]        frames_done,
    input wire               depth_apply,
    input wire [N_ANT-1:0]   in_frame,
    input wire [N_ANT-1:0]   wr_en
);

`ifndef SYNTHESIS

  // occupancy = min(frames_done, depth), exactly, at every instant. This is the
  // "frame-boundary consistency" property: it fails if the barrier ever
  // published a frame an antenna had not finished, or if the saturation was
  // written as >= where it should be >.
  wire [DEPTH_W-1:0] occ_expect =
      (frames_done >= 32'(depth_active)) ? depth_active : DEPTH_W'(frames_done);

  wire [DEPTH_W-1:0] depth_m2_expect =
      (depth_active <= DEPTH_W'(2)) ? '0 : (depth_active - DEPTH_W'(2));
  wire [DEPTH_W-1:0] readable_expect =
      (frames_done >= 32'(depth_m2_expect)) ? depth_m2_expect
                                            : DEPTH_W'(frames_done);

  always_ff @(posedge clk) begin
    if (rst_n) begin
      a_history_occupancy_exact : assert (occupancy == occ_expect)
        else $error("history: occupancy %0d is not min(frames_done=%0d, depth=%0d)",
                    occupancy, frames_done, depth_active);

      a_history_readable_exact : assert (readable_core == readable_expect)
        else $error("history: readable %0d is not min(frames_done=%0d, depth-2=%0d)",
                    readable_core, frames_done, depth_m2_expect);

      // The readable set is always TWO slots short of the depth: one for the
      // frame being written, one to absorb a frame of publication lag across the
      // clock-domain crossing. See history_core header section 5 — a depth-1
      // bound is a real defect, and one the collision counter cannot see.
      a_history_readable_leaves_two_slots :
        assert ((depth_active <= DEPTH_W'(2))
                  ? (readable_core == '0)
                  : ((readable_core + DEPTH_W'(2)) <= depth_active))
        else $error("history: readable %0d does not leave two slots at depth %0d",
                    readable_core, depth_active);

      a_history_depth_in_range :
        assert (depth_active >= DEPTH_W'(1))
        else $error("history: active depth is zero");

      // SPEC 14 "bank changes outside safe boundaries". A depth change remaps
      // every slot, so it may only happen with no antenna mid-frame.
      a_history_apply_at_boundary :
        assert (!depth_apply || (in_frame == '0))
        else $error("history: depth applied while %0d antenna(s) were mid-frame",
                    $countones(in_frame));

      // ... and nothing written by the old mapping may land after it.
      a_history_no_write_across_apply :
        assert (!$past(depth_apply) || (wr_en == '0))
        else $error("history: a write landed in the cycle after a depth change");

      // The frame counter is monotone and moves by at most one per cycle, unless
      // a depth change reset it.
      a_history_frames_done_step :
        assert ($past(depth_apply) ||
                (frames_done == $past(frames_done)) ||
                (frames_done == $past(frames_done) + 32'd1))
        else $error("history: frames_done jumped from %0d to %0d",
                    $past(frames_done), frames_done);
    end
  end

  // SPEC 7.3's "no globally broadcast enable network", as the consequence a
  // broadcast design could not produce. Meaningless with one antenna, so it is
  // only elaborated when there is more than one.
  if (N_ANT > 1) begin : g_wr_en_cover
    c_history_write_enables_differ : cover property (
        @(posedge clk) disable iff (!rst_n)
        (wr_en != '0) && (wr_en != {N_ANT{1'b1}}));
  end

`endif

endmodule : history_wr_assertions

`default_nettype wire
