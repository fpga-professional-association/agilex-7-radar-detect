#!/usr/bin/env python3
"""Synthetic radar-scene IQ generator (issue #44, part 1).

    python3 model/python/gen_target_iq.py --scenario three_targets --seed 1
    python3 model/python/gen_target_iq.py --scenario three_targets --seed 1 \
        --config config/medium.json --out results/scenarios

Purpose
-------
The per-block stimulus (impulses, tones, DC, random) is enough to prove each
stage is what NUMERICS.md says it is, but it is not a radar scene. This script
writes a multi-antenna IQ time series that a reader recognises as
"targets sitting in a noise floor": each target has a range (the fast-time
frequency bin the FFT is expected to peak at), a Doppler (a slow-time phase
progression across ``HISTORY_FRAMES`` frames), a per-antenna phase gradient
(the angle-of-arrival), and an SNR relative to the AWGN floor. Everything is
quantised through the shared independent NumPy numerics model
(``model/python/fxp_reference.py``), so the samples handed to the pipeline are
exactly Q1.15 integers — the same representation the C++ harness stream
drivers already consume.

What this file writes
---------------------
Two artefacts per scenario, under ``results/scenarios/<scenario>_seed<S>/``:

* ``scenario.iq`` — line-oriented ASCII, one header block plus one line per
  beat per antenna. See :func:`render_iq` for the exact format. This matches
  the ``.vec`` files under ``model/vectors/``: whitespace-separated signed
  decimals, Q1.15 per component, ``#`` comments; a reader can be three lines of
  parsing in Python, C++, or a shell script (SPEC.md 16). Part 2 of #44 will
  feed this same file to the ``benchmark_sim_top`` harness through its
  ADC-injection hook.

* ``scenario.json`` — ground truth for every target: index, range bin,
  Doppler bin, angle index, SNR (dB). The visualiser
  (``model/python/range_doppler.py``) reads this to overlay markers on the
  reference map.

The generator is deterministic in ``--seed``: the same seed on the same
config produces the same integers, so the reference map, the JSON sidecar and
(eventually) the sim RESULT are all reproducible.

Fast-time / slow-time mapping
-----------------------------
Fast-time samples are the ADC stream feeding the PFB / FFT chain. FFT bin
``k_r`` is the range gate for target ``r``. Slow-time is the frame axis:
after one full FFT_SIZE-sample frame produces one FFT_SIZE-bin spectrum, the
``HISTORY_FRAMES``-deep history stacks those spectra frame by frame. A target
at Doppler bin ``k_d`` shows up as a phase progression
``exp(j 2 pi k_d f / HISTORY_FRAMES)`` across frames ``f`` at the range bin
``k_r``, so an FFT across frames at that bin peaks at ``k_d``. This is the
Doppler / velocity axis of the map ``docs/range_doppler.md`` describes.

Angle-of-arrival is a per-antenna spatial phase gradient
``exp(j 2 pi angle_idx * a / N_ANTENNAS)`` for antenna ``a``. A beam sweep
across antennas is a spatial FFT and peaks at ``angle_idx``. The beamformer
in the real pipeline does this properly with programmed weights; this
scenario carries the ground truth so the range-Doppler map can print a
'target r landed at (k_r, k_d, angle_idx)' verdict.

Q1.15 quantisation
------------------
Every real component is rounded-to-nearest-even at ``2**FRAC_W`` and saturated
into the Q1.15 range through ``fxp_reference.round_sat`` — exactly the way
``pfb_model.quantise_q15`` does it. No independent rounding rule is invented
here.

Runs on WSL Ubuntu-24.04 python3 (numpy >= 1.26). Never imports the C++
library, never reads the RTL.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field, asdict
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

import fxp_reference as fxp  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[2]

SCHEMA_VERSION = 1
IQ_FORMAT = "iq_ascii_v1"

# Q1.15 endpoints, from the reference — never written as literals.
Q15_MAX = int(fxp.max_of(fxp.SAMPLE_W))
Q15_MIN = int(fxp.min_of(fxp.SAMPLE_W))
Q15_ONE = 1 << fxp.FRAC_W  # 32768 (float 1.0 not representable; ceiling is Q15_MAX)


# ---------------------------------------------------------------------------
# Q1.15 quantisation — real number -> integer, via the shared reference
# ---------------------------------------------------------------------------


def q15_quantise(x: float) -> int:
    """Round-to-nearest-even then saturate one real value into Q1.15.

    Uses the same recipe as ``pfb_model.quantise_q15``: scale the float by an
    extra ``2**scale_bits`` so the ``int(round(...))`` on the float is exact,
    then let :mod:`fxp_reference` do the last, semantically meaningful,
    rounding step. That is what keeps the integers bit-exact with the RTL and
    the C++ model rather than exact-to-a-float's-idea-of-half.
    """
    scale_bits = 20
    scaled = int(round(float(x) * float(1 << (fxp.FRAC_W + scale_bits))))
    return int(fxp.round_sat(scaled, scale_bits, fxp.SAMPLE_W))


def q15_quantise_array(arr: np.ndarray) -> np.ndarray:
    """Vectorised Q1.15 quantisation of a real ndarray. Returns int64."""
    scale_bits = 20
    scaled = np.rint(arr.astype(np.float64) * float(1 << (fxp.FRAC_W + scale_bits)))
    scaled_i = scaled.astype(np.int64)
    # fxp.round_sat operates on int64 arrays; the round-and-clamp semantics
    # match the scalar helper above.
    return np.asarray(
        fxp.round_sat(scaled_i, scale_bits, fxp.SAMPLE_W), dtype=np.int64
    )


# ---------------------------------------------------------------------------
# Scenario definition
# ---------------------------------------------------------------------------


@dataclass
class Target:
    """One target's ground truth.

    All bins are integer, so the peak is unambiguous. Non-integer bin values
    (a target on the edge of two bins) are a legitimate case but not this
    scenario's job — the ±1 bin sanity gate in the acceptance criterion is
    written against integer bins.
    """

    name: str
    range_bin: int          # fast-time FFT bin, 0..FFT_SIZE-1
    doppler_bin: int        # slow-time bin, 0..HISTORY_FRAMES-1
    angle_idx: int          # per-antenna spatial index, 0..N_ANTENNAS-1
    snr_db: float           # linear amplitude ratio, dB above the AWGN floor

    def to_dict(self) -> dict:
        return asdict(self)


@dataclass
class ScenarioConfig:
    """The synthesizable parameters this generator consumes.

    Read from ``config/<name>.json`` — see :func:`load_config` — so a
    generator invocation cannot silently disagree with the geometry the sim
    top elaborates.
    """

    name: str
    n_antennas: int
    samples_per_cycle: int
    fft_size: int
    history_frames: int
    n_beams: int
    sample_w: int

    @classmethod
    def from_config_json(cls, path: Path) -> "ScenarioConfig":
        with path.open("r", encoding="utf-8") as fh:
            body = json.load(fh)
        p = body["params"]
        return cls(
            name=body.get("name", path.stem),
            n_antennas=int(p["N_ANTENNAS"]),
            samples_per_cycle=int(p["SAMPLES_PER_CYCLE"]),
            fft_size=int(p["FFT_SIZE"]),
            history_frames=int(p["HISTORY_FRAMES"]),
            n_beams=int(p["N_BEAMS"]),
            sample_w=int(p["SAMPLE_W"]),
        )


@dataclass
class Scenario:
    """Everything a rendered scenario needs to know about itself.

    ``noise_sigma`` is the standard deviation of the complex AWGN floor (one
    component). ``clutter`` is an optional stationary ridge at
    ``clutter_bin`` in the range dimension; when non-zero it superimposes a
    strong low-Doppler-only tone. Both are scaled in the same amplitude units
    as the targets (Q1.15 -1..1 range, before quantisation).
    """

    name: str
    seed: int
    targets: list[Target]
    noise_sigma: float = 0.005
    clutter_bin: int = -1                       # -1 disables the clutter ridge
    clutter_amp: float = 0.0
    target_amp: float = 0.03                    # base linear amplitude for 0 dB
    description: str = ""
    schema_version: int = SCHEMA_VERSION
    iq_format: str = IQ_FORMAT
    config: dict = field(default_factory=dict)


# ---------------------------------------------------------------------------
# Built-in named scenarios
# ---------------------------------------------------------------------------


def scenario_three_targets(cfg: ScenarioConfig, seed: int) -> Scenario:
    """Three well-separated targets at distinct range / Doppler / angle / SNR.

    The three ranges span the low, middle and upper-half of the frequency
    axis (avoiding DC and Nyquist, which are ambiguous under any real windowed
    front-end); the three Dopplers cover a positive, a zero-ish and a negative
    (wrap-around) frame progression; the three angles are three distinct
    spatial indices so a beam sweep would separate them; the SNRs span a
    strong, a moderate and a marginal target so the map's dynamic range is
    exercised in one run.

    All bins are integers so the peak is unambiguous — see :class:`Target`.
    """
    f = cfg.fft_size
    h = cfg.history_frames
    a = cfg.n_antennas
    targets = [
        # (name,         range_bin,    doppler_bin,        angle_idx,    snr_db)
        Target("t0_strong",  f // 8,      2,                  1,            20.0),
        Target("t1_moderate", f // 4 + 3,  h - 3,               2,            12.0),
        Target("t2_weak",     3 * f // 8,  h // 2 - 1,          a - 1,        6.0),
    ]
    return Scenario(
        name="three_targets",
        seed=seed,
        targets=targets,
        noise_sigma=0.005,
        clutter_bin=-1,
        clutter_amp=0.0,
        target_amp=0.03,
        description=(
            "Three well-separated targets at distinct range/Doppler/angle/SNR. "
            "SPEC 3 medium config: FFT_SIZE range bins, HISTORY_FRAMES Doppler bins."
        ),
        config={
            "name": cfg.name,
            "N_ANTENNAS": cfg.n_antennas,
            "SAMPLES_PER_CYCLE": cfg.samples_per_cycle,
            "FFT_SIZE": cfg.fft_size,
            "HISTORY_FRAMES": cfg.history_frames,
            "N_BEAMS": cfg.n_beams,
            "SAMPLE_W": cfg.sample_w,
        },
    )


def scenario_three_targets_even(cfg: ScenarioConfig, seed: int) -> Scenario:
    """Three targets on the tapped-parity CFAR bins, angle 0 (beam 0 tap).

    Part 2 of #44 injects a scenario through ``benchmark_pipeline_top``, whose
    Phase-3 narrowing (DECISIONS.md 2026-07-27 Decision 7) taps ONE sample per
    beamformer beat -- (beam 0, bin 0). With BIN_PAR = 2 the align network
    maps LANE = bin mod BIN_PAR = bin[0], so lane 0 carries even FFT bins and
    lane 1 carries odd bins. The beamformer packs
    ``data[(k*BIN_PAR + j)*2*SAMPLE_W]`` = (beam k, bin j); the pipeline taps
    j = 0 = EVEN FFT bins.

    Beam discrimination is unavailable in Phase 3 with uniform beamformer
    weights: coherent addition of a per-antenna phase gradient
    ``exp(j 2 pi angle_idx * a / N_ANT)`` across ``N_ANT`` antennas with equal
    weights is
    ``N_ANT * sinc(pi*angle_idx)`` -- zero unless ``angle_idx == 0 (mod N_ANT)``.
    A non-zero angle_idx target would be nulled at beam 0 with uniform
    weights and become invisible to the tapped power path. So this scenario
    puts every target at ``angle_idx = 0``; the reference visualiser still
    prints the range-Doppler map and would find the peaks on antenna 0 (or
    on any antenna, since the tone amplitude is the same on all when
    angle_idx = 0).

    The three range bins are even, span the low, middle and upper half of
    the FFT range (avoiding DC and Nyquist for the same reason
    ``scenario_three_targets`` gives), and after halving into CFAR bin
    indices (``fft_bin // BIN_PAR``) sit well inside the fittable CFAR
    window at MAX_GUARD = 2, MAX_REF = 16 (half-window 18; unfittable CFAR
    bins are 0..17 and (F/BIN_PAR)-18..(F/BIN_PAR)-1 = 110..127 at
    FFT_SIZE = 256, BIN_PAR = 2). Bins 32, 96 and 160 map to CFAR bins
    16, 48 and 80 -- three well-separated, ALL fittable slots.

    NOTE: bin 32 -> CFAR bin 16, JUST inside the half-window (bin 17 is the
    first fittable). Moved up to 40 to have a comfortable margin for the
    strong target, which is the one whose false-alarm bound is most
    sensitive to a leaky edge. 40 // 2 = CFAR bin 20 which is well past
    the last unfittable index 17.
    """
    f = cfg.fft_size
    h = cfg.history_frames
    # Three range bins, all EVEN (tapped parity), all far enough from either
    # frame edge that the CFAR half-window (guard + ref) fits.
    range_bins = [40, 96, 160]
    dopplers   = [2, h - 3, h // 2 - 1]
    snr_dbs    = [20.0, 12.0, 6.0]
    targets = [
        Target(f"t{i}_{name}", range_bins[i], dopplers[i], 0, snr_dbs[i])
        for i, name in enumerate(("strong", "moderate", "weak"))
    ]
    return Scenario(
        name="three_targets_even",
        seed=seed,
        targets=targets,
        noise_sigma=0.005,
        clutter_bin=-1,
        clutter_amp=0.0,
        target_amp=0.03,
        description=(
            "Three targets on tapped-parity (even) FFT bins, angle_idx=0 so "
            "the beam-0 tap sees them coherently. Part-2 sim-injection "
            "scenario: designed around DECISIONS.md 2026-07-27 Decision 7 "
            "(single-lane power tap) and the medium config (FFT_SIZE=256, "
            "BIN_PAR=2, HISTORY_FRAMES=16)."
        ),
        config={
            "name": cfg.name,
            "N_ANTENNAS": cfg.n_antennas,
            "SAMPLES_PER_CYCLE": cfg.samples_per_cycle,
            "FFT_SIZE": cfg.fft_size,
            "HISTORY_FRAMES": cfg.history_frames,
            "N_BEAMS": cfg.n_beams,
            "SAMPLE_W": cfg.sample_w,
        },
    )


def scenario_mixed_parity(cfg: ScenarioConfig, seed: int) -> Scenario:
    """Six targets on mixed even / odd FFT bins, all angle_idx=0.

    Phase 6 (issue #21) lands per-beam CFAR + BIN_PAR-cycle serializer, so
    the pipeline now sees BOTH even and odd FFT bins as CFAR cells (the
    Phase-5 single-tap-at-(beam 0, bin_par 0) restriction is lifted). This
    scenario exercises that: six targets, three on even bins and three on
    odd bins, all at strong and moderate SNR. angle_idx = 0 keeps beam
    discrimination out of the picture (uniform BF weights are used by the
    default harness setup, so angle_idx != 0 targets would still not select
    a particular beam -- that is a Phase 7+ study when beam-weighted
    steering lands).

    Bin choices avoid DC and Nyquist, and stay inside a comfortable
    fittable-CFAR half-window margin (guard 1 + ref 8 = 9 unfittable at
    each frame edge, so bins 10..(FFT_SIZE-11) are all fittable at CFAR
    bin index = fft_bin under the Phase-6 mapping).
    """
    f = cfg.fft_size
    h = cfg.history_frames
    # Three even and three odd. Separation between adjacent target bins is
    # at least 4 CFAR bins so the +/-1 CFAR bin-tolerance in the check does
    # not aliasise odd targets onto adjacent even targets (per-beam CFAR
    # picks up BOTH parity lanes; the check must be able to attribute an
    # odd-bin detection to its OWN target, not the nearby even one).
    range_bins = [f // 8,       f // 4 + 4,  3 * f // 8,
                  f // 8 + 5,   f // 4 + 9,  3 * f // 8 + 5]
    dopplers   = [2, h - 3, h // 2 - 1, 3, h - 4, h // 2 + 1]
    snr_dbs    = [20.0, 15.0, 10.0, 18.0, 14.0, 8.0]
    parity_tag = ["e0", "e1", "e2", "o0", "o1", "o2"]
    targets = [
        Target(f"t{i}_{parity_tag[i]}", range_bins[i], dopplers[i], 0, snr_dbs[i])
        for i in range(6)
    ]
    return Scenario(
        name="mixed_parity",
        seed=seed,
        targets=targets,
        noise_sigma=0.005,
        clutter_bin=-1,
        clutter_amp=0.0,
        target_amp=0.03,
        description=(
            "Six targets on mixed even/odd FFT bins, angle_idx=0. Designed for "
            "the Phase-6 (issue #21) per-beam CFAR + BIN_PAR-serialiser "
            "sim-injection contract: every FFT bin now lands on some CFAR "
            "cell of every beam, so odd-bin targets that were invisible to "
            "the Phase-5 single-tap CFAR are now detectable."
        ),
        config={
            "name": cfg.name,
            "N_ANTENNAS": cfg.n_antennas,
            "SAMPLES_PER_CYCLE": cfg.samples_per_cycle,
            "FFT_SIZE": cfg.fft_size,
            "HISTORY_FRAMES": cfg.history_frames,
            "N_BEAMS": cfg.n_beams,
            "SAMPLE_W": cfg.sample_w,
        },
    )


SCENARIOS = {
    "three_targets": scenario_three_targets,
    "three_targets_even": scenario_three_targets_even,
    "mixed_parity": scenario_mixed_parity,
}


# ---------------------------------------------------------------------------
# Bin-parity helper — used by the part-2 sim test (via the JSON sidecar) to
# reason about which FFT bins the pipeline can see through its Phase-3 tap.
# ---------------------------------------------------------------------------


def cfar_bin_index(fft_bin: int, bin_par: int) -> int:
    """CFAR bin index for a given FFT bin, at the pipeline's tap.

    The pipeline taps (beam 0, bin 0) of each aligned beamformer beat, and
    with BIN_PAR = N the alignment network puts FFT bin `k` on
    (LANE = k mod N, GROUP = k // N). So bin 0 of a beat = LANE 0 = even FFT
    bins. The CFAR sees one power sample per beat, in beat (group) order,
    which is FFT bin // BIN_PAR for the tapped parity. This helper is the
    one place that mapping is written down.
    """
    return fft_bin // bin_par


def is_tapped_parity(fft_bin: int, bin_par: int) -> bool:
    """True when the given FFT bin sits on lane 0 (the tapped parity).

    Even FFT bins for BIN_PAR = 2.
    """
    return (fft_bin % bin_par) == 0


# ---------------------------------------------------------------------------
# IQ synthesis — float amplitudes, quantised at the very end
# ---------------------------------------------------------------------------


def synthesize_iq(scen: Scenario, cfg: ScenarioConfig) -> np.ndarray:
    """Return the pre-quantisation float IQ array, shape (H, A, N).

    Axes: ``[frame, antenna, sample_within_frame]``. Frames are indexed
    0..HISTORY_FRAMES-1; each frame is a full FFT_SIZE fast-time window;
    antennas are 0..N_ANTENNAS-1. Complex-valued (dtype complex128).

    Signal model per target ``r`` at (k_r, k_d, phi_r, amp_r):

        s_r[f, a, n] = amp_r
                     * exp(j 2 pi k_r n / FFT_SIZE)          # range tone
                     * exp(j 2 pi k_d f / HISTORY_FRAMES)    # Doppler phase
                     * exp(j 2 pi phi_r a / N_ANTENNAS)      # angle gradient

    plus AWGN and an optional stationary clutter ridge at ``clutter_bin``.
    """
    h = cfg.history_frames
    a = cfg.n_antennas
    n = cfg.fft_size

    rng = np.random.default_rng(scen.seed)

    iq = np.zeros((h, a, n), dtype=np.complex128)

    # Frames / antennas / samples grids used by every target.
    n_grid = np.arange(n, dtype=np.float64)
    f_grid = np.arange(h, dtype=np.float64)
    a_grid = np.arange(a, dtype=np.float64)

    for t in scen.targets:
        # 10^(dB/20) is an amplitude ratio; combined with target_amp this is
        # the tone's peak-modulus at each sample.
        amp = float(scen.target_amp) * float(10.0 ** (t.snr_db / 20.0))
        # Cap the target amplitude so N summed tones plus noise never on their
        # own overflow Q1.15 (float 1.0 quantises to Q15_MAX, and clipping is a
        # scenario defect). 0.3 per target leaves headroom for up to ~3 coherent
        # tones with noise before any sample sits at the endpoints.
        amp = min(amp, 0.3)
        # Phase along each axis is separable, so build the outer product with
        # numpy broadcasting rather than a triple loop.
        range_phase = np.exp(2j * np.pi * t.range_bin * n_grid / n)
        doppler_phase = np.exp(2j * np.pi * t.doppler_bin * f_grid / h)
        angle_phase = np.exp(2j * np.pi * t.angle_idx * a_grid / a)
        # Shapes: (H,) * (A,) * (N,) => (H, A, N)
        tone = amp * (
            doppler_phase[:, None, None]
            * angle_phase[None, :, None]
            * range_phase[None, None, :]
        )
        iq += tone

    # Optional clutter ridge: a stationary tone (Doppler bin 0) at a fixed
    # range bin, distributed equally across antennas.
    if scen.clutter_bin >= 0 and scen.clutter_amp > 0.0:
        clutter_range_phase = np.exp(
            2j * np.pi * scen.clutter_bin * n_grid / n
        )
        iq += scen.clutter_amp * clutter_range_phase[None, None, :]

    # Complex AWGN: independent Gaussian I and Q, both with std noise_sigma.
    noise_re = rng.standard_normal(iq.shape) * scen.noise_sigma
    noise_im = rng.standard_normal(iq.shape) * scen.noise_sigma
    iq = iq + noise_re + 1j * noise_im

    return iq


def quantise_iq(iq_float: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Quantise the float IQ array to Q1.15 (re, im) integer arrays.

    Returns ``(re_i, im_i)`` — two int64 arrays of the same shape as
    ``iq_float``. Every value goes through the shared reference model.
    """
    re_i = q15_quantise_array(iq_float.real)
    im_i = q15_quantise_array(iq_float.imag)
    return re_i, im_i


# ---------------------------------------------------------------------------
# Rendering — the harness-consumable file format
# ---------------------------------------------------------------------------


def render_iq(scen: Scenario, cfg: ScenarioConfig,
              re_i: np.ndarray, im_i: np.ndarray) -> str:
    """Render the IQ file as line-oriented ASCII.

    Layout, chosen to match the ``model/vectors/`` convention and to be
    trivially parseable by both the Python visualiser and the future C++
    harness (part 2 of this issue). One header block, then per-beat lines
    grouping ``SAMPLES_PER_CYCLE`` complex samples per antenna into one beat,
    with ``sof`` and ``eof`` flags on the first and last beats of each frame.

    Header keys:

        schema, format, generator, reference, scenario, seed, description,
        config_name, N_ANTENNAS, SAMPLES_PER_CYCLE, FFT_SIZE, HISTORY_FRAMES,
        SAMPLE_W, n_targets, beats_per_frame, samples_per_beat, total_frames

    Line format (one line per (frame, antenna, beat)):

        <frame> <antenna> <beat> <sof> <eof> \
            <s0_re> <s0_im> <s1_re> <s1_im> ... <sP-1_re> <sP-1_im>

    where ``P = SAMPLES_PER_CYCLE`` is the number of complex samples per
    beat. sof=1 on beat 0 of the frame; eof=1 on the last beat of the frame.
    Q1.15 integer components, signed decimal.

    Beats are grouped by frame first, then by antenna. So a consumer that
    wants per-antenna streams reads every ``H_ANTENNAS`` group in a frame in
    parallel; a consumer that wants per-frame data just reads sequentially.
    """
    h = cfg.history_frames
    a = cfg.n_antennas
    n = cfg.fft_size
    p = cfg.samples_per_cycle
    beats_per_frame = n // p

    if n % p != 0:
        raise ValueError(
            f"FFT_SIZE={n} is not a multiple of SAMPLES_PER_CYCLE={p}: "
            "cannot pack a frame into whole beats."
        )

    lines: list[str] = []
    add = lines.append

    add("# target-iq scenario file")
    add(f"# schema: {SCHEMA_VERSION}")
    add(f"# format: {IQ_FORMAT}")
    add("# generator: model/python/gen_target_iq.py")
    add("# reference: model/python/fxp_reference.py (NumPy, independent)")
    add(f"# scenario: {scen.name}")
    add(f"# seed: {scen.seed}")
    add(f"# description: {scen.description}")
    add(f"# config_name: {cfg.name}")
    add(f"# N_ANTENNAS: {cfg.n_antennas}")
    add(f"# SAMPLES_PER_CYCLE: {cfg.samples_per_cycle}")
    add(f"# FFT_SIZE: {cfg.fft_size}")
    add(f"# HISTORY_FRAMES: {cfg.history_frames}")
    add(f"# SAMPLE_W: {cfg.sample_w}")
    add(f"# n_targets: {len(scen.targets)}")
    add(f"# beats_per_frame: {beats_per_frame}")
    add(f"# samples_per_beat: {p}")
    add(f"# total_frames: {h}")
    add(f"# noise_sigma: {scen.noise_sigma}")
    if scen.clutter_bin >= 0 and scen.clutter_amp > 0.0:
        add(f"# clutter_bin: {scen.clutter_bin}")
        add(f"# clutter_amp: {scen.clutter_amp}")
    add("#")
    add("# targets (ground truth):")
    for i, t in enumerate(scen.targets):
        add(
            f"# t{i}: name={t.name} range_bin={t.range_bin} "
            f"doppler_bin={t.doppler_bin} angle_idx={t.angle_idx} "
            f"snr_db={t.snr_db}"
        )
    add("#")
    add(
        "# columns: frame antenna beat sof eof "
        + " ".join(f"s{i}_re s{i}_im" for i in range(p))
    )
    add("#")

    # Body. Emit in (frame, antenna, beat) order — one contiguous group per
    # frame per antenna, so a per-antenna consumer streams naturally.
    for f in range(h):
        for ant in range(a):
            for b in range(beats_per_frame):
                sof = 1 if b == 0 else 0
                eof = 1 if b == beats_per_frame - 1 else 0
                sample_pairs: list[str] = []
                for slot in range(p):
                    idx = b * p + slot
                    sample_pairs.append(str(int(re_i[f, ant, idx])))
                    sample_pairs.append(str(int(im_i[f, ant, idx])))
                add(
                    f"{f} {ant} {b} {sof} {eof} " + " ".join(sample_pairs)
                )

    return "\n".join(lines) + "\n"


def render_json(scen: Scenario, cfg: ScenarioConfig) -> str:
    """Render the ground-truth sidecar."""
    body = {
        "schema_version": scen.schema_version,
        "iq_format": scen.iq_format,
        "scenario": scen.name,
        "seed": scen.seed,
        "description": scen.description,
        "config": scen.config,
        "noise_sigma": scen.noise_sigma,
        "target_amp": scen.target_amp,
        "clutter_bin": scen.clutter_bin,
        "clutter_amp": scen.clutter_amp,
        "targets": [t.to_dict() for t in scen.targets],
        "generator": "model/python/gen_target_iq.py",
        "reference": "model/python/fxp_reference.py",
    }
    return json.dumps(body, indent=2) + "\n"


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def build_scenario(name: str, cfg: ScenarioConfig, seed: int) -> Scenario:
    if name not in SCENARIOS:
        raise SystemExit(
            f"unknown scenario '{name}'. Choose from: {', '.join(sorted(SCENARIOS))}"
        )
    return SCENARIOS[name](cfg, seed)


def load_config(path: Path) -> ScenarioConfig:
    if not path.is_file():
        raise SystemExit(f"config file not found: {path}")
    return ScenarioConfig.from_config_json(path)


def default_out_dir(scenario_name: str, seed: int) -> Path:
    return REPO_ROOT / "results" / "scenarios" / f"{scenario_name}_seed{seed}"


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--scenario", default="three_targets",
                   choices=sorted(SCENARIOS.keys()),
                   help="named scenario to generate (default: three_targets)")
    p.add_argument("--seed", type=int, default=1,
                   help="deterministic seed for AWGN and any random choices")
    p.add_argument("--config", default="config/medium.json",
                   help="config JSON file (default: config/medium.json)")
    p.add_argument("--out", default=None,
                   help="output directory (default: results/scenarios/<name>_seed<seed>)")
    args = p.parse_args()

    cfg_path = Path(args.config)
    if not cfg_path.is_absolute():
        cfg_path = REPO_ROOT / cfg_path
    cfg = load_config(cfg_path)
    scen = build_scenario(args.scenario, cfg, args.seed)

    out_dir = Path(args.out) if args.out else default_out_dir(scen.name, scen.seed)
    if not out_dir.is_absolute():
        out_dir = REPO_ROOT / out_dir
    out_dir.mkdir(parents=True, exist_ok=True)

    # Float model + Q1.15 quantisation.
    iq_float = synthesize_iq(scen, cfg)
    re_i, im_i = quantise_iq(iq_float)

    # Sanity: no sample should have saturated except by pathological amplitude
    # choices. Report how many samples hit the endpoints so the caller knows.
    saturated = int(np.sum((re_i == Q15_MAX) | (re_i == Q15_MIN) |
                           (im_i == Q15_MAX) | (im_i == Q15_MIN)))

    iq_path = out_dir / "scenario.iq"
    json_path = out_dir / "scenario.json"
    iq_text = render_iq(scen, cfg, re_i, im_i)
    json_text = render_json(scen, cfg)
    iq_path.write_text(iq_text, encoding="utf-8", newline="\n")
    json_path.write_text(json_text, encoding="utf-8", newline="\n")

    total_samples = int(iq_float.size) * 2  # re + im components
    print(f"[gen_target_iq] scenario '{scen.name}' seed {scen.seed} "
          f"config {cfg.name}")
    print(f"[gen_target_iq]   wrote {iq_path.relative_to(REPO_ROOT)}")
    print(f"[gen_target_iq]   wrote {json_path.relative_to(REPO_ROOT)}")
    print(f"[gen_target_iq]   {len(scen.targets)} targets, "
          f"{cfg.history_frames} frames x {cfg.n_antennas} antennas x "
          f"{cfg.fft_size} samples")
    print(f"[gen_target_iq]   Q1.15 saturated components: {saturated} / "
          f"{total_samples}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
