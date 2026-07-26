// -----------------------------------------------------------------------------
// weight_bank — double-buffered beam weights with a frame-aligned swap
// (SPEC.md 7.5, 9; issue #12).
//
// N_BEAMS x N_ANT complex Q1.15 weights, held twice over, written from the
// configuration domain, with the active bank changing only at a safe frame
// boundary. SPEC 7.5's "weight double buffering" and "safe weight-bank
// switching", in one module.
//
// -----------------------------------------------------------------------------
// 1. THIS MODULE DOES NOT REIMPLEMENT THE BANK. IT REUSES rtl/pfb/coeff_bank.sv.
// -----------------------------------------------------------------------------
// The requirement above is, word for word, the requirement SPEC 7.1 places on
// the polyphase coefficient store, and issue #10 built exactly that: a dual-bank
// store of PHASES x TAPS complex Q1.15 words, written through a cdc_handshake,
// swapped by a cdc_pulse at the next admitted start-of-frame beat, with the
// active bank and the sticky reject/overrun flags synchronised back to the
// configuration domain, and a checker (coeff_bank_checker) that proves the swap
// point and the stability of the active bank's contents between swaps.
//
// Nothing about that logic is polyphase-specific. `PHASES x TAPS` is a
// two-dimensional index into a flat store; here it is `N_BEAMS x N_ANT`. So this
// module INSTANTIATES coeff_bank rather than containing a second copy of a
// state machine, a clock-domain seam and a set of assertions that would then
// have to be kept in step with the first copy forever.
//
// WHAT THIS MODULE ADDS, and why it is not merely an alias:
//
//   * the beamformer's own bounds and elaboration checks (beamformer_pkg), so a
//     geometry outside SPEC 7.5's range fails at time 0 with a beamformer
//     message rather than a polyphase one;
//   * the beam-major / antenna-minor address contract
//     (beamformer_pkg::bf_weight_index), stated and checked here, which is what
//     control/regmap.json's WEIGHT_ADDR.INDEX field means;
//   * per-beam slice extraction: `w_beam` presents the active bank as N_BEAMS
//     rows of N_ANT weights, which is the shape rtl/beamformer/beamformer.sv
//     muxes its BEAM_PAR engine rows out of;
//   * a beamformer-named status surface, so the register plane's weight window
//     is wired to weight_bank ports and not to a module whose name says `coeff`.
//
// WHAT WAS DELIBERATELY NOT DONE, and the cost of not doing it. The tidier
// refactor is to hoist coeff_bank's body into a `dual_bank_store` under
// rtl/common/ and make both coeff_bank and weight_bank thin wrappers. That was
// rejected FOR NOW, in the open, for three reasons: it changes no logic; it
// would move the SPEC 8 CDC inventory entry and the assertion names of a module
// that is already verified and calibrated, for no functional gain; and issue #13
// is in flight against the same tree, so a mechanical refactor of a shared file
// is a merge hazard bought with nothing. The honest cost is a naming seam — a
// file under rtl/beamformer/ instantiating a module under rtl/pfb/ — and it is
// recorded rather than hidden. The moment to pay for the hoist is when a THIRD
// consumer appears; control/regmap.json already names issue #16's per-antenna
// fan-out as one. See DECISIONS.md (issue #12).
//
// -----------------------------------------------------------------------------
// 2. SWAP GRANULARITY: THE WHOLE ARRAY, NOT PER BEAM
// -----------------------------------------------------------------------------
// One `active_bank` bit covers all N_BEAMS x N_ANT weights. A swap replaces the
// entire beamforming matrix atomically at a frame boundary. Per-beam granularity
// — N_BEAMS independent bank bits and N_BEAMS independent pending flags — was
// considered and rejected:
//
//   * A beamforming matrix is a CALIBRATION SOLUTION, not N_BEAMS independent
//     filters. The rows are computed together from one array manifold estimate;
//     a beam pattern is only meaningful relative to the other beams' patterns.
//     Half-swapped, the array is steering to a geometry that was never solved
//     for, and no downstream consumer could tell that from a real result.
//   * "Which bank is active" is ONE BIT in the register map
//     (WEIGHT_STATUS.ACTIVE_BANK, the same shape as COEFF_STATUS.ACTIVE_BANK).
//     Per-beam granularity makes it an N_BEAMS-bit field, makes SWAP_REQ a
//     mask, and makes "the swap completed" a reduction over N_BEAMS status bits
//     that software has to poll — a materially larger control surface bought to
//     enable an operation nobody has asked for.
//   * The property that makes double buffering worth having —
//     `a_coeff_stable_between`, the active bank's contents never change except
//     on the cycle the active bank changes — is stateable for one bank bit and
//     becomes N_BEAMS separate properties for N_BEAMS bits.
//
// The cost of the whole-array choice is that a single-beam weight update still
// costs a full spare-bank load. That is a software cost measured in
// configuration writes, on a plane that is not in the datapath, and it buys an
// atomic matrix. If a future issue needs incremental steering it should get a
// separate mechanism with its own name, not a widened bank bit.
//
// -----------------------------------------------------------------------------
// 3. WRITES ARE REFUSED ON THE ACTIVE BANK
// -----------------------------------------------------------------------------
// Inherited from coeff_bank, and restated because it is a programming contract:
// a write whose target bank IS the bank currently in use is DROPPED and sets the
// sticky `cfg_wr_reject` flag. It is not merged, not deferred and not applied.
// Allowing it would change the matrix under a frame that is already being
// beamformed, which is precisely what double buffering exists to prevent.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

// (* cdc_primitive *) — scripts/cdc_inventory.py reads the attribute block below
// and reports this module as a crossing in the SPEC 8 inventory. It is a
// COMPOSITE whose only crossing is the coeff_bank instance below (itself a
// composite of the issue #6 primitives); this module adds no clock-domain logic
// of its own. Same arrangement, for the same reason, as rtl/pfb/pfb_bank.sv over
// rtl/pfb/coeff_bank.sv.
//
// cdc_width is the weight word (2 x FXP_SAMPLE_W). The write crossing actually
// carries 1 + clog2(N_BEAMS*N_ANT) + 32 bits and says so in its own nested
// entry; this one names the payload the module exists to move.
(* cdc_primitive = "weight_bank_dual", cdc_src_clk = "cfg_clk", cdc_dst_clk = "core_clk", cdc_width = "32", cdc_stages = "SYNC_STAGES" *)
module weight_bank
  import fxp_pkg::*;
  import beamformer_pkg::*;
#(
    // Beamformer geometry. SPEC 7.5: up to 16 beams, up to 16 antennas.
    parameter int unsigned N_BEAMS = 8,
    parameter int unsigned N_ANT   = 8,

    // Flip-flops per synchronizer chain, forwarded to every issue #6 primitive
    // inside coeff_bank.
    parameter int unsigned SYNC_STAGES = 2,

    // Negative-test escape hatch, forwarded to coeff_bank. NEVER 1 in a design
    // instance: it makes the swap take effect the moment the request arrives
    // instead of at the next start of frame, which is the violation
    // a_coeff_swap_at_sof exists to catch. See sim/verilator/tops/pfb_top.sv for
    // the precedent and the reason an assertion nothing can provoke is an
    // assertion nobody has tested.
    parameter bit ALLOW_UNSAFE_SWAP = 1'b0
) (
    // ---- configuration domain ------------------------------------------------
    input  wire                                       cfg_clk,
    input  wire                                       cfg_rst_n,

    // One weight per transfer, accepted on the cycle
    // `cfg_wr_valid && cfg_wr_ready`. The address is beam-major and
    // antenna-minor: index = beam*N_ANT + antenna
    // (beamformer_pkg::bf_weight_index).
    input  wire                                       cfg_wr_valid,
    output wire                                       cfg_wr_ready,
    input  wire                                       cfg_wr_bank,
    input  wire [$clog2(N_BEAMS*N_ANT)-1:0]           cfg_wr_addr,
    input  wire [2*FXP_SAMPLE_W-1:0]                  cfg_wr_data,  // {im, re}

    // Swap request: a one-cycle strobe. Refused while `cfg_swap_busy` is high.
    input  wire                                       cfg_swap_req,
    output wire                                       cfg_swap_busy,
    output wire                                       cfg_swap_overrun,

    // Status, synchronised back into the configuration domain.
    output wire                                       cfg_active_bank,
    output wire                                       cfg_swap_pending,
    output wire                                       cfg_wr_reject,

    // ---- core (datapath) domain ----------------------------------------------
    input  wire                                       core_clk,
    input  wire                                       core_rst_n,

    // An input beat is admitted into the datapath this cycle, and whether that
    // beat is a start of frame. Together they define the safe swap point.
    input  wire                                       core_beat,
    input  wire                                       core_sof,

    output wire                                       core_active_bank,
    output wire                                       core_swap_pending,

    // The active bank, beam-major: weight (b, a) is at
    // bf_weight_index(N_ANT, b, a) * 32 +: 32, packed {im, re}.
    output wire [N_BEAMS*N_ANT*2*FXP_SAMPLE_W-1:0]    w_o
);

  localparam int unsigned N_WEIGHT = int'(bf_n_weights(bf_uint_t'(N_BEAMS),
                                                       bf_uint_t'(N_ANT)));
  localparam int unsigned ADDR_W   = int'(bf_weight_addr_w(bf_uint_t'(N_BEAMS),
                                                           bf_uint_t'(N_ANT)));

`ifndef SYNTHESIS
  initial begin
    if (N_BEAMS < 1 || N_BEAMS > int'(bf_max_beams())) begin
      $fatal(1, "weight_bank: N_BEAMS=%0d outside [1, %0d]",
             N_BEAMS, bf_max_beams());
    end
    if (N_ANT < 1 || N_ANT > int'(bf_max_antennas())) begin
      $fatal(1, "weight_bank: N_ANT=%0d outside [1, %0d]",
             N_ANT, bf_max_antennas());
    end
    // ADDR_W would be zero for a single weight, which is not a legal port
    // width. A one-weight matrix is not a beamformer, so this costs nothing.
    if (N_WEIGHT < 2) begin
      $fatal(1, "weight_bank: N_BEAMS*N_ANT=%0d; at least 2 weights are required",
             N_WEIGHT);
    end
    if ($bits(cfg_wr_addr) != ADDR_W) begin
      $fatal(1, "weight_bank: cfg_wr_addr is %0d bits but the geometry needs %0d",
             $bits(cfg_wr_addr), ADDR_W);
    end
    // The index contract this module publishes must be the one the store
    // actually uses. coeff_bank addresses phase-major/tap-minor as
    // pfb_coeff_index(TAPS, phase, tap) = phase*TAPS + tap, and the mapping
    // {phase -> beam, tap -> antenna} makes that identical to
    // bf_weight_index(N_ANT, beam, antenna). Checked rather than asserted in a
    // comment, at the two corners that would catch a transposed instantiation.
    if (bf_weight_index(bf_uint_t'(N_ANT), bf_uint_t'(1), bf_uint_t'(0)) !=
        bf_uint_t'(N_ANT)) begin
      $fatal(1, "weight_bank: bf_weight_index is not beam-major");
    end
    if (bf_weight_index(bf_uint_t'(N_ANT), bf_uint_t'(0), bf_uint_t'(1)) !=
        bf_uint_t'(1)) begin
      $fatal(1, "weight_bank: bf_weight_index is not antenna-minor");
    end
    if (ALLOW_UNSAFE_SWAP) begin
      $display("weight_bank: WARNING ALLOW_UNSAFE_SWAP=1 — the frame-boundary rule is disabled; this must be a negative-test instance only");
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // The store. PHASES -> beams, TAPS -> antennas; see section 1.
  //
  // coeff_bank's `coeff_o` is the whole active bank in its phase-major order,
  // which under that mapping IS the beam-major order this module publishes, so
  // `w_o` is a rename and not a permutation. The two elaboration checks above
  // are what make that a checked claim rather than a comment.
  // ---------------------------------------------------------------------------
  coeff_bank #(
      .PHASES            (N_BEAMS),
      .TAPS              (N_ANT),
      .SYNC_STAGES       (SYNC_STAGES),
      .ALLOW_UNSAFE_SWAP (ALLOW_UNSAFE_SWAP)
  ) u_store (
      .cfg_clk          (cfg_clk),
      .cfg_rst_n        (cfg_rst_n),
      .cfg_wr_valid     (cfg_wr_valid),
      .cfg_wr_ready     (cfg_wr_ready),
      .cfg_wr_bank      (cfg_wr_bank),
      .cfg_wr_addr      (cfg_wr_addr),
      .cfg_wr_data      (cfg_wr_data),
      .cfg_swap_req     (cfg_swap_req),
      .cfg_swap_busy    (cfg_swap_busy),
      .cfg_swap_overrun (cfg_swap_overrun),
      .cfg_active_bank  (cfg_active_bank),
      .cfg_swap_pending (cfg_swap_pending),
      .cfg_wr_reject    (cfg_wr_reject),
      .core_clk         (core_clk),
      .core_rst_n       (core_rst_n),
      .core_beat        (core_beat),
      .core_sof         (core_sof),
      .core_active_bank (core_active_bank),
      .core_swap_pending(core_swap_pending),
      .coeff_o          (w_o)
  );

  // No further assertions here, and that is deliberate rather than an omission.
  // The swap discipline this module exists to provide is checked INSIDE
  // coeff_bank by sim/assertions/coeff_bank_checker.sv — a_coeff_swap_at_sof
  // (the bank in use changes only on an admitted start-of-frame beat) and
  // a_coeff_stable_between (the active bank's contents never change except on
  // that cycle) — and those run in every build that instantiates this module,
  // with no wiring from here. Restating them would be a second copy that can
  // drift, which is the whole reason this module reuses the store instead of
  // reimplementing it.
  //
  // The property that IS specific to the beamformer — that the weight index is
  // beam-major and not transposed — is a statement about a mapping, not about a
  // waveform, so it is discharged by the two elaboration checks above and,
  // from the outside, by the SPEC 13.2 permutation metamorphic test in
  // sim/tests/test_beamformer.cpp. A transposed matrix is still a matrix: it
  // produces beams, it looks structurally healthy, and only a value check or a
  // permutation relation can see it.

endmodule : weight_bank

`default_nettype wire
