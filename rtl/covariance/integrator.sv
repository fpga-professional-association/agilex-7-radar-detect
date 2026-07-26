// -----------------------------------------------------------------------------
// integrator — the programmable integration window (SPEC.md 7.6, issue #13).
//
// One signed accumulator with four properties SPEC 7.6 names explicitly:
// a programmable integration window, accumulator protection, window-boundary
// metadata, and an optional exponential-averaging mode; plus the deterministic
// flush that makes the block restartable without a chip reset.
//
// It is instantiated once per integrated quantity: once behind power_calc for
// `Power = I^2 + Q^2`, and twice per pair inside covar_engine for the real and
// imaginary halves of `Rxy = X * conj(Y)`. That reuse is why the accumulator is
// SIGNED even for power, which is provably non-negative — one accumulator, one
// saturation rule, one C++ model, one set of directed corner tests. See
// power_calc.sv section 1.
//
// -----------------------------------------------------------------------------
// 1. Accumulator protection, and the exact window bound
// -----------------------------------------------------------------------------
// Every term this module sums is bounded by 2^31 (covar_pkg section 1: it is
// either `I^2 + Q^2` or one component of a Q1.15 conjugate product). A signed
// ACC_W-bit accumulator therefore integrates
//
//     N <= 2^(ACC_W - 32) - 1        samples with NO possibility of clamping
//
// which at the SPEC 3 width ACC_W = POWER_W = 40 is N <= 255. covar_pkg exports
// that bound in both directions (covar_window_max_exact / covar_acc_w_required)
// and this module checks the elaborated geometry against it, so a build whose
// maximum programmable window exceeds the exact bound says so at elaboration
// rather than in a field report.
//
// Beyond the bound the accumulator SATURATES and raises a sticky flag. It never
// wraps: fxp_pkg's standing rule is that a wrapped overflow turns a large
// positive detection into a large negative one, which the CFAR stage downstream
// (SPEC 7.7) cannot distinguish from a real target, whereas a clamp degrades
// monotonically and is visibly flagged. Saturation is applied ONCE, to the new
// accumulator value, through fxp_pkg::fxp_sat — there is no second rounding rule
// in this file and no `>>>` outside the one exponential-mode call to
// fxp_pkg::fxp_trunc.
//
// The sticky flag is held by rtl/common/fxp_sticky_flags.sv, the project's one
// sanctioned collector, so "did this block saturate?" reads the same here as in
// every other kernel and the telemetry plane (issue #8) has one shape to fetch.
//
// -----------------------------------------------------------------------------
// 2. The window, and what "takes effect at a window boundary" means
// -----------------------------------------------------------------------------
// The programmed length, the mode, the exponential shift and the enable are ALL
// latched into an active copy at a window boundary and nowhere else. Mid-window
// they are ignored. This is not politeness — it is what makes a result
// interpretable: a window whose length changed halfway through is a sum over an
// interval nobody can name, and a consumer normalising by the programmed length
// would divide by a number that never applied.
//
// A boundary is: reset release, a window closing normally, a flush, or an idle
// cycle in which no window is open and none is opening. So the worst case for a
// configuration write is that it takes effect one window later, bounded and
// known, and software that needs it immediately writes the register and then
// pulses FLUSH. The "no window open" term is what lets a block that has been
// DISABLED be enabled again: a disabled block accepts no samples, so it closes
// no windows, so without that term the enable could never be latched high a
// second time. The "and none is opening" qualification is what stops a write
// landing in the same cycle as a window's first sample from changing the length
// of the window that sample has just started; see `boundary` below.
//
// The result carries the metadata that makes it self-describing:
//
//   window_id     wraps at 2^COVAR_WINDOW_ID_W. Increments by exactly one per
//                 emitted result, so a consumer detects a dropped window.
//   sample_count  how many samples ACTUALLY went in. Equal to the active length
//                 for a normal close; smaller for a flushed partial window.
//   flushed       this result was drained by software rather than by the
//                 counter reaching the length.
//   truncated     this result covers fewer samples than the active length.
//
// `flushed` and `truncated` are separate bits because they answer different
// questions, and a flush that lands exactly on the closing sample is flushed and
// NOT truncated. The rule SPEC 7.6 is really asking for — "never emit a partial
// window silently" — is then structural: a short result cannot leave this module
// without `truncated` set beside it.
//
// -----------------------------------------------------------------------------
// 3. Deterministic flush
// -----------------------------------------------------------------------------
// `flush` is a one-cycle request, and its contract is exactly this:
//
//     After a flush, the module is in the state it is in one cycle after reset
//     release, and any partial window that existed has been EMITTED first.
//
// Concretely the flush cycle (a) emits the open window if one has any samples in
// it, with `flushed` set, (b) zeroes the accumulator, the sample counter and the
// exponential state, (c) resets `window_id` to zero, (d) clears the sticky
// saturation flags and their counter, and (e) reloads the active configuration
// from the cfg_* ports.
//
// (c) and (d) are the parts that are easy to get wrong and are the reason the
// contract is written as an equivalence rather than as a list: the test
// (sim/tests/test_covariance.cpp, "flush determinism") runs one stimulus from
// reset and the same stimulus after a flush, and requires the two output streams
// to be identical bit for bit — window ids included. A flush that preserved the
// window id, or the sticky flags, would fail that comparison, which is the whole
// point of stating the property as "same state as a fresh start".
//
// Software that wants to keep the saturation history reads it before flushing;
// `sat_clear` exists for the opposite case, clearing the flags without
// disturbing the window.
//
// -----------------------------------------------------------------------------
// 4. Exponential averaging, and its fixed-point behaviour
// -----------------------------------------------------------------------------
// COVAR_MODE_EXP replaces the block sum with the classic leaky integrator,
// evaluated once per accepted sample:
//
//     y <- y + ((x - y) >>> k)                k programmable, 0..15
//
// The shift is fxp_pkg::fxp_trunc — arithmetic right shift, i.e. floor division,
// round toward -infinity. That is a deliberate choice and it has consequences
// worth stating exactly, because they are what the model has to reproduce:
//
//   * k = 0 makes the update y <- x: a pass-through, not a divide-by-one bug.
//   * For x > y the increment is floor((x-y)/2^k), which is ZERO whenever
//     0 < x - y < 2^k. Rising convergence therefore STALLS in a dead band up to
//     2^k - 1 LSBs below x, and y never quite reaches a rising target.
//   * For x < y the increment is floor(negative/2^k) <= -1 always, so falling
//     convergence never stalls; y decreases every sample until x - y >= 0.
//   * The fixed set is consequently y in (x - 2^k, x] for a constant x: the
//     filter is biased LOW by up to one shift quantum, and it is exactly, not
//     approximately, that.
//
// Round-to-nearest would remove the bias, and the project rule (fxp_pkg) is
// round-to-nearest-even everywhere a value is QUANTISED. This is not a
// quantisation of a result: it is the loop gain of a feedback path, and it is
// the one path in this block that cannot be pipelined — y is needed next cycle.
// Putting fxp_pkg's rounding network inside that loop buys a fraction of an LSB
// of DC accuracy and costs the closure of the accumulator loop, on a block whose
// output feeds a threshold that is itself software-programmable. Truncation is
// therefore the documented rule HERE, it is spelled as a call into
// fxp_pkg::fxp_trunc rather than as a bare `>>>` so a reviewer grepping for
// quantisation finds it, and the dead band above is a checked property of the
// C++ model rather than an accepted surprise.
//
// In exponential mode the state is NOT cleared at a window boundary — that is
// what makes it exponential. The window then serves only as the report cadence:
// y is sampled and emitted every `window_len` samples with the same metadata as
// a block result. `flush` still zeroes y, because flush means "fresh start".
//
// -----------------------------------------------------------------------------
// 5. Flow control
// -----------------------------------------------------------------------------
// No `ready`, in or out, and no clock enable on the datapath — the same contract
// as complex_multiplier and power_calc (DECISIONS.md issue #9, decision 4).
// Consequences, both of which the test checks:
//
//   * gaps in `valid_in` are invariant. The same beats in the same order produce
//     the same results, byte for byte, whether they arrive back to back or one
//     every hundred cycles. There is no free-running counter anywhere in this
//     module; every state update is qualified by an accepted sample.
//   * the output cannot be back-pressured, and does not need to be: a result is
//     emitted at most once per accepted sample (window_len >= 1), so the output
//     rate never exceeds the input rate. A consumer that needs elasticity puts a
//     rtl/stream/ primitive after this module, where backpressure belongs.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module integrator
  import fxp_pkg::*;
  import covar_pkg::*;
#(
    // Width of one input term, signed. Terms must satisfy |x| <= 2^31 for the
    // window bound of section 1 to hold; see TERM_BOUND_W below.
    parameter int unsigned DATA_W = COVAR_POWER_W,

    // Accumulator and result width, signed. SPEC 3 POWER_W.
    parameter int unsigned ACC_W = COVAR_POWER_W,

    // Width of the programmable window length and of the sample counter. The
    // longest programmable window is 2^WINDOW_W - 1 samples.
    parameter int unsigned WINDOW_W = COVAR_WINDOW_LEN_W,

    // Width of the saturation-event counter in the sticky-flag collector.
    parameter int unsigned SAT_COUNT_W = 32
) (
    input  wire                              clk,
    input  wire                              rst_n,

    // ---- configuration. Sampled ONLY at a window boundary (section 2). ------
    // A length of zero is treated as one; see WL below. Nothing else is
    // sanitised, because every other field is exhaustive in its own width.
    input  wire [WINDOW_W-1:0]               cfg_window_len,
    input  wire                              cfg_mode,      // covar_mode_e
    input  wire [COVAR_EXP_K_W-1:0]          cfg_exp_k,
    input  wire                              cfg_enable,

    // ---- control ------------------------------------------------------------
    // One-cycle requests. `flush` is section 3; `sat_clear` clears the sticky
    // saturation state and nothing else.
    input  wire                              flush,
    input  wire                              sat_clear,

    // ---- sample input. No ready; see section 5. -----------------------------
    input  wire                              valid_in,
    input  wire signed [DATA_W-1:0]          data_in,

    // ---- window result ------------------------------------------------------
    output wire                              valid_out,
    output wire signed [ACC_W-1:0]           acc_out,
    output wire [COVAR_WINDOW_ID_W-1:0]      window_id,
    output wire [WINDOW_W-1:0]               sample_count,
    output wire                              flushed,
    output wire                              truncated,

    // ---- accumulator protection (section 1) ---------------------------------
    output wire fxp_flags_t                  sat_flags,
    output wire                              sat_sticky,
    output wire [SAT_COUNT_W-1:0]            sat_count,

    // ---- observation --------------------------------------------------------
    // The live accumulator and the active configuration. Not part of the data
    // contract; exported so a test can separate "the sum is wrong" from "the
    // window closed at the wrong time", which is otherwise a guess.
    output wire signed [ACC_W-1:0]           obs_acc,
    output wire [WINDOW_W-1:0]               obs_count,
    output wire [WINDOW_W-1:0]               obs_window_len,
    output wire                              obs_mode,
    output wire [COVAR_EXP_K_W-1:0]          obs_exp_k,
    output wire                              obs_enable
);

  // ---------------------------------------------------------------------------
  // Elaboration checks
  // ---------------------------------------------------------------------------

  // The magnitude bound every term must respect for section 1's arithmetic.
  localparam int unsigned TERM_BOUND_W = COVAR_TERM_W;              // 32
  // Longest window this accumulator integrates exactly, and the longest one the
  // counter can express.
  localparam int unsigned WIN_EXACT_MAX = int'(covar_window_max_exact(covar_uint_t'(ACC_W)));
  localparam int unsigned WIN_PROG_MAX  = (1 << WINDOW_W) - 1;

`ifndef SYNTHESIS
  initial begin
    if (ACC_W < DATA_W) begin
      $fatal(1, "integrator: ACC_W=%0d is narrower than DATA_W=%0d", ACC_W, DATA_W);
    end
    if (ACC_W < TERM_BOUND_W + 1) begin
      $fatal(1, "integrator: ACC_W=%0d leaves no integration growth over the %0d-bit term bound",
             ACC_W, TERM_BOUND_W);
    end
    if (WINDOW_W < 1 || WINDOW_W > 24) begin
      $fatal(1, "integrator: WINDOW_W=%0d outside [1, 24]", WINDOW_W);
    end
    // NOT fatal: a build MAY choose a programmable range wider than the exact
    // bound, and then the saturation path is a real operating mode rather than
    // an error. It is announced, because a silent one is how a design acquires
    // an accumulator nobody knows can clamp. sim/tests/test_covariance.cpp
    // deliberately elaborates such an instance.
    if (WIN_PROG_MAX > WIN_EXACT_MAX) begin
      $display("[integrator] note: ACC_W=%0d integrates exactly to %0d samples, but WINDOW_W=%0d permits %0d; windows above %0d may saturate",
               ACC_W, WIN_EXACT_MAX, WINDOW_W, WIN_PROG_MAX, WIN_EXACT_MAX);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Active configuration. Loaded at a window boundary only (section 2).
  // ---------------------------------------------------------------------------
  logic [WINDOW_W-1:0]      wl_q;
  logic                     mode_q;
  logic [COVAR_EXP_K_W-1:0] k_q;
  logic                     en_q;

  // The effective length: zero means one, so a zero-initialised register plane
  // cannot make the window infinite (which would look exactly like a hang).
  wire [WINDOW_W-1:0] WL = (wl_q == '0) ? WINDOW_W'(1) : wl_q;

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  logic signed [ACC_W-1:0]        acc_q;
  logic [WINDOW_W-1:0]            cnt_q;
  logic [COVAR_WINDOW_ID_W-1:0]   wid_q;

  // Registered outputs.
  logic                           out_valid_q;
  logic signed [ACC_W-1:0]        out_acc_q;
  logic [COVAR_WINDOW_ID_W-1:0]   out_wid_q;
  logic [WINDOW_W-1:0]            out_cnt_q;
  logic                           out_flushed_q;
  logic                           out_trunc_q;

  // ---------------------------------------------------------------------------
  // The update, in one always_comb so the order of the three rules — accept the
  // sample, then close the window, then honour the flush — is written once and
  // is readable as a sequence rather than reconstructed from priorities.
  // ---------------------------------------------------------------------------
  wire accept = valid_in && en_q;

  fxp_wide_t   raw_next;      // the pre-saturation accumulator value
  fxp_flags_t  step_flags;
  logic signed [ACC_W-1:0] acc_next;
  logic [WINDOW_W-1:0]     cnt_next;
  logic                    close;      // the counter reached the active length

  always_comb begin
    // ---- rule 1: the sample ------------------------------------------------
    if (!accept) begin
      raw_next = fxp_wide_t'(acc_q);
    end else if (mode_q == COVAR_MODE_EXP) begin
      // y + trunc((x - y) >> k). Section 4.
      raw_next = fxp_wide_t'(acc_q)
               + fxp_trunc(fxp_wide_t'(data_in) - fxp_wide_t'(acc_q),
                           uint_t'(k_q));
    end else begin
      raw_next = fxp_wide_t'(acc_q) + fxp_wide_t'(data_in);
    end

    step_flags = accept ? fxp_sat_flags(raw_next, uint_t'(ACC_W)) : fxp_flags_none();
    acc_next   = ACC_W'(fxp_sat(raw_next, uint_t'(ACC_W)));

    // ---- rule 2: the counter -----------------------------------------------
    cnt_next = accept ? (cnt_q + WINDOW_W'(1)) : cnt_q;
    close    = accept && (cnt_next >= WL);
  end

  // A flush emits only if the open window actually contains something. Emitting
  // an empty window would be a result covering zero samples, which no consumer
  // can use and which would break the window_id sequence for no information.
  wire flush_emit = flush && !close && (cnt_next != '0);

  // A boundary: any cycle at which no window is open AND none is opening. That
  // is a window closing, a flush, or the idle state between windows — but NOT
  // the cycle in which the first sample of a new window is accepted, because
  // that cycle is the window opening and the configuration that governed the
  // accept is the configuration the window must run under.
  //
  // Both terms are load-bearing.
  //
  //   The IDLE term: without it, a block disabled by `cfg_enable` accepts no
  //   samples, so no window ever closes, so no boundary ever occurs, so the
  //   enable can never be latched high again — the register plane could disable
  //   a pair and never get it back without a flush.
  //
  //   The `!accept` term: without it, a length written in the very cycle the
  //   first sample of a window arrives would latch while that sample is being
  //   counted, so the window would run to a length that was never in force when
  //   it opened. The visible symptom is a window that overshoots its own length
  //   and is reported truncated without having been flushed — which is exactly
  //   what sim/assertions/covar_assertions.sv's
  //   a_covar_truncated_implies_flushed caught during bring-up.
  wire boundary = close || flush || ((cnt_q == '0) && !accept);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wl_q          <= cfg_window_len;
      mode_q        <= cfg_mode;
      k_q           <= cfg_exp_k;
      en_q          <= cfg_enable;
      acc_q         <= '0;
      cnt_q         <= '0;
      wid_q         <= '0;
      out_valid_q   <= 1'b0;
      out_acc_q     <= '0;
      out_wid_q     <= '0;
      out_cnt_q     <= '0;
      out_flushed_q <= 1'b0;
      out_trunc_q   <= 1'b0;
    end else begin
      // ---- results ---------------------------------------------------------
      out_valid_q   <= close || flush_emit;
      out_acc_q     <= acc_next;
      out_wid_q     <= wid_q;
      out_cnt_q     <= cnt_next;
      out_flushed_q <= flush && (close || flush_emit);
      out_trunc_q   <= (close || flush_emit) && (cnt_next != WL);

      // ---- state -----------------------------------------------------------
      if (flush) begin
        // Section 3: identical to one cycle after reset release.
        acc_q <= '0;
        cnt_q <= '0;
        wid_q <= '0;
      end else if (close) begin
        // Block mode restarts the sum; exponential mode carries y forward.
        acc_q <= (mode_q == COVAR_MODE_EXP) ? acc_next : ACC_W'(0);
        cnt_q <= '0;
        wid_q <= wid_q + COVAR_WINDOW_ID_W'(1);
      end else begin
        acc_q <= acc_next;
        cnt_q <= cnt_next;
      end

      // ---- active configuration --------------------------------------------
      if (boundary) begin
        wl_q   <= cfg_window_len;
        mode_q <= cfg_mode;
        k_q    <= cfg_exp_k;
        en_q   <= cfg_enable;
      end
    end
  end

  assign valid_out    = out_valid_q;
  assign acc_out      = out_acc_q;
  assign window_id    = out_wid_q;
  assign sample_count = out_cnt_q;
  assign flushed      = out_flushed_q;
  assign truncated    = out_trunc_q;

  assign obs_acc        = acc_q;
  assign obs_count      = cnt_q;
  assign obs_window_len = WL;
  assign obs_mode       = mode_q;
  assign obs_exp_k      = k_q;
  assign obs_enable     = en_q;

  // ---------------------------------------------------------------------------
  // Sticky saturation (section 1). The project's one collector; `flush` clears
  // it for the same reason it clears the window id — flush means fresh start.
  // ---------------------------------------------------------------------------
  fxp_sticky_flags #(
      .COUNT_W (SAT_COUNT_W)
  ) u_sticky (
      .clk          (clk),
      .rst_n        (rst_n),
      .clear        (sat_clear || flush),
      .valid        (accept),
      .flags_in     (step_flags),
      .flags_sticky (sat_flags),
      .any_sticky   (sat_sticky),
      .event_count  (sat_count)
  );

  // ---------------------------------------------------------------------------
  // SPEC 14 property set. Instantiated here rather than bound from a test, so
  // the window contract holds wherever this module is used.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  covar_assertions #(
      .WINDOW_W (WINDOW_W),
      .ACC_W    (ACC_W)
  ) u_chk (
      .clk          (clk),
      .rst_n        (rst_n),
      .flush        (flush),
      .valid_out    (valid_out),
      .flushed      (flushed),
      .truncated    (truncated),
      .window_id    (window_id),
      .sample_count (sample_count),
      .acc_out      (acc_out),
      .active_len   (obs_window_len),
      .enable       (obs_enable)
  );
`endif

endmodule : integrator

`default_nettype wire
