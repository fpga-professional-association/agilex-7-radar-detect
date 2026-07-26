// -----------------------------------------------------------------------------
// fft_pkg — geometry, control-index arithmetic and twiddle addressing for the
// streaming FFT (SPEC.md 7.2, issue #11).
//
// This package is to the FFT what fxp_pkg is to the numerics: the ONE place the
// structure is defined. Delay-line lengths, butterfly types, which sub-stages
// carry a twiddle multiplier, the twiddle exponent of every sample position, the
// bit-reversal permutation, the per-stage scaling schedule and the latency
// accounting are all functions here. No module below recomputes any of them, and
// model/cpp/fft/fft_ref.hpp is a line-for-line mirror of this file in C++ —
// which is what makes "the RTL and the model implement the same transform" a
// property of one document rather than a coincidence between two.
//
// -----------------------------------------------------------------------------
// 1. Architecture, in one picture
// -----------------------------------------------------------------------------
// SPEC 7.2 asks for a parameterised streaming FFT, radix-2^2 single-path delay
// feedback preferred, SAMPLES_PER_CYCLE complex samples per cycle, frame
// continuous, twiddles in memory, twiddle multipliers in DSPs.
//
// A radix-2^2 SDF path is inherently ONE sample per cycle: it has a single
// datapath and a single delay-feedback memory. Parallelism is obtained by
// DECIMATION IN TIME across the input beat, not by widening the SDF path:
//
//   beat t carries x[P*t + 0] .. x[P*t + P-1]      (P = SAMPLES_PER_CYCLE)
//              --> lane p is exactly the subsequence x[P*n + p]
//
//   +--------+   lane 0 = evens   +--------------------+
//   |        |------------------->| M-point R2^2 SDF   |--> E[bitrev(j)]
//   | beat   |                    +--------------------+        |
//   | split  |                                                  +--> DIT merge
//   | (wires)|   lane 1 = odds    +--------------------+        |    (radix-2
//   |        |------------------->| M-point R2^2 SDF   |--> O[bitrev(j)]  + W)
//   +--------+                    +--------------------+
//
//   X[m]       = E[m] + W_N^m O[m]        m = bitrev(j), j the output beat index
//   X[m + N/2] = E[m] - W_N^m O[m]
//
// with M = N/P. The split is FREE — it is how the samples already arrive on the
// bus — and the merge is one radix-2 butterfly plus one complex multiplier per
// beat. Every lane is a textbook radix-2^2 SDF core, so the memory-efficiency
// property that makes R2^2 SDF worth choosing (one delay-feedback word per
// sample of transform state, log4(M)-1 non-trivial multipliers) is preserved
// per lane rather than traded away for the parallelism.
//
// The alternative — a P-parallel multi-path delay COMMUTATOR (MDC) or a
// 2-parallel R2^2 with the delay lines split across paths — is discussed, with
// its trade-offs, in DECISIONS.md (issue #11). The short version: MDC needs the
// same total delay memory but adds a commutator network and makes every stage's
// control depend on P, whereas this decomposition makes P a structural parameter
// that changes the NUMBER of identical cores and nothing inside one.
//
// Scaling to P = 8 (SPEC 7.2 nominal, issue #20) is log2(P) levels of the same
// DIT merge over 8 lanes of an N/8-point core. The merge module here implements
// one level and the level index is a parameter, so the generalisation is a
// generate loop, not a rewrite. Only P in {1, 2} is VERIFIED by this issue and
// fft_spc_supported() says so; relaxing it is a verification job, not an RTL job.
//
// -----------------------------------------------------------------------------
// 2. Radix-2^2 SDF, as this package indexes it
// -----------------------------------------------------------------------------
// An M-point decimation-in-frequency radix-2^2 SDF path is n = log2(M)
// BUTTERFLY SUB-STAGES, indexed s = 0 .. n-1:
//
//   delay          D(s) = 2^(n-1-s)          (M/2, M/4, ... , 1)
//   type           s even -> BF2I, s odd -> BF2II
//   twiddle after  s odd AND s < n-1
//
// A radix-2^2 GROUP is the pair (2g, 2g+1) followed by its twiddle multiplier.
// When n is ODD the last sub-stage, s = n-1, is a lone BF2I with D = 1: that is
// the "final radix-2 stage" a non-power-of-four transform needs, and it falls
// out of the rule above rather than being a special case bolted on. It is not a
// rare configuration here — it is the NORMAL one: N a power of four with P = 2
// gives M = N/2 and n odd for every N this design uses.
//
// The two butterflies (He & Torkelson, 1996), written the way the hardware runs
// them. Let a be the sample already in the delay feedback and b the sample
// arriving 2^(n-1-s) beats later:
//
//   BF2I     out_early = a + b        out_late = a - b
//   BF2II    out_early = a + t        out_late = a - t     t = (k1 ? -j*b : b)
//
// where k1 is the bit ABOVE the phase bit of the sub-stage's input position.
// -j*(re + j*im) = im - j*re, i.e. a swap and a negate: the trivial twiddle of
// the radix-2^2 decomposition, which is why only every SECOND butterfly needs a
// real multiplier. The derivation is the standard radix-2^2 DIF factorisation
//
//   X[k1 + 2k2 + 4k3] = sum_{n3} H(k1,k2,n3) W_N^{n3(k1+2k2)} W_{N/4}^{n3 k3}
//   H(k1,k2,n3) = [x(n3) + (-1)^k1 x(n3+N/2)]
//               + (-j)^(k1+2k2) [x(n3+N/4) + (-1)^k1 x(n3+3N/4)]
//
// and fft_r22_tw_exp() below is exactly the exponent n3(k1+2k2) of that formula,
// read off the sample's position in the serial stream.
//
// -----------------------------------------------------------------------------
// 3. Position tags, and why control is data
// -----------------------------------------------------------------------------
// Every SDF sub-stage needs to know where in the frame the sample it is looking
// at sits: the phase bit chooses write-or-butterfly, the k1 bit chooses the
// trivial twiddle, and the low bits address the twiddle ROM. A counter per stage
// would have to be ALIGNED to that stage's stream, and the alignment is a
// function of every delay and every pipeline register ahead of it — the kind of
// arithmetic that is right in the comment and wrong in the RTL.
//
// So the position travels WITH the sample as an n-bit tag. A sub-stage reads its
// control bits out of the tag of the sample on its input, and emits
//
//     idx_out = idx_in - D(s)   (mod M)
//
// because its output stream is its input stream delayed by D positions. The tag
// is n bits wide and M is 2^n, so the modulo is free. Nothing anywhere reasons
// about cumulative latency to derive a control signal; the only place cumulative
// latency appears is fft_core_latency(), which sizes the metadata delay line,
// and an assertion in streaming_fft checks that against the tag the core
// actually emits.
//
// -----------------------------------------------------------------------------
// 4. Scaling schedule (SPEC 6 accumulator-width policy, applied)
// -----------------------------------------------------------------------------
// The datapath is Q1.15 complex at EVERY sub-stage boundary. A butterfly sums
// two Q1.15 values, so by fxp_pkg's own growth rule its exact result needs
// fxp_acc_w(FXP_SAMPLE_W, 2) = 17 bits. The schedule decides, per sub-stage,
// whether that 17th bit is discarded by a one-place right shift or kept by
// letting the value saturate:
//
//   SCALE_SCHED bit g = 1   shift right one place, round-to-nearest-even,
//                           then saturate into 16 bits.
//   SCALE_SCHED bit g = 0   no shift; the sum saturates into 16 bits and the
//                           stage's saturation flags fire.
//
// All-ones is the default and is the classic 1/N scaled FFT: one bit of signal
// given up per sub-stage in exchange for headroom. Every quantisation is
// fxp_pkg::fxp_round_sat, and the direction-resolved flags are
// fxp_pkg::fxp_sat_flags of the ROUNDED value — the same order, for the same
// reason, as complex_multiplier.
//
// HOW CLOSE "overflow-free" ACTUALLY IS, because the obvious claim is wrong and
// an assertion in fft_bf2 caught it. Sums first:
//
//     a + b in [-2^16, 2^16 - 2]      rne(-2^16 / 2) = -2^15    fits
//     a - b in [-(2^16 - 1), 2^16 - 1]
//
// The DIFFERENCE reaches 2^16 - 1 = 65535, at a = +0.99997 and b = -1.0, and
// rne(65535 / 2) = rne(32767.5) = 32768 — one LSB past the top of Q1.15. So a
// fully scaled butterfly CAN saturate, on exactly one operand pair, by exactly
// one LSB, in the positive direction only. It is the asymmetric two's-complement
// range showing through again, the same way it does in -(-1.0), and it is a real
// event that the model reproduces and the flags report rather than something to
// be argued away. fft_bf2 asserts the precise statement — never negative, never
// more than one LSB over — on every beat.
//
// The trivial twiddle is a second, independent source: -j negates a component,
// and -(-1.0) is not representable, so a sample of exactly -1.0 saturates in
// BF2II whatever the schedule says.
//
// The schedule is a COMPILE-TIME parameter, not a register. A programmable
// schedule would put a per-stage shift multiplexer in the datapath and make the
// bit-exact reference model a function of run-time state; the same coverage is
// obtained by elaborating a second instance, which is what the verification top
// does. See DECISIONS.md (issue #11).
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

package fft_pkg;

  import fxp_pkg::fxp_complex_t;
  import fxp_pkg::fxp16_t;
  import fxp_pkg::FXP_SAMPLE_W;
  import fft_twiddle_pkg::FFT_TW_N;
  import fft_twiddle_pkg::FFT_TW_W;
  import fft_twiddle_pkg::FFT_TW_SAMPLE_W;
  import fft_twiddle_pkg::FFT_TW_DIGEST;
  import fft_twiddle_pkg::fft_tw_word;

  // ---------------------------------------------------------------------------
  // Working type
  //
  // Same device, for the same reason, as fxp_pkg::uint_t and stream_pkg::uint_t:
  // SystemVerilog has no parameterised functions, so the functions here take the
  // geometry as arguments and work on one unsigned integer type. `int unsigned'(x)`
  // is not legal cast syntax, so the type has to have a name.
  //
  // WHY THE NAME IS NOT `uint_t`, WHICH WOULD MATCH THE OTHER TWO PACKAGES.
  // Modules here wildcard-import fxp_pkg AND fft_pkg — streaming_fft imports
  // stream_pkg as well — and IEEE 1800 makes a name visible through more than one
  // wildcard import an ERROR at the point of reference. Verilator 5.020 accepts
  // it silently; Quartus Prime Pro 26.1 does not, and said so on the very first
  // calibration compile of this design:
  //
  //     Error (16941): uint_t is visible via multiple package imports
  //     Error (13406): object "uint_t" is not declared
  //
  // The other two packages are shared and predate this one, so the collision is
  // resolved on this side. `fft_uint_t` is the SAME underlying type — `int
  // unsigned` — so a value cast with either name is the same value, and a cast
  // spelled `fft_uint_t'(...)` is a legal argument to an fxp_pkg function whose
  // formal is `uint_t`. Nothing is converted; only the spelling is unambiguous.
  // ---------------------------------------------------------------------------
  typedef int unsigned fft_uint_t;

  // Largest transform this package can address. The master twiddle table holds
  // W_FFT_TW_N^e, and every stage's twiddles are a subsampling of it, so the
  // table size IS the maximum transform size, and log2 of it is the deepest
  // butterfly chain any configuration can have. Derived from the table rather
  // than written as 10, so regenerating the table with a different size moves
  // this with it. Used below by fft_max_size(), by fft_tw_index() and by the
  // schedule type, so it is never a dead parameter.
  localparam int unsigned FFT_MAX_STAGES = $clog2(FFT_TW_N);   // 10

  // Per-stage scaling schedule: one bit per butterfly sub-stage of the whole
  // transform (lane sub-stages first, then the merge levels). Carried as an
  // int unsigned parameter at module boundaries so that a Quartus
  // `set_parameter` override is an ordinary integer.
  typedef logic [FFT_MAX_STAGES-1:0] fft_sched_t;

  // ---------------------------------------------------------------------------
  // Limits, as functions
  //
  // Functions rather than localparams, exactly as stream_pkg does it: a package
  // localparam that a given build happens not to reference is reported as a dead
  // parameter by `verilator --lint-only --Wall`, and this package must be
  // lintable in a build that elaborates none of the FFT modules.
  // ---------------------------------------------------------------------------

  function automatic fft_uint_t fft_max_size();
    return fft_uint_t'(FFT_TW_N);            // 1024
  endfunction

  function automatic fft_uint_t fft_min_size();
    // Four points per lane at P = 2 — the smallest transform with a radix-2^2
    // group and a trailing radix-2 stage, i.e. the smallest one whose structure
    // is the same shape as the real ones.
    return 32'd8;
  endfunction

  // SAMPLES_PER_CYCLE values this issue VERIFIES. The decomposition generalises
  // to any power of two (section 1); the guard exists so that an unverified
  // configuration fails at elaboration rather than in the field.
  function automatic logic fft_spc_supported(input fft_uint_t spc);
    return (spc == 32'd1) || (spc == 32'd2);
  endfunction

  // ---------------------------------------------------------------------------
  // Geometry
  // ---------------------------------------------------------------------------

  function automatic logic fft_is_pow2(input fft_uint_t v);
    return (v != 0) && ((v & (v - 32'd1)) == 0);
  endfunction

  // Exact log2 of a power of two. $clog2 is the ceiling, which coincides with
  // log2 on powers of two; every argument here is checked to be one.
  function automatic fft_uint_t fft_log2(input fft_uint_t v);
    return fft_uint_t'($clog2(v));
  endfunction

  // Samples per lane == length of each lane's own transform.
  function automatic fft_uint_t fft_lane_len(input fft_uint_t n_fft, input fft_uint_t spc);
    return n_fft / spc;
  endfunction

  // n = log2(M): the number of butterfly sub-stages in one lane.
  function automatic fft_uint_t fft_lane_stages(input fft_uint_t n_fft, input fft_uint_t spc);
    return fft_log2(fft_lane_len(n_fft, spc));
  endfunction

  // Radix-2 DIT merge levels across the lanes. log2(P); 1 for P = 2.
  function automatic fft_uint_t fft_merge_levels(input fft_uint_t spc);
    return fft_log2(spc);
  endfunction

  // Butterfly sub-stages in the whole transform, lanes plus merges. Equals
  // log2(N) — the decomposition moves work between the two halves but does not
  // change how many radix-2 butterflies an N-point DFT needs.
  function automatic fft_uint_t fft_total_stages(input fft_uint_t n_fft);
    return fft_log2(n_fft);
  endfunction

  // Reversal of the low `w` bits of `v`. The SDF output permutation, and the
  // twiddle addressing of the merge.
  function automatic fft_uint_t fft_bitrev(input fft_uint_t v, input fft_uint_t w);
    fft_uint_t r;
    r = 32'd0;
    for (int unsigned i = 0; i < w; i++) begin
      if (((v >> i) & 32'd1) != 32'd0) r = r | (32'd1 << (w - 32'd1 - i));
    end
    return r;
  endfunction

  // ---------------------------------------------------------------------------
  // Radix-2^2 sub-stage structure (section 2)
  // ---------------------------------------------------------------------------

  // Delay-feedback length of sub-stage s in an n-sub-stage lane: M/2, M/4, ..., 1.
  function automatic fft_uint_t fft_bf_delay(input fft_uint_t n, input fft_uint_t s);
    return 32'd1 << (n - 32'd1 - s);
  endfunction

  // BF2II — the butterfly that carries the trivial -j — is every odd sub-stage.
  function automatic logic fft_bf_is_bf2ii(input fft_uint_t s);
    return (s % 32'd2) == 32'd1;
  endfunction

  // A twiddle multiplier follows every completed radix-2^2 group except the last
  // one, whose twiddles are all W^0. When n is odd the trailing lone BF2I has no
  // group and therefore no multiplier.
  function automatic logic fft_stage_has_twiddle(input fft_uint_t n, input fft_uint_t s);
    return fft_bf_is_bf2ii(s) && (s < (n - 32'd1));
  endfunction

  // Non-trivial twiddle multipliers in one lane: floor((n-1)/2). For n = 2m this
  // is m-1 = log4(M)-1, the textbook radix-2^2 count; for n odd the trailing
  // radix-2 stage adds none.
  function automatic fft_uint_t fft_lane_mults(input fft_uint_t n);
    return (n < 32'd1) ? 32'd0 : ((n - 32'd1) / 32'd2);
  endfunction

  // log2 of the sub-transform length L of the radix-2^2 group that ENDS at
  // sub-stage s (s odd). The group covers sub-stages s-1 and s, its butterflies
  // have delays L/2 and L/4, and its twiddles are powers of W_L.
  function automatic fft_uint_t fft_group_l2l(input fft_uint_t n, input fft_uint_t s);
    return n - s + 32'd1;
  endfunction

  // ---------------------------------------------------------------------------
  // Twiddle addressing
  // ---------------------------------------------------------------------------

  // The radix-2^2 twiddle exponent, read off the sample's position.
  //
  // At the multiplier's input the position p, taken modulo the group's L, splits
  // as {k1, k2, n3} with k1 the top bit, k2 the next, and n3 the remaining
  // log2(L)-2 bits. The factor is W_L^{n3 (k1 + 2 k2)}, which is the exponent
  // this returns. It is bounded by 3(L/4 - 1) < L, so the master-table index
  // below never wraps.
  function automatic fft_uint_t fft_r22_tw_exp(input fft_uint_t l2l, input fft_uint_t p);
    fft_uint_t q, k1, k2, n3;
    q  = p & ((32'd1 << l2l) - 32'd1);
    k1 = (q >> (l2l - 32'd1)) & 32'd1;
    k2 = (q >> (l2l - 32'd2)) & 32'd1;
    n3 = q & ((32'd1 << (l2l - 32'd2)) - 32'd1);
    return n3 * (k1 + 32'd2 * k2);
  endfunction

  // W_L^e out of the master W_FFT_TW_N table. L = 2^l2l must divide FFT_TW_N,
  // which fft_size_ok() guarantees for every L the structure produces.
  function automatic fft_uint_t fft_tw_index(input fft_uint_t l2l, input fft_uint_t e);
    return e << (fft_uint_t'(FFT_MAX_STAGES) - l2l);
  endfunction

  function automatic fxp_complex_t fft_tw_unpack(input logic [FFT_TW_W-1:0] w);
    fxp_complex_t c;
    c.re = fxp16_t'(w[FXP_SAMPLE_W-1:0]);
    c.im = fxp16_t'(w[2*FXP_SAMPLE_W-1:FXP_SAMPLE_W]);
    return c;
  endfunction

  function automatic fxp_complex_t fft_tw(input fft_uint_t l2l, input fft_uint_t e);
    return fft_tw_unpack(fft_tw_word(fft_tw_index(l2l, e)));
  endfunction

  // Contents of a radix-2^2 stage's twiddle ROM at address p. The ROM is
  // addressed by the low log2(L) bits of the position, so the address IS the
  // position and no exponent arithmetic survives into the hardware.
  function automatic fxp_complex_t fft_r22_tw(input fft_uint_t l2l, input fft_uint_t p);
    return fft_tw(l2l, fft_r22_tw_exp(l2l, p));
  endfunction

  // Exponent of the DIT merge's twiddle at output beat j of merge level `level`.
  //
  // Level `level` assembles sub-transforms of length M*2^level into ones of
  // length M*2^(level+1), so its factor is a power of W_{M*2^(level+1)} and its
  // exponent runs over the position within the half being combined — which, the
  // lanes' outputs being bit-reversed, is bitrev of the beat index over
  // n_lane+level bits.
  //
  // For P = 2 there is exactly one level: beat j carries E[m] and O[m] with
  // m = bitrev_n(j), the factor is W_N^m, and this returns m. That is the only
  // level VERIFIED by issue #11; the level argument exists so that the P = 8
  // generalisation (issue #20) is an argument rather than a new function, and
  // fft_spc_supported() is what stops an unverified level from elaborating.
  function automatic fft_uint_t fft_dit_tw_exp(input fft_uint_t n_lane,
                                           input fft_uint_t level,
                                           input fft_uint_t j);
    fft_uint_t w;
    w = n_lane + level;
    return fft_bitrev(j & ((32'd1 << w) - 32'd1), w);
  endfunction

  // Contents of the DIT merge's twiddle ROM at output beat j.
  function automatic fxp_complex_t fft_dit_tw(input fft_uint_t n_lane,
                                              input fft_uint_t level,
                                              input fft_uint_t j);
    return fft_tw(n_lane + level + 32'd1, fft_dit_tw_exp(n_lane, level, j));
  endfunction

  // ---------------------------------------------------------------------------
  // Scaling schedule
  // ---------------------------------------------------------------------------

  // Right shift applied after butterfly sub-stage g of the whole transform.
  // g < n indexes a lane sub-stage; g >= n indexes merge level g-n.
  function automatic fft_uint_t fft_shift(input fft_uint_t sched, input fft_uint_t g);
    return (sched >> g) & 32'd1;
  endfunction

  // The all-ones schedule: 1/N overall, provably overflow-free (section 4). The
  // default of every module, spelled as a function so no module writes '1 and
  // means something slightly different.
  function automatic fft_uint_t fft_sched_all();
    return 32'hFFFF_FFFF;
  endfunction

  // ---------------------------------------------------------------------------
  // Elaboration checks
  // ---------------------------------------------------------------------------

  // The generated twiddle table declares its own format; it must be the format
  // fxp_pkg defines, or every coefficient in the design is being read at the
  // wrong width. Checked from fft_size_ok(), so every elaboration checks it, and
  // the digest is required to be present so that a table generated by an older
  // script without one cannot slip through.
  function automatic logic fft_tw_table_ok();
    return (FFT_TW_SAMPLE_W == FXP_SAMPLE_W) &&
           (FFT_TW_W == 2 * FXP_SAMPLE_W) &&
           (FFT_TW_DIGEST != "");
  endfunction

  // Read latency of a twiddle ROM, in beats. One for the memory's input
  // register, one more when its output register is enabled. The stages align
  // their datapaths against this, so the number exists once.
  function automatic fft_uint_t fft_tw_rom_latency(input fft_uint_t out_reg);
    return 32'd1 + out_reg;
  endfunction

  // ---------------------------------------------------------------------------
  // Delay-feedback placement (SPEC 18 "memory geometry", MEASURED)
  //
  // Leaving the choice to Quartus is the wrong answer for a small SDF delay
  // line, and the SPEC 18 sweep is what established that rather than an opinion
  // about it. On AGMF039R47B1E1VC, for the 16-word by 32-bit feedback of the
  // first radix-2^2 group of a 64-point / 2-samples-per-cycle lane:
  //
  //   STYLE      M20K  MLAB  kernel ALM  Fmax     critical path
  //   ---------  ----  ----  ----------  -------  --------------------------
  //   "AUTO"        2     0       468.3  345.9    INSIDE the M20K, block reg
  //                                               to block reg
  //   "MLAB"        0     6       505.8  382.0    MLAB output to the
  //                                               butterfly's own register
  //
  // The M20K version is not merely slower, it is slower in a way nothing
  // downstream can fix: the failing path is inside a hard block, so the
  // Hyper-Retimer cannot move a register into it, and both points report the
  // Fitter's "Path Limit" reason. The same path is the limiter of the whole
  // 64-point block (330.0 MHz, results/synthesis/calibration_fft_core.json).
  // Moving it to LUT-RAM costs 37 ALMs, frees both M20Ks, and gives the
  // retimer something it can work on.
  //
  // So "DEFAULT" — the project rule, and the default everywhere in rtl/fft/ —
  // places a delay line of at most fft_delay_mlab_max_depth() words in MLAB and
  // leaves anything deeper to the tool. "AUTO" still means "no attribute, tool
  // chooses", so the sweep can keep measuring the tool's own choice; that is
  // what the table above compares.
  //
  // THE THRESHOLD IS PARTLY EXTRAPOLATED AND SAYS SO. 16 words is measured. 64
  // words by 32 bits is 2 Kbit, still a handful of MLABs, and is the deepest
  // line in a 256-point / 2-SPC lane; the crossover above which an M20K is the
  // right answer has NOT been measured, and a 1024-point configuration (256-word
  // first line) must re-measure it before issue #20 freezes full-scale
  // parameters. That is one number, here, and a calibration point.
  // ---------------------------------------------------------------------------

  function automatic fft_uint_t fft_delay_mlab_max_depth();
    return 32'd64;
  endfunction

  function automatic string fft_delay_style(input fft_uint_t depth);
    return (depth <= fft_delay_mlab_max_depth()) ? "MLAB" : "AUTO";
  endfunction

  // Resolves a module's MEM_STYLE parameter for one delay line: "DEFAULT" asks
  // for the project rule above, anything else is passed through verbatim so a
  // calibration point can force a placement.
  function automatic string fft_resolve_mem_style(input string style,
                                                  input fft_uint_t depth);
    return (style == "DEFAULT") ? fft_delay_style(depth) : style;
  endfunction

  function automatic logic fft_size_ok(input fft_uint_t n_fft, input fft_uint_t spc);
    if (!fft_tw_table_ok())                   return 1'b0;
    if (!fft_is_pow2(n_fft))                  return 1'b0;
    if (!fft_is_pow2(spc))                    return 1'b0;
    if (n_fft < fft_min_size())               return 1'b0;
    if (n_fft > fft_max_size())               return 1'b0;
    if (spc > n_fft)                          return 1'b0;
    // Two samples per lane is the floor: a one-sample lane has no transform.
    if (fft_lane_len(n_fft, spc) < 32'd4)     return 1'b0;
    return 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Latency accounting
  //
  // Two quantities, kept apart because they are different things:
  //
  //   POSITION offset  how far the output stream lags the input stream in
  //                    SAMPLE POSITIONS. Contributed only by the delay lines,
  //                    and it is sum_s D(s) = M-1 for a lane, 0 for a merge.
  //   TIME latency     how many enabled beats a value takes to cross the
  //                    pipeline registers. One per butterfly, ROM_LAT+TW_PIPE
  //                    per twiddle multiplier.
  //
  // Their SUM is the number of enabled beats between an input beat and the
  // output beat that carries the same position within the frame, which is what
  // sizes the metadata delay line in streaming_fft. streaming_fft asserts the
  // number against the position tag the core actually emits, so this arithmetic
  // is checked rather than trusted.
  // ---------------------------------------------------------------------------

  function automatic fft_uint_t fft_lane_pos_offset(input fft_uint_t n_lane);
    return (32'd1 << n_lane) - 32'd1;               // M - 1
  endfunction

  function automatic fft_uint_t fft_mult_latency(input fft_uint_t rom_lat,
                                             input fft_uint_t tw_pipe);
    return rom_lat + tw_pipe;
  endfunction

  function automatic fft_uint_t fft_lane_time_latency(input fft_uint_t n_lane,
                                                  input fft_uint_t rom_lat,
                                                  input fft_uint_t tw_pipe);
    return n_lane + fft_lane_mults(n_lane) * fft_mult_latency(rom_lat, tw_pipe);
  endfunction

  // One merge level: ROM + multiplier, then the butterfly's output register.
  function automatic fft_uint_t fft_merge_latency(input fft_uint_t rom_lat,
                                              input fft_uint_t tw_pipe);
    return fft_mult_latency(rom_lat, tw_pipe) + 32'd1;
  endfunction

  // Enabled beats from an input beat to the output beat holding the same
  // position of the same frame, for the core alone (no output reordering).
  function automatic fft_uint_t fft_core_latency(input fft_uint_t n_fft,
                                             input fft_uint_t spc,
                                             input fft_uint_t rom_lat,
                                             input fft_uint_t tw_pipe);
    fft_uint_t n_lane;
    n_lane = fft_lane_stages(n_fft, spc);
    return fft_lane_pos_offset(n_lane)
         + fft_lane_time_latency(n_lane, rom_lat, tw_pipe)
         + fft_merge_levels(spc) * fft_merge_latency(rom_lat, tw_pipe);
  endfunction

  // The bit-reversal reorder buffer is double buffered: a frame is only readable
  // once it is complete, so it costs one whole frame of beats, plus the one
  // register on the memory's read port.
  function automatic fft_uint_t fft_reorder_latency(input fft_uint_t n_fft,
                                                input fft_uint_t spc);
    return fft_lane_len(n_fft, spc) + 32'd1;
  endfunction

  function automatic fft_uint_t fft_total_latency(input fft_uint_t n_fft,
                                              input fft_uint_t spc,
                                              input fft_uint_t rom_lat,
                                              input fft_uint_t tw_pipe,
                                              input logic  reorder);
    return fft_core_latency(n_fft, spc, rom_lat, tw_pipe)
         + (reorder ? fft_reorder_latency(n_fft, spc) : 32'd0);
  endfunction

endpackage : fft_pkg

`default_nettype wire
