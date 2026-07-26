#!/usr/bin/env python3
"""Generate the golden streaming-FFT vectors under ``model/vectors/`` (issue #11).

    python3 model/python/gen_fft_vectors.py [--out model/vectors] [--seed N]
    python3 model/python/gen_fft_vectors.py --check      # verify, write nothing

WHICH MODEL IS THE ORACLE
-------------------------
Three implementations of the same fixed-point transform exist, and they are
arranged in the triangle SPEC 12.4 asks for — the same one issues #4 and #9 use:

    this script (NumPy/Python)  ---writes--->  model/vectors/fft64.vec
              |                                        |
              | independent of both                    | committed, reviewable
              v                                        v
    model/cpp/fft/fft_ref.hpp  <---checked against---  the vectors
              |
              | per-beat oracle
              v
          rtl/fft/*.sv

So: **the vectors are the oracle for the C++ model, and the C++ model is the
oracle for the RTL.** This script never imports the C++ library and never reads
the RTL; the expected values below are an independent statement of what fft_pkg
and NUMERICS.md say the answer is. sim/tests/test_fft.cpp then requires the RTL,
the C++ model and these vectors to agree bit-for-bit on the directed set, so any
two of the three disagreeing is a named failure rather than a silent
substitution of one for the other.

The one thing that is deliberately NOT re-derived here is the twiddle TABLE. It
is imported from ``gen_fft_twiddles.py``, because the table is a shared committed
artefact by design — the RTL's ROMs, the C++ model and these vectors all read the
same 1024 integers, and that is the whole point of committing it (see that
script's header). What is independent here is the ALGORITHM: the decimation-in-
time lane split, the radix-2^2 butterfly schedule, the trivial-twiddle rule, the
scaling and the output permutation are written out again, from fft_pkg's prose,
rather than transcribed from the C++.

Every quantisation goes through ``fxp_reference.py``, the shared independent
NumPy numerics model, exactly as gen_fxp_vectors.py does. No rounding rule is
invented here (NUMERICS.md 4).

FLOAT CROSS-CHECK
-----------------
Each record is also compared against ``numpy.fft.fft`` of the same input, scaled
by the schedule's total gain. That does not produce the expected values — it
cannot, the whole point is bit-exact fixed point — but it does catch the class of
error a bit-exact self-consistent model cannot: a transform that is internally
consistent and is not a DFT. The bound is printed by ``--report`` and asserted
here, so "this is a Fourier transform" is checked rather than assumed.

Coverage (SPEC 7.2 verification cases)
--------------------------------------
* impulse at several position classes: 0, 1, an odd interior position, N/2 and
  N-1 — the positions whose bit-reversed images differ most;
* DC at half scale and at full scale;
* single-bin tones at low bins, at N/4, at the Nyquist-adjacent bins and at
  Nyquist itself;
* negative-frequency tones (bins N-1 and N-3);
* two-tone combinations, including one pair straddling Nyquist;
* seeded random frames (three of them, from three distinct substreams);
* maximum-amplitude saturation stress, including records run with the shifts
  REMOVED from the schedule so that the saturation flags are exercised rather
  than reasoned about;
* the same input under REORDER = 0 and REORDER = 1, so the output permutation is
  pinned by data.

Format: see model/vectors/README.md.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

import fxp_reference as fx           # noqa: E402
import gen_fft_twiddles as twgen     # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent.parent

SCHEMA = 1
DEFAULT_SEED = 20260726
OUT_NAME = "fft64.vec"

FFT_SIZE = 64
SPC = 2
SAMPLE_W = 16

# The master twiddle table, as (re, im) pairs. Imported, not recomputed: see the
# header. The digest travels into the vector header so a table change cannot be
# paired with stale expected outputs.
TW_TABLE = [twgen.twiddle(e) for e in range(twgen.TW_N)]
TW_DIGEST = twgen.digest(twgen.build_table())
TW_LOG2N = 10


# ---------------------------------------------------------------------------
# Fixed-point helpers — every one a call into the shared numerics model
# ---------------------------------------------------------------------------


def q(v: int, sh: int) -> int:
    """Round once at `sh`, then saturate into Q1.15. fxp_pkg's order."""
    return int(fx.round_sat(int(v), sh, SAMPLE_W))


def qflags(v: int, sh: int) -> int:
    """Packed {sat_pos<<1 | sat_neg} of the ROUNDED value."""
    return int(fx.round_sat_flags(int(v), sh, SAMPLE_W))


def neg_sat(v: int) -> int:
    return int(fx.neg_sat(int(v), SAMPLE_W))


def neg_sat_flags(v: int) -> int:
    return int(fx.neg_sat_flags(int(v), SAMPLE_W))


def cmul(a: tuple[int, int], b: tuple[int, int]) -> tuple[int, int]:
    return (int(fx.cmul_re(a[0], a[1], b[0], b[1])),
            int(fx.cmul_im(a[0], a[1], b[0], b[1])))


def cmul_flags(a: tuple[int, int], b: tuple[int, int]) -> int:
    return (int(fx.cmul_re_flags(a[0], a[1], b[0], b[1])) |
            int(fx.cmul_im_flags(a[0], a[1], b[0], b[1])))


# ---------------------------------------------------------------------------
# Structure — fft_pkg's rules, written out from the prose
# ---------------------------------------------------------------------------


def log2_exact(v: int) -> int:
    assert v > 0 and (v & (v - 1)) == 0, f"{v} is not a power of two"
    return v.bit_length() - 1


def bitrev(v: int, w: int) -> int:
    r = 0
    for i in range(w):
        if (v >> i) & 1:
            r |= 1 << (w - 1 - i)
    return r


def bf_is_bf2ii(s: int) -> bool:
    return (s % 2) == 1


def stage_has_twiddle(n: int, s: int) -> bool:
    return bf_is_bf2ii(s) and s + 1 < n


def group_l2l(n: int, s: int) -> int:
    return n - s + 1


def r22_tw_exp(l2l: int, p: int) -> int:
    qv = p & ((1 << l2l) - 1)
    k1 = (qv >> (l2l - 1)) & 1
    k2 = (qv >> (l2l - 2)) & 1
    n3 = qv & ((1 << (l2l - 2)) - 1)
    return n3 * (k1 + 2 * k2)


def tw(l2l: int, e: int) -> tuple[int, int]:
    return TW_TABLE[e << (TW_LOG2N - l2l)]


def shift_of(sched: int, g: int) -> int:
    return (sched >> g) & 1


# ---------------------------------------------------------------------------
# The transform
# ---------------------------------------------------------------------------


def butterfly_stage(v: list[tuple[int, int]], n_lane: int, s: int, sched: int,
                    flags: list[int], g: int) -> None:
    """One BF2I / BF2II sub-stage, in place.

    Block length L = 2^(n-s). The first L/2 entries of a block are the samples
    the hardware holds in its delay feedback, the second L/2 the samples
    arriving; BF2II multiplies the arriving one by -j when the block index is
    odd, which is the position bit above the phase bit.
    """
    l = 1 << (n_lane - s)
    half = l // 2
    sh = shift_of(sched, s)
    bf2ii = bf_is_bf2ii(s)

    for b in range(0, len(v), l):
        k1 = bf2ii and (((b // l) & 1) != 0)
        for i in range(half):
            a = v[b + i]
            t = v[b + half + i]
            if k1:
                flags[g] |= neg_sat_flags(t[0])
                t = (t[1], neg_sat(t[0]))
            sre = a[0] + t[0]
            sim = a[1] + t[1]
            dre = a[0] - t[0]
            dim = a[1] - t[1]
            flags[g] |= (qflags(sre, sh) | qflags(sim, sh) |
                         qflags(dre, sh) | qflags(dim, sh))
            v[b + i] = (q(sre, sh), q(sim, sh))
            v[b + half + i] = (q(dre, sh), q(dim, sh))


def twiddle_stage(v: list[tuple[int, int]], n_lane: int, s: int,
                  flags: list[int], g: int) -> None:
    l2l = group_l2l(n_lane, s)
    for i in range(len(v)):
        w = tw(l2l, r22_tw_exp(l2l, i))
        flags[g] |= cmul_flags(v[i], w)
        v[i] = cmul(v[i], w)


def merge(e: list[tuple[int, int]], o: list[tuple[int, int]], n_lane: int,
          sched: int, flags: list[int], g: int) -> list[tuple[int, int]]:
    m = len(e)
    sh = shift_of(sched, n_lane)
    beats: list[tuple[int, int]] = [(0, 0)] * (2 * m)
    for j in range(m):
        w = tw(n_lane + 1, bitrev(j, n_lane))
        flags[g] |= cmul_flags(o[j], w)
        t = cmul(o[j], w)
        sre = e[j][0] + t[0]
        sim = e[j][1] + t[1]
        dre = e[j][0] - t[0]
        dim = e[j][1] - t[1]
        flags[g] |= (qflags(sre, sh) | qflags(sim, sh) |
                     qflags(dre, sh) | qflags(dim, sh))
        beats[2 * j + 0] = (q(sre, sh), q(sim, sh))
        beats[2 * j + 1] = (q(dre, sh), q(dim, sh))
    return beats


def transform(x: list[tuple[int, int]], n: int, spc: int, sched: int,
              reorder: bool):
    """Returns (beats, stage_flags, bins)."""
    m = n // spc
    n_lane = log2_exact(m)
    n_stage = log2_exact(n)
    flags = [0] * n_stage

    lanes = [[x[t * spc + p] for t in range(m)] for p in range(spc)]

    for lane in lanes:
        for s in range(n_lane):
            butterfly_stage(lane, n_lane, s, sched, flags, s)
            if stage_has_twiddle(n_lane, s):
                twiddle_stage(lane, n_lane, s, flags, s)

    if spc == 1:
        beats = list(lanes[0])
    else:
        beats = merge(lanes[0], lanes[1], n_lane, sched, flags, n_lane)

    bins: list[tuple[int, int]] = [(0, 0)] * n
    for j in range(m):
        mj = bitrev(j, n_lane)
        for p in range(spc):
            bins[mj + p * (n // spc)] = beats[j * spc + p]

    if reorder:
        out = [(0, 0)] * n
        for j in range(m):
            src = bitrev(j, n_lane)
            for p in range(spc):
                out[j * spc + p] = beats[src * spc + p]
    else:
        out = list(beats)

    return out, flags, bins


# ---------------------------------------------------------------------------
# The float cross-check: this must actually be a DFT
# ---------------------------------------------------------------------------


def float_error(x: list[tuple[int, int]], bins: list[tuple[int, int]],
                sched: int, n: int) -> float:
    """Worst absolute error, in Q1.15 LSBs, against numpy's float FFT.

    The schedule's shifts are a division by 2 per set bit, so the fixed-point
    result approximates gain * DFT(x) with gain = 2^-popcount(sched bits used).
    The comparison is diagnostic, never an expected value.
    """
    n_stage = log2_exact(n)
    used = sched & ((1 << n_stage) - 1)
    gain = 0.5 ** bin(used).count("1")
    xf = np.array([complex(a, b) for a, b in x], dtype=np.complex128)
    ref = np.fft.fft(xf) * gain
    got = np.array([complex(a, b) for a, b in bins], dtype=np.complex128)
    return float(np.max(np.abs(ref - got)))


# ---------------------------------------------------------------------------
# Stimulus
# ---------------------------------------------------------------------------

Q15_MAX = 32767
Q15_MIN = -32768


def frame_zero(n: int) -> list[tuple[int, int]]:
    return [(0, 0)] * n


def frame_impulse(n: int, pos: int, amp: int = Q15_MAX) -> list[tuple[int, int]]:
    x = frame_zero(n)
    x[pos] = (amp, 0)
    return x


def frame_dc(n: int, amp: int) -> list[tuple[int, int]]:
    return [(amp, 0)] * n


def frame_tone(n: int, k: int, amp: int):
    """amp * exp(+j 2 pi k t / n), quantised through the master twiddle table.

    Built from the SAME table the transform multiplies by, rather than from a
    second sine generator: a tone at bin k is then exactly the conjugate of the
    coefficients the transform will use, and the test measures the transform
    instead of measuring the agreement of two trigonometric routines.
    """
    step = twgen.TW_N // n
    x = []
    for t in range(n):
        re, im = TW_TABLE[((k * t) % n) * step]
        im = neg_sat(im)          # conjugate: the table holds exp(-j...)
        x.append((int(fx.mul_q15_rs(re, amp)), int(fx.mul_q15_rs(im, amp))))
    return x


def frame_two_tone(n: int, k1: int, k2: int, a1: int, a2: int):
    t1 = frame_tone(n, k1, a1)
    t2 = frame_tone(n, k2, a2)
    return [(int(fx.add_sat(p[0], qq[0], SAMPLE_W)),
             int(fx.add_sat(p[1], qq[1], SAMPLE_W)))
            for p, qq in zip(t1, t2)]


def frame_random(rng, n: int, edge_p: float = 0.0):
    edges = [Q15_MIN, Q15_MIN + 1, -16384, -1, 0, 1, 16384, Q15_MAX - 1, Q15_MAX]
    x = []
    for _ in range(n):
        comp = []
        for _ in range(2):
            if edge_p > 0.0 and rng.random() < edge_p:
                comp.append(int(edges[rng.integers(0, len(edges))]))
            else:
                comp.append(int(rng.integers(Q15_MIN, Q15_MAX + 1)))
        x.append((comp[0], comp[1]))
    return x


def frame_full_scale(n: int, sign_pattern: str):
    """Every sample at a Q1.15 endpoint. The saturation-stress input."""
    x = []
    for t in range(n):
        if sign_pattern == "all_min":
            x.append((Q15_MIN, Q15_MIN))
        elif sign_pattern == "all_max":
            x.append((Q15_MAX, Q15_MAX))
        elif sign_pattern == "alt":
            x.append((Q15_MAX, Q15_MIN) if (t % 2) == 0 else (Q15_MIN, Q15_MAX))
        else:  # "half_split"
            x.append((Q15_MAX, 0) if t < n // 2 else (Q15_MIN, 0))
    return x


# ---------------------------------------------------------------------------
# Record assembly
# ---------------------------------------------------------------------------

SCHED_ALL = 0xFFFFFFFF
SCHED_NONE = 0                    # no shifts at all: maximum overflow pressure
SCHED_LATE = 0b000011             # shift only the first two sub-stages


class Record:
    def __init__(self, rid, x, sched, reorder):
        self.id = rid
        self.x = x
        self.sched = sched
        self.reorder = reorder
        self.out, self.flags, self.bins = transform(x, FFT_SIZE, SPC, sched,
                                                    reorder)
        self.float_err = float_error(x, self.bins, sched, FFT_SIZE)


def build_records(seed: int) -> list[Record]:
    n = FFT_SIZE
    recs: list[Record] = []
    add = recs.append

    # ---- impulses, one per position class ----------------------------------
    for pos in (0, 1, 3, n // 4, n // 2, n - 1):
        add(Record(f"imp_{pos}", frame_impulse(n, pos), SCHED_ALL, True))
    # An imaginary-axis impulse, so a real/imaginary swap anywhere is visible.
    x = frame_zero(n)
    x[5] = (0, Q15_MAX)
    add(Record("imp_j_5", x, SCHED_ALL, True))
    # The -1.0 impulse: the one sample value whose negation saturates.
    add(Record("imp_min_2", frame_impulse(n, 2, Q15_MIN), SCHED_ALL, True))

    # ---- DC ----------------------------------------------------------------
    add(Record("dc_half", frame_dc(n, 16384), SCHED_ALL, True))
    add(Record("dc_max", frame_dc(n, Q15_MAX), SCHED_ALL, True))
    add(Record("dc_min", frame_dc(n, Q15_MIN), SCHED_ALL, True))

    # ---- single-bin tones ---------------------------------------------------
    for k in (1, 2, 5, n // 4, n // 2 - 1, n // 2, n // 2 + 1):
        add(Record(f"tone_{k}", frame_tone(n, k, 30000), SCHED_ALL, True))

    # ---- negative-frequency tones ------------------------------------------
    for k in (n - 1, n - 3, n - n // 4):
        add(Record(f"negtone_{k}", frame_tone(n, k, 30000), SCHED_ALL, True))

    # ---- two tones ----------------------------------------------------------
    add(Record("two_3_11", frame_two_tone(n, 3, 11, 15000, 12000), SCHED_ALL,
               True))
    add(Record("two_1_nyq", frame_two_tone(n, 1, n // 2, 16000, 16000),
               SCHED_ALL, True))
    add(Record("two_5_neg5", frame_two_tone(n, 5, n - 5, 16000, 16000),
               SCHED_ALL, True))

    # ---- random -------------------------------------------------------------
    for i in range(3):
        rng = np.random.default_rng(seed + 1000 * (i + 1))
        add(Record(f"rand_{i}", frame_random(rng, n, edge_p=0.25), SCHED_ALL,
                   True))

    # ---- saturation stress --------------------------------------------------
    # With the shifts removed the butterflies grow by a bit per sub-stage, so
    # these records DO saturate and their stage_flags are non-zero. That is the
    # scaling/overflow case of SPEC 7.2, pinned by data.
    for pattern in ("all_min", "all_max", "alt", "half_split"):
        add(Record(f"sat_{pattern}", frame_full_scale(n, pattern), SCHED_NONE,
                   True))
    add(Record("sat_late_dc", frame_dc(n, Q15_MAX), SCHED_LATE, True))
    rng = np.random.default_rng(seed + 9999)
    add(Record("sat_rand", frame_random(rng, n, edge_p=0.9), SCHED_NONE, True))

    # ---- the output permutation, pinned by data ----------------------------
    # The same three inputs with REORDER = 0. Comparing these against their
    # reordered twins is what makes the bit-reversal a checked property.
    add(Record("bitrev_imp_1", frame_impulse(n, 1), SCHED_ALL, False))
    add(Record("bitrev_tone_5", frame_tone(n, 5, 30000), SCHED_ALL, False))
    rng = np.random.default_rng(seed + 4242)
    add(Record("bitrev_rand", frame_random(rng, n, edge_p=0.25), SCHED_ALL,
               False))

    return recs


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------


def pack_flags(flags: list[int]) -> int:
    v = 0
    for g, f in enumerate(flags):
        v |= (f & 0x3) << (2 * g)
    return v


def render(records: list[Record], seed: int) -> str:
    n_stage = log2_exact(FFT_SIZE)
    lines = [
        "# fft vector file",
        f"# schema: {SCHEMA}",
        "# kind: fft",
        f"# rounding_mode: {fx.ROUND_MODE}",
        f"# seed: {seed}",
        f"# count: {len(records)}",
        f"# fft_size: {FFT_SIZE}",
        f"# spc: {SPC}",
        f"# stages: {n_stage}",
        f"# twiddle_digest: {TW_DIGEST}",
        "# generator: model/python/gen_fft_vectors.py",
        "# reference: model/python/fxp_reference.py (NumPy, independent)",
        "# columns(record): vec <id> <scale_sched_hex> <reorder> <stage_flags_hex>",
        "# columns(sample): s <i> <in_re> <in_im> <out_re> <out_im>",
        "# stage_flags packs one {sat_pos<<1|sat_neg} field per butterfly",
        "# sub-stage, sub-stage g at bits [2g+1:2g]",
        "# samples are in BEAT ORDER: beat b slot p is index b*spc + p",
    ]
    for r in records:
        lines.append(
            f"vec {r.id} {r.sched & 0xFFFFFFFF:08x} {1 if r.reorder else 0} "
            f"{pack_flags(r.flags):05x}"
        )
        for i in range(FFT_SIZE):
            xi = r.x[i]
            yi = r.out[i]
            lines.append(f"s {i} {xi[0]} {xi[1]} {yi[0]} {yi[1]}")
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def write_if_needed(path: Path, content: str, check: bool) -> bool:
    if path.is_file():
        with path.open("r", encoding="utf-8", newline="") as fh:
            if fh.read() == content:
                return True
    if check:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as fh:
        fh.write(content)
    return False


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--out", default="model/vectors")
    p.add_argument("--seed", type=int, default=DEFAULT_SEED)
    p.add_argument("--check", action="store_true",
                   help="verify the committed file matches; write nothing")
    p.add_argument("--report", action="store_true",
                   help="print the float cross-check error of every record")
    args = p.parse_args()

    records = build_records(args.seed)

    # The float cross-check. A scaled fixed-point FFT of a Q1.15 frame carries a
    # few LSBs of quantisation noise per stage; a transform that is not a DFT
    # misses by orders of magnitude, which is the only thing this bound has to
    # separate. 64 points, 6 sub-stages, so a few hundred LSBs is generous and
    # still four orders of magnitude below a wrong transform.
    worst = 0.0
    worst_id = ""
    for r in records:
        if r.sched != SCHED_ALL:
            continue     # saturating records are not approximations of anything
        if r.float_err > worst:
            worst, worst_id = r.float_err, r.id
        if args.report:
            print(f"  {r.id:16s} float error {r.float_err:10.3f} LSB")
    # MEASURED, not guessed: the worst record of the committed set is 3.0 LSB
    # (dc_max, where the 1/N-scaled sum of 64 full-scale samples accumulates the
    # per-stage rounding). The bound is set just above the measured worst so it
    # is a real gate — a structural error in the butterfly schedule, the trivial
    # twiddle or the output permutation misses by thousands of LSBs, and even a
    # single wrong twiddle index misses by hundreds.
    limit = 16.0
    if worst > limit:
        print(f"ERROR: record '{worst_id}' differs from numpy's float FFT by "
              f"{worst:.1f} LSB, above the {limit:.0f} LSB bound. The fixed-point "
              "transform is not approximating a DFT.", file=sys.stderr)
        return 1

    path = REPO_ROOT / args.out / OUT_NAME
    content = render(records, args.seed)
    ok = write_if_needed(path, content, args.check)

    if args.check:
        if not ok:
            print(f"ERROR: {args.out}/{OUT_NAME} is stale or hand edited. "
                  "Re-run without --check and review the diff.", file=sys.stderr)
            return 1
        print(f"[fft-vectors] check: {len(records)} records match "
              f"(twiddle digest {TW_DIGEST}, worst float error {worst:.1f} LSB)")
        return 0

    print(f"[fft-vectors] {args.out}/{OUT_NAME}: "
          f"{'unchanged' if ok else 'written'} — {len(records)} records, "
          f"twiddle digest {TW_DIGEST}, worst float error {worst:.1f} LSB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
