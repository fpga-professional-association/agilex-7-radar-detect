#!/usr/bin/env python3
"""Design, quantise and emit the SPEC 7.1 polyphase FIR coefficient sets.

    python3 scripts/generate_coefficients.py                 # rewrite
    python3 scripts/generate_coefficients.py --check         # verify only
    python3 scripts/generate_coefficients.py --geometry 8x16 # one geometry
    python3 scripts/generate_coefficients.py --print proto   # dump to stdout

Governing spec: SPEC.md 6 (numerics), 7.1 (polyphase FIR bank), 12.4 (reference
model), 16 (build commands). Normative numeric prose: NUMERICS.md.

WHAT THIS PRODUCES
------------------
For each geometry (phases x taps) and each named coefficient set, two files in
``model/vectors/``:

    pfb_<set>_p<P>t<T>.coeff    the quantised coefficients, phase-major
    pfb_<set>_p<P>t<T>.vec      a golden input/output vector set for them

Both are line-oriented ASCII with parsed header comments, the same format
``model/vectors/README.md`` documents for the issue #4 vectors and for the same
reason: three lines of parsing serve a Verilator test binary, a standalone C++
unit test and a Python script without any of them vendoring a JSON library.

BOTH FILES ARE READ BY BOTH SIDES. ``model/cpp/pfb/pfb_model.hpp`` loads them,
and so does ``sim/tests/test_pfb_bank.cpp``, which additionally programs the
coefficients into the RTL through the coefficient bank's configuration port. One
file, one ordering, no second definition of how a coefficient index maps to a
(phase, tap) pair.

DETERMINISM
-----------
Everything is a pure function of ``(geometry, set, window, seed)``. The seed is
recorded in every file's header, the design uses ``numpy.random.default_rng``
with an explicitly derived per-set seed, and the quantisation goes through
``model/python/fxp_reference.py`` rather than through a float cast. Running this
twice produces byte-identical files; ``--check`` regenerates in memory and exits
non-zero on any difference, so a hand edit of a coefficient file cannot survive
``make sim-tiny``.

WHY THE FILES ARE COMMITTED
---------------------------
Same argument as ``model/vectors/README.md`` makes for the fixed-point vectors: a
golden expectation that is regenerated on demand proves only that the generator
agrees with itself, whereas a committed one makes a change to the filter a
reviewable diff. The regeneration check is what keeps them honest. See
DECISIONS.md (issue #10).

THE FILTER DESIGN
-----------------
The prototype is the textbook windowed sinc for a ``P``-channel polyphase
channelizer: a low-pass whose cutoff is one channel wide, windowed to control
stopband leakage, then decomposed phase-wise.

    L    = phases * taps
    fc   = 1 / phases                      (normalised; one channel wide)
    h[n] = fc * sinc(fc * (n - (L-1)/2)) * w[n]

with ``w`` one of rect / hann / hamming / blackman. Optionally multiplied by a
complex ramp ``exp(2j*pi*mix*n)`` so that at least one committed set has genuinely
complex coefficients — a real-coefficient set cannot catch a swapped real and
imaginary partial product, and that is exactly the defect a complex FIR is
prone to.

SCALING, AND WHY IT IS PART OF THE DESIGN
------------------------------------------
A Q1.15 datapath saturates at +/-1.0, so a filter whose per-phase L1 norm exceeds
1.0 will clip on full-scale input regardless of how good the frequency response
is. The designed sets are therefore scaled to

    max_p sum_k |h_p[k]|  =  L1_TARGET  (0.98)

which makes clipping impossible for any legal input and turns any saturation the
RTL reports into a real defect rather than a design consequence. The ``max`` set
deliberately does the opposite — see its description below — because the
saturation path has to be exercised too.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

import numpy as np

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "model" / "python"))

import fxp_reference as fxp  # noqa: E402
import pfb_model as pfb      # noqa: E402

SCHEMA_VERSION = 1
GENERATOR = "scripts/generate_coefficients.py"

# The one seed. Recorded in every file header; change it and every committed
# coefficient file changes, which is a reviewable event and not a tuning knob.
DEFAULT_SEED = 20260727

# Per-phase L1 bound for the DESIGNED sets. See the module docstring.
L1_TARGET = 0.98

DEFAULT_GEOMETRIES = [(4, 8), (8, 16)]

DEFAULT_OUT = REPO_ROOT / "model" / "vectors"

# Beats per golden vector file. Large enough that the longest history
# (taps = 16) is fully flushed several times over and that every stimulus
# segment below gets a run of its own; small enough that the committed diff
# stays readable.
GOLDEN_BEATS = 96


# ---------------------------------------------------------------------------
# Windows. Written out rather than taken from numpy so the definition is visible
# and cannot change under a numpy upgrade.
# ---------------------------------------------------------------------------


def window(name: str, length: int) -> np.ndarray:
    n = np.arange(length, dtype=np.float64)
    if length == 1:
        return np.ones(1, dtype=np.float64)
    # Symmetric (not periodic) form: the prototype is a filter, not a spectral
    # analysis window, so the endpoints belong to the design.
    t = n / float(length - 1)
    if name == "rect":
        return np.ones(length, dtype=np.float64)
    if name == "hann":
        return 0.5 - 0.5 * np.cos(2.0 * np.pi * t)
    if name == "hamming":
        return 0.54 - 0.46 * np.cos(2.0 * np.pi * t)
    if name == "blackman":
        return (0.42 - 0.5 * np.cos(2.0 * np.pi * t)
                + 0.08 * np.cos(4.0 * np.pi * t))
    raise ValueError(f"unknown window '{name}'")


WINDOWS = ("rect", "hann", "hamming", "blackman")


def prototype(phases: int, taps: int, win: str, mix: float) -> np.ndarray:
    """Windowed-sinc prototype of length phases*taps, optionally complex."""
    length = phases * taps
    n = np.arange(length, dtype=np.float64)
    fc = 1.0 / float(phases)
    h = fc * np.sinc(fc * (n - (length - 1) / 2.0)) * window(win, length)
    if mix != 0.0:
        h = h * np.exp(2j * np.pi * mix * n)
    return h.astype(np.complex128)


def scale_to_l1(h: np.ndarray, phases: int, taps: int,
                target: float) -> np.ndarray:
    """Scale so the largest per-phase L1 norm equals `target`.

    Per PHASE, not overall: each lane is an independent filter and it is a
    lane's own L1 norm that bounds its output. Scaling by the whole prototype's
    norm would leave the busiest lane free to clip.
    """
    branches = pfb.decompose(list(h), phases, taps)
    worst = max(sum(abs(c) for c in branch) for branch in branches)
    if worst == 0.0:
        return h
    return h * (target / worst)


# ---------------------------------------------------------------------------
# The coefficient sets
# ---------------------------------------------------------------------------
#
# Each entry returns the quantised (re, im) pairs in phase-major, tap-minor
# order: index = phase*taps + tap, exactly the order rtl/pfb/coeff_bank.sv
# addresses.


def set_designed(phases: int, taps: int, win: str, mix: float,
                 seed: int) -> tuple[list[tuple[int, int]], dict]:
    h = scale_to_l1(prototype(phases, taps, win, mix), phases, taps, L1_TARGET)
    branches = pfb.decompose(list(h), phases, taps)
    coeff = [pfb.quantise_complex(branches[p][k])
             for p in range(phases) for k in range(taps)]
    return coeff, {"window": win, "cutoff": 1.0 / phases, "mix": mix,
                   "l1_target": L1_TARGET, "seed": seed}


def set_ident(phases: int, taps: int, seed: int):
    """Per-phase unit impulse: every lane is a pass-through at maximum gain.

    The one set whose expected output can be written down without running any
    model at all — output beat m is input beat m — which is what makes it the
    right first failure to look at when everything disagrees.
    """
    coeff = []
    for _p in range(phases):
        coeff.append((pfb.Q15_MAX, 0))
        coeff.extend([(0, 0)] * (taps - 1))
    return coeff, {"window": "none", "cutoff": 0.0, "mix": 0.0,
                   "l1_target": 0.0, "seed": seed}


def set_random(phases: int, taps: int, seed: int):
    """Uniform full-range Q1.15 complex coefficients.

    Deliberately NOT L1-scaled: a random full-range set has an L1 norm far above
    one, so it saturates constantly. That is the point — it is the set under
    which the saturation flags, the sticky telemetry and the model's own
    round-then-saturate ordering are exercised on nearly every beat.
    """
    rng = np.random.default_rng(seed)
    raw = rng.integers(pfb.Q15_MIN, pfb.Q15_MAX + 1,
                       size=(phases * taps, 2), dtype=np.int64)
    coeff = [(int(r[0]), int(r[1])) for r in raw]
    return coeff, {"window": "none", "cutoff": 0.0, "mix": 0.0,
                   "l1_target": 0.0, "seed": seed}


def set_max(phases: int, taps: int, seed: int):
    """Every coefficient at an endpoint, alternating sign.

    The extreme case for the accumulator and for saturation in BOTH directions.
    -1.0 (0x8000) is included on purpose: it is the value whose negation is not
    representable, so it is where a sign bug shows up first.
    """
    coeff = []
    for i in range(phases * taps):
        if i % 2 == 0:
            coeff.append((pfb.Q15_MAX, pfb.Q15_MIN))
        else:
            coeff.append((pfb.Q15_MIN, pfb.Q15_MAX))
    return coeff, {"window": "none", "cutoff": 0.0, "mix": 0.0,
                   "l1_target": 0.0, "seed": seed}


SETS = {
    "proto": {
        "description": "windowed-sinc channelizer prototype, hann, real "
                       "coefficients, L1-scaled so it cannot clip",
        "build": lambda p, t, s: set_designed(p, t, "hann", 0.0, s),
    },
    "mixed": {
        "description": "windowed-sinc prototype, hamming, mixed to a channel "
                       "centre so the coefficients are genuinely complex",
        "build": lambda p, t, s: set_designed(p, t, "hamming",
                                              1.0 / (2.0 * p), s),
    },
    "ident": {
        "description": "per-phase unit impulse; every lane a pass-through",
        "build": lambda p, t, s: set_ident(p, t, s),
    },
    "random": {
        "description": "uniform full-range Q1.15 complex; saturates often",
        "build": lambda p, t, s: set_random(p, t, s),
    },
    "max": {
        "description": "every coefficient at a Q1.15 endpoint, alternating",
        "build": lambda p, t, s: set_max(p, t, s),
    },
}


def set_seed(base: int, name: str, phases: int, taps: int) -> int:
    """Per-set seed derived from the master seed and the set identity.

    Derived rather than shared so that adding a set, or a geometry, does not
    perturb any other set's numbers — the same substream discipline
    sim/verilator/harness/random.h applies to simulation stimulus, and for the
    same reason: a committed file must not change because a neighbour did.
    """
    h = 1469598103934665603
    for byte in f"{name}:{phases}x{taps}".encode("utf-8"):
        h = ((h ^ byte) * 1099511628211) & 0xFFFFFFFFFFFFFFFF
    return (base ^ h) & 0x7FFFFFFF


# ---------------------------------------------------------------------------
# Golden stimulus
# ---------------------------------------------------------------------------


def golden_stimulus(phases: int, taps: int, seed: int) -> list[list[tuple[int, int]]]:
    """The SPEC 7.1 verification list, as one deterministic beat sequence.

    Segments, in order, each long enough to flush a `taps`-deep history:

        zeros           the trivial case, and the one that catches a history
                        that was never cleared
        complex impulse a single full-scale beat then zeros: the output IS the
                        programmed response, tap by tap, which is the only
                        stimulus that checks the coefficient ORDER
        constant        DC: the output settles to the per-lane coefficient sum
        sinusoid        a single complex tone, sampled exactly so the sequence
                        is periodic and a phase error is visible
        max pos/neg     both Q1.15 endpoints on both components
        random          uniform full range, the general case
    """
    rng = np.random.default_rng(seed)
    seg = max(taps + 2, 8)
    beats: list[list[tuple[int, int]]] = []

    def push(beat):
        beats.append(beat)

    zero_beat = [(0, 0)] * phases

    # zeros
    for _ in range(seg):
        push(list(zero_beat))

    # complex impulse: one full-scale sample in every lane, then quiet
    push([(pfb.Q15_MAX, pfb.Q15_MIN)] * phases)
    for _ in range(seg):
        push(list(zero_beat))

    # constant
    const = [(12345, -9876)] * phases
    for _ in range(seg):
        push(list(const))

    # single complex sinusoid, one cycle every `seg` beats per lane
    for m in range(2 * seg):
        beat = []
        for p in range(phases):
            ang = 2.0 * np.pi * (m * phases + p) / float(4 * phases)
            re, _, _ = pfb.quantise_q15(0.75 * float(np.cos(ang)))
            im, _, _ = pfb.quantise_q15(0.75 * float(np.sin(ang)))
            beat.append((re, im))
        push(beat)

    # maximum positive and maximum negative
    for _ in range(seg // 2):
        push([(pfb.Q15_MAX, pfb.Q15_MAX)] * phases)
    for _ in range(seg // 2):
        push([(pfb.Q15_MIN, pfb.Q15_MIN)] * phases)

    # random, to fill out the file
    while len(beats) < GOLDEN_BEATS:
        raw = rng.integers(pfb.Q15_MIN, pfb.Q15_MAX + 1,
                           size=(phases, 2), dtype=np.int64)
        push([(int(r[0]), int(r[1])) for r in raw])

    return beats[:GOLDEN_BEATS]


# ---------------------------------------------------------------------------
# File rendering
# ---------------------------------------------------------------------------


def render_coeff(name: str, phases: int, taps: int,
                 coeff: list[tuple[int, int]], meta: dict) -> str:
    lines = [
        "# pfb coefficient file",
        f"# schema: {SCHEMA_VERSION}",
        "# kind: pfb_coeff",
        f"# set: {name}",
        f"# description: {SETS[name]['description']}",
        f"# phases: {phases}",
        f"# taps: {taps}",
        f"# window: {meta['window']}",
        f"# cutoff: {meta['cutoff']:.9f}",
        f"# mix: {meta['mix']:.9f}",
        f"# l1_target: {meta['l1_target']:.9f}",
        f"# seed: {meta['seed']}",
        f"# rounding_mode: {fxp.ROUND_MODE}",
        f"# coeff_w: {fxp.COEFF_W}",
        f"# frac_w: {fxp.FRAC_W}",
        f"# count: {len(coeff)}",
        f"# generator: {GENERATOR}",
        "# reference: model/python/pfb_model.py (NumPy, independent)",
        "# order: phase-major, tap-minor: index = phase*taps + tap",
        "# columns: index phase tap re im",
    ]
    for p in range(phases):
        for k in range(taps):
            i = p * taps + k
            re, im = coeff[i]
            lines.append(f"{i} {p} {k} {re} {im}")
    return "\n".join(lines) + "\n"


def render_golden(name: str, phases: int, taps: int,
                  coeff: list[tuple[int, int]], meta: dict,
                  coeff_file: str) -> str:
    model = pfb.PfbModel(phases, taps, coeff)
    beats = golden_stimulus(phases, taps, meta["seed"] ^ 0x5EED)

    cols = ["beat"]
    cols += [f"x{p}_{c}" for p in range(phases) for c in ("re", "im")]
    cols += [f"y{p}_{c}" for p in range(phases) for c in ("re", "im")]
    cols += [f"f{p}_{c}" for p in range(phases) for c in ("re", "im")]

    lines = [
        "# pfb vector file",
        f"# schema: {SCHEMA_VERSION}",
        "# kind: pfb_io",
        f"# set: {name}",
        f"# phases: {phases}",
        f"# taps: {taps}",
        f"# coeff_file: {coeff_file}",
        f"# seed: {meta['seed']}",
        f"# rounding_mode: {fxp.ROUND_MODE}",
        f"# acc_w: {pfb.acc_width(taps)}",
        f"# count: {len(beats)}",
        f"# generator: {GENERATOR}",
        "# reference: model/python/pfb_model.py (NumPy, independent)",
        "# the model starts from an all-zero history at beat 0",
        "# f* is the packed saturation flag word: sat_pos<<1 | sat_neg",
        f"# columns: {' '.join(cols)}",
    ]

    for m, beat in enumerate(beats):
        ys, fs = model.step(beat)
        row = [str(m)]
        for (re, im) in beat:
            row += [str(re), str(im)]
        for (re, im) in ys:
            row += [str(re), str(im)]
        for (fr, fi) in fs:
            row += [str(fr), str(fi)]
        lines.append(" ".join(row))

    return "\n".join(lines) + "\n"


def write_if_needed(path: Path, content: str, check: bool) -> bool:
    """Returns True when the file on disk differs from `content`."""
    existing = None
    if path.is_file():
        existing = path.read_text(encoding="utf-8")
    if existing == content:
        return False
    if check:
        return True
    path.parent.mkdir(parents=True, exist_ok=True)
    # newline="\n": the repository forces LF (.gitattributes); a CRLF vector
    # file would fail the byte comparison on the next run under a different host.
    with path.open("w", encoding="utf-8", newline="\n") as fh:
        fh.write(content)
    return True


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def parse_geometry(text: str) -> tuple[int, int]:
    try:
        a, b = text.lower().split("x")
        return int(a), int(b)
    except Exception as exc:  # noqa: BLE001
        raise argparse.ArgumentTypeError(
            f"geometry '{text}' is not <phases>x<taps>") from exc


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--out", default=str(DEFAULT_OUT),
                   help="output directory (default: model/vectors)")
    p.add_argument("--seed", type=int, default=DEFAULT_SEED,
                   help=f"master seed (default: {DEFAULT_SEED})")
    p.add_argument("--geometry", type=parse_geometry, action="append",
                   help="<phases>x<taps>; repeatable. "
                        f"Default: {', '.join(f'{a}x{b}' for a, b in DEFAULT_GEOMETRIES)}")
    p.add_argument("--sets", default=",".join(SETS),
                   help=f"comma-separated subset of: {', '.join(SETS)}")
    p.add_argument("--check", action="store_true",
                   help="regenerate in memory and fail on any difference; "
                        "writes nothing")
    p.add_argument("--print", dest="print_set", metavar="SET",
                   help="print one set's coefficients to stdout and exit")
    p.add_argument("--quiet", action="store_true")
    args = p.parse_args()

    geometries = args.geometry or DEFAULT_GEOMETRIES
    names = [s.strip() for s in args.sets.split(",") if s.strip()]
    for n in names:
        if n not in SETS:
            print(f"ERROR: unknown set '{n}'; known: {', '.join(SETS)}",
                  file=sys.stderr)
            return 2

    if args.print_set:
        phases, taps = geometries[0]
        seed = set_seed(args.seed, args.print_set, phases, taps)
        coeff, meta = SETS[args.print_set]["build"](phases, taps, seed)
        sys.stdout.write(render_coeff(args.print_set, phases, taps, coeff, meta))
        return 0

    out_dir = Path(args.out)
    if not out_dir.is_absolute():
        out_dir = REPO_ROOT / out_dir

    differed: list[str] = []
    written = 0

    for phases, taps in geometries:
        for name in names:
            seed = set_seed(args.seed, name, phases, taps)
            coeff, meta = SETS[name]["build"](phases, taps, seed)

            stem = f"pfb_{name}_p{phases}t{taps}"
            coeff_name = f"{stem}.coeff"
            vec_name = f"{stem}.vec"

            pairs = [
                (out_dir / coeff_name,
                 render_coeff(name, phases, taps, coeff, meta)),
                (out_dir / vec_name,
                 render_golden(name, phases, taps, coeff, meta, coeff_name)),
            ]
            for path, content in pairs:
                changed = write_if_needed(path, content, args.check)
                if changed:
                    differed.append(str(path.relative_to(REPO_ROOT)))
                    written += 0 if args.check else 1
                if not args.quiet and not args.check:
                    state = "written" if changed else "unchanged"
                    print(f"[coeff] {path.relative_to(REPO_ROOT)} {state}")

    if args.check:
        if differed:
            print("ERROR: committed coefficient files differ from what "
                  f"{GENERATOR} produces for seed {args.seed}:", file=sys.stderr)
            for d in differed:
                print(f"  {d}", file=sys.stderr)
            print("Re-run without --check and review the diff.", file=sys.stderr)
            return 1
        if not args.quiet:
            n = len(geometries) * len(names) * 2
            print(f"[coeff] check OK: {n} files match seed {args.seed}")
        return 0

    if not args.quiet:
        print(f"[coeff] {written} file(s) written into "
              f"{out_dir.relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
