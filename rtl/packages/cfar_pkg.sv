// -----------------------------------------------------------------------------
// cfar_pkg — geometry, threshold format and detection-event layout of the
// SPEC.md 7.7 CFAR detector (issue #14).
//
// SPEC 7.7 asks for a configurable one-dimensional CFAR detector over frequency
// bins with, at minimum, cell averaging, a programmable guard-cell count, a
// programmable reference-cell count, a programmable threshold multiplier, edge
// handling, detection metadata, and detection suppression under invalid or
// incomplete windows. This package is the one place where the WIDTHS of that
// block, the FIXED-POINT FORMAT of the threshold multiplier, and the BIT LAYOUT
// of a detection event are defined. The rounding and saturation RULES stay in
// fxp_pkg, and the input width comes from covar_pkg, which owns the power
// stream this detector consumes; neither is duplicated here.
//
// Naming (DECISIONS.md, issue #10 decision 9 / issue #13)
// ------------------------------------------------------
// The integer helper type is `cfar_uint_t`, NOT `uint_t`. fxp_pkg, stream_pkg
// and covar_pkg already export types of that name; a fourth one is ambiguous
// under IEEE 1800-2017 26.3 in any module that wildcard-imports two of them.
// Quartus Prime Pro rejects that outright and Verilator accepts it silently
// (issue #10 decision 9 — the defect that cost a calibration compile). One
// package, one spelling.
//
// -----------------------------------------------------------------------------
// 1. What the detector consumes, and why the width is not negotiable
// -----------------------------------------------------------------------------
// The input is the INTEGRATED POWER stream of rtl/covariance/ (SPEC 7.6): one
// non-negative value per frequency bin, in bin order, in a signed
// covar_pkg::COVAR_POWER_W = 40-bit field. CFAR_POWER_W is that constant, by
// reference rather than by copy, so a change to SPEC 3's POWER_W moves this
// block with it.
//
// The value is signed on the wire because covar_pkg carries power and
// cross-power in one signed accumulator (issue #13 decision 2), and provably
// non-negative in content: power_calc emits I^2 + Q^2 in [0, 2^31] and the
// integrator sums non-negative terms with a clamp, never a wrap. Everything in
// this block is therefore UNSIGNED arithmetic on a magnitude; rtl/cfar/
// cfar_core.sv clamps a negative input to zero, counts it, and raises a fault
// bit, because a negative "power" can only be an upstream defect or a
// cross-power stream wired here by mistake, and silently sign-extending one
// into a comparison would turn that mistake into a plausible-looking detection.
//
// -----------------------------------------------------------------------------
// 2. The threshold multiplier: UQ8.8, and why it is not Q1.15
// -----------------------------------------------------------------------------
// Cell-averaging CFAR compares the cell under test against
//
//     T = alpha * (sum of reference cells) / (number of reference cells)
//
// where alpha is the programmable threshold multiplier. SPEC 6 fixes Q1.15 for
// SAMPLES and COEFFICIENTS, and alpha is neither: Q1.15 represents only
// [-1, 1), and a CFAR multiplier is essentially always GREATER than one. For
// the textbook cell-averaging design point,
//
//     alpha = N * (Pfa^(-1/N) - 1)
//
// so N = 16 reference cells at Pfa = 1e-6 gives alpha ~= 21.9, and N = 32 at
// Pfa = 1e-8 gives alpha ~= 25.6. A format that cannot express 21.9 cannot
// express the design point.
//
// The format is therefore UNSIGNED Q8.8: CFAR_ALPHA_W = 16 bits with
// CFAR_ALPHA_FRAC_W = 8 fractional bits, covering [0, 255.99609375] in steps of
// 1/256. The 16-bit width is the design's native coefficient width, so alpha is
// one register field and one 16-bit multiplier operand like every other
// programmable constant in the design.
//
// PRECISION JUSTIFICATION. One LSB of alpha is 2^-8 = 0.0039. At the design
// point alpha ~= 21.9 that is a relative threshold step of 1.8e-4, i.e.
// 20*log10(1 + 1.8e-4) = 0.0016 dB. The quantities being compared are integrated
// powers whose own uncertainty is set by the integration length — a 16-sample
// non-coherent integration of an exponentially distributed power has a standard
// deviation of 1/sqrt(16) = 25% of the mean, which is 1.9 dB. The threshold
// quantisation is therefore three orders of magnitude below the statistical
// spread of the thing it is thresholding, and adding fractional bits would buy
// nothing measurable. At the other end, the largest representable alpha (256)
// corresponds to a 24 dB threshold above the noise mean, well past any useful
// operating point; a design needing more raises CFAR_ALPHA_W here rather than
// scaling in software.
//
// alpha < 1 is legal and means "threshold below the noise mean". It is not a
// useful operating point but it is the cheapest way for a test to force
// detections everywhere, so it is defined rather than excluded.
//
// -----------------------------------------------------------------------------
// 3. The comparison is DIVISION-FREE and EXACT
// -----------------------------------------------------------------------------
// The mean is never computed. Writing S for the reference sum, N for the
// reference-cell count, C for the cell under test and A for the integer stored
// in the alpha register (A = round(alpha * 2^F), F = CFAR_ALPHA_FRAC_W):
//
//     C > alpha * S / N
//   <=> C > (A / 2^F) * S / N
//   <=> C * N * 2^F  >  A * S                                            (*)
//
// Both sides of (*) are exact integer products of quantities the datapath
// already holds. There is no divider, no reciprocal table, no rounding, and no
// tolerance: the detection decision is a total order on integers, so the RTL and
// the C++ model agree bit for bit by construction rather than by comparison.
// cfar_over_threshold() below IS (*), and it is what sim/assertions/
// cfar_assertions.sv checks the sized datapath against on every decision.
//
// The comparison is STRICT. Two consequences are worth stating because they are
// the cheapest available tests of the whole arithmetic path:
//
//   * an identically-zero spectrum raises NO detection at any alpha, including
//     alpha = 0, because 0 > 0 is false;
//   * a perfectly flat spectrum at alpha = exactly 1.0 raises no detection,
//     because C*N*2^F and A*S are then the same integer.
//
// Widths. C < 2^CFAR_POWER_W, N <= 2^CFAR_TOTREF_W - 1, S < 2^CFAR_SUM_W, and
// A < 2^CFAR_ALPHA_W, so
//
//     left  side < 2^(CFAR_POWER_W + CFAR_TOTREF_W + CFAR_ALPHA_FRAC_W) = 2^55
//     right side < 2^(CFAR_SUM_W + CFAR_ALPHA_W)                        = 2^63
//
// both of which fit the unsigned 64-bit working type below with a bit to spare.
// cfar_widths_ok() is that statement, elaborated rather than believed.
//
// -----------------------------------------------------------------------------
// 4. Edge handling: SUPPRESS, and why not shrink or mirror
// -----------------------------------------------------------------------------
// A bin whose complete programmed window — guard cells and reference cells on
// both sides — does not lie entirely inside the frame produces NO detection and
// is counted as suppressed. It is not evaluated against a shortened window and
// it is not evaluated against mirrored data. SPEC 7.7 requires "detection
// suppression under invalid or incomplete windows"; suppression is that
// requirement, and the two alternatives are ways of pretending the window is
// complete:
//
//   SHRINK gives the edge bins a different reference-cell count, so their noise
//   estimate has a different variance, so their false-alarm rate differs from
//   every other bin's. A detector whose Pfa varies by bin is not a
//   CONSTANT-false-alarm-rate detector, and the variation is largest exactly
//   where it cannot be calibrated.
//
//   MIRROR invents data. A target near bin 0 is mirrored into its own reference
//   window and raises the threshold that is supposed to detect it — the classic
//   self-masking failure — and the mirrored cells are perfectly correlated with
//   the real ones, which breaks the independence the threshold multiplier is
//   derived from.
//
// The price is stated rather than hidden: the first and last
// (guard + reference) bins of every frame yield no detections, and the count of
// suppressed bins is reported per frame in the end-of-frame summary event and
// cumulatively in CFAR_SUP_COUNT. At the SPEC 11 tiny geometry — 64 bins, 2
// guard and 8 reference cells per side — that is 20 of 64 bins, which is a lot,
// and it is the reason the guard and reference counts are runtime registers
// rather than compile-time constants.
//
// The same rule covers every other way a window can be incomplete: a frame
// shorter than the window, a bin evaluated while the block is disabled, and a
// configuration with zero reference cells on a side the selected mode needs.
// One policy, one counter, no special cases.
//
// -----------------------------------------------------------------------------
// 5. Detection modes
// -----------------------------------------------------------------------------
// CFAR_MODE_CA — cell averaging. One comparison, (*), against the COMBINED
//                reference sum and the COMBINED count.
// CFAR_MODE_GO — greatest-of. The noise estimate is the larger of the two
//                one-sided MEANS.
//
// Greatest-of needs no maximum and no division, because
//
//     C > alpha * max(S_lead/N_lead, S_lag/N_lag)
//   <=> C > alpha * S_lead/N_lead   AND   C > alpha * S_lag/N_lag
//
// i.e. GO is the logical AND of two independent instances of (*), one per side,
// each with its own count. That is why the two modes share one comparator
// structure and why greatest-of works with INDEPENDENT leading and lagging
// reference counts, which a literal max(S_lead, S_lag) would not.
//
// Ordered-statistics CFAR is NOT implemented; it needs a rank-order network over
// the reference cells rather than a sum, which is a different structure and a
// different cost class. SPEC 7.7 lists it as optional.
//
// Lint contract: linted by `make lint` on every run, clean under --Wall with no
// waiver.
// -----------------------------------------------------------------------------

`default_nettype none

package cfar_pkg;

  // ---------------------------------------------------------------------------
  // Working types
  // ---------------------------------------------------------------------------

  // Unsigned 32-bit integer, so widths and offsets can be cast explicitly
  // (`cfar_uint_t'(x)`); `int unsigned'(x)` is not legal cast syntax. Same
  // device as fxp_pkg::uint_t, stream_pkg::uint_t and covar_pkg::covar_uint_t,
  // deliberately spelled differently — see the naming note at the top.
  typedef int unsigned cfar_uint_t;

  // Unsigned 64-bit working type for the threshold comparison. UNSIGNED, not
  // signed like fxp_pkg::fxp_wide_t, because every quantity in (*) is a
  // magnitude and the right-hand side reaches 2^63 (section 3) — one bit past
  // what a signed 64-bit type holds.
  localparam int unsigned CFAR_WIDE_W = 64;
  typedef logic [CFAR_WIDE_W-1:0] cfar_wide_t;

  // ---------------------------------------------------------------------------
  // Widths
  // ---------------------------------------------------------------------------

  // The power stream this block consumes (SPEC 3 POWER_W, section 1). By
  // reference to covar_pkg rather than by copy.
  localparam int unsigned CFAR_POWER_W = covar_pkg::COVAR_POWER_W;  // 40

  // Frequency-bin index within a frame, and the frame identity carried with an
  // event. 16 bits covers 65536 bins against the 4096 of the SPEC 11 full-scale
  // FFT, and matches covar_pkg::COVAR_WINDOW_ID_W so that a covariance window id
  // used as a frame id needs no resizing at the seam.
  localparam int unsigned CFAR_BIN_W      = 16;
  localparam int unsigned CFAR_FRAME_ID_W = 16;

  // Per-frame detection and suppression counts in the summary event. Same width
  // as the bin index, because neither can exceed the number of bins in a frame.
  localparam int unsigned CFAR_CNT_W = 16;

  // Threshold multiplier, unsigned Q8.8 (section 2).
  localparam int unsigned CFAR_ALPHA_W      = 16;
  localparam int unsigned CFAR_ALPHA_FRAC_W = 8;

  // Programmable geometry, as REGISTER FIELD widths. These bound what software
  // can ask for; what a given elaboration can deliver is its MAX_GUARD/MAX_REF
  // parameters, which are reported back through CFAR_STATUS and are always less
  // than or equal to these. A request above the elaborated maximum is clamped
  // and flagged (rtl/cfar/cfar_core.sv), never silently wrapped.
  localparam int unsigned CFAR_GUARD_CNT_W = 5;  // guard cells per side,  0..31
  localparam int unsigned CFAR_REF_CNT_W   = 6;  // reference cells/side,  0..63

  // Combined reference count, N_lead + N_lag <= 2*63 = 126.
  localparam int unsigned CFAR_TOTREF_W = CFAR_REF_CNT_W + 1;  // 7

  // Reference SUM width in the EVENT format. Sized for the widest legal
  // geometry — 126 terms each below 2^CFAR_POWER_W — so that the event layout is
  // the same in every configuration. A given elaboration's internal sum is
  // narrower; cfar_sum_w() below is that width.
  localparam int unsigned CFAR_SUM_W = CFAR_POWER_W + CFAR_TOTREF_W;  // 47

  // ---------------------------------------------------------------------------
  // Modes
  // ---------------------------------------------------------------------------

  // Detection mode (section 5). Two bits so that ordered statistics can be added
  // as a named value rather than as a magic 2.
  localparam int unsigned CFAR_MODE_W = 2;

  typedef enum logic [CFAR_MODE_W-1:0] {
    CFAR_MODE_CA = 2'd0,  // cell averaging
    CFAR_MODE_GO = 2'd1   // greatest-of
  } cfar_mode_e;

  // Output mode. EVENTS is the operational one: the output stream carries only
  // the bins that detected, plus one end-of-frame summary. DENSE reports EVERY
  // bin — detected, not detected, or suppressed — plus the same summary, and is
  // what makes the whole per-bin decision observable to a test and to issue #19
  // snapshot capture without a second data path.
  typedef enum logic {
    CFAR_OUT_EVENTS = 1'b0,
    CFAR_OUT_DENSE  = 1'b1
  } cfar_out_mode_e;

  // ---------------------------------------------------------------------------
  // Detection-event kinds
  //
  // Four values, all used, so the "was it detected" and "was it suppressed"
  // questions are one field rather than a kind plus two flag bits that can
  // contradict it.
  // ---------------------------------------------------------------------------
  localparam int unsigned CFAR_EV_KIND_W = 2;

  typedef enum logic [CFAR_EV_KIND_W-1:0] {
    CFAR_EV_DETECT     = 2'd0,  // the cell exceeded its threshold
    CFAR_EV_BIN        = 2'd1,  // evaluated, did not exceed (DENSE mode only)
    CFAR_EV_SUPPRESSED = 2'd2,  // window incomplete or invalid; not evaluated
    CFAR_EV_SUMMARY    = 2'd3   // end of frame; carries the per-frame counts
  } cfar_ev_kind_e;

  // ---------------------------------------------------------------------------
  // Detection-event layout  (NORMATIVE)
  //
  //   MSB                                                                  LSB
  //   +-----------+------+------+------+------+---------+----------+------+
  //   | noise_sum | cell | sup  | det  | alpha| ref_cnt | frame_id | bin  | kind
  //   +-----------+------+------+------+------+---------+----------+------+
  //        47       40     16     16     16        7         16      16      2
  //
  // Total CFAR_EVENT_W = 176 bits, which is the DATA_W of the detector's output
  // stream and the payload the issue #18 packet network carries in a 512-bit
  // packet. The layout is CONFIGURATION-INDEPENDENT by construction — every
  // field width above is a constant of this package, none is an elaboration
  // parameter — because a packet format that changed with the FFT size would
  // have to be renegotiated at every SPEC 11 size.
  //
  // Field order rationale, the same one stream_pkg gives: the two wide numeric
  // fields are at the top, so widening the power or the sum moves no other
  // field's offset and a payload captured in a waveform stays readable across a
  // resize.
  //
  // Per kind:
  //
  //   DETECT / BIN    bin, frame_id, ref_cnt, alpha, cell, noise_sum carry the
  //                   decision; det and sup are zero. The four numbers
  //                   (cell, noise_sum, ref_cnt, alpha) are exactly the operands
  //                   of (*), so a consumer can RE-DERIVE the decision with the
  //                   same integer comparison the detector made. That is the
  //                   point of carrying alpha in the event rather than expecting
  //                   the consumer to read the register plane: an event is
  //                   self-verifying, and remains so after the register changes.
  //
  //   SUPPRESSED      bin, frame_id and alpha are valid; cell carries the cell's
  //                   power (it is known — it was simply not evaluated) and
  //                   noise_sum and ref_cnt are zero, because no valid reference
  //                   window existed.
  //
  //   SUMMARY         bin carries the frame's LENGTH in bins, det and sup carry
  //                   the per-frame detection and suppression counts, alpha the
  //                   multiplier that was in force; cell, noise_sum and ref_cnt
  //                   are zero. Exactly one summary is emitted per input frame,
  //                   and it is the beat that carries end_of_frame, so a frame
  //                   with no detections is still a well-formed output frame of
  //                   one beat.
  //
  // The NOISE ESTIMATE is reported as the reference SUM and the reference COUNT,
  // not as their quotient. The detector never divides (section 3) and adding a
  // divider purely to fill in a metadata field would put the only inexact
  // operation in the block on the reporting path. A consumer that wants the mean
  // computes noise_sum / ref_cnt at whatever precision it needs; a consumer that
  // wants to CHECK the detection does not need the mean at all.
  // ---------------------------------------------------------------------------

  typedef enum int unsigned {
    CFAR_SEL_KIND     = 0,
    CFAR_SEL_BIN      = 1,
    CFAR_SEL_FRAME_ID = 2,
    CFAR_SEL_REF_CNT  = 3,
    CFAR_SEL_ALPHA    = 4,
    CFAR_SEL_DET      = 5,
    CFAR_SEL_SUP      = 6,
    CFAR_SEL_CELL     = 7,
    CFAR_SEL_SUM      = 8,
    CFAR_SEL_END      = 9
  } cfar_ev_sel_e;

  // The one place the event layout arithmetic exists. Every accessor is a thin
  // wrapper on it, for the reason stream_layout_bit() gives: a second expression
  // for any boundary is a second definition of the layout.
  function automatic cfar_uint_t cfar_ev_bit(input cfar_ev_sel_e sel);
    cfar_uint_t b;
    b = 32'd0;
    if (sel == CFAR_SEL_KIND) return b;
    b = b + cfar_uint_t'(CFAR_EV_KIND_W);
    if (sel == CFAR_SEL_BIN) return b;
    b = b + cfar_uint_t'(CFAR_BIN_W);
    if (sel == CFAR_SEL_FRAME_ID) return b;
    b = b + cfar_uint_t'(CFAR_FRAME_ID_W);
    if (sel == CFAR_SEL_REF_CNT) return b;
    b = b + cfar_uint_t'(CFAR_TOTREF_W);
    if (sel == CFAR_SEL_ALPHA) return b;
    b = b + cfar_uint_t'(CFAR_ALPHA_W);
    if (sel == CFAR_SEL_DET) return b;
    b = b + cfar_uint_t'(CFAR_CNT_W);
    if (sel == CFAR_SEL_SUP) return b;
    b = b + cfar_uint_t'(CFAR_CNT_W);
    if (sel == CFAR_SEL_CELL) return b;
    b = b + cfar_uint_t'(CFAR_POWER_W);
    if (sel == CFAR_SEL_SUM) return b;
    b = b + cfar_uint_t'(CFAR_SUM_W);
    return b;  // CFAR_SEL_END
  endfunction

  // Total width of a packed detection event. This is the DATA_W of the
  // detector's output stream. Written as the sum of the field widths so the
  // packed type below can be declared with it; cfar_event_w() returns the same
  // number by WALKING the layout, and rtl/cfar/cfar_core.sv elaborates the two
  // against each other — which is what stops the layout walk and the type from
  // disagreeing after a field is added.
  localparam int unsigned CFAR_EVENT_W =
      CFAR_EV_KIND_W + CFAR_BIN_W + CFAR_FRAME_ID_W + CFAR_TOTREF_W +
      CFAR_ALPHA_W + CFAR_CNT_W + CFAR_CNT_W + CFAR_POWER_W + CFAR_SUM_W;

  function automatic cfar_uint_t cfar_event_w();
    return cfar_ev_bit(CFAR_SEL_END);
  endfunction

  // Unpacked view. Field widths are constants, so unlike stream_pkg this struct
  // needs no maximum-width working form.
  typedef struct packed {
    logic [CFAR_SUM_W-1:0]      noise_sum;
    logic [CFAR_POWER_W-1:0]    cut_power;
    logic [CFAR_CNT_W-1:0]      sup_count;
    logic [CFAR_CNT_W-1:0]      det_count;
    logic [CFAR_ALPHA_W-1:0]    alpha;
    logic [CFAR_TOTREF_W-1:0]   ref_count;
    logic [CFAR_FRAME_ID_W-1:0] frame_id;
    logic [CFAR_BIN_W-1:0]      bin;
    logic [CFAR_EV_KIND_W-1:0]  kind;
  } cfar_event_t;

  // Packed view, at the exact event width.
  typedef logic [CFAR_EVENT_W-1:0] cfar_event_bits_t;

  // Fields -> packed. Every field is masked by its own width before it is
  // shifted, so a value too large for its field is truncated rather than written
  // into its neighbour.
  function automatic cfar_event_bits_t cfar_event_pack(input cfar_event_t e);
    cfar_event_bits_t p;
    p = '0;
    p[cfar_ev_bit(CFAR_SEL_KIND)     +: CFAR_EV_KIND_W]  = e.kind;
    p[cfar_ev_bit(CFAR_SEL_BIN)      +: CFAR_BIN_W]      = e.bin;
    p[cfar_ev_bit(CFAR_SEL_FRAME_ID) +: CFAR_FRAME_ID_W] = e.frame_id;
    p[cfar_ev_bit(CFAR_SEL_REF_CNT)  +: CFAR_TOTREF_W]   = e.ref_count;
    p[cfar_ev_bit(CFAR_SEL_ALPHA)    +: CFAR_ALPHA_W]    = e.alpha;
    p[cfar_ev_bit(CFAR_SEL_DET)      +: CFAR_CNT_W]      = e.det_count;
    p[cfar_ev_bit(CFAR_SEL_SUP)      +: CFAR_CNT_W]      = e.sup_count;
    p[cfar_ev_bit(CFAR_SEL_CELL)     +: CFAR_POWER_W]    = e.cut_power;
    p[cfar_ev_bit(CFAR_SEL_SUM)      +: CFAR_SUM_W]      = e.noise_sum;
    return p;
  endfunction

  // Packed -> fields. A round trip through pack/unpack is the identity on any
  // event whose fields fit their widths.
  function automatic cfar_event_t cfar_event_unpack(input cfar_event_bits_t p);
    cfar_event_t e;
    e           = '0;
    e.kind      = p[cfar_ev_bit(CFAR_SEL_KIND)     +: CFAR_EV_KIND_W];
    e.bin       = p[cfar_ev_bit(CFAR_SEL_BIN)      +: CFAR_BIN_W];
    e.frame_id  = p[cfar_ev_bit(CFAR_SEL_FRAME_ID) +: CFAR_FRAME_ID_W];
    e.ref_count = p[cfar_ev_bit(CFAR_SEL_REF_CNT)  +: CFAR_TOTREF_W];
    e.alpha     = p[cfar_ev_bit(CFAR_SEL_ALPHA)    +: CFAR_ALPHA_W];
    e.det_count = p[cfar_ev_bit(CFAR_SEL_DET)      +: CFAR_CNT_W];
    e.sup_count = p[cfar_ev_bit(CFAR_SEL_SUP)      +: CFAR_CNT_W];
    e.cut_power = p[cfar_ev_bit(CFAR_SEL_CELL)     +: CFAR_POWER_W];
    e.noise_sum = p[cfar_ev_bit(CFAR_SEL_SUM)      +: CFAR_SUM_W];
    return e;
  endfunction

  // ---------------------------------------------------------------------------
  // The comparison  (NORMATIVE — section 3, equation (*))
  //
  // This function IS the detection rule. rtl/cfar/cfar_core.sv builds the same
  // comparison out of SIZED multipliers, because a 64-bit multiply in the
  // datapath would synthesise a 64-bit multiplier; sim/assertions/
  // cfar_assertions.sv checks the sized datapath against this function on every
  // decision, which is the same arrangement power_calc uses to keep its
  // arithmetic honest against fxp_pkg.
  // ---------------------------------------------------------------------------

  // C * N * 2^F, the left-hand side of (*).
  function automatic cfar_wide_t cfar_cmp_lhs(input cfar_wide_t cut,
                                              input cfar_wide_t n_ref);
    return (cut * n_ref) << CFAR_ALPHA_FRAC_W;
  endfunction

  // A * S, the right-hand side of (*).
  function automatic cfar_wide_t cfar_cmp_rhs(input cfar_wide_t alpha,
                                              input cfar_wide_t sum);
    return alpha * sum;
  endfunction

  // The decision. Strict, for the reasons in section 3.
  function automatic logic cfar_over_threshold(input cfar_wide_t cut,
                                               input cfar_wide_t sum,
                                               input cfar_wide_t n_ref,
                                               input cfar_wide_t alpha);
    return cfar_cmp_lhs(cut, n_ref) > cfar_cmp_rhs(alpha, sum);
  endfunction

  // ---------------------------------------------------------------------------
  // Geometry helpers
  //
  // Exported as FUNCTIONS rather than as localparams for the measured reason
  // stream_pkg and covar_pkg give: `verilator --lint-only --Wall` reports a
  // package localparam that a given build happens not to reference as a dead
  // parameter, and this package is deliberately lintable one top at a time
  // (files_cfar.f, files_control.f, files.f). A function is available to every
  // build and dead in none, and referencing the localparam from a function body
  // is what makes the localparam "used" in every build as well.
  // ---------------------------------------------------------------------------

  // Half-window in bins: the distance from the cell under test to the outermost
  // reference cell on one side, at the elaborated maxima. This is the pipeline
  // delay the detector needs before a bin's window can be complete, and half the
  // number of bins suppressed at each frame edge.
  function automatic cfar_uint_t cfar_half_window(input cfar_uint_t max_guard,
                                                  input cfar_uint_t max_ref);
    return max_guard + max_ref;
  endfunction

  // Slots in the sliding-window register file: both sides plus the cell under
  // test.
  function automatic cfar_uint_t cfar_window_slots(input cfar_uint_t max_guard,
                                                   input cfar_uint_t max_ref);
    return 32'd2 * cfar_half_window(max_guard, max_ref) + 32'd1;
  endfunction

  // Internal reference-sum width for an elaboration: max_ref cells per side,
  // both sides, each below 2^CFAR_POWER_W. Narrower than the EVENT field
  // CFAR_SUM_W at every configuration smaller than the maximum, which is why the
  // two are separate constants.
  function automatic cfar_uint_t cfar_sum_w(input cfar_uint_t max_ref);
    cfar_uint_t n;
    n = (max_ref == 32'd0) ? 32'd1 : (32'd2 * max_ref);
    return cfar_uint_t'(CFAR_POWER_W) + cfar_uint_t'($clog2(n + 32'd1));
  endfunction

  // Comparison width for an elaboration: the wider of the two sides of (*).
  function automatic cfar_uint_t cfar_cmp_w(input cfar_uint_t max_ref);
    cfar_uint_t lhs_w, rhs_w;
    lhs_w = cfar_uint_t'(CFAR_POWER_W) + cfar_uint_t'(CFAR_TOTREF_W) +
            cfar_uint_t'(CFAR_ALPHA_FRAC_W);
    rhs_w = cfar_sum_w(max_ref) + cfar_uint_t'(CFAR_ALPHA_W);
    return (lhs_w > rhs_w) ? lhs_w : rhs_w;
  endfunction

  // True when the WIDEST legal geometry still fits the 64-bit working type
  // (section 3). Elaborated by rtl/cfar/cfar_core.sv rather than argued.
  function automatic logic cfar_widths_ok();
    cfar_uint_t lhs_w, rhs_w;
    lhs_w = cfar_uint_t'(CFAR_POWER_W) + cfar_uint_t'(CFAR_TOTREF_W) +
            cfar_uint_t'(CFAR_ALPHA_FRAC_W);
    rhs_w = cfar_uint_t'(CFAR_SUM_W) + cfar_uint_t'(CFAR_ALPHA_W);
    return (lhs_w <= cfar_uint_t'(CFAR_WIDE_W)) &&
           (rhs_w <= cfar_uint_t'(CFAR_WIDE_W));
  endfunction

  // ---------------------------------------------------------------------------
  // Register-plane reset values, mirrored from control/regmap.json. Exported so
  // the RTL and the generated register map are compared at elaboration instead
  // of by inspection (rtl/control/reg_block_cfar.sv does the comparing).
  // ---------------------------------------------------------------------------

  // alpha = 1.0 exactly, in UQ8.8. The identity multiplier: on a flat spectrum
  // it detects nothing (section 3), which makes it the safe reset value — a
  // detector that powers up detecting everything would flood the packet network
  // before software had configured anything.
  function automatic cfar_uint_t cfar_alpha_one();
    return 32'd1 << CFAR_ALPHA_FRAC_W;  // 0x0100
  endfunction

  // Reset value of CFAR_THRESHOLD.ALPHA: 20.0 in UQ8.8 (0x1400). Close to the
  // textbook 16-cell, Pfa = 1e-6 design point of section 2, so a block enabled
  // without programming the threshold behaves like a CFAR rather than like a
  // wire.
  function automatic cfar_uint_t cfar_alpha_default();
    return 32'd20 << CFAR_ALPHA_FRAC_W;  // 0x1400
  endfunction

  function automatic cfar_uint_t cfar_guard_default();
    return 32'd2;
  endfunction

  function automatic cfar_uint_t cfar_ref_default();
    return 32'd8;
  endfunction

  // Function forms of the widths, for the dead-parameter reason above.
  function automatic cfar_uint_t cfar_power_w();
    return cfar_uint_t'(CFAR_POWER_W);
  endfunction

  function automatic cfar_uint_t cfar_bin_w();
    return cfar_uint_t'(CFAR_BIN_W);
  endfunction

  function automatic cfar_uint_t cfar_alpha_w();
    return cfar_uint_t'(CFAR_ALPHA_W);
  endfunction

  function automatic cfar_uint_t cfar_alpha_frac_w();
    return cfar_uint_t'(CFAR_ALPHA_FRAC_W);
  endfunction

  function automatic cfar_uint_t cfar_guard_cnt_w();
    return cfar_uint_t'(CFAR_GUARD_CNT_W);
  endfunction

  function automatic cfar_uint_t cfar_ref_cnt_w();
    return cfar_uint_t'(CFAR_REF_CNT_W);
  endfunction

  function automatic cfar_uint_t cfar_totref_w();
    return cfar_uint_t'(CFAR_TOTREF_W);
  endfunction

  function automatic cfar_uint_t cfar_event_sum_w();
    return cfar_uint_t'(CFAR_SUM_W);
  endfunction

  function automatic cfar_uint_t cfar_cnt_w();
    return cfar_uint_t'(CFAR_CNT_W);
  endfunction

  function automatic cfar_uint_t cfar_mode_w();
    return cfar_uint_t'(CFAR_MODE_W);
  endfunction

  function automatic cfar_uint_t cfar_frame_id_w();
    return cfar_uint_t'(CFAR_FRAME_ID_W);
  endfunction

endpackage : cfar_pkg

`default_nettype wire
