#!/usr/bin/env python3
"""Independent NumPy fixed-point reference (SPEC.md 6, SPEC.md 12.4).

SPEC 12.4: "Validate the C++ model independently against Python, NumPy, or
MATLAB-generated vectors before using it as the RTL oracle."

This module is that independent third implementation. It is written from
NUMERICS.md, not from ``rtl/packages/fxp_pkg.sv`` or ``model/cpp/fxp/fxp.hpp``,
and it is expressed differently on purpose: ``numpy.divmod`` and
``numpy.floor_divide`` rather than the masks and arithmetic shifts the two
implementations under test use. A transliteration would agree with a
transliteration's bug; a re-derivation is what makes agreement evidence.

It is NEVER compiled into, imported by, or linked against the RTL or C++ paths.
Its only job is to produce and re-check the golden vectors under
``model/vectors/`` (see ``gen_fxp_vectors.py``).

Domain
------
Everything here computes in ``numpy.int64``. That is exact — and identical to the
SystemVerilog 64-bit signed working type and to the C++ ``int64_t`` mirror — only
while no intermediate wraps, so the module enforces its domain rather than
trusting it:

    |v|  <= 2**62      operands and intermediates
    0    <= s <= 62    shift / fractional-bit counts
    2    <= w <= 63    target widths

``fxp_pkg`` and ``fxp.hpp`` additionally define ``s >= 64`` (result 0) and
``w >= 64`` (the full 64-bit range); those are degenerate cases outside this
module's domain and outside the generated vector set. They exist so the RTL and
C++ agree on a defined answer, not because any datapath reaches them.

Canonical interpreter: WSL Ubuntu-24.04 python3 (3.12), numpy >= 1.26.
"""

from __future__ import annotations

import numpy as np

# ---------------------------------------------------------------------------
# Formats — mirrors of the fxp_pkg localparams (NUMERICS.md 2, 3)
# ---------------------------------------------------------------------------

WIDE_W = 64
SAMPLE_W = 16
COEFF_W = 16
FRAC_W = 15
PROD_W = 32
PROD_FRAC_W = 30
PROD_SHIFT = PROD_FRAC_W - FRAC_W  # 15

Q15_MAX = (1 << (SAMPLE_W - 1)) - 1  # 32767  = +0.999969482421875
Q15_MIN = -(1 << (SAMPLE_W - 1))     # -32768 = -1.0

# The project-wide rounding rule (NUMERICS.md 4, DECISIONS.md).
ROUND_MODE = "nearest_even"

# Domain limits (see the module docstring).
DOMAIN_ABS_MAX = 1 << 62
MAX_SHIFT = 62
MIN_WIDTH = 2
MAX_WIDTH = 63


def _i64(x):
    """As an int64 array, checked against the module's operand domain."""
    a = np.asarray(x, dtype=np.int64)
    if a.size and int(np.max(np.abs(a))) > DOMAIN_ABS_MAX:
        raise ValueError(
            f"operand magnitude exceeds the int64 reference domain 2**62: "
            f"{int(np.max(np.abs(a)))}"
        )
    return a


def _shift(s):
    a = np.asarray(s, dtype=np.int64)
    if a.size and (int(np.min(a)) < 0 or int(np.max(a)) > MAX_SHIFT):
        raise ValueError(f"shift outside [0, {MAX_SHIFT}]")
    return a


def _width(w):
    a = np.asarray(w, dtype=np.int64)
    if a.size and (int(np.min(a)) < MIN_WIDTH or int(np.max(a)) > MAX_WIDTH):
        raise ValueError(f"width outside [{MIN_WIDTH}, {MAX_WIDTH}]")
    return a


# ---------------------------------------------------------------------------
# Range endpoints (NUMERICS.md 5)
# ---------------------------------------------------------------------------


def max_of(w):
    """Largest value representable in a signed w-bit field: 2**(w-1) - 1."""
    return np.left_shift(np.int64(1), _width(w) - 1) - np.int64(1)


def min_of(w):
    """Smallest value representable in a signed w-bit field: -2**(w-1)."""
    return -np.left_shift(np.int64(1), _width(w) - 1)


# ---------------------------------------------------------------------------
# Saturation
# ---------------------------------------------------------------------------


def sat(v, w):
    """Clamp to the full two's-complement range of a signed w-bit field."""
    return np.clip(_i64(v), min_of(w), max_of(w)).astype(np.int64)


def sat_pos(v, w):
    return _i64(v) > max_of(w)


def sat_neg(v, w):
    return _i64(v) < min_of(w)


def sat_flags(v, w):
    """Packed {sat_pos, sat_neg} — sat_pos is bit 1, sat_neg is bit 0."""
    return (sat_pos(v, w).astype(np.int64) << np.int64(1)) | sat_neg(
        v, w
    ).astype(np.int64)


# ---------------------------------------------------------------------------
# Truncation and rounding (NUMERICS.md 4, 6)
# ---------------------------------------------------------------------------


def trunc(v, s):
    """floor(v / 2**s) — round toward -infinity. Biased by -0.5 LSB."""
    v = _i64(v)
    s = _shift(s)
    return np.floor_divide(v, np.left_shift(np.int64(1), s)).astype(np.int64)


def round_half_up(v, s):
    """floor((v + 2**(s-1)) / 2**s). Asymmetric; NOT the project rule."""
    v = _i64(v)
    s = _shift(s)
    se = np.maximum(s, np.int64(1))
    scale = np.left_shift(np.int64(1), se)
    half = np.right_shift(scale, np.int64(1))
    shifted = np.floor_divide(v + half, scale)
    return np.where(s == 0, v, shifted).astype(np.int64)


def round_even(v, s):
    """Round to nearest, ties to even (convergent). THE PROJECT RULE.

    Expressed with ``numpy.divmod`` — whose remainder for a positive divisor is
    the floor remainder, non-negative even for negative ``v`` — rather than with
    the mask-and-shift form the RTL and C++ use.
    """
    v = _i64(v)
    s = _shift(s)
    se = np.maximum(s, np.int64(1))
    scale = np.left_shift(np.int64(1), se)
    q, r = np.divmod(v, scale)
    half = np.right_shift(scale, np.int64(1))
    inc = np.where(
        r > half,
        np.int64(1),
        np.where(r < half, np.int64(0), np.bitwise_and(q, np.int64(1))),
    )
    return np.where(s == 0, v, q + inc).astype(np.int64)


def round_(v, s):
    """The datapath rounding entry point. Selected by ROUND_MODE."""
    if ROUND_MODE == "half_up":
        return round_half_up(v, s)
    return round_even(v, s)


def round_sat(v, s, w):
    """Round first, saturate second — the order is normative (NUMERICS.md 6)."""
    return sat(round_(v, s), w)


def round_sat_flags(v, s, w):
    return sat_flags(round_(v, s), w)


# ---------------------------------------------------------------------------
# Saturating add / subtract / negate
# ---------------------------------------------------------------------------


def add_sat(a, b, w):
    return sat(_i64(a) + _i64(b), w)


def add_sat_flags(a, b, w):
    return sat_flags(_i64(a) + _i64(b), w)


def sub_sat(a, b, w):
    return sat(_i64(a) - _i64(b), w)


def sub_sat_flags(a, b, w):
    return sat_flags(_i64(a) - _i64(b), w)


def neg_sat(a, w):
    return sat(-_i64(a), w)


def neg_sat_flags(a, w):
    return sat_flags(-_i64(a), w)


# ---------------------------------------------------------------------------
# Q1.15 multiply (NUMERICS.md 3)
# ---------------------------------------------------------------------------


def mul_q15(a, b):
    """Exact Q1.15 x Q1.15 -> Q2.30. |result| <= 2**30."""
    return (_i64(a) * _i64(b)).astype(np.int64)


def mul_q15_rs(a, b):
    return round_sat(mul_q15(a, b), PROD_SHIFT, SAMPLE_W)


def mul_q15_rs_flags(a, b):
    return round_sat_flags(mul_q15(a, b), PROD_SHIFT, SAMPLE_W)


# ---------------------------------------------------------------------------
# Complex multiply (SPEC 6, four-real-multiply form)
#
# Rounded ONCE, after the exact two-term sum.
# ---------------------------------------------------------------------------


def cmul_re_raw(a_re, a_im, b_re, b_im):
    return mul_q15(a_re, b_re) - mul_q15(a_im, b_im)


def cmul_im_raw(a_re, a_im, b_re, b_im):
    return mul_q15(a_re, b_im) + mul_q15(a_im, b_re)


def cmul_re(a_re, a_im, b_re, b_im):
    return round_sat(cmul_re_raw(a_re, a_im, b_re, b_im), PROD_SHIFT, SAMPLE_W)


def cmul_im(a_re, a_im, b_re, b_im):
    return round_sat(cmul_im_raw(a_re, a_im, b_re, b_im), PROD_SHIFT, SAMPLE_W)


def cmul_re_flags(a_re, a_im, b_re, b_im):
    return round_sat_flags(
        cmul_re_raw(a_re, a_im, b_re, b_im), PROD_SHIFT, SAMPLE_W
    )


def cmul_im_flags(a_re, a_im, b_re, b_im):
    return round_sat_flags(
        cmul_im_raw(a_re, a_im, b_re, b_im), PROD_SHIFT, SAMPLE_W
    )


# ---------------------------------------------------------------------------
# Accumulator width policy (NUMERICS.md 7)
#
#   growth(N)   = ceil(log2 N)   [ growth(1) = 0, matching $clog2 ]
#   acc_w(P, N) = P + growth(N)
# ---------------------------------------------------------------------------


def growth_bits(n_terms):
    n = np.asarray(n_terms, dtype=np.int64)
    v = np.maximum(n, np.int64(1)) - np.int64(1)
    b = np.zeros_like(v)
    while bool(np.any(v > 0)):
        b = b + (v > 0).astype(np.int64)
        v = np.right_shift(v, np.int64(1))
    return b.astype(np.int64)


def acc_w(prod_w, n_terms):
    return (np.asarray(prod_w, dtype=np.int64) + growth_bits(n_terms)).astype(
        np.int64
    )


def mac_q15_acc_w(n_terms):
    """Accumulator width for an N-term Q1.15 MAC: 32 + ceil(log2 N)."""
    return acc_w(PROD_W, n_terms)


# ---------------------------------------------------------------------------
# Packing helpers used by the vector files
# ---------------------------------------------------------------------------


def pack_complex(re, im):
    """{im, re} into one 32-bit word, real part in the low half."""
    re_u = np.asarray(re, dtype=np.int64) & np.int64(0xFFFF)
    im_u = np.asarray(im, dtype=np.int64) & np.int64(0xFFFF)
    return ((im_u << np.int64(16)) | re_u).astype(np.int64)


def to_q15_bits(x):
    """Low 16 bits of x, reinterpreted as a signed Q1.15 value."""
    u = np.asarray(x, dtype=np.int64) & np.int64(0xFFFF)
    return np.where(u >= 0x8000, u - 0x10000, u).astype(np.int64)


def q15_to_float(x):
    """Diagnostic only. Never used to compute an expected value."""
    return np.asarray(x, dtype=np.float64) / float(1 << FRAC_W)
