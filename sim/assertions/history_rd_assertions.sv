// -----------------------------------------------------------------------------
// history_rd_assertions — SPEC.md 14 property set for the READ side of the
// time-frequency history and corner turn (issue #15), in `history_clk`.
//
// Instantiated INSIDE rtl/memory/history_core.sv under `ifndef SYNTHESIS`. See
// sim/assertions/history_wr_assertions.sv for why the two domains have separate
// checkers rather than one straddling both.
//
// SPEC 14 classes covered here:
//
//   "Illegal simultaneous read/write states"  a_history_no_safe_collision
//   "Invalid state-machine states"            a_history_lane_onehot0,
//                                             a_history_lane_en_tracks_pipe
//   "Memory response without a request"       a_history_all_antennas_answer
//   "FIFO overflow"                           a_history_out_never_blocked
//
// THE COLLISION CLAIM IS THE ONE THAT MATTERS. history_core says the readable set
// excludes the in-flight write slot by construction, so a correctly-formed
// request can never address the slot being written.
// `a_history_no_safe_collision` is that sentence as a property, and it is what
// licenses `no_rw_check` on every M20K in the subsystem — without it the design
// would be asserting a read-during-write behaviour that the memory does not
// define.
//
// `a_history_all_antennas_answer` is the corner turn's own property: when a
// response is formed, EVERY antenna's bank produced a word for it. A vector
// missing one antenna is exactly the failure SPEC 7.4 exists to prevent, and it
// is invisible in the output values.
//
// ONE CROSS-DOMAIN OBSERVATION, DELIBERATE AND SIMULATION-ONLY.
// `a_history_publication_fresh` compares the write domain's frame counter
// against the published copy this domain works from. That is a testbench-style
// probe rather than hardware, and it is here rather than in the C++ test because
// it is the assumption history_core's readable bound is SIZED against: the bound
// absorbs exactly one frame of publication lag, and the margin comes from a frame
// being far longer than a handshake round trip. A future configuration with a
// very short frame, or a very slow read clock, would break it — and would break
// it as unexplained data corruption at maximum frame offset, which is the least
// diagnosable failure this block has. Named, it fails in one line.
//
// The simulator this project uses, at 5.020, accepts no `##` cycle-delay
// sequences, so every temporal property here is written with `$past` and an
// implication. All ports are `input wire`: a checker observes and never drives.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module history_rd_assertions #(
    parameter int unsigned N_ANT  = 2,
    parameter int unsigned LANES  = 1,
    parameter int unsigned SLOT_W = 2
) (
    input wire              clk,
    input wire              rst_n,

    input wire              req_fire,
    input wire [SLOT_W-1:0] req_slot,
    input wire [SLOT_W-1:0] write_slot,
    input wire              req_oor,
    input wire              force_unsafe,

    input wire [31:0]       frames_done_pub,
    // From the write domain. See the header: a simulation-only probe.
    input wire [31:0]       frames_done_core,

    input wire [LANES-1:0]  lane_en,
    input wire              r1_v,
    input wire              out_v,
    input wire              out_fifo_ready,
    input wire [N_ANT-1:0]  bank_dvalid
);

`ifndef SYNTHESIS

  always_ff @(posedge clk) begin
    if (rst_n) begin
      // Outside fault injection, an in-range request never addresses the slot
      // the writer is filling.
      a_history_no_safe_collision :
        assert (!(req_fire && !force_unsafe && !req_oor) ||
                (req_slot != write_slot))
        else $error("history: an in-range request addressed the in-flight write slot %0d",
                    write_slot);

      // The read half of SPEC 7.3's no-broadcast prohibition: at most one lane's
      // banks may be enabled, which is impossible if one enable drives them all.
      a_history_lane_onehot0 :
        assert ($countones(lane_en) <= 1)
        else $error("history: %0d lanes enabled at once; the read enable is not per-lane",
                    $countones(lane_en));

      // A read enable exists exactly when the pipeline says a request is in
      // flight — no enable without a request, no request without an enable.
      a_history_lane_en_tracks_pipe :
        assert (r1_v == (|lane_en))
        else $error("history: read enable %b disagrees with the request pipeline valid %0b",
                    lane_en, r1_v);

      // The corner turn's own property; see the header.
      a_history_all_antennas_answer :
        assert (!out_v || (bank_dvalid == {N_ANT{1'b1}}))
        else $error("history: a response was formed with only %0d of %0d antennas answering",
                    $countones(bank_dvalid), N_ANT);

      // The credit reservation in front of the output FIFO means a push can
      // never be refused. SPEC 14 "FIFO overflow".
      a_history_out_never_blocked :
        assert (!out_v || out_fifo_ready)
        else $error("history: the output FIFO refused a response — the credit reservation is over-committed");

      // `frames_done_pub > frames_done_core` can only mean one thing: a depth
      // change has just reset the write domain's counter and this domain is
      // still holding the pre-change publication. That transient is the design
      // working as specified — the history is discarded and republished — not a
      // staleness defect, so it is excluded rather than papered over with a
      // settling window whose length would be one more thing to keep true.
      a_history_publication_fresh :
        assert ((frames_done_pub > frames_done_core) ||
                ((frames_done_core - frames_done_pub) <= 32'd1))
        else $error("history: the published frame pointer is %0d frames behind the write domain; the readable bound absorbs one",
                    frames_done_core - frames_done_pub);
    end
  end

  // Both branches of the range check must be exercised, or the error counter is
  // never proved reachable; and the collision counter is unreachable altogether
  // without fault injection, which is why its cover names that condition.
  c_history_request_out_of_range : cover property (
      @(posedge clk) disable iff (!rst_n) req_fire && req_oor);
  c_history_request_in_range : cover property (
      @(posedge clk) disable iff (!rst_n) req_fire && !req_oor);
  c_history_forced_collision : cover property (
      @(posedge clk) disable iff (!rst_n)
      req_fire && force_unsafe && (req_slot == write_slot));

`endif

endmodule : history_rd_assertions

`default_nettype wire
