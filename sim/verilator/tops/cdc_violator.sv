// -----------------------------------------------------------------------------
// cdc_violator — a deliberately broken crossing, for the SPEC 14 negative test.
//
// THIS RTL IS KNOWINGLY WRONG. It exists so that sim/tests/test_cdc_assertions.cpp
// can prove that the CDC assertion set in sim/assertions/ actually fires, rather
// than merely never failing. It appears in sim/verilator/files_cdc_violator.f and
// in no other file list, so it can never reach the design build or a Quartus
// source list. Same arrangement, for the same reason, as
// sim/verilator/tops/stream_violator.sv (issue #5).
//
// `viol_mode` selects the defect. Mode 0 is correct in every respect and must
// produce no assertion at all; a failure there means the checker is reporting
// something the protocol permits, which is as serious a defect as a checker that
// never fires.
//
//   0  clean            Gray-coded pointer, four-phase handshake, all correct.
//   1  gray_is_binary   the pointer increments in BINARY and is presented as if
//                       Gray-coded. 0 -> 1 is still a one-bit step, so the first
//                       increment passes; 1 -> 2 (01 -> 10) is two bits and
//                       a_gray_one_bit fires. This is the exact mistake the
//                       assertion exists to catch — an asynchronous FIFO whose
//                       pointer synchronizer carries a binary counter works
//                       perfectly in simulation until two bits land in different
//                       destination cycles on silicon.
//   2  data_mutates     the handshake payload is incremented every cycle while
//                       the request is up. a_hs_data_stable fires. The
//                       destination would sample an arbitrary point in that
//                       window and get a value the source never intended to
//                       send.
//   3  req_withdrawn    the request is dropped after a fixed delay whether or
//                       not it was acknowledged. a_hs_req_held fires.
//   4  spurious_ack     an acknowledge is generated with no request outstanding.
//                       a_hs_ack_after_req fires.
//
// ONE CLOCK, NOT TWO. The properties under test are single-domain properties by
// construction: cdc_sva.svh checks the Gray pointer in the domain that owns it
// and the handshake in the source domain against the *synchronized* acknowledge,
// precisely so that no checker ever samples two clock domains at once. Giving
// the violator a second clock would add sampling noise to a test whose whole
// purpose is an exact, named, reproducible failure. The multi-domain behaviour
// is covered by the positive tests on cdc_prims_top.
// -----------------------------------------------------------------------------

`default_nettype none

module cdc_violator #(
    // Pointer width. 4 bits is enough for the binary-versus-Gray divergence to
    // appear within three increments.
    parameter int unsigned PTR_W = 4,

    // Handshake payload width.
    parameter int unsigned WIDTH = 16,

    // Cycles from request to acknowledge in the built-in responder, and the
    // delay after which mode 3 withdraws its request. The withdrawal must happen
    // strictly before the acknowledge or the mode is not a violation.
    parameter int unsigned ACK_DELAY  = 3,
    parameter int unsigned DROP_DELAY = 2
) (
    input  wire              clk,
    input  wire              rst_n,

    input  wire [2:0]        viol_mode,

    // Step the pointer this cycle.
    input  wire              advance,

    // Start a handshake transfer when idle.
    input  wire              hs_start,

    // The pointer, claimed to be Gray-coded. Watched by a bound cdc_gray_checker.
    output wire [PTR_W-1:0]  ptr,

    // The four-phase handshake, watched by a cdc_handshake_checker in the top.
    output wire              req,
    output wire              ack,
    output wire [WIDTH-1:0]  data
);

  // Mode 0 (clean) has no constant: it is the absence of every defect below, so
  // no expression tests for it, and an unread localparam is a lint warning.
  localparam logic [2:0] MODE_GRAY_IS_BINARY = 3'd1;
  localparam logic [2:0] MODE_DATA_MUTATES   = 3'd2;
  localparam logic [2:0] MODE_REQ_WITHDRAWN  = 3'd3;
  localparam logic [2:0] MODE_SPURIOUS_ACK   = 3'd4;

  // ---------------------------------------------------------------------------
  // The pointer.
  // ---------------------------------------------------------------------------
  logic [PTR_W-1:0] bin_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      bin_q <= PTR_W'(0);
    end else if (advance) begin
      bin_q <= bin_q + PTR_W'(1);
    end
  end

  // Mode 1 skips the encoding. Everything else presents the correct Gray value.
  assign ptr = (viol_mode == MODE_GRAY_IS_BINARY)
             ? bin_q
             : PTR_W'(cdc_pkg::cdc_bin2gray(cdc_pkg::uint_t'(PTR_W),
                                            cdc_pkg::cdc_word_t'(bin_q)));

  // ---------------------------------------------------------------------------
  // The handshake source.
  // ---------------------------------------------------------------------------
  logic             req_q;
  logic [WIDTH-1:0] data_q;
  logic [7:0]       age_q;     // cycles since the request went up
  logic [WIDTH-1:0] serial_q;  // payload generator, so successive values differ

  wire hs_idle   = !req_q && !ack;
  wire hs_launch = hs_idle && hs_start;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      req_q    <= 1'b0;
      age_q    <= 8'd0;
      serial_q <= WIDTH'(1);
    end else begin
      if (hs_launch) begin
        req_q    <= 1'b1;
        age_q    <= 8'd0;
        serial_q <= serial_q + WIDTH'(1);
      end else if (req_q) begin
        age_q <= age_q + 8'd1;
        // Correct behaviour: drop the request only once it has been answered.
        if (ack) begin
          req_q <= 1'b0;
        end
        // Mode 3: drop it early, answered or not.
        if ((viol_mode == MODE_REQ_WITHDRAWN) && (age_q >= 8'(DROP_DELAY))) begin
          req_q <= 1'b0;
        end
      end
    end
  end

  // Payload register. Loaded at launch, which is the correct behaviour; mode 2
  // additionally mutates it under an asserted request, which is the defect.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      data_q <= WIDTH'(0);
    end else if (hs_launch) begin
      data_q <= serial_q;
    end else if ((viol_mode == MODE_DATA_MUTATES) && req_q) begin
      data_q <= data_q + WIDTH'(1);
    end
  end

  // ---------------------------------------------------------------------------
  // The responder. Correct in every mode but 4: the acknowledge rises ACK_DELAY
  // cycles after the request and falls once the request has gone.
  // ---------------------------------------------------------------------------
  logic       ack_q;
  logic [7:0] free_q;   // free-running, drives the spurious acknowledge

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ack_q  <= 1'b0;
      free_q <= 8'd0;
    end else begin
      free_q <= free_q + 8'd1;

      if (viol_mode == MODE_SPURIOUS_ACK) begin
        // An acknowledge with nothing outstanding: high for eight cycles in
        // every sixteen, regardless of the request.
        ack_q <= free_q[3];
      end else if (!ack_q && req_q && (age_q >= 8'(ACK_DELAY))) begin
        ack_q <= 1'b1;
      end else if (ack_q && !req_q) begin
        ack_q <= 1'b0;
      end
    end
  end

  assign req  = req_q;
  assign ack  = ack_q;
  assign data = data_q;

endmodule : cdc_violator

`default_nettype wire
