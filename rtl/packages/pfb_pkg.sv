// -----------------------------------------------------------------------------
// pfb_pkg — shared parameters, latency arithmetic and storage-style policy for
// the polyphase FIR bank (SPEC.md 7.1, issue #10).
//
// The FIR lane, the coefficient bank, the delay line and the polyphase bank all
// have to agree about three things that are easy to get subtly inconsistent and
// impossible to notice from a waveform:
//
//   1. ACCUMULATOR WIDTH. One place, derived from fxp_pkg's own accumulator
//      policy, never written as a number.
//   2. LATENCY. A FIR lane's latency is NOT one number. Depending on the
//      accumulation style it is partly measured in CYCLES (free-running
//      register stages) and partly in BEATS (stages that advance only when a
//      sample is admitted). Both halves are computed here so the lane, the bank
//      and the C++ model cannot disagree about the alignment of a result with
//      its metadata. See "Beats and cycles" below — this is the single most
//      load-bearing paragraph in the whole issue.
//   3. STORAGE STYLE. Whether a delay line is a shift register (ALM/MLAB) or a
//      memory (M20K) is a threshold decision, and the threshold lives here so
//      that every delay line in the design makes the same choice for the same
//      reason.
//
// Nothing here is a design size. The sizes are SPEC 11 configuration values
// (SAMPLES_PER_CYCLE, PFB_TAPS) and reach the RTL as elaboration parameters.
//
// -----------------------------------------------------------------------------
// Beats and cycles (read this before changing any latency)
// -----------------------------------------------------------------------------
// A FIR delay line must advance ONCE PER SAMPLE, not once per clock. The SPEC 5
// stream can present gaps, so the lane's history registers carry an enable
// (`en = a beat is admitted this cycle`). Anything downstream that combines
// values from DIFFERENT beats must therefore also advance once per beat, while
// anything that combines values from the SAME beat may free-run.
//
//   ACC_STYLE = "TREE"      A balanced adder tree sums the TAPS products of ONE
//                           beat. Every node combines same-beat values, so every
//                           tree register free-runs and the whole lane has a
//                           pure CYCLE latency:
//                               beats  = 0
//                               cycles = MULT_PIPE + clog2(TAPS) + 1
//
//   ACC_STYLE = "SYSTOLIC"  A linear cascade — the DSP-chainin shape — in which
//                           stage k adds its product to the PREVIOUS BEAT's
//                           partial sum. That is a cross-beat combination, so
//                           every cascade register carries the beat enable, and
//                           the lane's latency is partly measured in beats:
//                               beats  = TAPS - 1
//                               cycles = MULT_PIPE + 2
//                           The two cycles are the cascade register itself and
//                           the lane's output register. The cascade's OTHER
//                           TAPS-1 registers are the beat-measured half: a beat
//                           passes through one of them per beat, not per clock.
//
// Both styles compute the SAME INTEGER for the same beat sequence; they differ
// only in when it appears and in what it costs. That is the comparison SPEC 18
// asks for and the reason both exist.
//
// The consequence for a consumer: metadata belonging to a sample must be delayed
// by pfb_lat_beats() BEATS and then by pfb_lat_cycles() CYCLES. Delaying by the
// sum of the two in either unit is wrong under backpressure, and is the defect
// this package exists to prevent.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

package pfb_pkg;

  // Unsigned 32-bit integer type, so widths can be cast explicitly
  // (`pfb_uint_t'(x)`); `int unsigned'(x)` is not legal cast syntax. Declared
  // here rather than imported from fxp_pkg because a package import does NOT
  // re-export into the importer's namespace, so `import pfb_pkg::*` in a module
  // would not bring fxp_pkg::uint_t with it.
  //
  // NAMED DIFFERENTLY from fxp_pkg::uint_t and stream_pkg::pfb_uint_t on purpose.
  // A module that wildcard-imports two packages which both declare `pfb_uint_t` has
  // an AMBIGUOUS name, and IEEE 1800 26.3 says so: Quartus Prime Pro rejects it
  // outright ("pfb_uint_t is visible via multiple package imports"), which is how
  // this was found -- the first calibration compile failed to elaborate.
  // The simulator accepts it silently, so lint alone would never have caught it.
  // rtl/pfb/pfb_bank.sv imports fxp_pkg, stream_pkg and this package at once,
  // and a third `pfb_uint_t` would have made the collision unfixable without
  // qualifying every use site.
  typedef int unsigned pfb_uint_t;

  // ---------------------------------------------------------------------------
  // Bounds on the parameterisation
  //
  // Not design sizes: bounds, so that an out-of-range elaboration fails at time
  // 0 with a name rather than producing a design that is merely wrong. Sized
  // from SPEC 11 full_agmf039 (SAMPLES_PER_CYCLE 8, PFB_TAPS 16) with headroom.
  // ---------------------------------------------------------------------------
  // Exported as FUNCTIONS rather than as localparams, and for the reason
  // stream_pkg gives for the same choice: a package localparam that a given
  // build happens not to instantiate is reported as a dead parameter by
  // `verilator --lint-only --Wall`, and this design is meant to be lintable one
  // top at a time (files.f, files_pfb.f, files_cmult.f, ...). A function is
  // available to every build and dead in none.
  function automatic pfb_uint_t pfb_max_taps();
    return 32'd64;
  endfunction

  function automatic pfb_uint_t pfb_max_phases();
    return 32'd16;
  endfunction

  // ---------------------------------------------------------------------------
  // Accumulator width (SPEC 6 "Accumulator widths", via fxp_pkg)
  //
  // A TAPS-tap COMPLEX FIR is, on each output component, a sum of 2*TAPS
  // Q1.15 x Q1.15 real products: the real output is
  //     sum_k (h_k.re*x_k.re - h_k.im*x_k.im)
  // which is 2*TAPS product terms. fxp_pkg's policy gives the width, and the
  // policy's guarantee follows: the accumulation provably cannot overflow, so
  // there is NO intermediate saturation anywhere in a lane. The only
  // quantisation is the single round-and-saturate at the lane output.
  //
  // That is also why the adder tree and the systolic cascade are bit-identical:
  // integer addition is associative, and nothing in between clamps.
  // ---------------------------------------------------------------------------
  function automatic pfb_uint_t pfb_acc_w(input pfb_uint_t taps);
    return pfb_uint_t'(fxp_pkg::fxp_mac_q15_acc_w(fxp_pkg::uint_t'(2 * taps)));
  endfunction

  // Number of levels in a balanced binary adder tree over `taps` leaves.
  // clog2(1) = 0: a one-tap lane has no tree and no tree register.
  function automatic pfb_uint_t pfb_tree_levels(input pfb_uint_t taps);
    return (taps <= 1) ? 32'd0 : pfb_uint_t'($clog2(taps));
  endfunction

  // Leaves after padding to a power of two. The padding leaves are constant
  // zero and optimise away; they exist so the tree is one uniform generate loop
  // rather than a ragged special case at every level.
  function automatic pfb_uint_t pfb_tree_leaves(input pfb_uint_t taps);
    return (taps <= 1) ? 32'd1 : (32'd1 << pfb_tree_levels(taps));
  endfunction

  // ---------------------------------------------------------------------------
  // Latency (see "Beats and cycles" above)
  // ---------------------------------------------------------------------------

  // 1 when ACC_STYLE names the systolic cascade. Written as a function rather
  // than compared inline so there is one spelling of the style name.
  function automatic logic pfb_style_systolic(input string acc_style);
    return (acc_style == "SYSTOLIC");
  endfunction

  function automatic logic pfb_style_ok(input string acc_style);
    return (acc_style == "TREE") || (acc_style == "SYSTOLIC");
  endfunction

  // Beat-measured latency: register stages that advance only when a sample is
  // admitted.
  function automatic pfb_uint_t pfb_lat_beats(input string acc_style,
                                          input pfb_uint_t taps);
    return pfb_style_systolic(acc_style) ? (taps - 32'd1) : 32'd0;
  endfunction

  // Cycle-measured latency: free-running register stages. `mult_pipe` is the
  // complex_multiplier PIPE_STAGES value, which is that module's latency by
  // construction. The final +1 in both branches is the lane's output register,
  // which holds the rounded result and its flags and keeps the rounding network
  // off the path into whatever consumes the lane (SPEC 23).
  //
  // The cascade's extra +1 is its own accumulator register: a beat's LAST
  // partial sum is added at the beat-measured stage and the total is only
  // readable on the cycle after that stage's enable. Getting this wrong shifts
  // every SYSTOLIC result one beat away from its metadata, which is exactly what
  // the sequence-matched scoreboard in sim/tests/test_pfb_bank.cpp catches.
  function automatic pfb_uint_t pfb_lat_cycles(input string acc_style,
                                           input pfb_uint_t taps,
                                           input pfb_uint_t mult_pipe);
    return pfb_style_systolic(acc_style)
             ? (mult_pipe + 32'd2)
             : (mult_pipe + pfb_tree_levels(taps) + 32'd1);
  endfunction

  // Upper bound on the number of beats simultaneously inside a lane. Each
  // free-running cycle stage can hold at most one beat and each beat stage holds
  // exactly one, so the sum bounds the in-flight count. The polyphase bank sizes
  // its credit counter and its output elastic buffer from this, which is what
  // makes "the internal pipeline never stalls" a structural fact rather than a
  // hope.
  function automatic pfb_uint_t pfb_inflight_beats(input string acc_style,
                                               input pfb_uint_t taps,
                                               input pfb_uint_t mult_pipe);
    return pfb_lat_beats(acc_style, taps) +
           pfb_lat_cycles(acc_style, taps, mult_pipe);
  endfunction

  // ---------------------------------------------------------------------------
  // Delay-line geometry
  //
  // A direct-form ("TREE") lane taps the history at every stage: taps 1..TAPS-1
  // are x[n-1] .. x[n-(TAPS-1)], stride 1.
  //
  // A systolic ("SYSTOLIC") lane needs TWO delay stages per tap. That is not an
  // implementation quirk, it is what makes the cascade compute a FIR at all: the
  // partial sum walks forward one stage per beat while the data must walk
  // backward relative to it, so tap k must see x[n-2k]. The delay line is
  // therefore twice as deep, stride 2, and the extra registers are the price of
  // the cascade — one of the numbers the SPEC 18 sweep is there to weigh against
  // the tree's adder cost.
  // ---------------------------------------------------------------------------
  function automatic pfb_uint_t pfb_tap_stride(input string acc_style);
    return pfb_style_systolic(acc_style) ? 32'd2 : 32'd1;
  endfunction

  // ---------------------------------------------------------------------------
  // Delay-line storage-style policy (SPEC 7.1 "Delay lines should infer M20Ks
  // when their size makes that appropriate")
  //
  // THE THRESHOLD, AND THE HONEST ANSWER ABOUT IT
  // ---------------------------------------------
  // A memory can serve ONE read port per cycle. A tapped delay line presents
  // every stage at once, so a tapped line CANNOT be a memory at any depth: the
  // question does not arise. The style choice exists only for a line with a
  // single end tap — a pure delay, such as the metadata alignment path.
  //
  // For a pure delay the threshold is a joint condition on depth and total bits.
  // Depth alone is not enough (a 64-deep 4-bit line is 256 bits and wastes a
  // 20 Kb block); bits alone are not enough (a 4-deep 512-bit line is 2048 bits
  // but only four registers deep and belongs in ALMs). Both must be met.
  //
  //   PFB_MEM_MIN_DEPTH  32   below this an M20K's address/output registers cost
  //                           more than the flip-flops they replace
  //   PFB_MEM_MIN_BITS  2048  a tenth of an M20K; below this the block is mostly
  //                           empty and an MLAB or ALM shift register is cheaper
  //
  // These are STARTING values, not measured ones, and they are deliberately set
  // so that the nominal SPEC 7.1 geometry (8 phases x 16 taps) lands on SHIFT
  // REGISTERS everywhere — which is the correct answer for it. The SPEC 18 sweep
  // measures what Quartus actually does with both styles; DECISIONS.md records
  // the outcome and this is where a revised threshold would land.
  // ---------------------------------------------------------------------------
  localparam int unsigned PFB_MEM_MIN_DEPTH = 32;
  localparam int unsigned PFB_MEM_MIN_BITS  = 2048;

  // Style names, so a caller writes pfb_pkg::PFB_STYLE_MEM rather than a string
  // literal that a typo turns into "AUTO" silently.
  //
  // Strings rather than an enum, because Quartus's `set_parameter` sweeps
  // integers while the simulator overrides strings; the elaboration check below
  // rejects anything that is neither, so a typo is a time-0 $fatal and not a
  // silent fall-through to the default.
  function automatic logic pfb_delay_style_ok(input string style);
    return (style == "AUTO") || (style == "SRL") || (style == "MEM");
  endfunction

  // Resolved style for a line. `n_taps == 1` means a pure delay; anything larger
  // is tapped and can only be a shift register.
  function automatic logic pfb_delay_use_mem(input string style,
                                             input pfb_uint_t width,
                                             input pfb_uint_t n_taps,
                                             input pfb_uint_t depth);
    if (n_taps != 32'd1) return 1'b0;                 // tapped: never a memory
    if (style == "MEM")  return 1'b1;                 // forced
    if (style == "SRL")  return 1'b0;                 // forced
    return (depth >= pfb_uint_t'(PFB_MEM_MIN_DEPTH)) &&
           ((width * depth) >= pfb_uint_t'(PFB_MEM_MIN_BITS));
  endfunction

  // ---------------------------------------------------------------------------
  // Coefficient-bank addressing
  //
  // One flat address space across the whole polyphase bank: {phase, tap}. The
  // register plane writes one coefficient per transaction and does not need to
  // know how the phases are distributed across lanes, and the ordering matches
  // the coefficient files scripts/generate_coefficients.py writes (phase-major,
  // tap-minor) so a file is loaded by counting up from zero.
  // ---------------------------------------------------------------------------
  function automatic pfb_uint_t pfb_coeff_addr_w(input pfb_uint_t phases,
                                             input pfb_uint_t taps);
    return pfb_uint_t'($clog2(phases * taps));
  endfunction

  function automatic pfb_uint_t pfb_coeff_index(input pfb_uint_t taps,
                                            input pfb_uint_t phase,
                                            input pfb_uint_t tap);
    return phase * taps + tap;
  endfunction

  // ---------------------------------------------------------------------------
  // Coefficient banks. Two, always: SPEC 7.1 requires double buffering and the
  // number is not a parameter, because "which bank is active" is a single bit
  // everywhere in the design and a third bank would change the register map.
  // ---------------------------------------------------------------------------
  function automatic pfb_uint_t pfb_n_banks();
    return 32'd2;
  endfunction

endpackage : pfb_pkg

`default_nettype wire
