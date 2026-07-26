// -----------------------------------------------------------------------------
// beamformer_pkg — shared geometry, accumulator width and latency arithmetic for
// the beamforming matrix (SPEC.md 7.5, issue #12).
//
// The dot product, the weight bank, the matrix and the C++ model all have to
// agree about four things that are easy to get subtly inconsistent and
// impossible to notice from a waveform:
//
//   1. ACCUMULATOR WIDTH. One place, derived from fxp_pkg's own accumulator
//      policy, never written as a number. A 16-antenna complex dot product is,
//      on each output component, a sum of 2*N_ANT Q1.15 x Q1.15 real products,
//      so the width is fxp_mac_q15_acc_w(2*N_ANT) and the accumulation
//      PROVABLY cannot overflow. That is what makes "round once, at the end"
//      legal rather than merely convenient.
//   2. LATENCY. Every register in this kernel is free-running, so unlike the
//      polyphase bank (rtl/packages/pfb_pkg.sv, "Beats and cycles") the latency
//      is a pure CYCLE count with no beat-measured component -- there is no
//      sample history anywhere in a beamformer. That simplification is real and
//      is stated here so nobody goes looking for the other half.
//   3. THE TIME-MULTIPLEX FACTOR. SPEC 7.5: "Do not silently reduce throughput
//      to meet utilization. Any time multiplexing must be visible in parameters
//      and reported throughput." bf_beam_mux() is that factor, it is derived
//      from the parameters rather than chosen, and rtl/beamformer/beamformer.sv
//      exports it on a port so the register plane can read it back.
//   4. THE WEIGHT INDEX. One flat address space, beam-major and antenna-minor,
//      shared by the register plane, the RTL and the C++ model.
//
// Nothing here is a design size. The sizes are SPEC 11 configuration values
// (N_ANTENNAS, N_BEAMS) and reach the RTL as elaboration parameters.
//
// -----------------------------------------------------------------------------
// The adder-tree pipelining parameter (read this before changing a latency)
// -----------------------------------------------------------------------------
// The dot product sums N_ANT exact 33-bit complex partial products through a
// balanced binary tree of ceil(log2 N_ANT) levels. How many of those levels get
// a register is a cost/Fmax trade and therefore a PARAMETER, not a constant:
//
//   ADD_REG_EVERY = 1   a register after every level. clog2(N_ANT) registered
//                       levels; one adder per register stage; the shortest
//                       combinational path and the most flip-flops.
//   ADD_REG_EVERY = 2   a register after every second level. Half the register
//                       stages; two adders (an ACC_W-bit carry chain traversed
//                       twice) between registers.
//
// bf_tree_regs() computes the resulting stage count for any stride, so the
// latency moves with the parameter instead of being a table a caller looks up.
// SPEC 18 item 6 sweeps the two values on a 16-antenna dot product and
// DECISIONS.md carries the outcome; until that data existed the default was 1,
// for the honest reason that a register per level is the structure whose cost is
// predictable without knowing what the retimer will do with it.
//
// Note what the parameter does NOT change: the arithmetic. There is no
// saturation anywhere inside the tree (point 1 above), so integer addition is
// associative and every stride computes the same integer. The sweep is a pure
// cost comparison, exactly as ACC_STYLE is for the FIR lane.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

package beamformer_pkg;

  // Unsigned 32-bit integer type, so widths can be cast explicitly
  // (`bf_uint_t'(x)`); `int unsigned'(x)` is not legal cast syntax.
  //
  // NAMED DIFFERENTLY from fxp_pkg::uint_t, stream_pkg::uint_t and
  // pfb_pkg::pfb_uint_t, and that is not a style choice. A module that
  // wildcard-imports two packages which both declare the same type name has an
  // AMBIGUOUS name under IEEE 1800 26.3, and Quartus Prime Pro rejects it
  // outright ("visible via multiple package imports") while Verilator accepts it
  // silently -- so lint alone would never catch it. That cost issue #10 a failed
  // calibration compile (DECISIONS.md, issue #10 decision 13), and
  // rtl/beamformer/beamformer.sv imports fxp_pkg, stream_pkg and this package at
  // once.
  typedef int unsigned bf_uint_t;

  // ---------------------------------------------------------------------------
  // Bounds on the parameterisation
  //
  // Not design sizes: bounds, so that an out-of-range elaboration fails at time
  // 0 with a name rather than producing a design that is merely wrong. Sized
  // from SPEC 7.5 ("up to 16 antennas", "up to 16 beams", "eight frequency bins
  // per cycle") with one binary octave of headroom.
  //
  // Exported as FUNCTIONS rather than as localparams, and for the reason
  // stream_pkg and pfb_pkg give for the same choice: a package localparam that a
  // given build happens not to instantiate is reported as a dead parameter by
  // `verilator --lint-only --Wall`, and this design is meant to be lintable one
  // top at a time. A function is available to every build and dead in none.
  // ---------------------------------------------------------------------------
  function automatic bf_uint_t bf_max_antennas();
    return 32'd32;
  endfunction

  function automatic bf_uint_t bf_max_beams();
    return 32'd32;
  endfunction

  function automatic bf_uint_t bf_max_bin_par();
    return 32'd16;
  endfunction

  function automatic bf_uint_t bf_max_beam_par();
    return 32'd32;
  endfunction

  // ---------------------------------------------------------------------------
  // Accumulator width (SPEC 6 "Accumulator widths", via fxp_pkg)
  //
  //     Y[b] = sum over a of X[a] * W[b][a]
  //
  // The real component of that sum is
  //     sum_a (X[a].re*W[b][a].re - X[a].im*W[b][a].im)
  // which is 2*N_ANT Q1.15 x Q1.15 product terms. fxp_pkg's policy gives the
  // width as FXP_PROD_W + ceil(log2(2*N_ANT)), and the policy's guarantee
  // follows: the accumulation provably cannot overflow, so there is NO
  // intermediate saturation anywhere in a dot product. The only quantisation is
  // the single round-and-saturate at the output.
  //
  // For N_ANT = 16 that is 32 + 5 = 37 bits. The task statement's "grows
  // log2(16) = 4 bits over the product width" counts the growth over the
  // 33-bit EXACT complex product (which is itself one bit over FXP_PROD_W,
  // because the sum of two Q2.30 products does not fit 32 bits -- see
  // rtl/common/complex_multiplier.sv section 1). 33 + 4 = 37. The two
  // derivations agree, and this one is the one the package can compute.
  // ---------------------------------------------------------------------------
  function automatic bf_uint_t bf_acc_w(input bf_uint_t n_ant);
    return bf_uint_t'(fxp_pkg::fxp_mac_q15_acc_w(fxp_pkg::uint_t'(2 * n_ant)));
  endfunction

  // Width of the exact per-antenna complex product carried into the tree. This
  // is complex_multiplier's full-precision port: FXP_PROD_W + 1, i.e. the
  // two-term MAC width, because the sum of two Q2.30 products reaches +2^31.
  function automatic bf_uint_t bf_prod_w();
    return bf_uint_t'(fxp_pkg::fxp_mac_q15_acc_w(fxp_pkg::uint_t'(2)));
  endfunction

  // ---------------------------------------------------------------------------
  // Adder-tree geometry
  // ---------------------------------------------------------------------------

  // Levels in a balanced binary adder tree over `n` leaves. clog2(1) = 0: a
  // one-antenna dot product has no tree and no tree register.
  function automatic bf_uint_t bf_tree_levels(input bf_uint_t n);
    return (n <= 1) ? 32'd0 : bf_uint_t'($clog2(n));
  endfunction

  // Leaves after padding to a power of two. The padding leaves are constant zero
  // and optimise away; they exist so the tree is one uniform generate loop
  // rather than a ragged special case at every level.
  function automatic bf_uint_t bf_tree_leaves(input bf_uint_t n);
    return (n <= 1) ? 32'd1 : (32'd1 << bf_tree_levels(n));
  endfunction

  // Registered stages in the tree for a given pipelining stride: a register is
  // placed after level l when l is a multiple of `reg_every`, and unconditionally
  // after the last level so the tree's output is always registered. That last
  // clause is what makes the count ceil(levels / reg_every) rather than
  // floor(...), and it is why the output of the tree is a legal thing to hand to
  // the quantisation network without a further register.
  function automatic bf_uint_t bf_tree_regs(input bf_uint_t n_ant,
                                            input bf_uint_t reg_every);
    bf_uint_t lv, re;
    lv = bf_tree_levels(n_ant);
    re = (reg_every == 32'd0) ? 32'd1 : reg_every;
    return (lv + re - 32'd1) / re;
  endfunction

  function automatic logic bf_reg_every_ok(input bf_uint_t reg_every);
    return (reg_every >= 32'd1) && (reg_every <= 32'd4);
  endfunction

  // ---------------------------------------------------------------------------
  // Latency
  //
  // ALL CYCLES, NO BEATS. Every register in this kernel combines values from the
  // SAME beat -- there is no sample history in a beamformer, only a weighted sum
  // across the antenna dimension of one beat -- so every register free-runs and
  // the latency is a pure cycle count. Contrast rtl/packages/pfb_pkg.sv, whose
  // FIR delay line forces a two-unit latency. A consumer of this block delays
  // metadata by bf_lat_cycles() CYCLES and nothing else.
  // ---------------------------------------------------------------------------

  // rtl/beamformer/bf_dot.sv: the multiplier, the registered tree levels, and
  // the output register that holds the rounded result and its flags. The final
  // +1 is that output register, and it is there for the reason SPEC 23 gives and
  // issue #9 measured: rounding and saturating a 37-bit accumulator to Q1.15 is
  // about a hundred ALMs and half the achievable clock, and it must not be on
  // the path into whatever consumes the dot product.
  function automatic bf_uint_t bf_dot_lat(input bf_uint_t n_ant,
                                          input bf_uint_t mult_pipe,
                                          input bf_uint_t reg_every);
    return mult_pipe + bf_tree_regs(n_ant, reg_every) + 32'd1;
  endfunction

  // rtl/beamformer/beamformer.sv: the block's input hold register (which is also
  // what the beam time-multiplex issues from) plus the dot product.
  function automatic bf_uint_t bf_lat_cycles(input bf_uint_t n_ant,
                                             input bf_uint_t mult_pipe,
                                             input bf_uint_t reg_every);
    return 32'd1 + bf_dot_lat(n_ant, mult_pipe, reg_every);
  endfunction

  // Upper bound on the number of OUTPUT beats simultaneously inside the block.
  // Each free-running stage can hold at most one, so the cycle latency bounds
  // the in-flight count. beamformer.sv sizes its credit counter and its output
  // elastic buffer from this, which is what makes "the internal pipeline never
  // stalls" a structural fact rather than a hope.
  function automatic bf_uint_t bf_inflight_beats(input bf_uint_t n_ant,
                                                 input bf_uint_t mult_pipe,
                                                 input bf_uint_t reg_every);
    return bf_lat_cycles(n_ant, mult_pipe, reg_every);
  endfunction

  // ---------------------------------------------------------------------------
  // Time multiplexing (SPEC 7.5, "any time multiplexing must be visible in
  // parameters and reported throughput")
  //
  // The engine builds BIN_PAR x BEAM_PAR dot products. If BEAM_PAR < N_BEAMS the
  // remaining beams are computed on later cycles from the SAME held input beat,
  // in bf_beam_mux() groups of BEAM_PAR. The consequences, all of them visible:
  //
  //   input beats per cycle  = 1 / bf_beam_mux()
  //   output beats per cycle = 1                  (one group per cycle)
  //   bins   per input beat  = BIN_PAR
  //   beams  per output beat = BEAM_PAR
  //
  // So the block sustains BIN_PAR bins/cycle only when bf_beam_mux() == 1. That
  // sentence is the throughput statement SPEC 7.5 demands, it is derived from
  // the parameters rather than asserted, and beamformer.sv exports all five
  // numbers on ports so it can be read back rather than believed.
  //
  // THE MULTIPLEX FACTOR IS A POWER OF TWO, and that is a real restriction with
  // a real payoff: the output sequence number is {input_seq, group}, which is a
  // free concatenation, is continuous beat to beat (which the SPEC 5 protocol
  // checker requires), and is invertible -- a consumer recovers the input beat
  // and the beam group by slicing. A non-power-of-two factor would need a
  // multiply-accumulate on the sequence field and would break the slice.
  // ---------------------------------------------------------------------------
  function automatic bf_uint_t bf_beam_mux(input bf_uint_t n_beams,
                                           input bf_uint_t beam_par);
    return (beam_par == 32'd0) ? 32'd1 : (n_beams / beam_par);
  endfunction

  // Width of the beam-group index. At least 1, because a zero-width field is not
  // a legal port or slice even when the only legal value is zero.
  function automatic bf_uint_t bf_grp_w(input bf_uint_t beam_mux);
    return (beam_mux <= 1) ? 32'd1 : bf_uint_t'($clog2(beam_mux));
  endfunction

  // Number of bits the output sequence field is shifted left by, i.e. the number
  // of low bits the beam group occupies. ZERO when there is no multiplexing, so
  // the sequence number passes through unchanged in the un-multiplexed case.
  function automatic bf_uint_t bf_seq_shift(input bf_uint_t beam_mux);
    return (beam_mux <= 1) ? 32'd0 : bf_uint_t'($clog2(beam_mux));
  endfunction

  function automatic logic bf_is_pow2(input bf_uint_t n);
    return (n != 32'd0) && ((n & (n - 32'd1)) == 32'd0);
  endfunction

  // ---------------------------------------------------------------------------
  // Weight addressing
  //
  // ONE FLAT ADDRESS SPACE across the whole matrix: {beam, antenna}, beam-major
  // and antenna-minor. The register plane writes one weight per transaction and
  // does not need to know how the beams are distributed across engine groups,
  // and the ordering matches the weight files
  // scripts/generate_coefficients.py writes, so a bank is loaded by counting up
  // from zero. Same arrangement, and the same reasoning, as
  // pfb_pkg::pfb_coeff_index.
  // ---------------------------------------------------------------------------
  function automatic bf_uint_t bf_n_weights(input bf_uint_t n_beams,
                                            input bf_uint_t n_ant);
    return n_beams * n_ant;
  endfunction

  function automatic bf_uint_t bf_weight_addr_w(input bf_uint_t n_beams,
                                                input bf_uint_t n_ant);
    return bf_uint_t'($clog2(n_beams * n_ant));
  endfunction

  function automatic bf_uint_t bf_weight_index(input bf_uint_t n_ant,
                                               input bf_uint_t beam,
                                               input bf_uint_t ant);
    return beam * n_ant + ant;
  endfunction

  // ---------------------------------------------------------------------------
  // Weight banks. Two, always: SPEC 7.5 requires double buffering and the number
  // is not a parameter, because "which bank is active" is a single bit
  // everywhere in the design and a third bank would change the register map.
  // Deliberately the same answer, for the same reason, as pfb_pkg::pfb_n_banks.
  // ---------------------------------------------------------------------------
  function automatic bf_uint_t bf_n_banks();
    return 32'd2;
  endfunction

  // ---------------------------------------------------------------------------
  // Payload geometry (SPEC 5, and the contract ARCHITECTURE.md states in prose)
  //
  //   INPUT   one beat carries BIN_PAR consecutive frequency bins, each as a
  //           vector of N_ANT complex Q1.15 samples. Bin-major, antenna-minor:
  //           sample (bin j, antenna a) occupies
  //               data[(j*N_ANT + a) * 2*FXP_SAMPLE_W +: 2*FXP_SAMPLE_W]
  //           packed {im, re}. With BIN_PAR = 1 this is exactly "one beat is one
  //           bin's aligned antenna vector", which is what issue #16's frequency
  //           alignment network produces.
  //
  //   OUTPUT  one beat carries BIN_PAR bins x BEAM_PAR beams of one beam group.
  //           Beam-major, bin-minor -- the transpose of the input's nesting,
  //           because the output's slow axis is the beam and the input's is the
  //           bin:
  //               data[(k*BIN_PAR + j) * 2*FXP_SAMPLE_W +: 2*FXP_SAMPLE_W]
  //           is beam group*BEAM_PAR + k at bin j.
  //
  // These two functions are the normative statement of those widths; every
  // instance's port width is checked against them at elaboration.
  // ---------------------------------------------------------------------------
  function automatic bf_uint_t bf_sample_pair_w();
    return bf_uint_t'(2 * fxp_pkg::FXP_SAMPLE_W);
  endfunction

  function automatic bf_uint_t bf_in_data_w(input bf_uint_t bin_par,
                                            input bf_uint_t n_ant);
    return bin_par * n_ant * bf_sample_pair_w();
  endfunction

  function automatic bf_uint_t bf_out_data_w(input bf_uint_t bin_par,
                                             input bf_uint_t beam_par);
    return bin_par * beam_par * bf_sample_pair_w();
  endfunction

endpackage : beamformer_pkg

`default_nettype wire
