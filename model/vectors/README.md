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

## Changing these files

A diff here is a change to the numerics. It must be accompanied by a NUMERICS.md change
and a DECISIONS.md entry, and it invalidates every downstream expected value.
