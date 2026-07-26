# Golden fixed-point vectors

**These files are committed on purpose.** They are source-of-truth test data, not build
output. The point of a golden vector is that a change to it shows up as a reviewable
diff; a regenerated-on-demand vector set proves only that the generator agrees with
itself. `.gitignore` therefore ignores `model/cpp/build/` and does **not** ignore
`*.vec`. See DECISIONS.md, 2026-07-25 (issue #4).

Produced by [`model/python/gen_fxp_vectors.py`](../python/gen_fxp_vectors.py) from the
independent NumPy model [`model/python/fxp_reference.py`](../python/fxp_reference.py),
with seed `20260725`. Neither the RTL package nor the C++ library is consulted; the
expected values are an independent statement of what [`NUMERICS.md`](../../NUMERICS.md)
says the answer is (SPEC §12.4).

Regenerate, or verify without writing:

```bash
python3 model/python/gen_fxp_vectors.py            # rewrite
python3 model/python/gen_fxp_vectors.py --check    # verify only; non-zero on drift
```

`make numerics-check` runs the `--check` form, then the C++ unit test, then the Verilator
cross-check. It is a prerequisite of `make sim-tiny`.

## Format

Line-oriented ASCII: `#` comments, whitespace-separated fields, integers in signed
decimal, LF line endings. Chosen over JSON because the same three lines of parsing serve
a Verilator test binary, a standalone C++ unit test and a Python script, without any of
them vendoring a JSON library into a clean checkout (SPEC §16).

Header comments are parsed, not decoration:

| Key | Meaning |
|---|---|
| `schema` | format version; a reader that does not recognise it fails |
| `kind` | `ops`, `accum` or `cmult` |
| `rounding_mode` | `nearest_even` or `half_up`; a build whose `FXP_ROUND_MODE` disagrees fails immediately rather than "passing" against whichever implementation matches |
| `seed` | the generator seed that produced the file |
| `count` | number of records; a truncated file fails rather than passing short |
| `prod_w` | `cmult` only: width of the exact full-precision product. A build whose `fxp::cmult::kCmulProdW` disagrees fails rather than "passing" against whichever implementation matches |

### `fxp_ops.vec` — combinational operations

```text
# columns: id op a b sh w y flags
sat_w4_maxp1 sat 8 0 0 4 7 2
```

| Field | Meaning |
|---|---|
| `id` | unique label, used in failure messages |
| `op` | operation name; mirrored in `model/cpp/fxp/fxp_ops.hpp` and, by code, in `sim/verilator/tops/fxp_probe_top.sv` |
| `a`, `b` | operands, as the signed value of the 64-bit working type. A Q1.15 operand uses the low 16 bits; a complex operand packs `{im, re}` into the low 32 bits with the real part in the low half |
| `sh` | shift / fractional-bit count |
| `w` | target signed width in bits (for `acc_w`, the product width `P`) |
| `y` | expected result |
| `flags` | expected packed saturation flags: `sat_pos << 1 | sat_neg`. `0` for operations that cannot saturate |

Operations: `sat`, `trunc`, `round_even`, `round_half_up`, `round`, `round_sat`,
`add_sat`, `sub_sat`, `neg_sat`, `mul_q15`, `mul_q15_rs`, `cmul_re`, `cmul_im`, `acc_w`,
`growth_bits`.

### `fxp_accum.vec` — saturating accumulator sequences

```text
# columns: id step acc_w x y step_flags sticky_flags count
climb_pos_16 1 16 16384 32767 2 2 1
```

One line per accumulate step, so an intermediate divergence is caught at the step where
it happens rather than at the end of a sequence. Steps of a sequence are contiguous and
`step 0` follows a clear. `sticky_flags` and `count` are the state of the sticky-flag
collector after the step; the counter saturates at all-ones and never wraps.

Sequence families: `climb_*` / `bounce_*` / `recover_*` cross overflow in both
directions; `policy_*` accumulate worst-case Q1.15 products at the `acc_w(32, N)` policy
width and must never saturate; `no_growth_32` is the counter-example with the growth bits
omitted; `walk_w*` are seeded random walks.

### `cmult.vec` — complex multiplier (issue #9)

```text
# columns: id a_re a_im b_re b_im p_re p_im y_re y_im flags_re flags_im
cm_m1_m1_m1_m1 -32768 -32768 -32768 -32768 0 2147483648 0 32767 0 2
```

One record per operand pair, carrying **both** observable output formats of
`rtl/common/complex_multiplier.sv`, so one file proves the `ROUND_OUT = 1` and the
`ROUND_OUT = 0` build:

| Field | Meaning |
|---|---|
| `a_re`, `a_im`, `b_re`, `b_im` | the two complex operands, Q1.15 per component |
| `p_re`, `p_im` | the **exact** full-precision product, `prod_w = 33` bits (Q3.30). Never saturates and has no flags |
| `y_re`, `y_im` | the rounded Q1.15 product |
| `flags_re`, `flags_im` | packed saturation flags per component: `sat_pos << 1 \| sat_neg` |

The line above is the record a reader should look at first. It is `(-1-1j) x (-1-1j)`, whose
imaginary part is `+2^31` — one past the top of a signed 32-bit field, which is the whole
reason the full-precision port is 33 bits — and which then rounds to `+2^16` and saturates
to `0x7FFF` with `sat_pos`.

Families: `cm_*` is the 144-pair grid of every ordered pair of twelve corner operands;
`cmb_*` sweeps the round-then-saturate boundary one LSB at a time in both directions, through
both tie directions; `cms_*` puts each of the three Karatsuba pre-adders at its own extreme;
`cmu_*` multiplies by the near-unit values `±1` and `±j`; `cml_*` is every single-LSB sign
combination; `cmr_*` is the seeded random set.

The generator asserts two properties for **every** record as it writes it, so producing the
file re-proves them over the whole set: that the three-real-multiply factorization gives the
same integers as the four-real-multiply form, and that the exact product is representable in
`prod_w` bits. The statistical argument is made at run time instead — `sim/tests/test_cmult.cpp`
draws at least 24 000 fresh pairs per seed — so this file stays a reviewable size.

### `fft64.vec` — streaming FFT (issue #11)

Produced by [`model/python/gen_fft_vectors.py`](../python/gen_fft_vectors.py) with seed
`20260726`. Multi-line records: one `vec` line naming the configuration, then one `s` line
per sample.

```text
vec tone_5 ffffffff 1 00000
s 0 30000 0 512 0
```

| Field | Meaning |
|---|---|
| `vec <id>` | unique label, used in failure messages |
| `<scale_sched>` | the per-sub-stage scaling schedule, hex; bit *g* set means sub-stage *g* shifts right one place |
| `<reorder>` | `1` natural bin order, `0` bit-reversed beat order |
| `<stage_flags>` | hex; one `sat_pos << 1 \| sat_neg` field per butterfly sub-stage, sub-stage *g* at bits `[2g+1:2g]` — the frame's saturation, per stage |
| `s <i> …` | sample `i` in **beat order** (beat `i/spc`, slot `i%spc`), with the input pair and the expected output pair |

Extra header keys: `fft_size`, `spc`, `stages`, and `twiddle_digest` — the digest of the
table in [`rtl/fft/generated/fft_twiddle_pkg.sv`](../../rtl/fft/generated/fft_twiddle_pkg.sv).
A build whose digest differs **refuses to run** against this file rather than reporting
thousands of wrong samples: a coefficient change invalidates every expected output here,
and the digest turns that into one line.

Families: `imp_*` is an impulse at each position class, including one on the imaginary axis
and one at the `-1.0` sample whose negation saturates; `dc_*` is constant input at three
amplitudes; `tone_*` and `negtone_*` are single-bin tones including Nyquist and its
neighbours; `two_*` are two-tone combinations; `rand_*` are seeded random frames; `sat_*`
are maximum-amplitude inputs run with shifts REMOVED from the schedule, so they saturate
and their `stage_flags` are non-zero; `bitrev_*` are three inputs repeated with
`reorder = 0`, which pins the output permutation by data.

The generator additionally compares every non-saturating record against `numpy.fft.fft`
scaled by the schedule's gain, and fails above **16 LSB**; the committed set's worst is
3.0 LSB. That produces no expected value — the point is bit-exact fixed point — but it
catches the one class of error a self-consistent bit-exact model cannot: a transform that
agrees with itself and is not a DFT.

## Changing these files

A diff here is a change to the numerics. It must be accompanied by a NUMERICS.md change
and a DECISIONS.md entry, and it invalidates every downstream expected value.

## `pfb_<set>_p<P>t<T>.coeff` and `.vec` — polyphase FIR bank (issue #10)

Produced by [`scripts/generate_coefficients.py`](../../scripts/generate_coefficients.py) from
the independent NumPy model [`model/python/pfb_model.py`](../python/pfb_model.py), with master
seed `20260727` and a per-set seed derived from `(set, phases, taps)` so that adding a set or
a geometry does not perturb any other file. Regenerate, or verify without writing:

```bash
python3 scripts/generate_coefficients.py            # rewrite
python3 scripts/generate_coefficients.py --check    # verify only; non-zero on drift
```

`make coeff-check` runs the `--check` form and is a prerequisite of `make sim-tiny`.

Two geometries are committed: `p4t8`, the geometry
[`sim/verilator/tops/pfb_top.sv`](../../sim/verilator/tops/pfb_top.sv) elaborates, and
`p8t16`, the SPEC §7.1 nominal that the SPEC §18 calibration project compiles.

Five sets per geometry:

| Set | Prototype | Purpose |
|---|---|---|
| `proto` | windowed sinc, hann, real coefficients, L1-scaled to 0.98 | the real filter. Cannot clip on any legal input, so any saturation the RTL reports is a defect |
| `mixed` | windowed sinc, hamming, mixed to a channel centre | genuinely complex coefficients. A real-coefficient set cannot catch a swapped real and imaginary partial product |
| `ident` | per-phase unit impulse at maximum gain | every lane a pass-through: the one set whose expected output can be written down without running any model |
| `random` | uniform full-range Q1.15 | saturates on most beats, on purpose |
| `max` | every coefficient at a Q1.15 endpoint, alternating | the extreme case for the accumulator and for saturation in both directions, including `-1.0`, whose negation is not representable |

### `.coeff` — the quantised coefficients

```text
# columns: index phase tap re im
4 0 4 20196 0
```

Phase-major, tap-minor: `index = phase*taps + tap`, the order
`rtl/pfb/coeff_bank.sv` addresses and `COEFF_ADDR.INDEX` counts through. The redundant
`index` column is **checked** by the loader, so a file whose rows were reordered by a
well-meaning edit fails rather than loading a silently different filter.

### `.vec` — a golden input/output run

```text
# columns: beat x0_re x0_im .. y0_re y0_im .. f0_re f0_im ..
```

96 beats through the model from an all-zero history: zeros, a complex impulse, a constant, a
complex sinusoid, both Q1.15 endpoints, then random. `f*` is the packed saturation flag word
(`sat_pos<<1 | sat_neg`). Header keys `phases`, `taps`, `acc_w`, `coeff_file` and
`rounding_mode` are all parsed and checked, so a file generated for a different geometry or a
different rounding rule fails immediately rather than "passing" against whichever
implementation happens to match.
