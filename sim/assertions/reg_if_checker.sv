// -----------------------------------------------------------------------------
// reg_if_checker — SPEC 14 assertions for the SPEC 9 register interface (#7).
//
// Instantiated inside reg_fabric under `ifndef SYNTHESIS`, so the protocol is
// checked wherever the fabric is used, in the fast build, with no test-side
// wiring — the same arrangement rtl/stream/ uses for stream_protocol_checker.
//
// It watches BOTH sides on purpose:
//
//   master obligations   the request is stable until `ready` is observed, and
//                        no new request is presented while one is outstanding.
//                        These check the C++ register driver, not the RTL. A
//                        harness that violates the protocol it is testing for is
//                        otherwise invisible, and every one of its results is
//                        worthless.
//   fabric obligations   `ready` only ever answers an accepted request, exactly
//                        one cycle per request, never two cycles running;
//                        `error` and non-zero `read_data` only in a ready cycle;
//                        the response arrives within the watchdog bound, which
//                        is the machine-checked form of "the fabric never
//                        hangs".
//
// Tool constraints, measured (DECISIONS.md 2026-07-26, decision 3): the version
// of Verilator this project pins supports no `##` delay
// in sequences, so everything is written with implication and $past. Immediate
// assertions inside always_ff carry the bounded-latency check, because it needs
// a counter rather than a fixed delay.
// -----------------------------------------------------------------------------

`default_nettype none

module reg_if_checker
  import reg_if_pkg::*;
#(
    parameter int unsigned WATCHDOG_CYCLES = REG_WATCHDOG_CYCLES
) (
    input wire                    clk,
    input wire                    rst_n,
    input wire [REG_ADDR_W-1:0]   address,
    input wire [REG_DATA_W-1:0]   write_data,
    input wire [REG_STRB_W-1:0]   byte_enable,
    input wire                    write_enable,
    input wire                    read_enable,
    input wire [REG_DATA_W-1:0]   read_data,
    input wire                    ready,
    input wire                    error,
    // The fabric's own "a transaction is outstanding" state.
    input wire                    busy
);

`ifndef SYNTHESIS

  wire req = write_enable || read_enable;

  // ---- master obligations -------------------------------------------------

  // The request holds until it is answered. Everything the slave might sample
  // is covered, not just the address: a driver that changes byte_enable while
  // stalled writes the wrong bytes and would otherwise look correct.
  property p_request_stable;
    @(posedge clk) disable iff (!rst_n)
      (req && !ready) |=>
        $stable({address, write_data, byte_enable, write_enable, read_enable});
  endproperty
  a_request_stable : assert property (p_request_stable)
    else $error("reg_if: the request changed before ready was observed");

  // ---- fabric obligations -------------------------------------------------

  // ready answers an accepted request and nothing else.
  property p_ready_only_when_busy;
    @(posedge clk) disable iff (!rst_n) ready |-> busy;
  endproperty
  a_ready_only_when_busy : assert property (p_ready_only_when_busy)
    else $error("reg_if: ready asserted with no transaction outstanding");

  // Exactly one ready per request: the fabric returns to idle for at least one
  // cycle, so two consecutive ready cycles would mean a response was duplicated.
  property p_ready_single_cycle;
    @(posedge clk) disable iff (!rst_n) ready |=> !ready;
  endproperty
  a_ready_single_cycle : assert property (p_ready_single_cycle)
    else $error("reg_if: ready held for more than one cycle");

  // error and read_data are response-cycle signals only. Sampling them at any
  // other time must not be able to invent a failure or a value.
  property p_error_needs_ready;
    @(posedge clk) disable iff (!rst_n) error |-> ready;
  endproperty
  a_error_needs_ready : assert property (p_error_needs_ready)
    else $error("reg_if: error asserted outside a response cycle");

  property p_read_data_needs_ready;
    @(posedge clk) disable iff (!rst_n) (read_data != '0) |-> ready;
  endproperty
  a_read_data_needs_ready : assert property (p_read_data_needs_ready)
    else $error("reg_if: read_data non-zero outside a response cycle");

  // A response cycle answers a request that was actually presented.
  property p_ready_follows_request;
    @(posedge clk) disable iff (!rst_n) ready |-> $past(req);
  endproperty
  a_ready_follows_request : assert property (p_ready_follows_request)
    else $error("reg_if: ready with no request in the preceding cycle");

  // ---- bounded latency ----------------------------------------------------
  // The reason the interface cannot hang. A counter rather than a property,
  // because the bound is a parameter and Verilator 5.020 has no `##`.
  // A block's own response time, plus the watchdog, plus one cycle of margin for
  // the fabric's accept stage. Nothing correct can reach it.
  localparam int unsigned LIMIT = REG_ACCESS_LATENCY + WATCHDOG_CYCLES + 1;
  int unsigned outstanding_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      outstanding_q <= 0;
    end else begin
      if (busy && !ready) begin
        outstanding_q <= outstanding_q + 1;
      end else begin
        outstanding_q <= 0;
      end
      a_bounded_response : assert (outstanding_q <= LIMIT)
        else $error("reg_if: no response after %0d cycles (bound %0d)",
                    outstanding_q, LIMIT);
    end
  end

  // ---- covers (counted in the SPEC 12.1 coverage build) -------------------
  property p_cover_write;
    @(posedge clk) disable iff (!rst_n) ready && !error && $past(write_enable);
  endproperty
  c_write : cover property (p_cover_write);

  property p_cover_read;
    @(posedge clk) disable iff (!rst_n) ready && !error && $past(read_enable);
  endproperty
  c_read : cover property (p_cover_read);

  property p_cover_error;
    @(posedge clk) disable iff (!rst_n) ready && error;
  endproperty
  c_error : cover property (p_cover_error);

`endif  // SYNTHESIS

endmodule : reg_if_checker

`default_nettype wire
