// -----------------------------------------------------------------------------
// fxp_sticky_flags — the standard saturation-flag collector (SPEC.md 6).
//
// SPEC 6 requires overflow flags as part of the one shared numerics definition.
// fxp_pkg produces them combinationally next to each result; this module is the
// one sanctioned way to hold them. Every kernel that quantises instantiates
// this rather than rolling its own sticky bit, for the same reason it calls
// fxp_pkg for the rounding: so that "did this block saturate?" means the same
// thing everywhere and the telemetry plane (issue #8) has one shape to read.
//
// Semantics
// ---------
//   * Sticky, not pulsed. A single saturating cycle at frame beat 40 000 is
//     still visible when the frame ends. Software clears it explicitly.
//   * `clear` is synchronous and wins over a simultaneous event, so a
//     read-then-clear can never drop an event that happened before the read,
//     but can never latch one that happened after it either — the alternative
//     (event wins) makes a clear non-idempotent and hides a stuck condition.
//   * The event counter SATURATES at all-ones instead of wrapping. A wrapped
//     counter can read zero on a permanently saturating datapath, which is the
//     one reading that must never be produced.
//   * Reset clears both, synchronously (SPEC 23: no async reset in the
//     datapath).
//
// Lint contract: clean under `--Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module fxp_sticky_flags
  import fxp_pkg::fxp_flags_t;
#(
    // Width of the saturation-event counter. 32 bits at ~450 MHz saturates
    // after ~9.5 s of continuous saturation, which is long enough that reaching
    // all-ones is itself the diagnosis.
    parameter int unsigned COUNT_W = 32
) (
    // `wire`, not `logic`, on every port. Quartus Prime Pro rejects an `input
    // logic` port under `default_nettype none` ("net type must be explicitly
    // specified"), which is how this was found: the polyphase bank (issue #10)
    // is the first block to instantiate this module in a Quartus compile, and
    // the eight-lane calibration point failed to elaborate. Every other module
    // in the repository already declares `wire` ports; this one was the
    // exception, and simulation had never noticed.
    input  wire                clk,
    input  wire                rst_n,

    // Synchronous clear of both the sticky flags and the counter.
    input  wire                clear,

    // Flags for the quantisation happening this cycle, qualified by `valid` so
    // that a combinational function of stale operands cannot be counted.
    input  wire                valid,
    input  wire fxp_flags_t    flags_in,

    output wire fxp_flags_t    flags_sticky,
    output wire                any_sticky,
    output wire [COUNT_W-1:0]  event_count
);

  fxp_flags_t         sticky_q;
  logic [COUNT_W-1:0] count_q;

  // One counted event per cycle in which a qualified quantisation saturated in
  // either direction: this counts saturating *cycles*, not saturating bits.
  logic event_now;
  assign event_now = valid && (flags_in.sat_pos || flags_in.sat_neg);

  logic count_at_max;
  assign count_at_max = &count_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      sticky_q <= '{sat_pos: 1'b0, sat_neg: 1'b0};
      count_q  <= '0;
    end else if (clear) begin
      sticky_q <= '{sat_pos: 1'b0, sat_neg: 1'b0};
      count_q  <= '0;
    end else begin
      if (valid) begin
        sticky_q.sat_pos <= sticky_q.sat_pos | flags_in.sat_pos;
        sticky_q.sat_neg <= sticky_q.sat_neg | flags_in.sat_neg;
      end
      if (event_now && !count_at_max) begin
        count_q <= count_q + COUNT_W'(1);
      end
    end
  end

  assign flags_sticky = sticky_q;
  assign any_sticky   = sticky_q.sat_pos | sticky_q.sat_neg;
  assign event_count  = count_q;

endmodule : fxp_sticky_flags

`default_nettype wire
