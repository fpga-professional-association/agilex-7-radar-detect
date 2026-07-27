// -----------------------------------------------------------------------------
// cfg_bundle_cdc — republish a quasi-static configuration BUNDLE across a clock
// domain boundary as one payload (SPEC.md 8, issue #17).
//
// Why this module exists
// ---------------------
// Every processing block in rtl/ takes its configuration as a set of level
// inputs in its OWN clock domain — `cfar_core`'s eight `cfg_*` ports in
// core_clk, `history_core`'s depth and enables in core_clk, `align_net`'s in
// history_clk. The register plane (rtl/control/, issue #7) is cfg_clk end to
// end. Something has to move the levels, and SPEC 8 is explicit about what that
// something may not be:
//
//     "Do not synchronize a multibit bus by independently synchronizing every
//      bit."
//
// A per-bit `cdc_sync2` on `{guard_lead, ref_lead, alpha}` is exactly the
// prohibited construction, and it is not a theoretical objection: a write that
// changes `ref_lead` from 7 to 8 changes four bits at once, and independent
// synchronisers can land any subset of them on any cycle. The detector would
// then run one frame against a reference count that was never programmed. The
// same argument applies to `history_core`'s `cfg_depth` and to `covar_engine`'s
// `cfg_window_len`.
//
// The mechanism is the one issue #15 chose for the same reason (ARCHITECTURE.md
// §5, "The publication bundle is a handshake and not a Gray pointer"): the whole
// bundle crosses as ONE `cdc_handshake` payload, which never passes through a
// synchroniser at all. The destination therefore sees a set of values that
// existed together in the source domain on one cycle, which is the property a
// per-signal crossing cannot provide however many stages it has.
//
// Republication, and why it is level-driven rather than write-driven
// ------------------------------------------------------------------
// The register plane offers no "the software wrote something" strobe that covers
// every field — `reg_csr_block` exposes storage, not writes. So this module
// watches the bundle itself: whenever the registered source value differs from
// the value last SENT, and no transfer is in flight, it launches one.
//
// Consequences, all of them wanted:
//
//   * a change of any width, in any number of fields, at any time, produces
//     exactly one transfer of the whole bundle;
//   * a burst of changes faster than the crossing produces FEWER transfers, not
//     a queue — the destination lands on the latest value and never on an
//     intermediate one it must then be walked off. Software writing six CFAR
//     registers back to back gets one or two publications, and the last one is
//     always the final state;
//   * the destination is CORRECT AT REST rather than correct-if-you-saw-the-
//     event: `d_data` is a register holding the last published bundle, so a
//     block that comes out of reset late reads the current configuration on its
//     first cycle rather than a stale one.
//
// `dst_valid` is exported for a consumer that wants the edge (a re-latch, a
// counter) but no consumer is required to use it, which is what makes the module
// safe to drop in front of blocks that were written expecting plain wires.
//
// What this module is NOT for
// ---------------------------
// One-cycle strobes. `cfg_counter_clear`, `flush`, `status_clear` and their kind
// are EVENTS, not levels: a level crossing would either lose them or repeat
// them. They cross on `rtl/cdc/cdc_pulse.sv`, one instance each, exactly as the
// coefficient plane's swap request does.
//
// Bulk data. A coefficient or a beam weight is not configuration in this sense;
// it is a stream of writes with its own addressing and its own accept/reject
// rules, and `rtl/pfb/coeff_bank.sv` owns that crossing.
//
// Latency
// -------
// One four-phase round trip, so tens of nanoseconds at the SPEC 8 cfg_clk of
// 100 MHz. Nothing in the design cares: every field crossing here is latched by
// its consumer at a frame or window boundary anyway, and a configuration write
// that took effect on a precise cycle would be a race the register plane has no
// way to express.
//
// Reset
// -----
// `d_data` resets to RESET_VALUE, not to zero, because zero is not a safe
// configuration for every bundle — a CFAR bundle whose `alpha` is zero detects
// on every bin. The instantiator states the safe value; see cdc_sync2's
// `RST_VALUE` parameter, which exists for the same reason and is documented the
// same way.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

// (* cdc_primitive *) — this module owns a source/destination clock seam. It is
// tagged as a COMPOSITE, the same arrangement rtl/cdc/stream_cdc.sv uses over
// `async_fifo`: scripts/cdc_inventory.py lists this crossing and the real
// `cdc_handshake` nested under it, so the report shows both the design-level
// crossing and the primitive that implements it.
(* cdc_primitive = "cfg_bundle", cdc_src_clk = "src_clk", cdc_dst_clk = "dst_clk", cdc_width = "WIDTH", cdc_stages = "SYNC_STAGES" *)
module cfg_bundle_cdc #(
    // Bundle width. Any width: the payload does not pass through a synchroniser.
    parameter int unsigned WIDTH = 8,

    // Flip-flops per synchronizer chain inside the handshake.
    parameter int unsigned SYNC_STAGES = 2,

    // Value `d_data` holds while `dst_rst_n` is low and until the first
    // publication lands. See the header: the SAFE configuration, not zero.
    parameter logic [WIDTH-1:0] RESET_VALUE = '0,

    // Refresh period, as the width of a free-running source-domain counter: the
    // bundle is republished unconditionally every 2**REFRESH_W source cycles
    // even when nothing changed. See the header, "Refresh".
    parameter int unsigned REFRESH_W = 8
) (
    // ---- source domain (the register plane; cfg_clk) ----
    input  wire              src_clk,
    input  wire              src_rst_n,
    input  wire [WIDTH-1:0]  src_data,

    // High while a publication is in flight. Exported as status only; nothing
    // has to wait for it, because a change arriving during a transfer is simply
    // picked up by the next one.
    output wire              src_busy,

    // ---- destination domain (the block's own clock) ----
    input  wire              dst_clk,
    input  wire              dst_rst_n,

    // The published bundle, held between publications.
    output wire [WIDTH-1:0]  dst_data,
    // One-cycle strobe when `dst_data` changed. Optional for the consumer.
    output wire              dst_valid
);

  // ---------------------------------------------------------------------------
  // Source side: register, compare, launch
  //
  // `src_q` exists so the comparison is register-to-register rather than from
  // whatever combinational cone the register plane presents; `sent_q` is the
  // value the destination is known to hold. The launch condition is exactly
  // "the destination is out of date and the wire is free".
  // ---------------------------------------------------------------------------
  logic [WIDTH-1:0]     src_q;
  logic [WIDTH-1:0]     sent_q;
  logic                 primed_q;  // one publication has been launched
  logic [REFRESH_W-1:0] tick_q;

  wire hs_ready;
  wire refresh = (tick_q == '0);
  wire stale   = !primed_q || (src_q != sent_q) || refresh;
  wire launch  = stale && hs_ready;

  always_ff @(posedge src_clk) begin
    if (!src_rst_n) begin
      src_q    <= RESET_VALUE;
      sent_q   <= RESET_VALUE;
      primed_q <= 1'b0;
      tick_q   <= '0;
    end else begin
      src_q  <= src_data;
      tick_q <= tick_q + REFRESH_W'(1);
      if (launch) begin
        sent_q   <= src_q;
        primed_q <= 1'b1;
      end
    end
  end

  // `primed_q` forces one publication after reset even when the source already
  // equals RESET_VALUE. Without it a design whose configuration is never written
  // would leave `dst_data` at its reset value by accident rather than by
  // agreement, and the two would silently disagree the first time RESET_VALUE
  // and the register plane's own reset value diverged.
  //
  // REFRESH — why a change detector alone is not enough
  // ---------------------------------------------------
  // The two domains have INDEPENDENT resets, and the register plane's is the one
  // that stays up: a datapath reset (SPEC 9's per-block soft reset, or a test
  // restarting the pipeline without losing its programming) returns `d_data` to
  // RESET_VALUE while the source still believes the destination holds the
  // programmed bundle. With change detection alone the two would then disagree
  // FOREVER, and the failure would look like a configuration that was never
  // written rather than one that was lost.
  //
  // So the bundle is republished unconditionally every `2**REFRESH_W` source
  // cycles. At the SPEC 8 cfg_clk of 100 MHz and the default width that is once
  // every 2.6 microseconds — far below any rate at which configuration changes
  // matter, and the only cost is a counter and a handshake that would otherwise
  // be idle. Convergence after a destination reset is therefore bounded and
  // stated rather than assumed.

  wire            d_valid_i;
  wire [WIDTH-1:0] d_data_i;

  cdc_handshake #(
      .WIDTH       (WIDTH),
      .SYNC_STAGES (SYNC_STAGES)
  ) u_hs (
      .src_clk   (src_clk),
      .src_rst_n (src_rst_n),
      .s_valid   (launch),
      .s_ready   (hs_ready),
      .s_data    (src_q),
      .s_busy    (src_busy),
      .dst_clk   (dst_clk),
      .dst_rst_n (dst_rst_n),
      .d_valid   (d_valid_i),
      .d_data    (d_data_i)
  );

  // ---------------------------------------------------------------------------
  // Destination side: hold
  //
  // `cdc_handshake` already holds `d_data` between strobes, so this register is
  // not strictly required for the value. It is here for the reset value: the
  // handshake's own output resets to zero, and zero is not a safe configuration
  // (header). One register buys a stated safe state and costs one cycle nobody
  // measures.
  // ---------------------------------------------------------------------------
  logic [WIDTH-1:0] dst_q;
  logic             dst_v_q;

  always_ff @(posedge dst_clk) begin
    if (!dst_rst_n) begin
      dst_q   <= RESET_VALUE;
      dst_v_q <= 1'b0;
    end else begin
      dst_v_q <= d_valid_i;
      if (d_valid_i) dst_q <= d_data_i;
    end
  end

  assign dst_data  = dst_q;
  assign dst_valid = dst_v_q;

endmodule : cfg_bundle_cdc

`default_nettype wire
