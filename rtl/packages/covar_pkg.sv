// -----------------------------------------------------------------------------
// covar_pkg — geometry and numerics of the power / covariance engine (SPEC.md
// 7.6, issue #13).
//
// SPEC 7.6 asks for `Power = I^2 + Q^2`, a configurable cross-power
// `Rxy = X * conj(Y)` over selected antenna or beam pairs, a programmable
// integration window, accumulator protection, window-boundary metadata,
// optional exponential averaging, per-pair runtime enable and deterministic
// reset/flush. This package is the one place where the WIDTHS and the WINDOW
// ARITHMETIC of that block are defined; the rounding, saturation and growth
// RULES stay in fxp_pkg, which this package calls and never duplicates.
//
// Naming (DECISIONS.md, issue #10 decision 9 / issue #11 decision 13)
// ------------------------------------------------------------------
// The integer helper type is `covar_uint_t`, NOT `uint_t`. `fxp_pkg`, and
// `stream_pkg` each export a type of that name; a third one collides under
// Quartus Prime Pro ("visible via multiple package imports") in any module that
// imports two of them, which Verilator accepts silently. One package, one
// spelling.
//
// -----------------------------------------------------------------------------
// 1. Why POWER_W is 40, exactly
// -----------------------------------------------------------------------------
// SPEC 3 fixes `POWER_W = 40`. That number is not a round-up: it is 32 bits of
// single-sample magnitude plus 8 bits of integration growth, and both halves are
// forced by the Q1.15 input format.
//
// ONE SAMPLE. With I, Q in Q1.15 (16-bit signed, |x| <= 2^15):
//
//     power   = I^2 + Q^2                     <= 2*(2^15)^2 = 2^31
//     Rxy.re  = Xr*Yr + Xi*Yi                 |.| <= 2^31
//     Rxy.im  = Xi*Yr - Xr*Yi                 |.| <= 2^31
//
// The extreme is real and reachable: I = Q = -32768 gives power = 2^31 exactly,
// and it is the first case any reviewer tries. 2^31 does not fit a signed 32-bit
// field, so a single power sample needs 33 signed bits (or 32 unsigned). This is
// the same "the sum of two Q2.30 products is not Q2.30" fact that made
// complex_multiplier's full-precision port 33 bits wide (DECISIONS.md, issue #9
// decision 1), and it is why COVAR_PROD_W below is that module's port width
// rather than a new constant.
//
// N SAMPLES. An N-sample integration of terms bounded by 2^31 is bounded by
// N * 2^31. A signed w-bit accumulator holds that without clamping iff
//
//     N * 2^31 <= 2^(w-1) - 1        i.e.        N <= 2^(w-32) - 1        (*)
//
// (the negative side is looser by one, so the positive bound governs). At
// w = POWER_W = 40 that is N <= 255. So:
//
//     POWER_W = 40  =  32 (one exact sample)  +  8 (integration growth)
//     -> the 40-bit accumulator is PROVABLY exact for every window up to 255
//        samples, whatever the input.
//
// At N = 256 the bound is missed by exactly one LSB, and only by the single
// input sequence in which every sample is the extreme above — e.g. 256 copies of
// X = Y = (-32768, -32768), whose cross-power real part sums to exactly +2^39
// against a maximum of 2^39 - 1. That case is a directed test
// (sim/tests/test_covariance.cpp, "accumulator saturation"), not a hypothetical:
// it is the cheapest proof that the saturation path and its sticky flag work.
//
// Beyond 255 the accumulator SATURATES (fxp_pkg::fxp_sat, clamp never wrap) and
// raises a sticky flag, per SPEC 6 and the standing rule that a wrapped power
// estimate is indistinguishable from a target to the CFAR stage downstream.
//
// covar_acc_w_required() and covar_window_max_exact() below are (*) in both
// directions, so a design that wants a longer exact window widens the
// accumulator by calling the function rather than by guessing.
//
// -----------------------------------------------------------------------------
// 2. Integration modes
// -----------------------------------------------------------------------------
// COVAR_MODE_BLOCK  — acc += x for WINDOW samples, emit, reset to 0. The SPEC
//                     7.6 "programmable integration window".
// COVAR_MODE_EXP    — y += (x - y) >>> k, evaluated per sample; the running y
//                     is emitted at every window boundary and is NOT cleared
//                     there. The SPEC 7.6 "optional exponential averaging".
//
// The shift is fxp_pkg::fxp_trunc — arithmetic right shift, round toward
// -infinity — and that choice is deliberate rather than inherited. See
// integrator.sv section 4 and DECISIONS.md (issue #13) for the fixed-point
// consequences, which are exactly reproducible and are checked against the C++
// model rather than against a tolerance.
//
// Lint contract: linted by `make lint` on every run, clean under --Wall with no
// waiver.
// -----------------------------------------------------------------------------

`default_nettype none

package covar_pkg;

  // ---------------------------------------------------------------------------
  // Working type
  // ---------------------------------------------------------------------------

  // Unsigned 32-bit integer, so widths and counts can be cast explicitly
  // (`covar_uint_t'(x)`); `int unsigned'(x)` is not legal cast syntax. Same
  // device as fxp_pkg::uint_t and stream_pkg::uint_t, deliberately spelled
  // differently — see the naming note at the top of this file.
  typedef int unsigned covar_uint_t;

  // ---------------------------------------------------------------------------
  // Widths (SPEC 3, SPEC 6)
  // ---------------------------------------------------------------------------

  // SPEC 3 POWER_W. The width of every accumulator and every result port in this
  // block. Section 1 above is the derivation; it is 40 because 32 + 8 = 40, not
  // because 40 was available.
  localparam int unsigned COVAR_POWER_W = 40;

  // Bits a single term occupies, unsigned-magnitude style: |term| <= 2^31 needs
  // 31 magnitude bits plus a sign, i.e. the accumulator's "zero-growth" width.
  // This is the 32 in equation (*).
  localparam int unsigned COVAR_TERM_W = fxp_pkg::FXP_PROD_W;  // 32

  // Programmable exponential-averaging shift, k in [0, covar_exp_k_max()].
  localparam int unsigned COVAR_EXP_K_W = 4;

  // Integration mode encoding. One bit today; an enum so a third mode is a
  // named addition rather than a magic 2.
  typedef enum logic {
    COVAR_MODE_BLOCK = 1'b0,
    COVAR_MODE_EXP   = 1'b1
  } covar_mode_e;

  // ---------------------------------------------------------------------------
  // Accumulator sizing — equation (*) of section 1, in both directions
  // ---------------------------------------------------------------------------

  // Signed accumulator width that holds an N-term sum of values bounded by 2^31
  // without ever clamping. Inverse of covar_window_max_exact().
  //
  //   N <= 2^(w-32) - 1   <=>   w >= 32 + ceil(log2(N + 1))
  //
  // $clog2(N+1) is ceil(log2(N+1)) for N >= 1, which is the +1 that makes the
  // bound exact rather than one-bit optimistic at the powers of two.
  function automatic covar_uint_t covar_acc_w_required(input covar_uint_t n_samples);
    covar_uint_t n;
    n = (n_samples == 32'd0) ? 32'd1 : n_samples;
    covar_acc_w_required = COVAR_TERM_W + covar_uint_t'($clog2(n + 32'd1));
  endfunction

  // Longest window a signed `acc_w`-bit accumulator integrates exactly, for any
  // input. Returns 0 for a degenerate width.
  function automatic covar_uint_t covar_window_max_exact(input covar_uint_t acc_w);
    if (acc_w <= COVAR_TERM_W) covar_window_max_exact = 32'd0;
    else if (acc_w >= COVAR_TERM_W + 32'd31) covar_window_max_exact = 32'hFFFF_FFFF;
    else covar_window_max_exact = (32'd1 << (acc_w - COVAR_TERM_W)) - 32'd1;
  endfunction

  // True when a window of `n_samples` is provably exact in `acc_w` bits.
  function automatic logic covar_window_is_exact(input covar_uint_t acc_w,
                                                 input covar_uint_t n_samples);
    covar_window_is_exact = (n_samples <= covar_window_max_exact(acc_w));
  endfunction

  // ---------------------------------------------------------------------------
  // Window-boundary metadata (SPEC 7.6 "window-boundary metadata")
  //
  // Travels with every emitted result. The point of carrying the sample count
  // rather than assuming the programmed length is that a FLUSHED window is
  // short by construction, and a consumer that normalises by the window length
  // must be told which length actually applied. `flushed` says the drain was
  // software-initiated; `truncated` says the window did not reach its
  // programmed length. They are different questions and are kept apart:
  // a flush that lands exactly on a boundary is flushed and NOT truncated.
  // ---------------------------------------------------------------------------
  localparam int unsigned COVAR_WINDOW_ID_W = 16;

  // Width of the programmable window length and of the sample counter.
  localparam int unsigned COVAR_WINDOW_LEN_W = 16;

  // ---------------------------------------------------------------------------
  // Constants exported as FUNCTIONS rather than as localparams
  //
  // Same device, for the same measured reason, as stream_pkg's latency
  // constants: `verilator --lint-only --Wall` reports a package localparam that
  // a given build happens not to reference as a dead parameter, and this package
  // is deliberately lintable one top at a time (files_covar.f, files_control.f,
  // files.f). A function is available to every build and dead in none.
  // ---------------------------------------------------------------------------

  // Exact width of one product term: complex_multiplier's full-precision port,
  // FXP_PROD_W + 1 = 33 signed bits, holding |v| <= 2^31. Written in terms of
  // fxp_pkg so it moves if the sample format ever does.
  function automatic covar_uint_t covar_prod_w();
    covar_prod_w = covar_uint_t'(fxp_pkg::FXP_PROD_W) + 32'd1;
  endfunction

  // Function forms of the three widths above. They exist because the localparam
  // forms are referenced only from the covariance modules' port declarations and
  // parameter defaults, and a build that lists those modules without
  // INSTANTIATING them — files.f, which lints the whole design against
  // benchmark_sim_top — then reports the localparams as dead parameters. A
  // function is available to every build and dead in none, and referencing the
  // localparam from its body is what makes the localparam "used" in every build
  // as well. Callers may use either form; the localparam is the definition.
  function automatic covar_uint_t covar_power_w();
    covar_power_w = covar_uint_t'(COVAR_POWER_W);
  endfunction

  function automatic covar_uint_t covar_window_id_w();
    covar_window_id_w = covar_uint_t'(COVAR_WINDOW_ID_W);
  endfunction

  function automatic covar_uint_t covar_window_len_w();
    covar_window_len_w = covar_uint_t'(COVAR_WINDOW_LEN_W);
  endfunction

  // Largest legal exponential-averaging shift.
  function automatic covar_uint_t covar_exp_k_max();
    covar_exp_k_max = (32'd1 << COVAR_EXP_K_W) - 32'd1;  // 15
  endfunction

  // Register-plane reset values, mirrored from control/regmap.json. Exported so
  // the RTL and the generated register map can be compared at elaboration
  // instead of by inspection.
  function automatic covar_uint_t covar_window_len_default();
    covar_window_len_default = 32'd16;
  endfunction

  function automatic covar_uint_t covar_exp_k_default();
    covar_exp_k_default = 32'd3;
  endfunction

  // Source-index width in the pair table. 8 bits covers 256 antenna or beam
  // streams against the 16 of SPEC 3's full-scale configuration.
  function automatic covar_uint_t covar_src_sel_w();
    covar_src_sel_w = 32'd8;
  endfunction

endpackage : covar_pkg

`default_nettype wire
