# Numerics

The single normative definition of every fixed-point format, growth rule, rounding mode,
and saturation policy used in the benchmark. The RTL package under `rtl/packages/` and
the C++ reference model under `model/cpp/` are both derived from this document and must
be bit-identical to it; where this document and an implementation disagree, the
implementation is wrong. Governing requirements: [SPEC.md](SPEC.md) §6 (numerical
definition) and §7 (per-block arithmetic).

**Status: normative as of issue #4** for the shared primitives — formats, rounding,
saturation, truncation, accumulator growth and overflow flags. The per-block sections
(§9) are still filled in by the kernel issues that implement them, but every one of those
kernels is bound by the rules stated here.

## 0. The rule

> SPEC §6: *"Define one shared package containing signed rounding rules, convergent or
> round-to-nearest behavior, saturation functions, truncation locations, accumulator
> widths, overflow flags. **Do not allow each module to invent its own rounding
> behavior.** The C++ reference model and RTL must use identical numerical rules."*

Operationally, in this repository, that means:

1. **Every quantisation is a call into `fxp_pkg`.** No module writes `>>> 15`,
   `+ 16'sd16384`, a `?:` clamp, or any other open-coded round/saturate/truncate. A
   module that does is a defect at review time even when its arithmetic happens to be
   correct, because the next module will spell it differently and the two will diverge
   under a format change.
2. **Every quantisation in the C++ model is a call into `model/cpp/fxp/fxp.hpp`**, whose
   functions are one-to-one mirrors of the package's.
3. **Neither implementation is the definition.** This document is. Both are checked
   against a third, independently written NumPy model
   (`model/python/fxp_reference.py`) through committed golden vectors.
4. **Changing any rule here is a `DECISIONS.md` event**, and it invalidates every golden
   vector — which is exactly the friction it should have.

The artefacts:

| Role | Path |
|---|---|
| Normative prose | this file |
| RTL implementation | [`rtl/packages/fxp_pkg.sv`](rtl/packages/fxp_pkg.sv) |
| C++ implementation | [`model/cpp/fxp/fxp.hpp`](model/cpp/fxp/fxp.hpp) |
| Independent NumPy model | [`model/python/fxp_reference.py`](model/python/fxp_reference.py) |
| Golden vectors | [`model/vectors/`](model/vectors/) |
| Saturation-flag collector | [`rtl/common/fxp_sticky_flags.sv`](rtl/common/fxp_sticky_flags.sv) |
| Equivalence gate | `make numerics-check` (a prerequisite of `make sim-tiny`) |

## 1. Scope and invariants

Invariant widths from SPEC §3: `SAMPLE_W=16`, `COEFF_W=16`, `POWER_W=40`. These are held
constant across all four size configurations in `config/*.json`, so nothing in this
document depends on the configuration: the tiny and the full AGMF039 elaborations
quantise identically.

Every function in `fxp_pkg` computes in a **signed 64-bit working type**
(`fxp_wide_t`; `fxp::wide_t` in C++) and takes the target width or shift count as an
argument. SystemVerilog has no parameterised subroutines, and a per-width copy of each
function is exactly the duplication §0 forbids. Callers cast into and out of the working
type at the call site, which keeps the real width visible in the RTL.

The working type is not a design width. No register in the benchmark is 64 bits wide; the
widest accumulator this document defines is 44 bits (§7).

**Contract on the working type.** Behaviour is defined, and the two implementations are
proven identical, for:

```text
|v| <= 2^62        operands and intermediates
0 <= s <= 63       shift / fractional-bit counts
2 <= w <= 64       target signed widths
```

`s >= 64` returns 0 and `w >= 64` means the full 64-bit range in both implementations, so
an out-of-contract call has a defined answer rather than an X — but it is out of contract
and no datapath reaches it. The NumPy reference enforces a slightly tighter domain
(`s <= 62`, `w <= 63`), because that is where its own `int64` arithmetic stops being
exact; the generated vectors stay inside it.

## 2. Input and coefficient formats

| Name | Format | Width | Integer bits | Fractional bits | Range | Resolution |
|---|---|---|---|---|---|---|
| Sample I, sample Q | Q1.15 | 16 signed | 1 (sign) | 15 | `[-1.0, +1.0 - 2^-15]` | `2^-15` |
| Coefficient / weight | Q1.15 | 16 signed | 1 (sign) | 15 | `[-1.0, +1.0 - 2^-15]` | `2^-15` |
| Product | Q2.30 | 32 signed | 2 | 30 | `[-1.0, +1.0]` | `2^-30` |
| MAC accumulator | Q(2+g).30 | `32 + g` signed | `2 + g` | 30 | see §7 | `2^-30` |

Endpoints, which matter more than the ranges:

```text
Q1.15 max = 16'h7FFF = +32767 = +0.999969482421875
Q1.15 min = 16'h8000 = -32768 = -1.0
```

The format is **asymmetric**: `-1.0` is representable, `+1.0` is not. Almost every
surprising result in this document follows from that one fact.

A complex sample is an `{im, re}` pair of Q1.15 values (`fxp_complex_t` /
`fxp::Complex`). When a complex operand is packed into a single word — in the vector
files, in the probe's ports and in `Complex::packed()` — the **real part occupies the low
half**.

The endpoints are exported as functions (`fxp_q15_max()`, `fxp_q15_min()`,
`fxp::q15_max()`, `fxp::q15_min()`) derived from the general width rule, not as literal
constants, so there is no second copy of `0x7FFF` that can drift.

## 3. Multiplication and bit growth

A Q1.15 × Q1.15 product is **exact** in 32 bits:

```text
Q1.15 x Q1.15 -> Q2.30
product range = [-2^30, +2^30]      (in Q2.30 LSBs)
```

The upper endpoint `+2^30` is reached only by `(-1.0) x (-1.0)`, and it is what needs the
second integer bit. `fxp_mul_q15` therefore never overflows and never saturates; it
produces Q2.30 and nothing is discarded.

Quantisation happens **after** the multiply, on the way back to Q1.15, by discarding
`FXP_PROD_SHIFT = FXP_PROD_FRAC_W - FXP_FRAC_W = 15` fractional bits (§4) and then
saturating to 16 bits (§5). That composite is `fxp_mul_q15_rs`. The canonical consequence:

```text
(-1.0) x (-1.0) = +1.0  ->  not representable in Q1.15  ->  saturates to 0x7FFF, sat_pos
```

**Complex multiply** (SPEC §6, four-real-multiply form):

```text
real = a_re*b_re - a_im*b_im
imag = a_re*b_im + a_im*b_re
```

Both partial products are summed at full precision and the result is rounded **once**, at
the output. Rounding each partial product first would double the quantisation noise and
would not match the model. SPEC §6 also requires an optional three-real-multiply variant
for the Quartus DSP/ALM comparison; that is an arithmetic restructuring of the *same*
numerics, it must produce this exact result bit for bit, and it is not a licence to round
differently. Both variants landed with issue #9 as `rtl/common/complex_multiplier.sv`;
see §9.0.

**The two-term sum does not fit Q2.30.** Stated here because it is the one place where
"a Q1.15 product is 32 bits" stops being enough, and a reader who assumes otherwise
writes a 32-bit port:

```text
imag((-1.0 - 1.0j) x (-1.0 - 1.0j)) = (-2^15)(-2^15) + (-2^15)(-2^15) = +2^31
```

`+2^31` is one past the top of a signed 32-bit field. The exact sum of two Q1.15 products
therefore needs `acc_w(32, 2) = 33` bits — the general growth rule of §7, whose bound is
**tight** in this case rather than conservative — and the format is Q3.30: thirty
fractional bits, three integer bits including the sign. Nothing is lost and nothing
saturates at that width. Saturation enters only on the way back to Q1.15, and on exactly
this input pair: `+2^31 >> 15 = +2^16` rounds to 65536 and clamps to `0x7FFF` with
`sat_pos`.

## 4. Rounding policy

### The rule

> **Round to nearest, ties to even (convergent).** Project-wide, in RTL, in the C++
> model, and in every reference computation.

`fxp_round(v, s)` / `fxp::round(v, s)` is the only rounding entry point datapath code may
call. It selects the mode from the `FXP_ROUND_MODE` localparam, which is fixed to
`FXP_ROUND_MODE_NEAREST_EVEN`; the selection folds away at elaboration, so exactly one
implementation reaches synthesis.

Definition, for a shift of `s` fractional bits (`q = floor(v / 2^s)`, `rem = v mod 2^s`
taken as the non-negative floor remainder, `half = 2^(s-1)`):

```text
rem >  half  ->  q + 1
rem <  half  ->  q
rem == half  ->  q + (q & 1)      move to the even neighbour
s == 0       ->  v                identity
```

The four tie classes, which the vector set enumerates explicitly:

| Input (LSBs) | Result | Class |
|---|---|---|
| `+1.5` | `+2` | positive tie, up to even |
| `+0.5` | `0` | positive tie, down to even |
| `-0.5` | `0` | negative tie, up to even |
| `-1.5` | `-2` | negative tie, down to even |

### Why convergent, and not round-half-up

`fxp_round_half_up` is implemented and exported, and the vector set proves it, because
this comparison should be measurable rather than asserted. It is **not** available to the
datapath.

* **Bias.** Round-half-up is `floor((v + 2^(s-1)) / 2^s)`. Every exact tie moves toward
  `+infinity`, contributing a mean error of `+2^-(s+1)`. Measured over a complete residue
  sweep by `model/cpp/test/test_fxp_vectors.cpp` (131 072 consecutive inputs at `s = 3`):
  round-to-nearest-even's total error is **exactly 0**; round-half-up's is **+65 536
  LSB-scaled units, one half LSB for each of the 16 384 ties**. That line is printed on
  every run of the numerics gate, so it is evidence rather than a claim.
* **The bias is coherent, which is what makes it expensive.** A rounding error that is
  random averages down through a 12-tap FIR, a 1024-point FFT and a 64-element
  beamforming dot product. A constant `+0.5 LSB` offset does not: it adds through every
  tap, survives the FFT as energy at bin 0, and lands in the power estimate as a DC
  pedestal that CFAR then thresholds against. A DSP chain is precisely the structure that
  turns a small coherent bias into a visible one.
* **Symmetry about zero.** Round-half-up is asymmetric: `+0.5 -> +1` but `-0.5 -> 0`. On
  a signed I/Q datapath that is a DC offset with a sign, which is worse than an offset
  without one. Round-half-away-from-zero fixes the symmetry but keeps a magnitude bias
  and costs sign-dependent logic.
* **Cost.** Round-half-up is a carry-in — free inside a DSP block. Convergent rounding
  additionally needs the tie detection (`rem == half`, a wide NOR of the discarded bits)
  and one LSB of the quotient: on the order of a handful of ALMs per rounding site, at a
  level of the logic that is not on the critical path of a DSP-block cascade. This is the
  one place the project knowingly accepts a small area cost for a numerical property, and
  it is accepted because rounding sites are counted in the hundreds, not the hundreds of
  thousands.

Recorded in DECISIONS.md, 2026-07-25, issue #4.

## 5. Saturation policy

### The rule

> **Clamp, never wrap. To the full two's-complement range. Flag every event.**

For a target of `w` signed bits:

```text
max = +2^(w-1) - 1
min = -2^(w-1)
v > max  ->  max,  flags.sat_pos
v < min  ->  min,  flags.sat_neg
```

* **Clamp rather than wrap** because a wrapped overflow turns a large positive detection
  into a large negative one, which the CFAR detector cannot distinguish from a real
  target. A clamp degrades gracefully and is visible in the flags.
* **Full range, not symmetric range.** The negative endpoint is `-2^(w-1)`, i.e. exactly
  `-1.0` in Q1.15, not `-0.999969...`. Symmetric saturation (clamping the low end to
  `-max`) is common in DSP libraries because it makes negation total, but it silently
  discards a representable value on every path that never negates, and it means the
  format's own minimum is not a legal datapath value. This project keeps the full range
  and makes negation explicitly saturating instead.
* **Consequences of the asymmetry**, all covered by directed vectors:
  ```text
  -(-1.0)          -> +1.0 not representable -> 0x7FFF, sat_pos
  (-1.0)x(-1.0)    -> +1.0 not representable -> 0x7FFF, sat_pos
  0x7FFF + 1       -> 0x7FFF, sat_pos
  0x8000 - 1       -> 0x8000, sat_neg
  ```
* `fxp_neg_sat`, `fxp_add_sat` and `fxp_sub_sat` form the intermediate at the full 64-bit
  working width before clamping, so the intermediate itself cannot wrap for any
  `w <= 63` within the §1 contract.

## 6. Truncation points policy

Three distinct operations, deliberately not interchangeable:

| Function | Behaviour | Mean error | Where it is allowed |
|---|---|---|---|
| `fxp_trunc(v, s)` | `floor(v / 2^s)`, toward `-infinity` | `-0.5 LSB` | only where this section explicitly permits |
| `fxp_round(v, s)` | round to nearest, ties to even | `0` | every datapath quantisation |
| `fxp_round_sat(v, s, w)` | round then saturate | `0` | every datapath quantisation that narrows |

### Where quantisation happens

1. **Once per arithmetic stage, at its output.** Not between partial products, not
   between taps, not between butterfly inputs. A stage accumulates at full precision (§7)
   and quantises exactly once on the way to the next stage's input format.
2. **Round first, saturate second, always in that order.** `fxp_round_sat` is the single
   composite that guarantees it. The order is not cosmetic: a value one tie below the top
   of the target range rounds *up* past the range, and only a saturation applied
   afterwards catches it —
   ```text
   0x7FFF.8 in Q1.15  ->  round -> 0x8000  ->  saturate -> 0x7FFF, sat_pos
   ```
   Saturating first would clamp, then round the clamped value, and report **no
   overflow**. Both implementations are checked against directed vectors for exactly this
   case (`rsat_q15_tie_over_max`, `rsat_q15_tie_under_min`), and inverting the order in
   the RTL is one of the injected faults in §10.
3. **Truncation is permitted only where the discarded bits are provably zero**, or as an
   explicitly documented per-block exception recorded in §9 with its measured effect.
   "It was cheaper" is not such a documentation. `fxp_trunc` exists so that those places
   call a named function and a reviewer grepping for quantisation finds them, instead of
   an inline `>>>` hiding in an assignment.
4. **No quantisation inside an accumulation tree.** See §7.

## 7. Accumulator width policy

### The rule

```text
growth(N)        = ceil(log2 N)          $clog2, so growth(1) = 0
acc_w(P, N)      = P + growth(N)
mac_q15_acc_w(N) = 32 + ceil(log2 N)     for an N-term Q1.15 MAC
```

`fxp_growth_bits`, `fxp_acc_w` and `fxp_mac_q15_acc_w` (and `fxp::growth_bits`,
`fxp::acc_w`, `fxp::mac_q15_acc_w`) are the only sanctioned way to compute an accumulator
width. Worked values:

| N terms | `growth(N)` | `mac_q15_acc_w(N)` | worst-case sum | fits? |
|---|---|---|---|---|
| 1 | 0 | 32 | `2^30` | yes |
| 2 | 1 | 33 | `2^31` | yes |
| 3 | 2 | 34 | `3·2^30` | yes (one bit spare) |
| 4 | 2 | 34 | `2^32` | yes |
| 8 | 3 | 35 | `2^33` | yes |
| 16 | 4 | 36 | `2^34` | yes |
| 64 | 6 | 38 | `2^36` | yes |
| 1024 | 10 | 42 | `2^40` | yes |
| 4096 | 12 | 44 | `2^42` | yes |

The formula is **exact for power-of-two N and conservative by at most one bit
otherwise** (N=3 gets 34 bits where 33 would do). The project pays one flip-flop rather
than carrying a per-N special case, and gets the property that matters in exchange:

> **An accumulator sized by this rule provably cannot overflow.** The only saturation in a
> MAC is the final round-and-saturate back to the output format.

The C++ unit test asserts `N · 2^30 <= max_of(mac_q15_acc_w(N))` for every N it checks,
so the claim is verified rather than argued.

### Why no intermediate saturation

A saturating add is not associative. An accumulation tree that saturates internally
therefore produces a result that depends on the reduction order, and RTL (which reduces
in a balanced tree, for timing) and a reference model (which reduces linearly, because
that is how a loop is written) would legitimately disagree. Sizing the accumulator so no
intermediate can overflow removes the question. **Adder trees inside a kernel do not
saturate; only the kernel's output stage does.**

`fxp_probe_top` and `fxp::Acc` deliberately implement the *opposite* — saturate at every
step — and `model/vectors/fxp_accum.vec` pins that order-dependent behaviour down
exactly. That is on purpose: it is the naive implementation, it is what a kernel would do
if it ignored this section, and specifying it makes the difference between the two
policies measurable rather than theoretical. The `no_growth_32` sequence is the
counter-example — eight worst-case products in a 32-bit accumulator, which saturates on
the second term — while the `policy_*` sequences at `acc_w(32, N)` never saturate at all.

## 8. Overflow and saturation flag policy

### The rule

> Every saturating operation produces a **direction-resolved** flag pair alongside its
> result. Flags are **sticky** until explicitly cleared. Event counters **saturate**,
> never wrap.

```systemverilog
typedef struct packed {
  logic sat_pos;   // clamped to +max
  logic sat_neg;   // clamped to -min
} fxp_flags_t;
```

* **Direction is kept** because it is diagnostically different: persistent positive
  saturation is a gain-staging error, alternating positive/negative saturation is
  oscillation, and negative-only saturation on a power or magnitude path is a sign bug.
  Collapsing both into one bit throws that away to save one flip-flop.
* **Sticky, not pulsed.** A single saturating cycle 40 000 beats into a frame must still
  be visible when the frame ends. `rtl/common/fxp_sticky_flags.sv` is the one sanctioned
  holder; kernels instantiate it rather than rolling their own sticky bit, so that "did
  this block saturate?" means the same thing everywhere and the telemetry plane
  (issue #8) has one shape to read.
* **Clear wins over a simultaneous event.** A read-then-clear can therefore never drop an
  event that happened before the read; the alternative (event wins) makes `clear`
  non-idempotent and can hide a permanently stuck condition.
* **The event counter saturates at all-ones.** A wrapping counter can read zero on a
  permanently saturating datapath, and zero is the one reading that must never be
  produced by a broken pipeline. Reaching all-ones is itself the diagnosis.
* Flags are combinational functions of the same inputs as the result
  (`fxp_sat_flags(v, w)`), qualified by a `valid` where they are collected, so a
  combinational function of stale operands is never counted.
* `event_count` counts saturating **cycles**, not saturating bits: a step that clamps in
  one direction counts once.

### Counter widths and wrap policy (issue #8)

`rtl/common/perf_counter.sv` is the one counter implementation the design has, and it makes
the rule above general. The arithmetic is stated once and reused, so no kernel decides for
itself what happens at the top of a counter's range:

| Counter class | Width | Mode | Why |
|---|---|---|---|
| Stream beats, stall cycles | 64 (`WIDE_W`) | **modulo** | rate measures. 64 bits at 450 MHz is 1.3 million years, so the absolute value is safe in any real run; after a wrap the *difference* between two reads is still exactly right, which is the quantity anyone uses |
| Idle cycles, frames, frame starts | 32 (`COUNT_W`) | **modulo** | as above |
| FIFO overflows, arithmetic saturations, CDC errors | 32 | **saturating** | magnitudes. A dump taken long after a run must not report a small number because the counter went round — the rule this section already states for `event_count`, now enforced by the shared primitive |
| Sequence gaps, lost beats, duplicates, reorders, untracked beats | 32 | **saturating** | as above |
| `SNAPSHOT_ID` | 32 | **modulo** | an identity, not a magnitude: a saturated identity compares equal to every later one and stops detecting the read race it exists to detect |

Neither mode has an undefined overflow. The adder is one bit wider than the counter and its
carry out **is** the wrap decision, so the behaviour at the boundary is structural rather than
a property of the synthesiser, and it is identical for an increment of one and for a weighted
increment that steps over the maximum without landing on it.

Every counter carries a sticky range flag, surfaced per counter in `COUNTERS.WRAP_STATUS` and
as one bit in `COUNTERS.TELEM_STATUS.WRAP_ANY`, so a reader always knows whether an absolute
value still means anything. `TELEM_STATUS.TRAFFIC_SATURATE` and `.ERROR_SATURATE` report which
arithmetic was elaborated, so software never has to assume. SPEC §13.4 requires wrap to be
exercised: `telemetry_top` carries three deliberately 8-bit counters for exactly that, and
`test_perf_counters` wraps them in 300 events on every seed. Full rationale: DECISIONS.md
(issue #8) decision 2; the register-level view is in [docs/regmap.md](docs/regmap.md).

## 9. Per-block numerical contracts

Each kernel issue fills in its own subsection. Every one of them is bound by §§2–8: the
subsections below say *which* formats a block consumes and produces and *where* its one
quantisation point sits — never a different rounding rule.

### 9.0 Complex multiplier (issue #9)

`rtl/common/complex_multiplier.sv`. The kernel every later block multiplies with, so its
contract is stated first and the blocks below inherit it.

| | |
|---|---|
| Consumes | two `fxp_complex_t`, Q1.15 per component |
| Produces (exact) | `p_re` / `p_im`, **Q3.30 in `FXP_PROD_W + 1 = 33` bits**, never saturates, no flags |
| Produces (quantised) | `y_re` / `y_im`, Q1.15, present when `ROUND_OUT = 1` |
| Quantisation point | exactly one, at the output: `fxp_round_sat(p, FXP_PROD_SHIFT, FXP_SAMPLE_W)` |
| Flags | `fxp_sat_flags(fxp_round(p, FXP_PROD_SHIFT), FXP_SAMPLE_W)` per component, plus their OR as `ovf` |
| Latency | `PIPE_STAGES` cycles exactly, for both variants, for every legal value |

Two arithmetic realisations, **bit-identical by construction**:

```text
MULT4   re = a_re*b_re - a_im*b_im            4 x (16 x 16 -> 32b), 2 post-adds
        im = a_re*b_im + a_im*b_re

MULT3   k1 = a_re * (b_re + b_im)             3 x (16 x 17 -> 33b), 3 pre-adds,
        k2 = b_im * (a_re + a_im)             2 post-adds
        k3 = b_re * (a_im - a_re)
        re = k1 - k2      im = k1 + k3
```

The MULT3 identities are identities in **Z**: distributivity and cancellation of integer
terms, no division and no rounding, so they hold bit-exactly in two's complement provided
no intermediate wraps. The width discharge is `|pre-add| <= 2^16` (17 bits), `|k| <= 2^31`
(33 bits), `|k1 ± k2,3| = |result| <= 2^31` (33 bits). The RTL forms the post-adder one bit
wider than the output and casts down; both the cast and the whole core are checked against
`fxp_pkg`'s canonical four-multiply definition by in-module assertions on every simulated
cycle. See VERIFICATION_PLAN.md §5.9 and DECISIONS.md (issue #9).

The **choice** between the two, and the choice of `PIPE_STAGES`, is a SPEC §18 measurement,
not a numerical question: both give the same bits. See `results/synthesis/calibration_cmult.json`
and the table in DECISIONS.md.

### 9.1 Polyphase FIR bank

TODO — populated by issue #10.

### 9.2 Streaming FFT and scaling schedule

TODO — populated by issue #11. The scaling schedule is normative and must be stated
explicitly per stage.

### 9.3 Beamforming dot product and accumulation tree

TODO — populated by issue #12.

### 9.4 Power and covariance

TODO — populated by issue #13. `POWER_W = 40` (SPEC §3).

### 9.5 CFAR thresholding

TODO — populated by issue #14.

## 10. Bit-accuracy methodology

### The equivalence triangle

Three implementations, each written from this document and never from another:

```text
        model/python/fxp_reference.py        NumPy int64, divmod / floor_divide
                    |
                    |  generates, with a fixed seed
                    v
             model/vectors/*.vec             committed golden vectors
               /              \
              /                \
  rtl/packages/fxp_pkg.sv     model/cpp/fxp/fxp.hpp
  (driven through             (masks + arithmetic shifts,
   sim/verilator/tops/         unsigned-wrap primitives)
   fxp_probe_top.sv)
              \                /
               \              /
            also compared directly
```

`sim/tests/test_fxp_rtl.cpp` checks **all three pairwise relations** and reports them
separately (`rtl_vs_vector`, `rtl_vs_cpp`, `cpp_vs_vector`), because each fails for a
different reason:

* RTL == C++ alone would be satisfied by two implementations that share a mistake.
* RTL == NumPy alone would leave the C++ oracle — the thing every later kernel test
  compares against — unproven.
* C++ == NumPy alone would prove nothing about the hardware.

The two implementations under test are deliberately expressed differently. The NumPy
model uses `divmod` and `floor_divide`; the RTL and C++ use masks and arithmetic shifts.
A transliteration would agree with a transliteration's bug.

### The C++ mirror is exact by construction, not by observation

SystemVerilog arithmetic on a 64-bit signed vector wraps. C++ signed overflow is
undefined behaviour, and C++17 leaves `>>` on a negative value implementation-defined.
Neither may become the difference between model and RTL, so every primitive in `fxp.hpp`
goes through unsigned 64-bit operations with one reinterpretation at the end
(`add_wrap`, `sub_wrap`, `neg_wrap`, `shl_wrap`, `asr`). Nothing outside that block uses
a raw `+`, `-`, unary minus, `<<` or `>>` on a `wide_t`.

### What runs, and when

`make numerics-check` — a prerequisite of `make sim-tiny`, so it runs on every
regression:

1. `model/python/gen_fxp_vectors.py --check` regenerates the vectors in memory and
   compares them with the committed files, so the committed vectors are provably what the
   recorded seed produces.
2. The standalone C++ unit test builds `model/cpp/fxp` with
   `g++ -std=c++17 -O3 -Wall -Wextra -Werror` — no Verilator, no harness — and checks
   every vector bit-exactly, plus the property assertions below.
3. The Verilator cross-check drives the same vectors through `fxp_probe_top` and checks
   all three pairwise relations.

`make lint` covers `fxp_pkg.sv` and `fxp_sticky_flags.sv` on every run, with zero
waivers. Both vector files carry a `rounding_mode:` header, and a build whose
`FXP_ROUND_MODE` disagrees with it fails immediately rather than "passing" against
whichever implementation happens to match.

### Property checks beyond the vectors

No finite vector set establishes a rule. `model/cpp/test/test_fxp_vectors.cpp`
additionally asserts, over swept ranges: shift-0 identity for all three quantisers;
saturation idempotence and range containment for every width 2..48; agreement between
`sat`, `sat_ovf` and `sat_flags`; `round() == round_even()` across shifts; the four tie
classes for both modes; the **measured** rounding bias of §4; the accumulator-width
non-overflow claim of §7; complex packing round-trip; and the sticky-flag clear-wins and
counter-saturation semantics.

### Fault-injection validation

A cross-check that passes against a correct implementation is evidence of nothing until
it is shown to fail against a wrong one. Three faults were injected before this work was
accepted, and each was caught:

| Injected fault | Caught by |
|---|---|
| RTL ties round toward `-infinity` instead of to even (`q + (q & 1)` → `q`) | `rtl_vs_vector` **and** `rtl_vs_cpp` failures, first at `rne_s1_kn3_half` |
| C++ saturation made symmetric (low end clamps to `-max`) | 114 failures in the standalone unit test, first at `sat_w16_minm2` |
| RTL `fxp_round_sat` saturates before rounding instead of after | 292 `rtl_vs_vector` and 292 `rtl_vs_cpp` failures with `cpp_vs_vector` clean — correctly localising the fault to the RTL |

Re-run these whenever a check is added or relaxed. The middle row matters most: it is the
fault a reviewer is least likely to notice by reading.

### Triage procedure

A numerics failure names its own category. Read it in this order:

1. `cpp_vs_vector` and `rtl_vs_vector` both non-zero and matching → the **vectors** are
   stale, or the rounding-mode tag mismatched. Check the header line and re-run the
   generator.
2. `cpp_vs_vector` zero, `rtl_vs_vector` non-zero → the **RTL package** diverged.
3. `cpp_vs_vector` non-zero, `rtl_vs_vector` zero → the **C++ model** diverged, and every
   downstream kernel test that used it as an oracle is suspect.
4. Both zero but a kernel test fails → the kernel is open-coding a quantisation. Grep it
   for `>>>`, `>>`, `+ 16384` and inline clamps; §0 rule 1.

Test mechanics live in [VERIFICATION_PLAN.md](VERIFICATION_PLAN.md).

## 11. Arithmetic boundary coverage

Every kernel must exercise this list, in addition to whatever its own §9 subsection adds.
The shared primitives are covered today by `model/vectors/` as shown.

| Boundary | Covered by |
|---|---|
| Q1.15 max positive `0x7FFF`, max negative `0x8000` | `sat_w16_*`, every `mul_e*` / `mrs_e*` pair |
| One and two values past each endpoint, at widths 4/8/12/16/24/32/40/48 | `sat_w*_maxp1`, `_maxp2`, `_minm1`, `_minm2` |
| `±1.0` wrap cases: `-(-1.0)`, `(-1.0)×(-1.0)`, `0x7FFF+1`, `0x8000-1` | `q15_neg_min`, `mrs_e0_0`, `q15_add_ovf`, `q15_sub_unf` |
| All four rounding tie classes, at shifts 1/15/30 | `rne_*_half`, `rhu_*_half` |
| Non-tie neighbours either side of a tie | `rne_*_hm1`, `rne_*_hp1`, `rne_*_r0` |
| Shift-0 identity | `rne_s0_*`, `rhu_s0_*`, `trc_s0_*` |
| Large shifts (31, 40, 62) | `rne_big_s*`, `rhu_big_s*`, `trc_big_s*` |
| Round-then-saturate at and across the target endpoints | `rsat_q15_*`, `rsat_w*_s*_*` |
| Every pair of nine Q1.15 boundary values through both multiply forms | `mul_e*_*`, `mrs_e*_*` (81 pairs each) |
| Complex multiply at eight complex boundary operands, both parts | `cre_*`, `cim_*` (64 pairs each) |
| Accumulator growth at and around every power of two, N up to 4096 | `gb_*`, `accw32_*`, `accw{16,24,48}_*` |
| Accumulation crossing overflow, both directions, and recovering from it | `climb_pos_16`, `climb_neg_16`, `recover_16`, `bounce_16` |
| Accumulation at the policy width that provably never saturates | `policy_pos_n*`, `policy_neg_n*` |
| Accumulation with the growth bits omitted (the counter-example) | `no_growth_32` |
| Seeded random coverage of every operation | `r_*` (530 vectors) |

Current totals: **1457 operation vectors** and **251 accumulator steps in 19 sequences**,
generated with seed `20260725`, in 78 KB of committed text. The Phase 2 gate (SPEC §19)
requires each kernel to add its own rows here.
