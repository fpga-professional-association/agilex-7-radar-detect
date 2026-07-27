// -----------------------------------------------------------------------------
// telemetry_regs -- SPEC 8 telemetry_clk-domain aggregate counters (issue #19).
//
// This is the register-plane face of a set of counters that live in
// telemetry_clk (SPEC 8: 200 MHz nominal). The counters themselves count in
// telemetry_clk; the register interface is in cfg_clk; a snapshot latches every
// counter into a shadow at one telemetry_clk edge, and a cdc_handshake carries
// the whole shadow bundle across into cfg_clk as ONE consistent snapshot.
//
// Design point, in one paragraph: the alternative was to synchronise every
// running counter with cdc_sync2 and let software read them live, but two reads
// of a 32-bit register in cfg_clk cannot land on the same telemetry_clk edge.
// The register plane never reads a running counter here for the same reason it
// never does at 0x7000 (telemetry_block.sv comment): a 64-bit counter read
// through a 32-bit plane costs two accesses, and a running counter's low word
// can wrap between them, reporting a number that never existed. The whole
// bundle crosses at once so the fields are coherent with each other.
//
// Crossing mechanism: cfg pulses SNAPSHOT_REQ, which crosses to tel-clk via
// cdc_pulse. On that pulse the tel-side latches every counter into tel_bundle_q
// and toggles tel_done_tog_q. The cfg side observes the toggle through
// cdc_sync2 and, on the observed edge, samples tel_bundle_q (which is quiet
// between snapshots by construction: tel_bundle_q updates only on the snapshot
// pulse, and the next pulse waits for the cfg-side to release the handshake).
// The many-bit crossing is safe because the source registers are stable across
// the sync window.
//
// Reset (SPEC 23): counters and the shadow are control state and reset in full.
// -----------------------------------------------------------------------------

`default_nettype none

module telemetry_regs
  import reg_if_pkg::*;
  import regmap_pkg::*;
#(
    parameter int unsigned IDX_W    = REGMAP_WINDOW_W - 2,

    // Elaborated telemetry_clk to cfg_clk period ratio, reported through
    // TELE_GEOMETRY. The build system passes the config's clock periods here.
    parameter int unsigned RATIO_NUM = 1,
    parameter int unsigned RATIO_DEN = 1
) (
    // ---- cfg_clk domain: register interface ----
    input  wire                                     cfg_clk,
    input  wire                                     cfg_rst_n,

    input  wire                                     sel,
    input  wire                                     write_enable,
    input  wire                                     read_enable,
    input  wire [IDX_W-1:0]                         index,
    input  wire [REG_DATA_W-1:0]                    write_data,
    input  wire [REG_STRB_W-1:0]                    byte_enable,

    output wire [REG_DATA_W-1:0]                    read_data,
    output wire                                     ready,
    output wire                                     error,

    output wire [REGMAP_TELEMETRY_N_REGS*32-1:0]    csr,
    output wire [REGMAP_TELEMETRY_N_REGS*32-1:0]    pulse,

    // ---- telemetry_clk domain: event inputs ----
    // Every input is a single-cycle level in telemetry_clk. Aggregation into
    // 32-bit saturating counters happens here; the register plane reads the
    // shadow taken from those counters at the last SNAPSHOT.
    input  wire                                     tel_clk,
    input  wire                                     tel_rst_n,

    input  wire                                     ev_detection,       // CFAR detection
    input  wire                                     ev_packet_delivery, // packet egress
    input  wire                                     ev_packet_drop,
    input  wire                                     ev_fault_inject,    // any injected pulse
    input  wire                                     ev_cdc_error,
    input  wire                                     ev_overflow,
    input  wire                                     ev_saturate,
    input  wire                                     ev_seq_error,
    input  wire                                     ev_mem_error,
    input  wire                                     ev_cfar_fault
);

  localparam int unsigned N = REGMAP_TELEMETRY_N_REGS;

  // ---------------------------------------------------------------------------
  // cfg_clk half: CSR file, control pulses.
  // ---------------------------------------------------------------------------
  wire [N*32-1:0] csr_w;
  wire [N*32-1:0] pulse_w;

  wire [31:0] ctrl_word  = csr_w  [REGMAP_TELEMETRY_TELE_CTRL_INDEX * 32 +: 32];
  wire [31:0] ctrl_pulse = pulse_w[REGMAP_TELEMETRY_TELE_CTRL_INDEX * 32 +: 32];

  wire cfg_enable_bit = ctrl_word [REGMAP_TELEMETRY_TELE_CTRL_ENABLE_LSB];
  wire snapshot_req   = ctrl_pulse[REGMAP_TELEMETRY_TELE_CTRL_SNAPSHOT_LSB];
  wire clear_req      = ctrl_pulse[REGMAP_TELEMETRY_TELE_CTRL_CLEAR_LSB];
  wire sticky_clear   = ctrl_pulse[REGMAP_TELEMETRY_TELE_CTRL_STICKY_CLEAR_LSB];

  // ---------------------------------------------------------------------------
  // cfg_clk -> telemetry_clk one-bit crossings.
  // ---------------------------------------------------------------------------
  wire tel_enable_bit;
  cdc_sync2 #(.WIDTH(1), .RST_VALUE(1'b1)) u_sync_en (
      .clk (tel_clk),
      .rst_n (tel_rst_n),
      .d ({cfg_enable_bit}),
      .q ({tel_enable_bit})
  );

  wire tel_clear_pulse;
  /* verilator lint_off UNUSEDSIGNAL */
  wire src_busy_clear_dummy, src_overrun_clear_dummy;
  /* verilator lint_on UNUSEDSIGNAL */
  cdc_pulse u_pulse_clear (
      .src_clk         (cfg_clk),
      .src_rst_n       (cfg_rst_n),
      .src_pulse       (clear_req),
      .src_busy        (src_busy_clear_dummy),
      .src_overrun     (src_overrun_clear_dummy),
      .src_sticky_clear(1'b0),
      .dst_clk         (tel_clk),
      .dst_rst_n       (tel_rst_n),
      .dst_pulse       (tel_clear_pulse)
  );

  // Snapshot request: cfg pulse -> tel pulse.
  wire tel_snap_pulse;
  /* verilator lint_off UNUSEDSIGNAL */
  wire src_overrun_snap_dummy;
  /* verilator lint_on UNUSEDSIGNAL */
  // "busy" is high while the snap crossing is in flight; we use it directly as
  // TELE_STATUS.BUSY.
  wire snap_pulse_busy;
  cdc_pulse u_pulse_snap (
      .src_clk         (cfg_clk),
      .src_rst_n       (cfg_rst_n),
      .src_pulse       (snapshot_req),
      .src_busy        (snap_pulse_busy),
      .src_overrun     (src_overrun_snap_dummy),
      .src_sticky_clear(1'b0),
      .dst_clk         (tel_clk),
      .dst_rst_n       (tel_rst_n),
      .dst_pulse       (tel_snap_pulse)
  );
  // src_busy_snap is used as snap_pulse_busy above.

  // ---------------------------------------------------------------------------
  // telemetry_clk half: 7 x 32-bit saturating counters and 8 sticky flags.
  // ---------------------------------------------------------------------------
  logic [31:0] cnt_event_q;
  logic [31:0] cnt_drop_q;
  logic [31:0] cnt_fault_q;
  logic [31:0] cnt_cdc_q;
  logic [31:0] cnt_ovf_q;
  logic [31:0] cnt_sat_q;
  logic [31:0] cnt_seq_q;
  logic [31:0] cnt_health_bits_q;  // sticky OR of per-category fault events

  // ev_event = detection + delivery
  wire ev_event_any = ev_detection | ev_packet_delivery;

  // Saturating add helper (add 1 unless already at max).
  function automatic logic [31:0] sat_add1(input logic [31:0] v);
    return (v == 32'hFFFF_FFFF) ? v : (v + 32'd1);
  endfunction

  always_ff @(posedge tel_clk) begin
    if (!tel_rst_n) begin
      cnt_event_q       <= 32'd0;
      cnt_drop_q        <= 32'd0;
      cnt_fault_q       <= 32'd0;
      cnt_cdc_q         <= 32'd0;
      cnt_ovf_q         <= 32'd0;
      cnt_sat_q         <= 32'd0;
      cnt_seq_q         <= 32'd0;
      cnt_health_bits_q <= 32'd0;
    end else if (tel_clear_pulse) begin
      cnt_event_q       <= 32'd0;
      cnt_drop_q        <= 32'd0;
      cnt_fault_q       <= 32'd0;
      cnt_cdc_q         <= 32'd0;
      cnt_ovf_q         <= 32'd0;
      cnt_sat_q         <= 32'd0;
      cnt_seq_q         <= 32'd0;
      cnt_health_bits_q <= 32'd0;
    end else begin
      if (tel_enable_bit) begin
        if (ev_event_any)       cnt_event_q <= sat_add1(cnt_event_q);
        if (ev_packet_drop)     cnt_drop_q  <= sat_add1(cnt_drop_q);
        if (ev_fault_inject)    cnt_fault_q <= sat_add1(cnt_fault_q);
        if (ev_cdc_error)       cnt_cdc_q   <= sat_add1(cnt_cdc_q);
        if (ev_overflow)        cnt_ovf_q   <= sat_add1(cnt_ovf_q);
        if (ev_saturate)        cnt_sat_q   <= sat_add1(cnt_sat_q);
        if (ev_seq_error)       cnt_seq_q   <= sat_add1(cnt_seq_q);
      end
      // Health bits: sticky, regardless of enable.
      cnt_health_bits_q[REGMAP_TELEMETRY_TELE_HEALTH_PACKET_DROP_LSB]    <=
          cnt_health_bits_q[REGMAP_TELEMETRY_TELE_HEALTH_PACKET_DROP_LSB]    | ev_packet_drop;
      cnt_health_bits_q[REGMAP_TELEMETRY_TELE_HEALTH_CDC_ERROR_LSB]     <=
          cnt_health_bits_q[REGMAP_TELEMETRY_TELE_HEALTH_CDC_ERROR_LSB]     | ev_cdc_error;
      cnt_health_bits_q[REGMAP_TELEMETRY_TELE_HEALTH_OVERFLOW_LSB]      <=
          cnt_health_bits_q[REGMAP_TELEMETRY_TELE_HEALTH_OVERFLOW_LSB]      | ev_overflow;
      cnt_health_bits_q[REGMAP_TELEMETRY_TELE_HEALTH_SATURATION_LSB]    <=
          cnt_health_bits_q[REGMAP_TELEMETRY_TELE_HEALTH_SATURATION_LSB]    | ev_saturate;
      cnt_health_bits_q[REGMAP_TELEMETRY_TELE_HEALTH_SEQ_ERROR_LSB]     <=
          cnt_health_bits_q[REGMAP_TELEMETRY_TELE_HEALTH_SEQ_ERROR_LSB]     | ev_seq_error;
      cnt_health_bits_q[REGMAP_TELEMETRY_TELE_HEALTH_FAULT_INJECTED_LSB]<=
          cnt_health_bits_q[REGMAP_TELEMETRY_TELE_HEALTH_FAULT_INJECTED_LSB]| ev_fault_inject;
      cnt_health_bits_q[REGMAP_TELEMETRY_TELE_HEALTH_MEM_ERROR_LSB]     <=
          cnt_health_bits_q[REGMAP_TELEMETRY_TELE_HEALTH_MEM_ERROR_LSB]     | ev_mem_error;
      cnt_health_bits_q[REGMAP_TELEMETRY_TELE_HEALTH_CFAR_FAULT_LSB]    <=
          cnt_health_bits_q[REGMAP_TELEMETRY_TELE_HEALTH_CFAR_FAULT_LSB]    | ev_cfar_fault;
    end
  end

  // ---------------------------------------------------------------------------
  // Bundle latched on snapshot pulse, then a toggle synchronizer signals
  // completion back to cfg_clk. Bundle is stable between snapshots because
  // tel_bundle_q updates ONLY on tel_snap_pulse and the cfg side does not issue
  // a new SNAPSHOT while snap_pulse_busy is set (cdc_pulse enforces).
  // ---------------------------------------------------------------------------
  localparam int unsigned BUNDLE_W = 8 * 32;

  logic [BUNDLE_W-1:0] tel_bundle_q;
  logic tel_done_tog_q;

  always_ff @(posedge tel_clk) begin
    if (!tel_rst_n) begin
      tel_bundle_q   <= '0;
      tel_done_tog_q <= 1'b0;
    end else if (tel_snap_pulse) begin
      tel_bundle_q   <= {
          cnt_health_bits_q,
          cnt_seq_q,
          cnt_sat_q,
          cnt_ovf_q,
          cnt_cdc_q,
          cnt_fault_q,
          cnt_drop_q,
          cnt_event_q
      };
      tel_done_tog_q <= ~tel_done_tog_q;
    end
  end

  wire cfg_done_tog;
  cdc_sync2 #(.WIDTH(1), .RST_VALUE(1'b0)) u_sync_done (
      .clk (cfg_clk),
      .rst_n (cfg_rst_n),
      .d ({tel_done_tog_q}),
      .q ({cfg_done_tog})
  );

  logic cfg_done_tog_q;
  always_ff @(posedge cfg_clk) begin
    if (!cfg_rst_n) cfg_done_tog_q <= 1'b0;
    else            cfg_done_tog_q <= cfg_done_tog;
  end
  wire snap_complete_pulse = cfg_done_tog ^ cfg_done_tog_q;

  // Latch the bundle in cfg_clk on the completion edge.
  logic [BUNDLE_W-1:0] cfg_bundle_q;
  logic snap_valid_q;
  logic snap_overrun_q;
  logic [7:0] snap_latency_cnt_q;
  logic [7:0] snap_latency_last_q;

  always_ff @(posedge cfg_clk) begin
    if (!cfg_rst_n) begin
      cfg_bundle_q       <= '0;
      snap_valid_q       <= 1'b0;
      snap_overrun_q     <= 1'b0;
      snap_latency_cnt_q <= 8'd0;
      snap_latency_last_q<= 8'd0;
    end else begin
      // Overrun: a snap request while the cdc_pulse is still busy is refused
      // by cdc_pulse itself; we record it here.
      if (snapshot_req && snap_pulse_busy) begin
        snap_overrun_q <= 1'b1;
      end
      if (snapshot_req && !snap_pulse_busy) begin
        snap_latency_cnt_q <= 8'd0;
      end else if (snap_pulse_busy && (snap_latency_cnt_q != 8'hFF)) begin
        snap_latency_cnt_q <= snap_latency_cnt_q + 8'd1;
      end
      if (snap_complete_pulse) begin
        cfg_bundle_q        <= tel_bundle_q;
        snap_valid_q        <= 1'b1;
        snap_latency_last_q <= snap_latency_cnt_q;
      end
      if (clear_req) begin
        snap_valid_q   <= 1'b0;
        snap_overrun_q <= 1'b0;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // hw_value / hw_set assembly for the CSR block.
  // ---------------------------------------------------------------------------
  wire [31:0] shadow_event   = cfg_bundle_q[0*32 +: 32];
  wire [31:0] shadow_drop    = cfg_bundle_q[1*32 +: 32];
  wire [31:0] shadow_fault   = cfg_bundle_q[2*32 +: 32];
  wire [31:0] shadow_cdc     = cfg_bundle_q[3*32 +: 32];
  wire [31:0] shadow_ovf     = cfg_bundle_q[4*32 +: 32];
  wire [31:0] shadow_sat     = cfg_bundle_q[5*32 +: 32];
  wire [31:0] shadow_seq     = cfg_bundle_q[6*32 +: 32];
  // shadow_health lives in tel_bundle_q as incoming_health below (used for
  // edge-detected health_pulse_q); the cfg_bundle_q's slot 7 mirrors it after
  // latching but is not read directly here.
  /* verilator lint_off UNUSEDSIGNAL */
  wire [31:0] shadow_health  = cfg_bundle_q[7*32 +: 32];
  /* verilator lint_on UNUSEDSIGNAL */

  logic [N*32-1:0] hw_value;
  logic [N*32-1:0] hw_set;

  // health_pending_q: cfg-side sticky store, ORed with the shadow at each new
  // snapshot. Written to the register file's W1C bits by hw_set as a ONE-CYCLE
  // PULSE the cycle the snapshot lands; software then W1C-clears the register
  // bit and the pending store, and both go quiet until the NEXT snapshot
  // reports a fresh event. That is the same pattern reg_block_fault uses at
  // 0x3000 for its own sticky bits.
  //
  // Note: we OR with the INCOMING tel_bundle_q's health slice, NOT with the
  // stale shadow_health from the currently-registered cfg_bundle_q. On the
  // snap_complete_pulse cfg-clk edge, cfg_bundle_q is being updated to
  // tel_bundle_q at the SAME edge, so shadow_health at that moment is the
  // PREVIOUS snapshot's health bits.
  wire [31:0] incoming_health = tel_bundle_q[7*32 +: 32];
  logic [31:0] health_last_q;    // last snapshot's health bitmap (for edge detection)
  logic [31:0] health_pulse_q;   // per-bit 1-cycle strobe, drives hw_set
  always_ff @(posedge cfg_clk) begin
    if (!cfg_rst_n) begin
      health_last_q  <= 32'd0;
      health_pulse_q <= 32'd0;
    end else if (sticky_clear || clear_req) begin
      health_last_q  <= 32'd0;
      health_pulse_q <= 32'd0;
    end else if (snap_complete_pulse) begin
      // Pulse only on RISING edges of a health bit -- the first snapshot in
      // which that bit was set. This makes hw_set a 1-cycle strobe rather
      // than a level, so software W1C actually clears the register bit.
      health_pulse_q <= incoming_health & ~health_last_q;
      health_last_q  <= incoming_health;
    end else begin
      health_pulse_q <= 32'd0;
    end
  end

  // For HEALTHY: any bit currently set in the register storage. We probe the
  // CSR's own storage via csr_w.
  wire [31:0] tele_health_csr = csr_w[REGMAP_TELEMETRY_TELE_HEALTH_INDEX * 32 +: 32];
  wire        healthy_bit     = (tele_health_csr == 32'd0);

  always_comb begin
    hw_value = '0;
    hw_set   = '0;

    // TELE_STATUS
    hw_value[REGMAP_TELEMETRY_TELE_STATUS_INDEX*32
             + REGMAP_TELEMETRY_TELE_STATUS_SNAP_VALID_LSB] = snap_valid_q;
    hw_value[REGMAP_TELEMETRY_TELE_STATUS_INDEX*32
             + REGMAP_TELEMETRY_TELE_STATUS_BUSY_LSB]       = snap_pulse_busy;
    hw_set  [REGMAP_TELEMETRY_TELE_STATUS_INDEX*32
             + REGMAP_TELEMETRY_TELE_STATUS_OVERRUN_LSB]    = snap_overrun_q;
    hw_value[REGMAP_TELEMETRY_TELE_STATUS_INDEX*32
             + REGMAP_TELEMETRY_TELE_STATUS_HEALTHY_LSB]    = healthy_bit;

    // Counters (shadow values)
    hw_value[REGMAP_TELEMETRY_TELE_EVENT_RATE_INDEX*32   +: 32] = shadow_event;
    hw_value[REGMAP_TELEMETRY_TELE_PACKET_DROP_INDEX*32  +: 32] = shadow_drop;
    hw_value[REGMAP_TELEMETRY_TELE_FAULT_COUNT_INDEX*32  +: 32] = shadow_fault;
    hw_value[REGMAP_TELEMETRY_TELE_CDC_ERROR_INDEX*32    +: 32] = shadow_cdc;
    hw_value[REGMAP_TELEMETRY_TELE_OVERFLOW_INDEX*32     +: 32] = shadow_ovf;
    hw_value[REGMAP_TELEMETRY_TELE_SATURATE_INDEX*32     +: 32] = shadow_sat;
    hw_value[REGMAP_TELEMETRY_TELE_SEQ_ERRORS_INDEX*32   +: 32] = shadow_seq;

    // TELE_HEALTH W1C: hw_set drives per-bit set requests. The register file's
    // W1C engine stores them and lets software clear by writing 1.
    hw_set[REGMAP_TELEMETRY_TELE_HEALTH_INDEX*32
           + REGMAP_TELEMETRY_TELE_HEALTH_PACKET_DROP_LSB]     = health_pulse_q[REGMAP_TELEMETRY_TELE_HEALTH_PACKET_DROP_LSB];
    hw_set[REGMAP_TELEMETRY_TELE_HEALTH_INDEX*32
           + REGMAP_TELEMETRY_TELE_HEALTH_CDC_ERROR_LSB]      = health_pulse_q[REGMAP_TELEMETRY_TELE_HEALTH_CDC_ERROR_LSB];
    hw_set[REGMAP_TELEMETRY_TELE_HEALTH_INDEX*32
           + REGMAP_TELEMETRY_TELE_HEALTH_OVERFLOW_LSB]       = health_pulse_q[REGMAP_TELEMETRY_TELE_HEALTH_OVERFLOW_LSB];
    hw_set[REGMAP_TELEMETRY_TELE_HEALTH_INDEX*32
           + REGMAP_TELEMETRY_TELE_HEALTH_SATURATION_LSB]     = health_pulse_q[REGMAP_TELEMETRY_TELE_HEALTH_SATURATION_LSB];
    hw_set[REGMAP_TELEMETRY_TELE_HEALTH_INDEX*32
           + REGMAP_TELEMETRY_TELE_HEALTH_SEQ_ERROR_LSB]      = health_pulse_q[REGMAP_TELEMETRY_TELE_HEALTH_SEQ_ERROR_LSB];
    hw_set[REGMAP_TELEMETRY_TELE_HEALTH_INDEX*32
           + REGMAP_TELEMETRY_TELE_HEALTH_FAULT_INJECTED_LSB] = health_pulse_q[REGMAP_TELEMETRY_TELE_HEALTH_FAULT_INJECTED_LSB];
    hw_set[REGMAP_TELEMETRY_TELE_HEALTH_INDEX*32
           + REGMAP_TELEMETRY_TELE_HEALTH_MEM_ERROR_LSB]      = health_pulse_q[REGMAP_TELEMETRY_TELE_HEALTH_MEM_ERROR_LSB];
    hw_set[REGMAP_TELEMETRY_TELE_HEALTH_INDEX*32
           + REGMAP_TELEMETRY_TELE_HEALTH_CFAR_FAULT_LSB]     = health_pulse_q[REGMAP_TELEMETRY_TELE_HEALTH_CFAR_FAULT_LSB];

    // TELE_GEOMETRY
    hw_value[REGMAP_TELEMETRY_TELE_GEOMETRY_INDEX*32
             + REGMAP_TELEMETRY_TELE_GEOMETRY_RATIO_NUM_LSB
             +: REGMAP_TELEMETRY_TELE_GEOMETRY_RATIO_NUM_WIDTH] =
        REGMAP_TELEMETRY_TELE_GEOMETRY_RATIO_NUM_WIDTH'(RATIO_NUM);
    hw_value[REGMAP_TELEMETRY_TELE_GEOMETRY_INDEX*32
             + REGMAP_TELEMETRY_TELE_GEOMETRY_RATIO_DEN_LSB
             +: REGMAP_TELEMETRY_TELE_GEOMETRY_RATIO_DEN_WIDTH] =
        REGMAP_TELEMETRY_TELE_GEOMETRY_RATIO_DEN_WIDTH'(RATIO_DEN);
    hw_value[REGMAP_TELEMETRY_TELE_GEOMETRY_INDEX*32
             + REGMAP_TELEMETRY_TELE_GEOMETRY_SNAPSHOT_LATENCY_LSB
             +: REGMAP_TELEMETRY_TELE_GEOMETRY_SNAPSHOT_LATENCY_WIDTH] =
        REGMAP_TELEMETRY_TELE_GEOMETRY_SNAPSHOT_LATENCY_WIDTH'(snap_latency_last_q);
  end

  assign csr   = csr_w;
  assign pulse = pulse_w;

  reg_csr_block #(
      .N_REGS     (N),
      .IDX_W      (IDX_W),
      .RESET_VAL  (REGMAP_TELEMETRY_RESET),
      .WMASK      (REGMAP_TELEMETRY_WMASK),
      .W1C_MASK   (REGMAP_TELEMETRY_W1CMASK),
      .PULSE_MASK (REGMAP_TELEMETRY_PULSEMASK),
      .HW_MASK    (REGMAP_TELEMETRY_HWMASK)
  ) u_csr (
      .clk          (cfg_clk),
      .rst_n        (cfg_rst_n),
      .sel          (sel),
      .write_enable (write_enable),
      .read_enable  (read_enable),
      .index        (index),
      .write_data   (write_data),
      .byte_enable  (byte_enable),
      .read_data    (read_data),
      .ready        (ready),
      .error        (error),
      .hw_value     (hw_value),
      .hw_set       (hw_set),
      .csr          (csr_w),
      .pulse        (pulse_w)
  );

endmodule : telemetry_regs

`default_nettype wire
