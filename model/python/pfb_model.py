#!/usr/bin/env python3
"""NumPy reference for the SPEC 7.1 polyphase FIR bank (issue #10).

Governing spec: SPEC.md 6 (numerics), 7.1 (polyphase FIR bank), 12.4 (reference
model). Normative prose: NUMERICS.md.

WHAT THIS FILE IS FOR, AND WHAT IT IS NOT
-----------------------------------------
It is the INDEPENDENT statement of what a polyphase FIR bank computes. It is
written against ``model/python/fxp_reference.py`` — the NumPy fixed-point model
from issue #4 — and it consults neither the SystemVerilog package nor the C++
library. That independence is the whole point: the vectors it emits are an
expectation, and an expectation produced by the implementation under test is not
an expectation.

The triangle it closes is the one SPEC 12.4 asks for:

    rtl/pfb/*.sv   <-->   model/cpp/pfb/pfb_model.hpp   <-->   this file
        (Verilator)            (bit-accurate C++)            (NumPy, independent)

``sim/tests/test_pfb_bank.cpp`` checks the RTL against the C++ model on every
beat and both of them against the committed vectors on the directed pass.

THE DECOMPOSITION
-----------------
A prototype low-pass filter ``h`` of length ``phases * taps`` is split into
``phases`` polyphase branches::

    h_p[k] = h[k * phases + p]        p = 0 .. phases-1,  k = 0 .. taps-1

and branch ``p`` filters the decimated substream ``x_p[m] = x[m*phases + p]``::

    y_p[m] = sum_k h_p[k] * x_p[m-k]

A beat carries ``phases`` consecutive samples, so beat ``m`` of the output is
``y_0[m] .. y_{phases-1}[m]``. The branches do NOT share history: this is the
critically-decimated polyphase front end, not one long filter evaluated at
``phases`` samples per cycle. rtl/pfb/pfb_bank.sv says the same thing at greater
length.

THE ARITHMETIC (NUMERICS.md, and it is not negotiable)
------------------------------------------------------
Per output component, the branch accumulates ``2 * taps`` EXACT Q1.15 x Q1.15
products at full precision::

    acc_re = sum_k (h_k.re*x_k.re - h_k.im*x_k.im)
    acc_im = sum_k (h_k.re*x_k.im + h_k.im*x_k.re)

and quantises ONCE, at the end, with round-to-nearest-even followed by
saturation to Q1.15. There is no intermediate rounding and no intermediate
saturation: fxp_reference.acc_w(PROD_W, 2*taps) is wide enough that the
accumulation provably cannot overflow, which is also what makes the RTL's adder
tree and its systolic cascade bit-identical.

Everything here is exact Python integer arithmetic. NumPy is used for the filter
DESIGN (sinc, windows) in scripts/generate_coefficients.py, never for the
fixed-point evaluation — a float accumulator would disagree with the RTL in the
last bit and the disagreement would be invisible until it was not.

Usage as a library::

    from pfb_model import PfbModel, decompose, quantise_complex
    m = PfbModel(phases=4, taps=8, coeff=coeff_list)
    y, flags = m.step([(re, im), ...])       # one beat in, one beat out
"""

from __future__ import annotations

import os
import sys
from dataclasses import dataclass, field

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import fxp_reference as fxp  # noqa: E402  (path set above)

SCHEMA_VERSION = 1

# Q1.15 endpoints, from the reference rather than written as literals.
Q15_MAX = int(fxp.max_of(fxp.SAMPLE_W))
Q15_MIN = int(fxp.min_of(fxp.SAMPLE_W))


# ---------------------------------------------------------------------------
# Polyphase decomposition and quantisation
# ---------------------------------------------------------------------------


def decompose(proto: list[complex], phases: int, taps: int) -> list[list[complex]]:
    """Split a length ``phases*taps`` prototype into per-phase branches.

    Returns ``out[p][k] = proto[k*phases + p]``. Raises on a length mismatch
    rather than padding: a prototype of the wrong length is a design error, and
    silently zero-padding it would produce a filter nobody asked for.
    """
    if len(proto) != phases * taps:
        raise ValueError(
            f"prototype has {len(proto)} taps; phases*taps = {phases*taps}"
        )
    return [[proto[k * phases + p] for k in range(taps)] for p in range(phases)]


def quantise_q15(x: float) -> tuple[int, bool, bool]:
    """Round-to-nearest-even then saturate one real value into Q1.15.

    Returns ``(value, sat_pos, sat_neg)``.

    The rounding is done on the EXACT scaled rational, not on a float: the value
    is scaled by 2**FRAC_W into a Python integer numerator with a known
    denominator, and fxp_reference.round_sat does the rest. That is what makes
    this bit-exact with the RTL rather than exact-to-a-float's-idea-of-half.
    """
    # Represent x * 2**FRAC_W exactly enough to round: scale by an extra
    # 2**SCALE_BITS, round that to an integer (the float's own rounding, which is
    # exact for the magnitudes involved), then let the fixed-point reference do
    # the last, semantically meaningful, rounding step.
    scale_bits = 20
    scaled = int(round(x * float(1 << (fxp.FRAC_W + scale_bits))))
    flags = int(fxp.round_sat_flags(scaled, scale_bits, fxp.SAMPLE_W))
    value = int(fxp.round_sat(scaled, scale_bits, fxp.SAMPLE_W))
    return value, bool(flags & 2), bool(flags & 1)


def quantise_complex(z: complex) -> tuple[int, int]:
    """Quantise a complex coefficient to a Q1.15 ``(re, im)`` pair."""
    re, _, _ = quantise_q15(z.real)
    im, _, _ = quantise_q15(z.imag)
    return re, im


# ---------------------------------------------------------------------------
# The model
# ---------------------------------------------------------------------------


@dataclass
class LaneModel:
    """One complex FIR branch. Exact integer arithmetic throughout."""

    taps: int
    coeff: list[tuple[int, int]]          # [(re, im)] per tap, tap 0 = newest
    history: list[tuple[int, int]] = field(default_factory=list)

    def __post_init__(self) -> None:
        if len(self.coeff) != self.taps:
            raise ValueError(
                f"lane has {len(self.coeff)} coefficients for {self.taps} taps"
            )
        # History starts at zero, exactly as the RTL's unreset delay line reads
        # once its valid pipeline says enough beats have been admitted.
        self.history = [(0, 0)] * (self.taps - 1)

    def reset(self) -> None:
        self.history = [(0, 0)] * (self.taps - 1)

    def acc(self, x: tuple[int, int]) -> tuple[int, int]:
        """Exact accumulators for one input sample, WITHOUT quantising."""
        samples = [x] + self.history          # samples[k] = x[n-k]
        acc_re = 0
        acc_im = 0
        for k in range(self.taps):
            xr, xi = samples[k]
            hr, hi = self.coeff[k]
            # int() at every step: fxp_reference works in numpy int64 and the
            # accumulator must be an exact Python integer, not a 64-bit type
            # that could wrap silently if a future width grew.
            acc_re += int(fxp.cmul_re_raw(xr, xi, hr, hi))
            acc_im += int(fxp.cmul_im_raw(xr, xi, hr, hi))
        return acc_re, acc_im

    def step(self, x: tuple[int, int]) -> tuple[tuple[int, int], tuple[int, int]]:
        """Consume one sample; return ``((y_re, y_im), (flags_re, flags_im))``.

        Flags are the packed ``sat_pos<<1 | sat_neg`` encoding the RTL uses.
        """
        acc_re, acc_im = self.acc(x)
        y_re = int(fxp.round_sat(acc_re, fxp.PROD_SHIFT, fxp.SAMPLE_W))
        y_im = int(fxp.round_sat(acc_im, fxp.PROD_SHIFT, fxp.SAMPLE_W))
        f_re = int(fxp.round_sat_flags(acc_re, fxp.PROD_SHIFT, fxp.SAMPLE_W))
        f_im = int(fxp.round_sat_flags(acc_im, fxp.PROD_SHIFT, fxp.SAMPLE_W))
        # Advance the history AFTER the evaluation: tap k is x[n-k], so the
        # sample being consumed is tap 0 of THIS beat and tap 1 of the next.
        self.history = ([x] + self.history)[: self.taps - 1]
        return (y_re, y_im), (f_re, f_im)


class PfbModel:
    """``phases`` independent :class:`LaneModel` branches, stepped per beat."""

    def __init__(self, phases: int, taps: int,
                 coeff: list[tuple[int, int]]) -> None:
        if len(coeff) != phases * taps:
            raise ValueError(
                f"{len(coeff)} coefficients for a {phases}x{taps} bank"
            )
        self.phases = phases
        self.taps = taps
        # Phase-major, tap-minor: index = phase*taps + tap. The same order
        # rtl/pfb/coeff_bank.sv addresses and scripts/generate_coefficients.py
        # writes, so no consumer re-derives the mapping.
        self.lanes = [
            LaneModel(taps=taps, coeff=coeff[p * taps:(p + 1) * taps])
            for p in range(phases)
        ]

    def reset(self) -> None:
        for lane in self.lanes:
            lane.reset()

    def step(self, beat: list[tuple[int, int]]):
        """One beat of ``phases`` complex samples in, one beat out."""
        if len(beat) != self.phases:
            raise ValueError(f"beat has {len(beat)} samples, expected {self.phases}")
        ys = []
        fs = []
        for p, lane in enumerate(self.lanes):
            y, f = lane.step(beat[p])
            ys.append(y)
            fs.append(f)
        return ys, fs


def acc_width(taps: int) -> int:
    """Accumulator width for one component of a ``taps``-tap complex FIR."""
    return int(fxp.acc_w(fxp.PROD_W, 2 * taps))
