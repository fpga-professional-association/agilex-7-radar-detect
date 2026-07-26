#!/usr/bin/env python3
"""Generate the shared FFT twiddle table (issue #11, SPEC 6 / 7.2 / 12.4).

    python3 model/python/gen_fft_twiddles.py            # rewrite the artefacts
    python3 model/python/gen_fft_twiddles.py --check    # verify only; non-zero on drift

Two artefacts, both committed:

    rtl/fft/generated/fft_twiddle_pkg.sv     the table as a SystemVerilog package
    model/cpp/fft/fft_twiddle_table.hpp      the same table for the C++ model

Why the table is generated ONCE and committed
---------------------------------------------
The FFT's twiddle coefficients are the only numbers in this design that come
from transcendental functions. Every other constant is an integer. A table
computed at elaboration time would be computed three times — by Verilator's
libm, by Quartus's libm and by Python's — and "the three agree in the last unit
in the last place, on every host, for every entry" is an assumption that cannot
be checked from inside a simulation: a Quartus/Verilator disagreement produces
hardware that differs from the model it was verified against and NOTHING in the
flow would notice.

So the table is computed once, here, and becomes a committed integer artefact.
Then the RTL, the C++ model and the golden vectors are reading the same 2048
integers by construction rather than by coincidence, and the only thing that has
to be reproducible is this script — which ``--check`` proves on every lint and
every regression, exactly the way ``scripts/gen_regmap.py --check`` proves the
register map. The precedent and the reasoning are the same as for the committed
generated register map (DECISIONS.md, issue #7, decision 2) and for the
committed golden vectors (issue #4).

The values
----------
The master table holds W_M^e = exp(-j*2*pi*e/M) for e in [0, M), M = 1024 =
FFT_TW_N, quantised to Q1.15 per component. Every FFT_SIZE this benchmark uses
divides M, and W_L^e = W_M^(e * M/L), so one table serves every stage of every
size: the index arithmetic is in fft_pkg.sv and in fft_ref.hpp, and there is no
second table anywhere.

Quantisation rule (NORMATIVE — mirrored in the header of the generated files):

    re(e) = clamp(rne(cos(2*pi*e/M) * 2^15), -2^15, 2^15 - 1)
    im(e) = clamp(rne(-sin(2*pi*e/M) * 2^15), -2^15, 2^15 - 1)

with ``rne`` = round-to-nearest, ties-to-even, i.e. the project rounding rule of
NUMERICS.md 4 applied to a real number rather than to a fixed-point one.
Note that re(0) SATURATES: cos(0) = 1.0 is not representable in Q1.15, so
W^0 quantises to 0x7FFF, not to "exactly one". That is a real property of the
format and the whole design is built on it — see DECISIONS.md (issue #11,
"twiddle quantisation"), which records why the FFT multiplies by the quantised
W^0 instead of bypassing the multiplier for trivial twiddles.

Angle reduction. cos/sin are evaluated only on the first quadrant and the other
three are produced by exact sign/swap symmetry, so the four axis points come out
as exactly (+-1, 0) / (0, +-1) rather than as whatever the host's libm returns
for cos(pi/2). That removes the only entries where two libm implementations
could plausibly differ, and it makes ``--check`` portable in practice as well as
in principle. Scalar ``math``, not ``numpy``: a vectorised libm may use a
different kernel from the scalar one, and this table is small enough that the
speed does not matter.

Runs on the standard library alone.
"""

from __future__ import annotations

import argparse
import hashlib
import math
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent

SV_OUT = Path("rtl/fft/generated/fft_twiddle_pkg.sv")
HPP_OUT = Path("model/cpp/fft/fft_twiddle_table.hpp")

# Master table size. Covers every FFT_SIZE in SPEC 11 (largest is 1024). Raising
# it is a regeneration and a DECISIONS.md note, not a silent edit: every golden
# vector pins the table digest.
TW_N = 1024

# Q1.15, from fxp_pkg (FXP_SAMPLE_W / FXP_FRAC_W). Repeated rather than imported
# so this script has no dependency beyond the standard library; the generated
# files carry a static assertion against the package in both languages.
SAMPLE_W = 16
FRAC_W = 15
Q15_MAX = (1 << (SAMPLE_W - 1)) - 1
Q15_MIN = -(1 << (SAMPLE_W - 1))


# ---------------------------------------------------------------------------
# Quantisation
# ---------------------------------------------------------------------------


def rne(x: float) -> int:
    """Round-to-nearest, ties-to-even, of a real number.

    Python's built-in round() is exactly this for floats (IEEE 754 roundTiesToEven
    on the decimal-free case), and it is used rather than an open-coded
    floor(x+0.5) because the project rounding rule is convergent (NUMERICS.md 4)
    and a half-up helper here would be a second rounding rule in the design.
    """
    return int(round(x))


def q15(x: float) -> int:
    """Real number -> Q1.15, rounded to nearest-even then saturated."""
    v = rne(x * float(1 << FRAC_W))
    if v > Q15_MAX:
        return Q15_MAX
    if v < Q15_MIN:
        return Q15_MIN
    return v


def cos_sin(e: int) -> tuple[float, float]:
    """cos(2*pi*e/TW_N), sin(2*pi*e/TW_N) with exact quadrant symmetry.

    The reduction is what makes the four axis points exact: e = TW_N/4 returns
    (0.0, 1.0) rather than (6.1e-17, 1.0), so the quantised table has a true zero
    there and W^(N/4) is exactly -j. Every trivial twiddle the radix-2^2
    structure relies on is therefore exact in the table as well as in the
    structure.
    """
    quadrant, rem = divmod(e % TW_N, TW_N // 4)
    if rem == 0:
        c0, s0 = 1.0, 0.0
    else:
        theta = 2.0 * math.pi * float(rem) / float(TW_N)
        c0, s0 = math.cos(theta), math.sin(theta)
    if quadrant == 0:
        return c0, s0
    if quadrant == 1:
        return -s0, c0
    if quadrant == 2:
        return -c0, -s0
    return s0, -c0


def twiddle(e: int) -> tuple[int, int]:
    """W_TW_N^e = exp(-j*2*pi*e/TW_N) as a Q1.15 (re, im) pair."""
    c, s = cos_sin(e)
    return q15(c), q15(-s)


def packed(re: int, im: int) -> int:
    """{im, re} in one 32-bit word, real part in the low half.

    The same packing fxp_pkg::fxp_complex_t uses and the same packing
    fxp_reference.pack_complex writes into the vector files, so one convention
    covers the RTL, the C++ model, the Python model and the golden data.
    """
    return ((im & 0xFFFF) << 16) | (re & 0xFFFF)


def build_table() -> list[int]:
    return [packed(*twiddle(e)) for e in range(TW_N)]


def digest(table: list[int]) -> str:
    """Short digest of the table, embedded in both artefacts and in the vectors.

    A twiddle change is a numerics change: it invalidates every expected FFT
    output in model/vectors/. The digest is what makes that a loud failure —
    sim/tests/test_fft.cpp refuses to run a vector file whose digest does not
    match the table the build was compiled with — rather than a silent
    disagreement between a stale vector and a new table.
    """
    h = hashlib.sha256()
    for word in table:
        h.update(word.to_bytes(4, "little"))
    return h.hexdigest()[:16]


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

_PROVENANCE = (
    "Produced by model/python/gen_fft_twiddles.py. DO NOT EDIT: a hand edit is\n"
    "erased by the next run and, before that, fails `make fft-twiddle-check`,\n"
    "which `make lint` and `make sim-tiny` both depend on."
)

_RULE = [
    "Master twiddle table, W_M^e = exp(-j*2*pi*e/M) for e in [0, M), M = 1024.",
    "",
    "  re(e) = clamp(rne(cos(2*pi*e/M) * 2^15), -2^15, 2^15 - 1)",
    "  im(e) = clamp(rne(-sin(2*pi*e/M) * 2^15), -2^15, 2^15 - 1)",
    "",
    "rne is round-to-nearest ties-to-even (NUMERICS.md 4). Each entry is packed",
    "{im, re} into 32 bits with the real part in the low half — the packing of",
    "fxp_pkg::fxp_complex_t.",
    "",
    "re(0) is 0x7FFF, not 'one': cos(0) = 1.0 is not representable in Q1.15.",
    "The FFT multiplies by this value rather than bypassing the multiplier for",
    "trivial twiddles; see DECISIONS.md (issue #11).",
    "",
    "Every FFT_SIZE this design elaborates divides M, and W_L^e = W_M^(e*M/L),",
    "so this one table serves every stage of every size. The index arithmetic",
    "lives in rtl/fft/fft_pkg.sv and model/cpp/fft/fft_ref.hpp.",
]


def render_sv(table: list[int]) -> str:
    lines: list[str] = []
    a = lines.append
    a("// GENERATED FILE - DO NOT EDIT.")
    a("//")
    for line in _PROVENANCE.splitlines():
        a(f"// {line}")
    a("//")
    for line in _RULE:
        a(f"// {line}".rstrip())
    a("//")
    a("// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.")
    a("")
    a("`default_nettype none")
    a("")
    a("package fft_twiddle_pkg;")
    a("")
    a("  // Master table size. FFT_SIZE must divide this (checked in fft_pkg).")
    a(f"  localparam int unsigned FFT_TW_N = {TW_N};")
    a("")
    a("  // Q1.15 per component, packed {im, re}. Checked against fxp_pkg's own")
    a("  // widths by fft_pkg at elaboration.")
    a(f"  localparam int unsigned FFT_TW_SAMPLE_W = {SAMPLE_W};")
    a(f"  localparam int unsigned FFT_TW_W        = {2 * SAMPLE_W};")
    a("")
    a("  // Digest of the table, pinned by the golden vectors so that a twiddle")
    a("  // change cannot be silently paired with stale expected outputs.")
    a(f'  localparam string FFT_TW_DIGEST = "{digest(table)}";')
    a("")
    a("  localparam logic [FFT_TW_W-1:0] FFT_TW [FFT_TW_N] = '{")
    per_line = 4
    for base in range(0, TW_N, per_line):
        chunk = table[base : base + per_line]
        body = ", ".join(f"32'h{w:08X}" for w in chunk)
        comma = "," if base + per_line < TW_N else ""
        a(f"      {body}{comma}   // e = {base}..{base + len(chunk) - 1}")
    a("  };")
    a("")
    a("  // The one accessor. Everything that needs a twiddle goes through it, so")
    a("  // there is exactly one place the table is indexed.")
    a("  function automatic logic [FFT_TW_W-1:0] fft_tw_word(input int unsigned e);")
    a("    return FFT_TW[e % FFT_TW_N];")
    a("  endfunction")
    a("")
    a("endpackage : fft_twiddle_pkg")
    a("")
    a("`default_nettype wire")
    a("")
    return "\n".join(lines)


def render_hpp(table: list[int]) -> str:
    lines: list[str] = []
    a = lines.append
    a("// GENERATED FILE - DO NOT EDIT.")
    a("//")
    for line in _PROVENANCE.splitlines():
        a(f"// {line}")
    a("//")
    for line in _RULE:
        a(f"// {line}".rstrip())
    a("//")
    a("// C++ half of rtl/fft/generated/fft_twiddle_pkg.sv. The two are emitted")
    a("// from the same list of integers in the same run, so the model and the RTL")
    a("// cannot be built against different twiddles.")
    a("//")
    a("// Header-only. Build contract: g++ 13, -std=c++17 -O3 -Wall -Wextra -Werror.")
    a("#ifndef MODEL_CPP_FFT_FFT_TWIDDLE_TABLE_HPP_")
    a("#define MODEL_CPP_FFT_FFT_TWIDDLE_TABLE_HPP_")
    a("")
    a("#include <cstdint>")
    a("")
    a("namespace fft {")
    a("")
    a(f"inline constexpr unsigned kTwN = {TW_N};        // FFT_TW_N")
    a(f"inline constexpr unsigned kTwSampleW = {SAMPLE_W};  // FFT_TW_SAMPLE_W")
    a(f"inline constexpr unsigned kTwW = {2 * SAMPLE_W};        // FFT_TW_W")
    a("")
    a(f'inline constexpr const char* kTwDigest = "{digest(table)}";')
    a("")
    a("// Packed {im, re}, real part in the low half.")
    a("inline constexpr std::uint32_t kTw[kTwN] = {")
    per_line = 6
    for base in range(0, TW_N, per_line):
        chunk = table[base : base + per_line]
        body = ", ".join(f"0x{w:08X}u" for w in chunk)
        comma = "," if base + per_line < TW_N else ""
        a(f"    {body}{comma}  // e = {base}..{base + len(chunk) - 1}")
    a("};")
    a("")
    a("}  // namespace fft")
    a("")
    a("#endif  // MODEL_CPP_FFT_FFT_TWIDDLE_TABLE_HPP_")
    a("")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def write_if_needed(path: Path, content: str, check: bool) -> bool:
    """Returns True when the file on disk already matches `content`."""
    full = REPO_ROOT / path
    on_disk = None
    if full.is_file():
        with full.open("r", encoding="utf-8", newline="") as fh:
            on_disk = fh.read()
    if on_disk == content:
        return True
    if check:
        return False
    full.parent.mkdir(parents=True, exist_ok=True)
    with full.open("w", encoding="utf-8", newline="\n") as fh:
        fh.write(content)
    return False


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--check", action="store_true",
                   help="verify the committed artefacts match; write nothing")
    p.add_argument("--quiet", action="store_true")
    args = p.parse_args()

    table = build_table()
    artefacts = [(SV_OUT, render_sv(table)), (HPP_OUT, render_hpp(table))]

    stale: list[Path] = []
    for path, content in artefacts:
        if not write_if_needed(path, content, args.check):
            stale.append(path)

    if args.check:
        if stale:
            print(
                "ERROR: FFT twiddle artefacts are stale or hand edited:\n  "
                + "\n  ".join(str(s) for s in stale)
                + "\nRe-run `python3 model/python/gen_fft_twiddles.py` and review "
                  "the diff. A twiddle change is a numerics change: it also "
                  "invalidates model/vectors/fft*.vec.",
                file=sys.stderr,
            )
            return 1
        if not args.quiet:
            print(f"[fft-twiddle] check: {len(artefacts)} artefacts match "
                  f"(N={TW_N}, digest {digest(table)})")
        return 0

    if not args.quiet:
        for path, _ in artefacts:
            mark = "written" if path in stale else "unchanged"
            print(f"[fft-twiddle] {path}: {mark}")
        print(f"[fft-twiddle] N={TW_N} digest={digest(table)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
