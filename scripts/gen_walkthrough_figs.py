#!/usr/bin/env python3
"""Generate the input/output illustration figures for docs/design-walkthrough.html.

Every figure is computed with real signal processing (numpy) from a single
deterministic seed -- there is no external data and no hand-drawn artwork.  The
PNGs are rendered to a temporary directory, base64-encoded, and injected in
place into the HTML document, replacing the ``src`` attribute of the ``<img>``
tag carrying the matching ``data-fig`` attribute.

The injection is idempotent: re-running the script replaces the previously
embedded images rather than appending anything, so two consecutive runs produce
byte-identical HTML.

Usage
-----
    python3 scripts/gen_walkthrough_figs.py [--html PATH] [--keep-pngs DIR]
                                            [--seed N] [--dry-run]
"""

from __future__ import annotations

import argparse
import base64
import io
import json
import os
import re
import sys
import tempfile

import numpy as np

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.patches import Rectangle  # noqa: E402

# --------------------------------------------------------------------------
# Global style -- consistent, plain, colourblind-safe (Okabe-Ito palette)
# --------------------------------------------------------------------------

SEED = 20260726

BLUE = "#0072B2"
ORANGE = "#E69F00"
GREEN = "#009E73"
VERMILLION = "#D55E00"
PURPLE = "#CC79A7"
SKY = "#56B4E9"
GREY = "#5b6470"

FIGSIZE = (5.6, 3.0)
DPI = 100

plt.rcParams.update(
    {
        "figure.figsize": FIGSIZE,
        "figure.dpi": DPI,
        "savefig.dpi": DPI,
        "figure.facecolor": "white",
        "savefig.facecolor": "white",
        "axes.facecolor": "white",
        "font.family": "DejaVu Sans",
        "font.size": 8.0,
        "axes.titlesize": 9.0,
        "axes.labelsize": 8.0,
        "axes.linewidth": 0.8,
        "axes.grid": True,
        "grid.color": "#dfe4ea",
        "grid.linewidth": 0.6,
        "axes.spines.top": False,
        "axes.spines.right": False,
        "legend.frameon": False,
        "legend.fontsize": 7.5,
        "xtick.labelsize": 7.5,
        "ytick.labelsize": 7.5,
        "lines.linewidth": 1.2,
        "figure.constrained_layout.use": True,
        "path.simplify": False,
    }
)

ANNOT = dict(
    fontsize=7.2,
    color="#1a1d21",
    bbox=dict(boxstyle="round,pad=0.28", fc="white", ec="#b8c0cb", lw=0.6, alpha=0.92),
)


def _finish(fig) -> bytes:
    """Render a figure to deterministic, palette-quantised PNG bytes."""
    buf = io.BytesIO()
    # metadata Software=None keeps the byte stream free of a version stamp so
    # repeated runs are byte-identical.
    fig.savefig(buf, format="png", metadata={"Software": None})
    plt.close(fig)

    # 24-bit truecolour PNGs of anti-aliased plots are needlessly large; an
    # adaptive 8-bit palette is visually indistinguishable here and roughly
    # halves the byte count.  Median-cut without dithering is deterministic.
    from PIL import Image

    buf.seek(0)
    img = Image.open(buf).convert("RGB")
    img = img.quantize(colors=256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
    out = io.BytesIO()
    img.save(out, format="png", optimize=True)
    return out.getvalue()


def _db(x, floor=-120.0):
    x = np.abs(np.asarray(x))
    return np.maximum(20.0 * np.log10(np.maximum(x, 1e-18)), floor)


def _pdb(p, floor=-120.0):
    p = np.asarray(p, dtype=float)
    return np.maximum(10.0 * np.log10(np.maximum(p, 1e-18)), floor)


# ==========================================================================
# Stage 1 -- synthetic ADC / IQ sampling
# ==========================================================================


def stage1(rng):
    """IN: continuous complex two-tone + noise. OUT: Q1.15 discrete stems."""
    f1, f2 = 1.0e6, 2.6e6  # Hz
    fs = 40.0e6
    # ~1.5 cycles of the lower tone, densely sampled to look continuous
    t_end = 1.5 / f1
    t = np.linspace(0.0, t_end, 4000)
    sig = 0.62 * np.exp(2j * np.pi * f1 * t + 0.4j) + 0.28 * np.exp(
        2j * np.pi * f2 * t - 1.1j
    )
    sig = sig + (rng.standard_normal(t.size) + 1j * rng.standard_normal(t.size)) * 0.012

    fig, ax = plt.subplots()
    ax.plot(t * 1e6, sig.real, color=BLUE, label="I  (in-phase)")
    ax.plot(t * 1e6, sig.imag, color=ORANGE, label="Q  (quadrature)")
    ax.set_xlabel("time (µs)")
    ax.set_ylabel("amplitude (full scale = 1.0)")
    ax.set_title("Analogue baseband: one complex signal, two real traces")
    ax.set_ylim(-1.05, 1.05)
    ax.legend(loc="upper right", ncols=2)
    ax.text(
        0.02,
        0.04,
        "amplitude and phase carried together",
        transform=ax.transAxes,
        **ANNOT,
    )
    png_in = _finish(fig)

    # OUT: sample at fs, quantise to Q1.15, show a zoomed stem plot
    n = np.arange(0, 33)
    ts = n / fs
    s = 0.62 * np.exp(2j * np.pi * f1 * ts + 0.4j) + 0.28 * np.exp(
        2j * np.pi * f2 * ts - 1.1j
    )
    s = s + (rng.standard_normal(n.size) + 1j * rng.standard_normal(n.size)) * 0.012
    # Q1.15: round-to-nearest, saturate to [-32768, 32767], value = code / 2^15
    codes_i = np.clip(np.rint(s.real * 32768.0), -32768, 32767)
    codes_q = np.clip(np.rint(s.imag * 32768.0), -32768, 32767)
    qi, qq = codes_i / 32768.0, codes_q / 32768.0

    fig, ax = plt.subplots()
    ax.stem(
        n - 0.12,
        qi,
        linefmt="-",
        markerfmt="o",
        basefmt=" ",
        label="I code / 2¹⁵",
    )
    ax.stem(
        n + 0.12,
        qq,
        linefmt="-",
        markerfmt="s",
        basefmt=" ",
        label="Q code / 2¹⁵",
    )
    for coll, colour in zip(ax.containers, (BLUE, ORANGE)):
        coll.markerline.set_color(colour)
        coll.markerline.set_markersize(3.0)
        coll.stemlines.set_color(colour)
        coll.stemlines.set_linewidth(1.0)
    ax.axhline(0.0, color=GREY, lw=0.7)
    ax.set_xlabel("sample index n   (fs = 40 MS/s)")
    ax.set_ylabel("Q1.15 value")
    ax.set_title("Digitised stream: 16-bit I / 16-bit Q per sample")
    ax.set_ylim(-1.05, 1.05)
    ax.legend(loc="upper right", ncols=2)
    ax.text(
        0.02,
        0.05,
        f"n={n[3]}:  I={int(codes_i[3]):+d}   Q={int(codes_q[3]):+d}\n"
        "step = 2⁻¹⁵ ≈ 3.05e-5",
        transform=ax.transAxes,
        family="DejaVu Sans Mono",
        **ANNOT,
    )
    png_out = _finish(fig)
    return png_in, png_out


# ==========================================================================
# Stage 2 -- polyphase filter bank
# ==========================================================================


def stage2(rng):
    """IN: plain-FFT leakage buries a weak neighbour. OUT: PFB resolves it."""
    N = 1024
    L = 16  # taps per polyphase phase
    k_strong = 200.5  # deliberately between bin centres
    k_weak = 212.0
    a_weak = 10.0 ** (-52.0 / 20.0)

    n_long = np.arange(L * N)
    x_long = np.exp(2j * np.pi * k_strong * n_long / N) + a_weak * np.exp(
        2j * np.pi * k_weak * n_long / N + 0.7j
    )
    noise = (rng.standard_normal(n_long.size) + 1j * rng.standard_normal(n_long.size))
    x_long = x_long + noise * (10.0 ** (-96.0 / 20.0))

    # --- plain (rectangular-window) FFT of one 1024-sample block
    X_plain = np.fft.fft(x_long[:N]) / N
    plain_db = _db(X_plain) - _db(np.max(np.abs(X_plain)))

    # --- 16-tap/phase polyphase channelizer: windowed-sinc prototype, fold, FFT
    m = n_long - (L * N - 1) / 2.0
    proto = np.sinc(m / N) * np.kaiser(L * N, 9.0)
    proto = proto / np.sum(proto)
    folded = (x_long * proto).reshape(L, N).sum(axis=0)
    X_pfb = np.fft.fft(folded)
    pfb_db = _db(X_pfb) - _db(np.max(np.abs(X_pfb)))

    lo, hi = 178, 244
    k = np.arange(N)
    sl = slice(lo, hi)

    fig, ax = plt.subplots()
    ax.plot(k[sl], plain_db[sl], color=VERMILLION)
    ax.axvline(k_weak, color=GREEN, lw=1.0, ls="--")
    ax.set_xlabel("FFT bin")
    ax.set_ylabel("magnitude (dB, rel. peak)")
    ax.set_title("Straight FFT: leakage skirt from an off-centre tone")
    ax.set_ylim(-110, 8)
    ax.annotate(
        "strong tone at bin 200.5\n(between bin centres)",
        xy=(200.5, 0.0),
        xytext=(0.03, 0.72),
        textcoords="axes fraction",
        arrowprops=dict(arrowstyle="->", lw=0.8, color=GREY),
        **ANNOT,
    )
    ax.annotate(
        f"a −52 dB tone lives at bin 212,\nunder a {plain_db[212]:.0f} dB leakage skirt",
        xy=(212, plain_db[212]),
        xytext=(0.55, 0.20),
        textcoords="axes fraction",
        arrowprops=dict(arrowstyle="->", lw=0.8, color=GREEN),
        **ANNOT,
    )
    png_in = _finish(fig)

    fig, ax = plt.subplots()
    ax.plot(k[sl], plain_db[sl], color="#c9ced6", lw=0.9, label="straight FFT")
    ax.plot(k[sl], pfb_db[sl], color=BLUE, label="16-tap polyphase + FFT")
    ax.axvline(k_weak, color=GREEN, lw=1.0, ls="--")
    ax.set_xlabel("FFT bin")
    ax.set_ylabel("magnitude (dB, rel. peak)")
    ax.set_title("Polyphase channelizer: clean channels, weak tone recovered")
    ax.set_ylim(-110, 8)
    ax.legend(loc="lower left")
    ax.annotate(
        f"weak tone resolved at {pfb_db[212]:.0f} dB\n"
        f"(straight-FFT skirt here: {plain_db[212]:.0f} dB)",
        xy=(212, pfb_db[212]),
        xytext=(0.50, 0.60),
        textcoords="axes fraction",
        arrowprops=dict(arrowstyle="->", lw=0.8, color=GREEN),
        **ANNOT,
    )
    png_out = _finish(fig)
    return png_in, png_out


# ==========================================================================
# Stage 3 -- 1024-point FFT
# ==========================================================================


def stage3(rng):
    """IN: time-domain IQ of two echoes. OUT: 1024-pt spectrum = range gates."""
    N = 1024
    n = np.arange(N)
    k1, k2 = 148.0, 366.0
    x = 0.55 * np.exp(2j * np.pi * k1 * n / N + 0.3j) + 0.22 * np.exp(
        2j * np.pi * k2 * n / N - 0.9j
    )
    x = x + (rng.standard_normal(N) + 1j * rng.standard_normal(N)) * 0.05

    show = 192
    fig, ax = plt.subplots()
    ax.plot(n[:show], x.real[:show], color=BLUE, lw=1.0, label="I")
    ax.plot(n[:show], x.imag[:show], color=ORANGE, lw=1.0, label="Q")
    ax.set_xlabel("fast-time sample index (first 192 of 1024)")
    ax.set_ylabel("Q1.15 value")
    ax.set_title("Time domain: two echoes + noise, structure not visible")
    ax.legend(loc="upper right", ncols=2)
    ax.text(
        0.02,
        0.05,
        "two targets are in here — you cannot see them yet",
        transform=ax.transAxes,
        **ANNOT,
    )
    png_in = _finish(fig)

    X = np.fft.fft(x * np.hanning(N)) / N
    mag = _db(X)
    mag = mag - np.max(mag)

    fig, ax = plt.subplots()
    ax.plot(np.arange(N // 2), mag[: N // 2], color=BLUE, lw=0.9)
    ax.set_xlabel("frequency bin  =  range gate")
    ax.set_ylabel("magnitude (dB, rel. peak)")
    ax.set_title("1024-point FFT: delay became frequency, frequency is range")
    ax.set_ylim(-90, 10)
    for kk, lbl, dy in (
        (int(k1), "range gate 148", -16.0),
        (int(k2), "range gate 366", -24.0),
    ):
        ax.annotate(
            lbl,
            xy=(kk, mag[kk]),
            xytext=(kk + 34, mag[kk] + dy),
            arrowprops=dict(arrowstyle="->", lw=0.8, color=VERMILLION),
            **ANNOT,
        )
    png_out = _finish(fig)
    return png_in, png_out


# ==========================================================================
# Stage 4 -- history store & corner turn
# ==========================================================================


def stage4(rng):
    """IN: magnitude waterfall (frames x bins). OUT: one bin's phase vs frame."""
    n_frames, n_bins = 64, 128
    tgt_bin = 46
    fd = 0.085  # cycles per frame -> linear phase ramp
    frames = np.arange(n_frames)

    cube = (
        rng.standard_normal((n_frames, n_bins))
        + 1j * rng.standard_normal((n_frames, n_bins))
    ) * 0.16
    # a stationary-in-range target whose phase rotates frame to frame
    cube[:, tgt_bin] += 1.0 * np.exp(2j * np.pi * fd * frames + 0.35j)
    # a couple of static clutter ridges for realism
    cube[:, 18] += 0.42
    cube[:, 97] += 0.30 * np.exp(0.9j)

    fig, ax = plt.subplots()
    im = ax.imshow(
        np.abs(cube),
        aspect="auto",
        origin="lower",
        cmap="viridis",
        interpolation="nearest",
        extent=(0, n_bins, 0, n_frames),
    )
    ax.grid(False)
    ax.set_xlabel("frequency bin (range gate)")
    ax.set_ylabel("frame index (slow time)")
    ax.set_title("History store: 64 frames × 128 bins, written row by row")
    cb = fig.colorbar(im, ax=ax, pad=0.02)
    cb.set_label("|X| magnitude", fontsize=7.5)
    cb.ax.tick_params(labelsize=7)
    ax.add_patch(
        Rectangle(
            (tgt_bin - 0.5, 0), 2.0, n_frames, fill=False, ec=VERMILLION, lw=1.2
        )
    )
    ax.text(
        0.02,
        0.92,
        "corner turn = read this column, not a row",
        transform=ax.transAxes,
        **ANNOT,
    )
    png_in = _finish(fig)

    col = cube[:, tgt_bin]
    phase = np.unwrap(np.angle(col))
    slope, intercept = np.polyfit(frames, phase, 1)

    fig, ax = plt.subplots()
    ax.plot(frames, phase, "o", ms=3.0, color=BLUE, label="measured phase")
    ax.plot(
        frames,
        slope * frames + intercept,
        color=VERMILLION,
        lw=1.2,
        label=f"fit: {slope:.4f} rad/frame",
    )
    ax.set_xlabel("frame index (slow time)")
    ax.set_ylabel("unwrapped phase (rad)")
    ax.set_title(f"One column (bin {tgt_bin}) across frames: a linear phase ramp")
    ax.legend(loc="upper left")
    ax.text(
        0.52,
        0.10,
        f"Doppler = slope / 2π = {slope / (2 * np.pi):.4f} cycles/frame\n"
        f"(truth {fd:.4f})",
        transform=ax.transAxes,
        **ANNOT,
    )
    png_out = _finish(fig)
    return png_in, png_out


# ==========================================================================
# Stage 5 -- frequency-bin alignment network
# ==========================================================================


def stage5(rng):
    """IN: tiles arriving skewed/permuted. OUT: perfect (bin x antenna) raster."""
    n_bins, n_ant = 8, 16
    b, a = np.meshgrid(np.arange(n_bins), np.arange(n_ant), indexing="ij")
    bank = (a + 3 * b) % 8
    # bank-dependent service latency plus per-response jitter -> skewed arrivals
    latency = 6.0 * bank + 2.5 * ((a * 5 + b * 11) % 7) + rng.uniform(0, 4.0, (n_bins, n_ant))
    arrival_rank = np.empty(latency.size, dtype=int)
    arrival_rank[np.argsort(latency, axis=None, kind="stable")] = np.arange(latency.size)
    arrival_rank = arrival_rank.reshape(n_bins, n_ant)

    raster = (np.arange(n_bins * n_ant)).reshape(n_bins, n_ant)

    def _grid(data, title, note):
        fig, ax = plt.subplots()
        im = ax.imshow(
            data,
            aspect="auto",
            origin="upper",
            cmap="viridis",
            interpolation="nearest",
            vmin=0,
            vmax=n_bins * n_ant - 1,
        )
        ax.grid(False)
        ax.set_xticks(np.arange(0, n_ant, 2))
        ax.set_yticks(np.arange(n_bins))
        ax.set_xlabel("antenna index")
        ax.set_ylabel("bin (within beat)")
        ax.set_title(title)
        cb = fig.colorbar(im, ax=ax, pad=0.02)
        cb.set_label("order in time", fontsize=7.5)
        cb.ax.tick_params(labelsize=7)
        ax.text(0.012, 0.03, note, transform=ax.transAxes, **ANNOT)
        return _finish(fig)

    png_in = _grid(
        arrival_rank,
        "Read responses as they come back: banks answer out of order",
        "colour = arrival order — scrambled",
    )
    png_out = _grid(
        raster,
        "After alignment: one beat = 8 bins × 16 antennas, in order",
        "colour = delivery order — perfect raster",
    )
    return png_in, png_out


# ==========================================================================
# Stage 6 -- beamformer
# ==========================================================================


def stage6(rng):
    """IN: per-antenna phase of a plane wave. OUT: steered array factor."""
    n_ant = 16
    d_lam = 0.5
    theta0 = 25.0
    ant = np.arange(n_ant)
    psi = 2 * np.pi * d_lam * np.sin(np.deg2rad(theta0)) * ant
    meas = psi + rng.standard_normal(n_ant) * 0.09

    fig, ax = plt.subplots()
    ax.plot(ant, np.rad2deg(meas), "o", ms=4.0, color=BLUE, label="measured phase")
    ax.plot(ant, np.rad2deg(psi), color=VERMILLION, lw=1.1, label="ideal 25° ramp")
    ax.set_xlabel("antenna element index")
    ax.set_ylabel("unwrapped phase (degrees)")
    ax.set_title("A plane wave from 25°: a linear phase ramp across the array")
    ax.set_xticks(np.arange(0, n_ant, 2))
    ax.legend(loc="upper left")
    ax.text(
        0.46,
        0.08,
        "Δphase per element = 2π·(d/λ)·sin θ\n= 76.1° at d = λ/2, θ = 25°",
        transform=ax.transAxes,
        **ANNOT,
    )
    png_in = _finish(fig)

    ang = np.linspace(-90.0, 90.0, 2001)
    steer = np.exp(-1j * psi)  # conjugate weights -> point at 25 degrees
    sv = np.exp(
        2j * np.pi * d_lam * np.outer(np.sin(np.deg2rad(ang)), ant)
    )
    # floor the nulls at -40 dB so the legend has clean space below the pattern
    af_steer = np.maximum(_db(np.abs(sv @ steer) / n_ant), -40.0)
    af_broad = np.maximum(_db(np.abs(sv @ np.ones(n_ant)) / n_ant), -40.0)

    fig, ax = plt.subplots()
    ax.plot(ang, af_broad, color="#c9ced6", lw=0.9, label="unsteered (broadside)")
    ax.plot(ang, af_steer, color=BLUE, lw=1.2, label="weights steered to 25°")
    ax.set_xlabel("arrival angle (degrees)")
    ax.set_ylabel("array response (dB)")
    ax.set_title("16-element array factor: one of the 16 simultaneous beams")
    ax.set_ylim(-54, 5)
    ax.set_xlim(-90, 90)
    ax.set_yticks(np.arange(-40, 1, 10))
    ax.set_xticks(np.arange(-90, 91, 30))
    ax.legend(loc="lower center", ncols=2)
    pk = ang[np.argmax(af_steer)]
    half = ang[af_steer >= -3.0]
    ax.annotate(
        f"peak at {pk:+.1f}°\n−3 dB width ≈ {half.max() - half.min():.1f}°",
        xy=(pk, 0.0),
        xytext=(0.66, 0.66),
        textcoords="axes fraction",
        arrowprops=dict(arrowstyle="->", lw=0.8, color=VERMILLION),
        **ANNOT,
    )
    png_out = _finish(fig)
    return png_in, png_out


# ==========================================================================
# Stage 7 -- power & integration
# ==========================================================================


def stage7(rng):
    """IN: single-look power, +6 dB target. OUT: 64-look integration."""
    n_bins, n_looks = 256, 64
    tgt = 96
    amp = 10.0 ** (6.0 / 20.0) / np.sqrt(2.0)  # target power = 4x noise power

    noise = (
        rng.standard_normal((n_looks, n_bins)) + 1j * rng.standard_normal((n_looks, n_bins))
    ) / np.sqrt(2.0)
    sig = np.zeros((n_looks, n_bins), dtype=complex)
    sig[:, tgt] = amp * np.exp(2j * np.pi * rng.uniform(0, 1, n_looks))
    power = np.abs(sig + noise) ** 2

    single = power[0]
    integ = power.mean(axis=0)

    mask = np.ones(n_bins, dtype=bool)
    mask[tgt] = False
    ratio = single[mask].std() / integ[mask].std()

    def _plot(y, title, note, colour):
        fig, ax = plt.subplots()
        ax.plot(np.arange(n_bins), _pdb(y), color=colour, lw=0.9)
        ax.axvline(tgt, color=VERMILLION, lw=0.9, ls="--", alpha=0.7)
        ax.set_xlabel("frequency bin (range gate)")
        ax.set_ylabel("power (dB, rel. mean noise)")
        ax.set_title(title)
        ax.set_ylim(-24, 14)
        ax.annotate(
            note,
            xy=(tgt, _pdb(y[tgt])),
            xytext=(0.42, 0.80),
            textcoords="axes fraction",
            arrowprops=dict(arrowstyle="->", lw=0.8, color=VERMILLION),
            **ANNOT,
        )
        return _finish(fig)

    png_in = _plot(
        single,
        "One look: a +6 dB target lost in the speckle",
        f"target at bin {tgt}\nindistinguishable from noise peaks",
        GREY,
    )
    png_out = _plot(
        integ,
        f"{n_looks} looks integrated: the target stays, the noise smooths",
        f"same target, now unmistakable\nnoise σ shrank {ratio:.1f}× ≈ √{n_looks}",
        BLUE,
    )
    return png_in, png_out


# ==========================================================================
# Stage 8 -- CA-CFAR
# ==========================================================================


def ca_cfar(power, guard, ref, alpha):
    """Exact sliding cell-averaging CFAR. Returns (threshold, valid mask)."""
    n = power.size
    thr = np.full(n, np.nan)
    valid = np.zeros(n, dtype=bool)
    half = guard + ref
    for i in range(half, n - half):
        lead = power[i - half : i - guard]
        lag = power[i + guard + 1 : i + half + 1]
        thr[i] = alpha * (lead.sum() + lag.sum()) / (2 * ref)
        valid[i] = True
    return thr, valid


def stage8(rng):
    """IN: power with a noise-floor step + 3 targets. OUT: CFAR threshold."""
    n_bins = 256
    guard, ref = 2, 8
    n_ref = 2 * ref
    pfa = 1e-4
    alpha = n_ref * (pfa ** (-1.0 / n_ref) - 1.0)

    floor = np.where(np.arange(n_bins) < 128, 1.0, 6.31)  # +8 dB step at bin 128
    noise = (
        rng.standard_normal(n_bins) + 1j * rng.standard_normal(n_bins)
    ) / np.sqrt(2.0)
    x = noise * np.sqrt(floor)
    targets = [(58, 18.0), (152, 16.0), (207, 14.0)]  # (bin, SNR dB over local floor)
    for b, snr in targets:
        x[b] += np.sqrt(floor[b]) * 10.0 ** (snr / 20.0) * np.exp(1.1j * b)
    power = np.abs(x) ** 2

    fig, ax = plt.subplots()
    ax.plot(np.arange(n_bins), _pdb(power), color=GREY, lw=0.9)
    ax.axvline(128, color=PURPLE, lw=1.0, ls=":")
    ax.set_xlabel("frequency bin")
    ax.set_ylabel("integrated power (dB)")
    ax.set_title("Detector input: noise floor steps +8 dB, three targets hidden in it")
    ax.set_ylim(-26, 42)
    ax.text(
        0.24,
        0.90,
        "a single fixed threshold cannot serve both halves",
        transform=ax.transAxes,
        **ANNOT,
    )
    png_in = _finish(fig)

    thr, valid = ca_cfar(power, guard, ref, alpha)
    det = valid & (power > np.nan_to_num(thr, nan=np.inf))

    fig, ax = plt.subplots()
    ax.plot(np.arange(n_bins), _pdb(power), color=GREY, lw=0.9, label="power")
    ax.plot(
        np.arange(n_bins)[valid],
        _pdb(thr[valid]),
        color=VERMILLION,
        lw=1.2,
        label=f"CA-CFAR threshold (guard={guard}, ref={ref}/side, α={alpha:.1f})",
    )
    ax.plot(
        np.arange(n_bins)[det],
        _pdb(power[det]),
        "v",
        ms=6.0,
        color=GREEN,
        label=f"detections ({det.sum()})",
    )
    ax.axvline(128, color=PURPLE, lw=1.0, ls=":")
    ax.set_xlabel("frequency bin")
    ax.set_ylabel("integrated power (dB)")
    ax.set_title("CA-CFAR: the threshold rides the local noise, so Pfa stays constant")
    ax.set_ylim(-26, 42)
    ax.legend(loc="upper left", ncols=1)
    ax.annotate(
        "threshold steps with the floor",
        xy=(140, _pdb(np.nanmedian(thr[140:200]))),
        xytext=(0.46, 0.06),
        textcoords="axes fraction",
        arrowprops=dict(arrowstyle="->", lw=0.8, color=PURPLE),
        **ANNOT,
    )
    png_out = _finish(fig)
    return png_in, png_out


# ==========================================================================
# Stage 9 -- packet network
# ==========================================================================


def stage9(rng):
    """IN: concurrent events from 4 sources. OUT: serialized per-VC streams."""
    n_src, n_vc = 4, 4
    vc_names = ["VC0 detections", "VC1 telemetry", "VC2 bulk capture", "VC3 errors"]
    vc_colours = [VERMILLION, BLUE, ORANGE, PURPLE]
    src_names = ["CFAR", "power/covar", "capture", "health"]

    events = []  # (arrival_cycle, source, vc)
    rates = [0.30, 0.20, 0.34, 0.08]
    horizon = 120
    for s in range(n_src):
        t = 0.0
        while True:
            t += rng.exponential(1.0 / rates[s])
            if t > horizon:
                break
            vc = int(rng.choice(n_vc, p=[0.45, 0.22, 0.26, 0.07]))
            events.append((t, s, vc))
    events.sort(key=lambda e: e[0])
    arr = np.array(events)

    fig, ax = plt.subplots()
    for vc in range(n_vc):
        sel = arr[arr[:, 2] == vc]
        ax.scatter(
            sel[:, 0],
            sel[:, 1] + (vc - 1.5) * 0.13,
            s=16,
            color=vc_colours[vc],
            label=vc_names[vc],
            zorder=3,
        )
    ax.set_yticks(range(n_src), src_names)
    ax.set_ylim(-0.7, n_src - 0.3)
    ax.set_xlabel("cycle")
    ax.set_ylabel("producer")
    ax.set_title(f"{len(events)} events from 4 producers, all at once, 4 classes")
    ax.legend(loc="upper center", ncols=4, bbox_to_anchor=(0.5, 1.30))
    png_in = _finish(fig)

    # Serialise: one packet leaves per cycle; round-robin among ready VCs,
    # strictly preserving per-VC order.  Credit-based flow control means the
    # queue backs up rather than dropping anything.
    queues = {v: [] for v in range(n_vc)}
    for t, s, v in events:
        queues[v].append((t, s))
    pending = {v: 0 for v in range(n_vc)}
    out = []  # (departure_cycle, vc, source)
    cycle = 0.0
    rr = 0
    while any(pending[v] < len(queues[v]) for v in range(n_vc)):
        ready = [
            v
            for v in range(n_vc)
            if pending[v] < len(queues[v]) and queues[v][pending[v]][0] <= cycle
        ]
        if ready:
            order = [(rr + i) % n_vc for i in range(n_vc)]
            v = next(x for x in order if x in ready)
            t, s = queues[v][pending[v]]
            pending[v] += 1
            out.append((cycle, v, s))
            rr = (v + 1) % n_vc
        cycle += 1.0
        if cycle > 4000:
            break
    dep = np.array(out)

    fig, ax = plt.subplots()
    for vc in range(n_vc):
        sel = dep[dep[:, 1] == vc]
        ax.scatter(sel[:, 0], np.full(sel.shape[0], vc), s=16, color=vc_colours[vc], zorder=3)
        ax.plot(sel[:, 0], np.full(sel.shape[0], vc), color=vc_colours[vc], lw=0.7, alpha=0.5)
    ax.set_yticks(range(n_vc), vc_names)
    ax.set_ylim(-1.5, n_vc - 0.3)
    ax.set_xlabel("cycle (egress)")
    ax.set_ylabel("virtual channel")
    ax.set_title("Serialised onto one link: a lane per VC, arbitrated per hop")
    ax.text(
        0.02,
        0.04,
        f"{len(events)} in → {len(out)} out: no loss, no duplication,\n"
        "order preserved within every VC",
        transform=ax.transAxes,
        **ANNOT,
    )
    png_out = _finish(fig)
    return png_in, png_out


# ==========================================================================
# Stage 10 -- what the delivered data lets you build: range-Doppler
# ==========================================================================


def stage10(rng):
    """IN: raw slow-time magnitude waterfall. OUT: range-Doppler map."""
    n_frames, n_range = 128, 256
    frames = np.arange(n_frames)
    truth = [(62, 0.180, 1.05), (131, -0.086, 0.90), (194, 0.320, 0.78)]

    cube = (
        rng.standard_normal((n_frames, n_range))
        + 1j * rng.standard_normal((n_frames, n_range))
    ) / np.sqrt(2.0)
    # stationary clutter: strong, frame-to-frame constant (zero Doppler), so it
    # dominates the raw magnitude view but collapses onto one Doppler row
    clutter = (
        rng.standard_normal(n_range) + 1j * rng.standard_normal(n_range)
    ) * (1.4 + 0.9 * np.sin(np.arange(n_range) / 21.0) ** 2)
    cube += clutter[None, :]
    for rbin, fd, amp in truth:
        cube[:, rbin] += amp * np.exp(2j * np.pi * fd * frames + 0.5j * rbin)

    fig, ax = plt.subplots()
    im = ax.imshow(
        np.abs(cube),
        aspect="auto",
        origin="lower",
        cmap="viridis",
        interpolation="nearest",
        extent=(0, n_range, 0, n_frames),
    )
    ax.grid(False)
    ax.set_xlabel("range bin")
    ax.set_ylabel("frame index (slow time)")
    ax.set_title("Raw delivered cube: three moving targets are in here")
    cb = fig.colorbar(im, ax=ax, pad=0.02)
    cb.set_label("|X|", fontsize=7.5)
    cb.ax.tick_params(labelsize=7)
    ax.text(
        0.012,
        0.03,
        "static clutter dominates; per-look target SNR < 1 — motion is invisible",
        transform=ax.transAxes,
        **ANNOT,
    )
    png_in = _finish(fig)

    win = np.hanning(n_frames)[:, None]
    rd = np.fft.fftshift(np.fft.fft(cube * win, axis=0), axes=0) / n_frames
    rd_db = _pdb(np.abs(rd) ** 2)
    rd_db = rd_db - np.median(rd_db)
    dopp = np.fft.fftshift(np.fft.fftfreq(n_frames))

    fig, ax = plt.subplots()
    im = ax.imshow(
        rd_db,
        aspect="auto",
        origin="lower",
        cmap="magma",
        interpolation="nearest",
        extent=(0, n_range, dopp[0], dopp[-1] + (dopp[1] - dopp[0])),
        vmin=2.0,
        vmax=20.0,
    )
    ax.grid(False)
    ax.set_xlabel("range bin")
    ax.set_ylabel("Doppler (cycles / frame)")
    ax.set_title("Range-Doppler map: slow-time FFT per range bin")
    cb = fig.colorbar(im, ax=ax, pad=0.02)
    cb.set_label("power (dB above median)", fontsize=7.5)
    cb.ax.tick_params(labelsize=7)
    for rbin, fd, _amp in truth:
        ax.plot(rbin + 0.5, fd, "o", ms=13, mfc="none", mec="#39ff9a", mew=1.4)
    ax.axhline(0.0, color="#39ff9a", lw=0.6, ls=":", alpha=0.55)
    ax.text(
        0.012,
        0.90,
        "circles = ground truth (range, Doppler); dotted row = zero-Doppler clutter",
        transform=ax.transAxes,
        **ANNOT,
    )
    png_out = _finish(fig)
    return png_in, png_out


# ==========================================================================
# Driver
# ==========================================================================

STAGES = [
    ("s1", stage1),
    ("s2", stage2),
    ("s3", stage3),
    ("s4", stage4),
    ("s5", stage5),
    ("s6", stage6),
    ("s7", stage7),
    ("s8", stage8),
    ("s9", stage9),
    ("s10", stage10),
]


def build_figures(seed: int) -> "dict[str, bytes]":
    figs: dict[str, bytes] = {}
    for name, fn in STAGES:
        # a per-stage seed keeps every figure independent of the ones before it,
        # so editing one stage cannot churn the others
        rng = np.random.default_rng(seed + 1000 * int(name[1:]))
        png_in, png_out = fn(rng)
        figs[f"{name}-in"] = png_in
        figs[f"{name}-out"] = png_out
    return figs


def inject(html: str, figs: "dict[str, bytes]") -> "tuple[str, list[str]]":
    """Replace the src of every <img data-fig="..."> with a base64 data URI."""
    missing = []
    for fig_id, png in figs.items():
        uri = "data:image/png;base64," + base64.b64encode(png).decode("ascii")
        pattern = re.compile(
            r'(<img\b[^>]*\bdata-fig="' + re.escape(fig_id) + r'"[^>]*?\bsrc=")[^"]*(")'
        )
        html, n = pattern.subn(lambda m: m.group(1) + uri + m.group(2), html)
        if n != 1:
            missing.append(f"{fig_id} (matched {n} times)")
    return html, missing


def main() -> int:
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--html", default=os.path.join(here, "docs", "design-walkthrough.html"))
    ap.add_argument("--seed", type=int, default=SEED)
    ap.add_argument("--keep-pngs", default=None, help="also write the PNGs to this directory")
    ap.add_argument("--dry-run", action="store_true", help="render but do not touch the HTML")
    ap.add_argument("--manifest", default=None, help="write a JSON size manifest here")
    args = ap.parse_args()

    print(f"deterministic seed = {args.seed}")
    figs = build_figures(args.seed)

    tmpdir = args.keep_pngs or tempfile.mkdtemp(prefix="walkthrough-figs-")
    os.makedirs(tmpdir, exist_ok=True)
    sizes = {}
    for fig_id, png in figs.items():
        path = os.path.join(tmpdir, f"{fig_id}.png")
        with open(path, "wb") as fh:
            fh.write(png)
        sizes[fig_id] = len(png)

    total = sum(sizes.values())
    for fig_id in figs:
        print(f"  {fig_id:>8s}  {sizes[fig_id]:7d} B")
    print(f"  {'total':>8s}  {total:7d} B  ({total / 1024:.1f} KiB) in {tmpdir}")

    if args.manifest:
        with open(args.manifest, "w", encoding="utf-8") as fh:
            json.dump({"seed": args.seed, "sizes": sizes, "total": total}, fh, indent=2)

    if args.dry_run:
        return 0

    with open(args.html, "r", encoding="utf-8", newline="") as fh:
        html = fh.read()
    new_html, missing = inject(html, figs)
    if missing:
        print("ERROR: markers not found exactly once: " + ", ".join(missing), file=sys.stderr)
        return 1
    with open(args.html, "w", encoding="utf-8", newline="") as fh:
        fh.write(new_html)
    print(f"wrote {args.html}: {len(new_html.encode('utf-8')) / 1024:.1f} KiB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
