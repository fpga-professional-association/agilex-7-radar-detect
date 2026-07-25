// -----------------------------------------------------------------------------
// cdc_sva.svh — the reusable SPEC 8 / SPEC 14 clock-domain-crossing property set.
//
// SPEC 14 names two CDC obligations explicitly —
//
//     * CDC handshake completion.
//     * Gray-pointer one-bit transitions.
//
// — alongside the FIFO overflow, FIFO underflow and illegal-simultaneous-state
// checks that apply to the asynchronous FIFO as much as to the synchronous one,
// and requires all of them to "remain active in fast simulation".
//
// This header holds the property TEXT, once, exactly as sim/assertions/
// stream_sva.svh does for the SPEC 5 stream protocol. Two ways to use it:
//
//   1. `cdc_gray_checker` / `cdc_handshake_checker`
//      (sim/assertions/cdc_protocol_checker.sv) — modules built from these
//      macros, instantiated inside the primitives under `ifndef SYNTHESIS` so a
//      design built from rtl/cdc/ is checked everywhere by construction, or
//      `bind`-ed onto a module whose source you do not own.
//   2. The macros directly, for a check on an internal signal that has no port.
//      One use per scope: the macros declare fixed assertion and variable names,
//      so a second use in the same scope needs its own named block.
//
// WHAT THESE PROPERTIES CAN AND CANNOT SEE
// ----------------------------------------
// A four-state simulator can model metastability as an X on the first
// synchronizer flop. Verilator is two-state and does not, so nothing here claims
// to check metastability itself. What is checkable — and what actually breaks
// real crossings — is the *protocol* that makes metastability harmless:
//
//   * a Gray-coded pointer changes at most one bit per update, so a sample taken
//     mid-transition is either the old value or the new one and never a third
//     value that was never a real pointer. This is the single property the whole
//     asynchronous-FIFO construction rests on, and `a_gray_one_bit` is the only
//     thing standing between "the pointer is Gray-coded" and "someone wrote a
//     binary increment there".
//   * a multibit handshake holds its data stable for the entire window in which
//     the destination may sample it, and every raised request is answered. A
//     source that mutates data under an asserted request has a crossing that
//     works in simulation and fails on silicon, which is exactly the class of
//     defect an assertion has to catch.
//
// The negative test sim/tests/test_cdc_assertions.cpp drives a deliberately
// broken crossing (sim/verilator/tops/cdc_violator.sv) and requires
// `a_gray_one_bit` and `a_hs_data_stable` to fire by name, so neither property
// can rot into decoration.
//
// Tool constraints under Verilator 5.020, inherited from the measurements for
// stream_sva.svh (DECISIONS.md 2026-07-26, decision 3):
//   * concurrent `assert property` with |=>, |->, $stable, $past, disable iff  yes
//   * immediate `assert` inside always_ff with an else $error action           yes
//   * `##` cycle-delay sequences                                              NO
//   Everything below is therefore written with implication, $past, or an
//   explicit shadow register — never with sequence concatenation.
//
// Also inherited, and load-bearing: this preprocessor substitutes macro
// arguments inside string literals, so no message text below may contain a word
// that is also a macro parameter name (`clk_i`, `rst_ni`, `gray_i`, `req_i`,
// `ack_i`, `dat_i`, and the upper-case width/limit arguments).
//
// Non-synthesizable constructs are guarded by `ifndef SYNTHESIS` at every use
// site.
// -----------------------------------------------------------------------------

`ifndef CDC_SVA_SVH_
`define CDC_SVA_SVH_

// -----------------------------------------------------------------------------
// `CDC_SVA_GRAY(clk_i, rst_ni, gray_i, W_I)
//
// SPEC 14: "Gray-pointer one-bit transitions."
//
//   a_gray_one_bit   between two consecutive cycles the observed vector either
//                    does not change (no pointer update that cycle) or changes
//                    in exactly one bit position. The predicate itself lives in
//                    cdc_pkg::cdc_gray_step_ok so the rule is stated once.
//
// Implemented with an explicit shadow register plus an immediate assertion
// rather than with $past, for two reasons: the first comparison after reset
// release must be suppressed (there is no previous value yet, and the pointer's
// reset value is not reached by a Gray step from whatever preceded it), and the
// shadow makes the failure message able to print both values.
//
// The cover records that the pointer actually moved during the run — a crossing
// whose pointer never changes satisfies the assertion vacuously, and that is a
// dead test, not a passing one.
// -----------------------------------------------------------------------------
`define CDC_SVA_GRAY(clk_i, rst_ni, gray_i, W_I)                                \
  logic [(W_I)-1:0] cdc_gray_prev_q;                                            \
  logic             cdc_gray_seen_q;                                            \
  logic             cdc_gray_moved_q;                                           \
                                                                                \
  always_ff @(posedge (clk_i)) begin                                            \
    if (!(rst_ni)) begin                                                        \
      cdc_gray_prev_q  <= (gray_i);                                             \
      cdc_gray_seen_q  <= 1'b0;                                                 \
      cdc_gray_moved_q <= 1'b0;                                                 \
    end else begin                                                              \
      a_gray_one_bit : assert (!cdc_gray_seen_q ||                              \
          cdc_pkg::cdc_gray_step_ok(cdc_pkg::cdc_word_t'(cdc_gray_prev_q),      \
                                    cdc_pkg::cdc_word_t'(gray_i)))              \
        else $error("cdc: pointer took an illegal step, %0d bits changed at once (was %0h, now %0h)", \
                    $countones(cdc_gray_prev_q ^ (gray_i)),                     \
                    cdc_gray_prev_q, (gray_i));                                 \
                                                                                \
      if (cdc_gray_seen_q && (cdc_gray_prev_q != (gray_i))) begin               \
        cdc_gray_moved_q <= 1'b1;                                               \
      end                                                                       \
      cdc_gray_prev_q <= (gray_i);                                              \
      cdc_gray_seen_q <= 1'b1;                                                  \
    end                                                                         \
  end                                                                           \
                                                                                \
  property p_gray_moved;                                                        \
    @(posedge (clk_i)) disable iff (!(rst_ni)) cdc_gray_moved_q;                \
  endproperty                                                                   \
  c_gray_moved : cover property (p_gray_moved);

// -----------------------------------------------------------------------------
// `CDC_SVA_HANDSHAKE(clk_i, rst_ni, req_i, ack_i, dat_i)
//
// SPEC 14: "CDC handshake completion." The four-phase protocol this design uses
// (DECISIONS.md, issue #6) is:
//
//     idle -> raise request, hold payload  -> destination captures, raises
//     acknowledge -> source drops request  -> destination drops acknowledge ->
//     idle
//
//   a_hs_req_held      a raised request is never withdrawn before it has been
//                      acknowledged. A source that withdraws mid-flight may have
//                      its payload sampled by a destination that never reports
//                      taking it, which is a silent loss.
//   a_hs_data_stable   the payload does not change while the request is up. This
//                      is the property that makes a multibit crossing legal at
//                      all: the destination samples an arbitrary point inside
//                      that window and must see one coherent value.
//   a_hs_ack_after_req an acknowledge rises only while a request is up. A
//                      spurious acknowledge completes a transfer that was never
//                      offered.
//   a_hs_ack_held      an acknowledge is held until the request drops, so the
//                      source cannot miss it.
//
// The observed side matters: instantiate this in the SOURCE domain with the
// source's own request and the *synchronized* acknowledge, which is the pair the
// source's state machine actually reacts to.
// -----------------------------------------------------------------------------
`define CDC_SVA_HANDSHAKE(clk_i, rst_ni, req_i, ack_i, dat_i)                   \
  property p_hs_req_held;                                                       \
    @(posedge (clk_i)) disable iff (!(rst_ni))                                  \
      ((req_i) && !(ack_i)) |=> (req_i);                                        \
  endproperty                                                                   \
  a_hs_req_held : assert property (p_hs_req_held)                               \
    else $error("cdc handshake: a pending transfer was withdrawn before it was answered"); \
                                                                                \
  property p_hs_data_stable;                                                    \
    @(posedge (clk_i)) disable iff (!(rst_ni))                                  \
      (req_i) |=> (!(req_i) || $stable(dat_i));                                 \
  endproperty                                                                   \
  a_hs_data_stable : assert property (p_hs_data_stable)                         \
    else $error("cdc handshake: the payload changed while the transfer was still pending"); \
                                                                                \
  property p_hs_ack_after_req;                                                  \
    @(posedge (clk_i)) disable iff (!(rst_ni))                                  \
      ((ack_i) && !$past(ack_i)) |-> $past(req_i);                              \
  endproperty                                                                   \
  a_hs_ack_after_req : assert property (p_hs_ack_after_req)                     \
    else $error("cdc handshake: an answer arrived for a transfer that was never offered"); \
                                                                                \
  property p_hs_ack_held;                                                       \
    @(posedge (clk_i)) disable iff (!(rst_ni))                                  \
      ((ack_i) && (req_i)) |=> ((ack_i) || !$past(req_i));                      \
  endproperty                                                                   \
  a_hs_ack_held : assert property (p_hs_ack_held)                               \
    else $error("cdc handshake: the answer was dropped while the offer was still up"); \
                                                                                \
  property p_hs_completed;                                                      \
    @(posedge (clk_i)) disable iff (!(rst_ni)) ((req_i) && (ack_i));            \
  endproperty                                                                   \
  c_hs_completed : cover property (p_hs_completed);

// -----------------------------------------------------------------------------
// `CDC_SVA_HANDSHAKE_LIVE(clk_i, rst_ni, req_i, ack_i, LIMIT_I)
//
// The completion half of "CDC handshake completion": a raised request must be
// answered within LIMIT_I cycles of the observing clock. Bounded liveness rather
// than unbounded, because an unbounded eventuality is unfalsifiable in a
// finite simulation and because a crossing that takes an unbounded time to
// complete is already broken.
//
// LIMIT_I must be generous relative to the clock ratio: a source cycle can span
// many destination cycles and the round trip is (source registration + two
// destination synchronizer stages + destination registration + two source
// synchronizer stages). The primitives pass a limit derived from their own
// synchronizer depth times a large ratio allowance; see cdc_handshake.sv.
// -----------------------------------------------------------------------------
`define CDC_SVA_HANDSHAKE_LIVE(clk_i, rst_ni, req_i, ack_i, LIMIT_I)            \
  int unsigned cdc_hs_wait_q;                                                   \
                                                                                \
  always_ff @(posedge (clk_i)) begin                                            \
    if (!(rst_ni)) begin                                                        \
      cdc_hs_wait_q <= 32'd0;                                                   \
    end else begin                                                              \
      a_hs_completes : assert (cdc_hs_wait_q <= (LIMIT_I))                      \
        else $error("cdc handshake: no answer after %0d cycles (bound is %0d)", \
                    cdc_hs_wait_q, (LIMIT_I));                                  \
      if ((req_i) && !(ack_i)) begin                                            \
        cdc_hs_wait_q <= cdc_hs_wait_q + 32'd1;                                 \
      end else begin                                                            \
        cdc_hs_wait_q <= 32'd0;                                                 \
      end                                                                       \
    end                                                                         \
  end

// -----------------------------------------------------------------------------
// `CDC_SVA_FIFO_PTR(clk_i, rst_ni, wr_i, rd_i, DEPTH_I)
//
// SPEC 14 FIFO overflow / underflow / illegal simultaneous state, expressed on
// the two binary pointers rather than on an occupancy counter. Deliberately a
// second, naive implementation of the fill level: an assertion written against
// the same counter that drives the full and empty flags is a tautology.
//
//   a_fifo_no_overflow    the write pointer never runs more than DEPTH_I ahead
//                         of the read pointer.
//   a_fifo_no_underflow   the read pointer never passes the write pointer.
//
// `wr_i` and `rd_i` are the full-width binary pointers, `PW_I` bits wide
// ($clog2(DEPTH)+1), in the same clock domain. The difference is taken in that
// width and not in `int`, so the pointer wrap stays modular and a wrapped
// pointer pair still yields the true fill level rather than a negative number. Instantiate once per domain, using that domain's own
// pointer and the synchronized copy of the other — which is the conservative
// view each domain acts on, and therefore the one whose violation is a real bug
// rather than an artefact of sampling two domains in a testbench.
// -----------------------------------------------------------------------------
`define CDC_SVA_FIFO_PTR(clk_i, rst_ni, wr_i, rd_i, DEPTH_I, PW_I)              \
  wire [(PW_I)-1:0] cdc_fifo_fill = (wr_i) - (rd_i);                            \
                                                                                \
  always_ff @(posedge (clk_i)) begin                                            \
    if ((rst_ni)) begin                                                         \
      a_fifo_no_overflow : assert (int'(cdc_fifo_fill) <= int'(DEPTH_I))        \
        else $error("cdc fifo: fill level %0d exceeds the capacity of %0d entries", \
                    int'(cdc_fifo_fill), int'(DEPTH_I));                        \
    end                                                                         \
  end

`endif  // CDC_SVA_SVH_
