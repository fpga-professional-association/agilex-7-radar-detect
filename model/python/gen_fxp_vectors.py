#!/usr/bin/env python3
"""Generate the golden fixed-point vectors under ``model/vectors/``.

    python3 model/python/gen_fxp_vectors.py [--out model/vectors] [--seed N]
    python3 model/python/gen_fxp_vectors.py --check      # verify, write nothing

SPEC 12.4 requires the C++ reference model to be validated against
Python/NumPy-generated vectors before it is trusted as the RTL oracle. This
script is the generator. Every expected value it writes comes from
``fxp_reference.py`` — the independent NumPy model — and from nothing else. It
never imports the C++ library or reads the RTL, so the vectors are an
independent statement of what NUMERICS.md says the answer is.

The output files are committed. They are source-of-truth test data, not build
artefacts: the point of a golden vector is that a change to it shows up as a
reviewable diff. ``--check`` regenerates in memory and compares, so CI can prove
the committed files are exactly what this script and this seed produce (PLAN.md
standing rule 3 read the way it is meant: no *generated build output*, but
reproducible test data whose diff is the evidence).

Coverage (issue #4 acceptance gate)
-----------------------------------
* saturation boundaries: max positive, max negative, one past each, and the
  Q1.15 +-1.0 wrap cases, at eight widths;
* rounding ties: all four tie classes of round-to-nearest-even
  (+1.5 -> +2, +0.5 -> 0, -0.5 -> 0, -1.5 -> -2) plus their non-tie neighbours,
  at several shift amounts, for BOTH rounding modes so the comparison in
  NUMERICS.md 4 is measured rather than asserted;
* multiply + round + saturate compositions, including every pair of Q1.15
  boundary values and the (-1.0)x(-1.0) -> +1.0 saturation;
* complex multiplies at the same boundaries;
* accumulator-width formula values;
* accumulation sequences that cross overflow in both directions, and sequences
  at the policy width acc_w(32, N) that provably never saturate;
* seeded random vectors for every operation.

Format: see model/vectors/README.md and DECISIONS.md.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

import fxp_reference as R  # noqa: E402

SCHEMA = 1
DEFAULT_SEED = 20260725
REPO_ROOT = Path(__file__).resolve().parents[2]

# Operation names. MIRRORED in model/cpp/fxp/fxp_ops.hpp (kOpTable) and, by
# code, in sim/verilator/tops/fxp_probe_top.sv (FXP_OP_*).
OPS = (
    "sat",
    "trunc",
    "round_even",
    "round_half_up",
    "round",
    "round_sat",
    "add_sat",
    "sub_sat",
    "neg_sat",
    "mul_q15",
    "mul_q15_rs",
    "cmul_re",
    "cmul_im",
    "acc_w",
    "growth_bits",
)


# ---------------------------------------------------------------------------
# Evaluation — expected values come from fxp_reference and nowhere else.
# ---------------------------------------------------------------------------


def evaluate(op: str, a: int, b: int, sh: int, w: int) -> tuple[int, int]:
    """Returns (expected_y, expected_packed_flags) for one operation."""
    if op == "sat":
        return int(R.sat(a, w)), int(R.sat_flags(a, w))
    if op == "trunc":
        return int(R.trunc(a, sh)), 0
    if op == "round_even":
        return int(R.round_even(a, sh)), 0
    if op == "round_half_up":
        return int(R.round_half_up(a, sh)), 0
    if op == "round":
        return int(R.round_(a, sh)), 0
    if op == "round_sat":
        return int(R.round_sat(a, sh, w)), int(R.round_sat_flags(a, sh, w))
    if op == "add_sat":
        return int(R.add_sat(a, b, w)), int(R.add_sat_flags(a, b, w))
    if op == "sub_sat":
        return int(R.sub_sat(a, b, w)), int(R.sub_sat_flags(a, b, w))
    if op == "neg_sat":
        return int(R.neg_sat(a, w)), int(R.neg_sat_flags(a, w))
    if op in ("mul_q15", "mul_q15_rs"):
        a16 = R.to_q15_bits(a)
        b16 = R.to_q15_bits(b)
        if op == "mul_q15":
            return int(R.mul_q15(a16, b16)), 0
        return int(R.mul_q15_rs(a16, b16)), int(R.mul_q15_rs_flags(a16, b16))
    if op in ("cmul_re", "cmul_im"):
        a_re = R.to_q15_bits(a)
        a_im = R.to_q15_bits(np.int64(a) >> np.int64(16))
        b_re = R.to_q15_bits(b)
        b_im = R.to_q15_bits(np.int64(b) >> np.int64(16))
        if op == "cmul_re":
            return (
                int(R.cmul_re(a_re, a_im, b_re, b_im)),
                int(R.cmul_re_flags(a_re, a_im, b_re, b_im)),
            )
        return (
            int(R.cmul_im(a_re, a_im, b_re, b_im)),
            int(R.cmul_im_flags(a_re, a_im, b_re, b_im)),
        )
    if op == "acc_w":
        return int(R.acc_w(w, a)), 0
    if op == "growth_bits":
        return int(R.growth_bits(a)), 0
    raise ValueError(f"unknown op {op!r}")


class OpVectors:
    """Accumulates op records and renders the file."""

    def __init__(self) -> None:
        self.rows: list[tuple[str, str, int, int, int, int, int, int]] = []
        self._ids: set[str] = set()

    def add(self, vid: str, op: str, a: int, b: int = 0, sh: int = 0,
            w: int = 16) -> None:
        if op not in OPS:
            raise ValueError(f"unknown op {op!r}")
        if vid in self._ids:
            raise ValueError(f"duplicate vector id {vid!r}")
        self._ids.add(vid)
        y, flags = evaluate(op, a, b, sh, w)
        self.rows.append((vid, op, a, b, sh, w, y, flags))

    def render(self, seed: int) -> str:
        lines = [
            "# fxp vector file",
            f"# schema: {SCHEMA}",
            "# kind: ops",
            f"# rounding_mode: {R.ROUND_MODE}",
            f"# seed: {seed}",
            f"# count: {len(self.rows)}",
            "# generator: model/python/gen_fxp_vectors.py",
            "# reference: model/python/fxp_reference.py (NumPy, independent)",
            "# columns: id op a b sh w y flags",
            "# flags is packed {sat_pos<<1 | sat_neg}; 0 for ops that cannot saturate",
        ]
        for r in self.rows:
            lines.append(" ".join(str(x) for x in r))
        return "\n".join(lines) + "\n"


class AccumVectors:
    """Accumulates saturating-accumulator sequences and renders the file."""

    def __init__(self) -> None:
        self.rows: list[tuple[str, int, int, int, int, int, int, int]] = []
        self._ids: set[str] = set()

    def add_sequence(self, name: str, width: int, xs) -> None:
        if name in self._ids:
            raise ValueError(f"duplicate sequence id {name!r}")
        self._ids.add(name)
        acc = np.int64(0)
        sticky = 0
        count = 0
        for step, x in enumerate(xs):
            x = int(x)
            raw = acc + np.int64(x)
            flags = int(R.sat_flags(raw, width))
            acc = R.sat(raw, width)
            sticky |= flags
            if flags != 0:
                count += 1
            self.rows.append(
                (name, step, width, x, int(acc), flags, sticky, count)
            )

    def render(self, seed: int) -> str:
        lines = [
            "# fxp vector file",
            f"# schema: {SCHEMA}",
            "# kind: accum",
            f"# rounding_mode: {R.ROUND_MODE}",
            f"# seed: {seed}",
            f"# count: {len(self.rows)}",
            "# generator: model/python/gen_fxp_vectors.py",
            "# reference: model/python/fxp_reference.py (NumPy, independent)",
            "# columns: id step acc_w x y step_flags sticky_flags count",
            "# one line per accumulate step; step 0 follows a clear",
        ]
        for r in self.rows:
            lines.append(" ".join(str(x) for x in r))
        return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Directed vectors
# ---------------------------------------------------------------------------

SAT_WIDTHS = (4, 8, 12, 16, 24, 32, 40, 48)
TIE_SHIFTS = (1, 15, 30)
Q15_EDGES = (-32768, -32767, -16384, -1, 0, 1, 16384, 32766, 32767)


def directed_saturation(v: OpVectors) -> None:
    """Max positive, max negative, one/two past each, and mid-range."""
    for w in SAT_WIDTHS:
        hi = (1 << (w - 1)) - 1
        lo = -(1 << (w - 1))
        cases = {
            "max": hi,
            "maxp1": hi + 1,
            "maxp2": hi + 2,
            "min": lo,
            "minm1": lo - 1,
            "minm2": lo - 2,
            "zero": 0,
            "one": 1,
            "negone": -1,
            "far_hi": hi * 3 + 7,
            "far_lo": lo * 3 - 7,
        }
        for name, val in cases.items():
            v.add(f"sat_w{w}_{name}", "sat", val, w=w)

    # The Q1.15 +-1.0 wrap cases, called out by name because they are the ones
    # that break naive code: negating -1.0 is not representable, and the
    # positive endpoint is one LSB short of +1.0.
    v.add("q15_neg_min", "neg_sat", -32768, w=16)     # -(-1.0) -> +max, sat_pos
    v.add("q15_neg_max", "neg_sat", 32767, w=16)      # exact
    v.add("q15_neg_zero", "neg_sat", 0, w=16)
    v.add("q15_neg_one", "neg_sat", 1, w=16)
    v.add("q15_neg_min32", "neg_sat", -(1 << 31), w=32)
    v.add("q15_add_ovf", "add_sat", 32767, 1, w=16)   # +1 past max
    v.add("q15_add_unf", "add_sat", -32768, -1, w=16)
    v.add("q15_add_maxmax", "add_sat", 32767, 32767, w=16)
    v.add("q15_add_minmin", "add_sat", -32768, -32768, w=16)
    v.add("q15_sub_ovf", "sub_sat", 32767, -1, w=16)
    v.add("q15_sub_unf", "sub_sat", -32768, 1, w=16)
    v.add("q15_sub_minmax", "sub_sat", -32768, 32767, w=16)
    for w in (8, 16, 32, 40):
        hi = (1 << (w - 1)) - 1
        lo = -(1 << (w - 1))
        v.add(f"addsat_w{w}_edge", "add_sat", hi, 1, w=w)
        v.add(f"addsat_w{w}_edgn", "add_sat", lo, -1, w=w)
        v.add(f"subsat_w{w}_edge", "sub_sat", lo, 1, w=w)
        v.add(f"subsat_w{w}_edgn", "sub_sat", hi, -1, w=w)
        v.add(f"negsat_w{w}_min", "neg_sat", lo, w=w)


def directed_rounding(v: OpVectors) -> None:
    """All four RNE tie classes and their neighbours, both modes, plus trunc.

    For shift s, half = 2^(s-1). A value k*2^s + half is an exact tie. The four
    classes are (k even, k odd) x (k >= 0, k < 0):

        k=+1 -> +1.5 LSB -> +2   (tie up to even)
        k= 0 -> +0.5 LSB ->  0   (tie down to even)
        k=-1 -> -0.5 LSB ->  0   (tie up to even)
        k=-2 -> -1.5 LSB -> -2   (tie down to even)
    """
    for s in TIE_SHIFTS:
        scale = 1 << s
        half = scale >> 1
        for k in (-3, -2, -1, 0, 1, 2, 3):
            residues = {"r0": 0, "hm1": half - 1, "half": half, "hp1": half + 1}
            for rname, r in residues.items():
                val = k * scale + r
                tag = f"s{s}_k{k}_{rname}".replace("-", "n")
                v.add(f"rne_{tag}", "round_even", val, sh=s)
                v.add(f"rhu_{tag}", "round_half_up", val, sh=s)
                v.add(f"rnd_{tag}", "round", val, sh=s)
                v.add(f"trc_{tag}", "trunc", val, sh=s)

    # Shift 0 must be the identity for every rounding function.
    for i, val in enumerate((-5, -1, 0, 1, 5, 32767, -32768)):
        v.add(f"rne_s0_{i}", "round_even", val, sh=0)
        v.add(f"rhu_s0_{i}", "round_half_up", val, sh=0)
        v.add(f"rnd_s0_{i}", "round", val, sh=0)
        v.add(f"trc_s0_{i}", "trunc", val, sh=0)

    # Large shifts, at and near the reference-domain limit.
    for s in (31, 40, 62):
        for i, val in enumerate((0, 1, -1, (1 << s) - 1, 1 << s, -(1 << s))):
            v.add(f"rne_big_s{s}_{i}", "round_even", val, sh=s)
            v.add(f"rhu_big_s{s}_{i}", "round_half_up", val, sh=s)
            v.add(f"trc_big_s{s}_{i}", "trunc", val, sh=s)


def directed_round_sat(v: OpVectors) -> None:
    """round-then-saturate, including the case only that order catches.

    A value one tie below the top of the target range rounds UP past the range
    and must then saturate. Saturating before rounding would clamp first, round
    the clamped value, and report no overflow.
    """
    s = 15
    scale = 1 << s
    hi = 32767
    lo = -32768
    cases = {
        "at_max": hi * scale,
        "tie_over_max": hi * scale + (scale >> 1),          # rounds to 32768
        "just_over_max": hi * scale + (scale >> 1) + 1,
        "tie_under_max": hi * scale - (scale >> 1),
        "at_min": lo * scale,
        "tie_under_min": lo * scale - (scale >> 1),         # rounds to -32769
        "just_under_min": lo * scale - (scale >> 1) - 1,
        "tie_over_min": lo * scale + (scale >> 1),
        "zero": 0,
        "half": scale >> 1,
        "neg_half": -(scale >> 1),
        "one_and_half": scale + (scale >> 1),
    }
    for name, val in cases.items():
        v.add(f"rsat_q15_{name}", "round_sat", val, sh=s, w=16)

    for w in (8, 12, 24, 32):
        hi_w = (1 << (w - 1)) - 1
        lo_w = -(1 << (w - 1))
        for sh in (1, 4, 15):
            sc = 1 << sh
            v.add(f"rsat_w{w}_s{sh}_hi", "round_sat",
                  hi_w * sc + (sc >> 1), sh=sh, w=w)
            v.add(f"rsat_w{w}_s{sh}_lo", "round_sat",
                  lo_w * sc - (sc >> 1), sh=sh, w=w)


def directed_multiply(v: OpVectors) -> None:
    """Every pair of Q1.15 boundary values through both multiply forms."""
    for i, a in enumerate(Q15_EDGES):
        for j, b in enumerate(Q15_EDGES):
            v.add(f"mul_e{i}_{j}", "mul_q15", a, b)
            v.add(f"mrs_e{i}_{j}", "mul_q15_rs", a, b)


def directed_complex(v: OpVectors) -> None:
    """Complex multiplies at the boundaries, including the +1.0 saturation."""
    edges = (
        ("m1_0", -32768, 0),      # -1.0 + 0j
        ("p1_0", 32767, 0),
        ("0_m1", 0, -32768),
        ("m1_m1", -32768, -32768),
        ("p1_p1", 32767, 32767),
        ("h_h", 16384, 16384),
        ("z", 0, 0),
        ("one", 1, -1),
    )
    for an, a_re, a_im in edges:
        for bn, b_re, b_im in edges:
            pa = int(R.pack_complex(a_re, a_im))
            pb = int(R.pack_complex(b_re, b_im))
            v.add(f"cre_{an}_{bn}", "cmul_re", pa, pb)
            v.add(f"cim_{an}_{bn}", "cmul_im", pa, pb)


ACC_TERM_COUNTS = (
    1, 2, 3, 4, 5, 6, 7, 8, 9, 15, 16, 17, 31, 32, 33, 63, 64, 65,
    100, 128, 256, 1000, 1024, 4096,
)


def directed_acc_width(v: OpVectors) -> None:
    """The accumulator-growth formula, at and around every power of two."""
    for n in ACC_TERM_COUNTS:
        v.add(f"gb_{n}", "growth_bits", n)
        v.add(f"accw32_{n}", "acc_w", n, w=32)
    for prod_w in (16, 24, 48):
        for n in (1, 4, 5, 64, 1000):
            v.add(f"accw{prod_w}_{n}", "acc_w", n, w=prod_w)


# ---------------------------------------------------------------------------
# Random vectors
# ---------------------------------------------------------------------------

RANDOM_COUNTS = {
    "sat": 40,
    "trunc": 40,
    "round_even": 40,
    "round_half_up": 40,
    "round": 40,
    "round_sat": 60,
    "add_sat": 40,
    "sub_sat": 40,
    "neg_sat": 30,
    "mul_q15": 40,
    "mul_q15_rs": 40,
    "cmul_re": 40,
    "cmul_im": 40,
}


def random_vectors(v: OpVectors, seed: int) -> None:
    rng = np.random.default_rng(seed)

    def wide(n, bits=40):
        return rng.integers(-(1 << bits), (1 << bits), size=n, dtype=np.int64)

    def q15(n):
        return rng.integers(-32768, 32768, size=n, dtype=np.int64)

    def widths(n):
        return rng.integers(4, 49, size=n, dtype=np.int64)

    def shifts(n):
        return rng.integers(0, 41, size=n, dtype=np.int64)

    for op, count in RANDOM_COUNTS.items():
        if op == "sat":
            a, w = wide(count), widths(count)
            for i in range(count):
                v.add(f"r_sat_{i}", "sat", int(a[i]), w=int(w[i]))
        elif op in ("trunc", "round_even", "round_half_up", "round"):
            a, s = wide(count), shifts(count)
            for i in range(count):
                v.add(f"r_{op}_{i}", op, int(a[i]), sh=int(s[i]))
        elif op == "round_sat":
            a, s, w = wide(count), shifts(count), widths(count)
            for i in range(count):
                v.add(f"r_rsat_{i}", "round_sat", int(a[i]), sh=int(s[i]),
                      w=int(w[i]))
        elif op in ("add_sat", "sub_sat"):
            # Operands scaled to the target width so roughly half the cases
            # actually saturate; drawing from a fixed range would make wide
            # targets never saturate and narrow ones always saturate.
            w = widths(count)
            for i in range(count):
                lim = 1 << int(w[i])
                a = int(rng.integers(-lim, lim, dtype=np.int64))
                b = int(rng.integers(-lim, lim, dtype=np.int64))
                v.add(f"r_{op}_{i}", op, a, b, w=int(w[i]))
        elif op == "neg_sat":
            w = widths(count)
            for i in range(count):
                lim = 1 << int(w[i])
                a = int(rng.integers(-lim, lim, dtype=np.int64))
                v.add(f"r_neg_{i}", "neg_sat", a, w=int(w[i]))
        elif op in ("mul_q15", "mul_q15_rs"):
            a, b = q15(count), q15(count)
            tag = "mul" if op == "mul_q15" else "mrs"
            for i in range(count):
                v.add(f"r_{tag}_{i}", op, int(a[i]), int(b[i]))
        elif op in ("cmul_re", "cmul_im"):
            a_re, a_im, b_re, b_im = q15(count), q15(count), q15(count), q15(count)
            tag = "cre" if op == "cmul_re" else "cim"
            for i in range(count):
                pa = int(R.pack_complex(a_re[i], a_im[i]))
                pb = int(R.pack_complex(b_re[i], b_im[i]))
                v.add(f"r_{tag}_{i}", op, pa, pb)


# ---------------------------------------------------------------------------
# Accumulation sequences
# ---------------------------------------------------------------------------


def accum_sequences(acc: AccumVectors, seed: int) -> None:
    rng = np.random.default_rng(seed ^ 0x5EED)

    # Directed: climb past +max and past -min, one quarter-scale step at a time.
    acc.add_sequence("climb_pos_16", 16, [16384] * 8)
    acc.add_sequence("climb_neg_16", 16, [-16384] * 8)

    # Saturate, then walk back out of saturation: proves the clamp is a clamp
    # and not a latch, and that the sticky flag survives the recovery.
    acc.add_sequence("recover_16", 16,
                     [20000, 20000, 20000, -20000, -20000, -20000, -20000,
                      -20000, -20000])

    # Alternating overshoot in both directions.
    acc.add_sequence("bounce_16", 16, [25000, -25000] * 6)

    # The policy width: acc_w(32, N) = 32 + ceil(log2 N). Worst-case Q1.15
    # products are +-2^30, so an N-term accumulation at the policy width must
    # never saturate. These sequences assert count == 0 by construction.
    for n in (3, 4, 8, 16):
        width = int(R.mac_q15_acc_w(n))
        acc.add_sequence(f"policy_pos_n{n}_w{width}", width, [1 << 30] * n)
        acc.add_sequence(f"policy_neg_n{n}_w{width}", width, [-(1 << 30)] * n)

    # The counter-example: the same eight products in a 32-bit accumulator,
    # i.e. the growth bits omitted. It saturates on the second term.
    acc.add_sequence("no_growth_32", 32, [1 << 30] * 8)

    # Randomized walks across a range of widths. Step magnitude is set so that
    # saturation is reached but not immediately, which is where the interesting
    # per-step flag transitions live.
    for width in (16, 20, 24, 32, 35, 40):
        lim = 1 << (width - 2)
        xs = rng.integers(-lim, lim, size=24, dtype=np.int64)
        acc.add_sequence(f"walk_w{width}", width, xs)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def build(seed: int) -> tuple[str, str]:
    ops = OpVectors()
    directed_saturation(ops)
    directed_rounding(ops)
    directed_round_sat(ops)
    directed_multiply(ops)
    directed_complex(ops)
    directed_acc_width(ops)
    random_vectors(ops, seed)

    acc = AccumVectors()
    accum_sequences(acc, seed)

    return ops.render(seed), acc.render(seed)


def _display(path: Path) -> str:
    """Repo-relative when it can be, absolute otherwise. `--out` may point
    anywhere, and a ValueError from relative_to() must not sink the run."""
    try:
        return str(path.resolve().relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def write_if_needed(path: Path, content: str, check: bool) -> bool:
    """Returns True when the file on disk already matches `content`."""
    existing = None
    if path.is_file():
        existing = path.read_text(encoding="utf-8")
    if existing == content:
        print(f"  {_display(path)}: up to date")
        return True
    if check:
        print(f"  {_display(path)}: DIFFERS from the generator output",
              file=sys.stderr)
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8", newline="\n")
    print(f"  {_display(path)}: written "
          f"({len(content.encode('utf-8'))} bytes)")
    return True


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--out", default=str(REPO_ROOT / "model" / "vectors"),
                   help="output directory (default: model/vectors)")
    p.add_argument("--seed", type=int, default=DEFAULT_SEED,
                   help=f"deterministic seed (default: {DEFAULT_SEED})")
    p.add_argument("--check", action="store_true",
                   help="verify the committed files match; write nothing")
    args = p.parse_args()

    out = Path(args.out)
    ops_text, acc_text = build(args.seed)

    print(f"[vectors] seed={args.seed} rounding_mode={R.ROUND_MODE} "
          f"{'check' if args.check else 'write'}")
    ok = write_if_needed(out / "fxp_ops.vec", ops_text, args.check)
    ok = write_if_needed(out / "fxp_accum.vec", acc_text, args.check) and ok

    total = len(ops_text.encode("utf-8")) + len(acc_text.encode("utf-8"))
    print(f"[vectors] total {total} bytes")
    if not ok:
        print("ERROR: committed vectors do not match the generator output. "
              "Re-run without --check and review the diff.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
