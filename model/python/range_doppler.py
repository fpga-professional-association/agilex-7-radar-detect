#!/usr/bin/env python3
"""Run a scenario through the reference chain and render range-Doppler maps.

    python3 model/python/range_doppler.py \
        --iq results/scenarios/three_targets_seed1/scenario.iq \
        --json results/scenarios/three_targets_seed1/scenario.json

Or, to run the whole flow from a scenario name (generator + visualiser):

    python3 model/python/range_doppler.py --scenario three_targets --seed 1

Purpose
-------
The generator (``gen_target_iq.py``) produces the Q1.15 IQ time series. This
script reads it (or regenerates it if given a scenario name), runs it through
the reference chain the pipeline is verified against — polyphase FIR bank ->
per-frame FFT (bit-exact through ``pfb_model`` and the numpy FFT of the same
frames) -> per-bin history across ``HISTORY_FRAMES`` -> slow-time FFT per bin
across frames = Doppler — and renders one range-Doppler PNG per antenna. The
ground-truth targets are overlaid as circles, and a small table is printed
comparing ground truth to the map's own peak locations.

CFAR-detected comparison is deliberately NOT here. That belongs to part 2 of
issue #44: a real detector sees the map through the pipeline, not through a
Python argmax. The reference-map peak table below is only a sanity check:
the target should land in the right (range, Doppler) bin, within ±1 bin,
for the acceptance gate to pass.

Fast-time / slow-time
---------------------
See ``docs/range_doppler.md``. FFT bin = range gate; the slow-time FFT
across ``HISTORY_FRAMES`` at each range bin is the Doppler axis. The
Doppler axis is fftshifted so bin 0 (stationary) sits at the vertical
centre of the plotted map.

PFB path
--------
For a clean range-Doppler picture we use the ``ident`` prototype (the
per-phase unit impulse) so the PFB is a bit-exact pass-through. That is the
right choice for a target-visualisation script: the range-Doppler picture is
about where energy lands, and a real windowed prototype would broaden every
peak by the filter's main-lobe width. Using the identity keeps the peak a
peak. The bit-exact PFB step still runs — the pipeline path is exercised —
but its answer is exactly its input (SPEC 7.1 nominal, ident set is the
reference case). See ``model/vectors/pfb_ident_p4t8.vec`` for the same
property proved as data.

FFT path
--------
The scenario's per-frame FFT uses ``numpy.fft.fft`` at float precision.
This script's job is a REFERENCE map, not a bit-exact hardware-facing
oracle: the RTL FFT is proved bit-exact against ``model/vectors/fft64.vec``
by the SPEC 7.2 test, and part 2 will feed the same IQ through the RTL to
prove the picture is the same. The float FFT here is the arithmetic that
gives you clean picture; using it makes the peak table's ``±1 bin`` sanity
gate independent of the fixed-point scaling schedule (which shifts down by
one bit per set stage bit and would drop the weak target below the noise
after eight stages of a 256-point transform).

Runs on WSL Ubuntu-24.04 python3 (numpy >= 1.26, matplotlib >= 3.8).
"""

from __future__ import annotations

import argparse
import json
import re as _re
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

import fxp_reference as fxp  # noqa: E402
import gen_target_iq as gen  # noqa: E402
import pfb_model  # noqa: E402

# matplotlib is imported lazily inside render_map so a --no-plot dry run does
# not require the library.

REPO_ROOT = Path(__file__).resolve().parents[2]

Q15_MAX = int(fxp.max_of(fxp.SAMPLE_W))


# ---------------------------------------------------------------------------
# IQ file parsing
# ---------------------------------------------------------------------------


def _parse_header_kv(lines: list[str]) -> dict:
    """Extract ``# key: value`` pairs from an IQ file header block."""
    kv: dict = {}
    for line in lines:
        s = line.strip()
        if not s.startswith("#"):
            continue
        body = s.lstrip("#").strip()
        if ":" not in body:
            continue
        # Allow only single-colon parses on well-formed header keys.
        m = _re.match(r"([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)", body)
        if m:
            key, value = m.group(1), m.group(2).strip()
            if key not in kv:
                kv[key] = value
    return kv


def load_iq(iq_path: Path) -> tuple[dict, np.ndarray, np.ndarray]:
    """Read an IQ file. Return (header_kv, re_i, im_i) as (H, A, N) int64.

    The header must carry ``FFT_SIZE``, ``HISTORY_FRAMES``, ``N_ANTENNAS``,
    ``SAMPLES_PER_CYCLE`` — every value is checked against the row count so a
    truncated file fails immediately rather than "loading short".
    """
    with iq_path.open("r", encoding="utf-8") as fh:
        lines = fh.readlines()
    hdr = _parse_header_kv(lines)

    required = ("FFT_SIZE", "HISTORY_FRAMES", "N_ANTENNAS", "SAMPLES_PER_CYCLE")
    for key in required:
        if key not in hdr:
            raise SystemExit(f"IQ header missing key '{key}': {iq_path}")

    n = int(hdr["FFT_SIZE"])
    h = int(hdr["HISTORY_FRAMES"])
    a = int(hdr["N_ANTENNAS"])
    p = int(hdr["SAMPLES_PER_CYCLE"])
    beats_per_frame = n // p

    re_i = np.zeros((h, a, n), dtype=np.int64)
    im_i = np.zeros((h, a, n), dtype=np.int64)

    rows = 0
    for line in lines:
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        toks = s.split()
        # frame antenna beat sof eof <p pairs>
        f_idx = int(toks[0])
        ant = int(toks[1])
        beat = int(toks[2])
        # sof, eof at toks[3], toks[4] — checked against beat position, so an
        # invalid framing shows up here rather than silently at the visualiser.
        sof = int(toks[3])
        eof = int(toks[4])
        expected_sof = 1 if beat == 0 else 0
        expected_eof = 1 if beat == beats_per_frame - 1 else 0
        if sof != expected_sof or eof != expected_eof:
            raise SystemExit(
                f"IQ framing mismatch at frame {f_idx} antenna {ant} beat "
                f"{beat}: sof={sof} eof={eof}, expected sof={expected_sof} "
                f"eof={expected_eof}"
            )
        pairs = toks[5:]
        if len(pairs) != 2 * p:
            raise SystemExit(
                f"IQ beat has {len(pairs)/2} samples, expected {p} at "
                f"frame {f_idx} antenna {ant} beat {beat}"
            )
        for slot in range(p):
            idx = beat * p + slot
            re_i[f_idx, ant, idx] = int(pairs[2 * slot])
            im_i[f_idx, ant, idx] = int(pairs[2 * slot + 1])
        rows += 1

    expected_rows = h * a * beats_per_frame
    if rows != expected_rows:
        raise SystemExit(
            f"IQ has {rows} beat rows, expected {expected_rows} "
            f"({h} frames * {a} antennas * {beats_per_frame} beats)"
        )
    return hdr, re_i, im_i


def load_ground_truth(json_path: Path) -> dict:
    with json_path.open("r", encoding="utf-8") as fh:
        return json.load(fh)


# ---------------------------------------------------------------------------
# Reference chain — PFB pass-through, per-frame FFT, per-bin slow-time FFT
# ---------------------------------------------------------------------------


def ident_pfb_coeff(phases: int, taps: int) -> list[tuple[int, int]]:
    """Per-phase unit impulse at maximum gain (SPEC 7.1 ident set).

    Every lane is a pass-through: output beat m is input beat m, exactly.
    The one filter whose expected output can be written down without running
    any model. See ``model/vectors/pfb_ident_p4t8.vec`` for the property
    proved as data on the p4t8 geometry.
    """
    coeff: list[tuple[int, int]] = []
    for _p in range(phases):
        coeff.append((Q15_MAX, 0))
        coeff.extend([(0, 0)] * (taps - 1))
    return coeff


def run_pfb(re_i: np.ndarray, im_i: np.ndarray, phases: int, taps: int
            ) -> tuple[np.ndarray, np.ndarray]:
    """Push every antenna's every frame through a ``phases x taps`` PFB.

    Uses the identity coefficient set so the output is a bit-exact copy of the
    input in steady state. The PFB is stepped one beat at a time — one beat
    carries ``phases`` samples — so the accounting matches the RTL and part 2's
    sim injection. Returns re/im int64 arrays of the same shape as the input.
    """
    h, a, n = re_i.shape
    if n % phases != 0:
        raise SystemExit(
            f"FFT_SIZE={n} is not a multiple of PFB phases={phases}: "
            "cannot step a whole beat."
        )
    beats_per_frame = n // phases
    out_re = np.zeros_like(re_i)
    out_im = np.zeros_like(im_i)
    coeff = ident_pfb_coeff(phases, taps)
    for ant in range(a):
        model = pfb_model.PfbModel(phases=phases, taps=taps, coeff=coeff)
        for f in range(h):
            for b in range(beats_per_frame):
                beat = [
                    (int(re_i[f, ant, b * phases + p]),
                     int(im_i[f, ant, b * phases + p]))
                    for p in range(phases)
                ]
                ys, _flags = model.step(beat)
                for p, (yr, yi) in enumerate(ys):
                    out_re[f, ant, b * phases + p] = yr
                    out_im[f, ant, b * phases + p] = yi
    return out_re, out_im


def frame_fft(re_i: np.ndarray, im_i: np.ndarray) -> np.ndarray:
    """Per-frame, per-antenna FFT across the fast-time axis. Complex128.

    See the module docstring for why this is the float FFT: this script's job
    is a REFERENCE picture, not a bit-exact fixed-point oracle. The RTL FFT
    is proved bit-exact against ``model/vectors/fft64.vec`` by a separate
    test; part 2 of #44 will prove the RTL picture agrees with this one.
    """
    complex_iq = (re_i.astype(np.float64) + 1j * im_i.astype(np.float64)) / float(
        1 << fxp.FRAC_W
    )
    # Axis -1 is fast-time samples within a frame.
    return np.fft.fft(complex_iq, axis=-1)


def range_doppler(spectra: np.ndarray) -> np.ndarray:
    """Slow-time FFT at each range bin, across frames. Complex128.

    Input shape: ``(H, A, N)`` — H frames, A antennas, N range bins.
    Output shape: ``(H, A, N)`` — H Doppler bins, A antennas, N range bins.
    Applies ``fftshift`` on the Doppler axis so Doppler bin 0 (stationary)
    sits at the vertical centre when plotted with the natural origin at top.
    """
    # Axis 0 is the frame axis, i.e. slow-time.
    rd = np.fft.fft(spectra, axis=0)
    rd = np.fft.fftshift(rd, axes=0)
    return rd


def doppler_bin_to_shifted_index(k_d: int, h: int) -> int:
    """Where does Doppler ground-truth bin ``k_d`` land after ``fftshift``?

    ``fftshift`` maps ``k -> (k + h//2) % h`` on axis 0.
    """
    return (k_d + h // 2) % h


# ---------------------------------------------------------------------------
# Peak comparison
# ---------------------------------------------------------------------------


def find_peaks(rd_map: np.ndarray, targets: list[dict]
               ) -> list[tuple[int, int, int, float]]:
    """For each target, find the (antenna, range, shifted-Doppler) argmax.

    Only searches in a small window around the target's expected location so
    a much brighter neighbouring target does not steal a weaker target's
    peak. Window: ±2 bins on each axis, ±1 antenna. Returns a list of tuples
    ``(target_idx, best_ant, peak_range, peak_shifted_doppler, magnitude_dB)``
    — one per target, in input order.
    """
    h, a, n = rd_map.shape
    win_r = 2
    win_d = 2
    win_a = 1
    magnitudes = np.abs(rd_map)
    peak_max = float(np.max(magnitudes)) + 1e-30
    peaks = []
    for i, t in enumerate(targets):
        expected_r = int(t["range_bin"])
        expected_d = doppler_bin_to_shifted_index(int(t["doppler_bin"]), h)
        expected_a = int(t["angle_idx"])
        r_lo = max(0, expected_r - win_r)
        r_hi = min(n, expected_r + win_r + 1)
        d_lo = max(0, expected_d - win_d)
        d_hi = min(h, expected_d + win_d + 1)
        a_lo = max(0, expected_a - win_a)
        a_hi = min(a, expected_a + win_a + 1)
        sub = magnitudes[d_lo:d_hi, a_lo:a_hi, r_lo:r_hi]
        d_off, a_off, r_off = np.unravel_index(int(np.argmax(sub)), sub.shape)
        peak_d = d_lo + int(d_off)
        peak_a = a_lo + int(a_off)
        peak_r = r_lo + int(r_off)
        mag = float(magnitudes[peak_d, peak_a, peak_r])
        # Peak in dB relative to the map's overall maximum, so a "strong /
        # moderate / weak" verdict is visible in the numbers not just in the
        # picture.
        db = 20.0 * np.log10(max(mag, 1e-30) / peak_max)
        peaks.append((i, peak_a, peak_r, peak_d, db))
    return peaks


def compare_targets(rd_map: np.ndarray, targets: list[dict]) -> tuple[int, str]:
    """Return (fail_count, printable_table)."""
    h = rd_map.shape[0]
    peaks = find_peaks(rd_map, targets)
    hdr = (
        "target       range_bin(gt/peak/dr)  doppler_bin(gt/peak/dr)  "
        "angle_idx(gt/peak/dr)  mag[dB]"
    )
    rule = "-" * len(hdr)
    body = [hdr, rule]
    fails = 0
    for i, ant, peak_r, peak_d, db in peaks:
        t = targets[i]
        expected_d_shifted = doppler_bin_to_shifted_index(int(t["doppler_bin"]), h)
        # Undo the fftshift so the report shows the ground-truth Doppler bin.
        peak_d_unshifted = (peak_d - h // 2) % h
        dr = peak_r - int(t["range_bin"])
        dd = peak_d_unshifted - int(t["doppler_bin"])
        da = ant - int(t["angle_idx"])
        pass_r = abs(dr) <= 1
        pass_d = abs(dd) <= 1
        pass_a = abs(da) <= 1
        if not (pass_r and pass_d and pass_a):
            fails += 1
        line = (
            f"{t['name']:12s} "
            f"{t['range_bin']:>3d}/{peak_r:>3d}/{dr:+d}         "
            f"{t['doppler_bin']:>3d}/{peak_d_unshifted:>3d}/{dd:+d}          "
            f"{t['angle_idx']:>3d}/{ant:>3d}/{da:+d}          "
            f"{db:+.1f}"
        )
        body.append(line)
        # Retain the shifted index in a comment so a reader who is squinting
        # at the plot can find the peak visually as well.
        body.append(f"    (shifted doppler bin in plot: {expected_d_shifted} / {peak_d})")
    return fails, "\n".join(body)


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------


def render_maps(rd_map: np.ndarray, targets: list[dict], out_dir: Path,
                scenario_name: str, seed: int) -> list[Path]:
    """One PNG per antenna, ground-truth markers overlaid.

    Returns the list of written paths so the caller can print them.
    """
    import matplotlib
    matplotlib.use("Agg")           # no display in WSL; write files only
    import matplotlib.pyplot as plt

    h, a, n = rd_map.shape
    written: list[Path] = []
    magnitudes = np.abs(rd_map)
    peak_max = float(np.max(magnitudes)) + 1e-30
    # dB below the map's own peak. -80 dB is a comfortable floor for a plot
    # of a synthetic scene with a 20 dB dynamic range.
    db = 20.0 * np.log10(magnitudes / peak_max + 1e-30)

    doppler_axis = np.arange(-h // 2, h - h // 2)   # after fftshift

    for ant in range(a):
        fig, ax = plt.subplots(figsize=(9, 5))
        im = ax.imshow(
            db[:, ant, :],
            aspect="auto",
            origin="lower",
            extent=(0, n, doppler_axis[0] - 0.5, doppler_axis[-1] + 0.5),
            cmap="viridis",
            vmin=-60.0,
            vmax=0.0,
        )
        ax.set_xlabel("range bin (fast-time FFT bin)")
        ax.set_ylabel("Doppler bin (slow-time FFT, fftshifted)")
        ax.set_title(
            f"Range-Doppler map (antenna {ant}) — scenario '{scenario_name}' "
            f"seed {seed}"
        )
        cbar = fig.colorbar(im, ax=ax)
        cbar.set_label("magnitude [dB below map peak]")

        # Overlay ground-truth markers on the antenna the target is centred on.
        for t in targets:
            expected_a = int(t["angle_idx"])
            k_r = int(t["range_bin"])
            k_d = int(t["doppler_bin"])
            # Doppler axis is fftshifted; use signed Doppler for the y-axis.
            k_d_signed = k_d if k_d < h // 2 else k_d - h
            marker = "o" if ant == expected_a else "x"
            colour = "white" if ant == expected_a else "grey"
            label = (f"{t['name']} ({k_r}, {k_d_signed}) "
                     f"ant {expected_a} snr {t['snr_db']:.0f}dB")
            ax.plot(
                k_r + 0.5, k_d_signed, marker=marker,
                markerfacecolor="none", markeredgecolor=colour,
                markersize=14, markeredgewidth=1.6, linestyle="none",
                label=label,
            )
        ax.legend(loc="upper right", fontsize=7)
        fig.tight_layout()
        path = out_dir / f"range_doppler_ant{ant}.png"
        fig.savefig(path, dpi=110)
        plt.close(fig)
        written.append(path)
    return written


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def run_scenario_flow(scenario_name: str, seed: int, config_path: Path,
                      out_dir: Path, phases: int, taps: int,
                      make_plots: bool) -> int:
    """Regenerate the IQ (via ``gen_target_iq``), then render the maps."""
    cfg = gen.load_config(config_path)
    scen = gen.build_scenario(scenario_name, cfg, seed)
    out_dir.mkdir(parents=True, exist_ok=True)
    iq_float = gen.synthesize_iq(scen, cfg)
    re_i, im_i = gen.quantise_iq(iq_float)
    iq_path = out_dir / "scenario.iq"
    json_path = out_dir / "scenario.json"
    iq_path.write_text(gen.render_iq(scen, cfg, re_i, im_i), encoding="utf-8",
                       newline="\n")
    json_path.write_text(gen.render_json(scen, cfg), encoding="utf-8",
                        newline="\n")
    return _render_from_iq_arrays(
        re_i, im_i, [t.to_dict() for t in scen.targets],
        scen.name, scen.seed, out_dir, phases, taps, make_plots,
    )


def _render_from_iq_arrays(re_i: np.ndarray, im_i: np.ndarray,
                           targets: list[dict], scen_name: str, seed: int,
                           out_dir: Path, phases: int, taps: int,
                           make_plots: bool) -> int:
    print(f"[range_doppler] PFB pass-through: phases={phases} taps={taps}")
    pfb_re, pfb_im = run_pfb(re_i, im_i, phases=phases, taps=taps)

    # Sanity: the identity PFB is a pass-through, so once the delay lines have
    # warmed up the outputs match the inputs. If they do not, the mapping in
    # ``run_pfb`` is wrong.
    warm = (taps - 1) * phases
    # Compare per-antenna, per-frame beyond the warmup.
    mismatch = int(np.sum(pfb_re[:, :, warm:] != re_i[:, :, warm:]))
    if mismatch:
        raise SystemExit(
            f"identity PFB pass-through gave {mismatch} sample mismatches "
            f"beyond the warmup ({warm} samples). Bug in run_pfb."
        )

    print("[range_doppler] per-frame FFT (float, reference chain)")
    spectra = frame_fft(pfb_re, pfb_im)

    print("[range_doppler] slow-time FFT per bin -> range-Doppler map")
    rd_map = range_doppler(spectra)

    fails, table = compare_targets(rd_map, targets)
    print(table)
    if make_plots:
        paths = render_maps(rd_map, targets, out_dir, scen_name, seed)
        for path in paths:
            print(f"[range_doppler]   wrote {path.relative_to(REPO_ROOT)}")
    if fails:
        print(f"[range_doppler] FAIL: {fails} target(s) off by more than 1 bin")
        return 1
    print(f"[range_doppler] PASS: every target within +/-1 bin of ground truth")
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--scenario", default=None,
                   help="named scenario to regenerate + visualise")
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--config", default="config/medium.json")
    p.add_argument("--iq", default=None,
                   help="path to a pre-generated scenario.iq file")
    p.add_argument("--json", default=None,
                   help="path to the matching scenario.json sidecar")
    p.add_argument("--out", default=None,
                   help="output directory (default: results/scenarios/<name>_seed<seed>)")
    p.add_argument("--pfb-phases", type=int, default=4,
                   help="polyphase branches (default 4, ident pass-through)")
    p.add_argument("--pfb-taps", type=int, default=8,
                   help="taps per phase (default 8)")
    p.add_argument("--no-plot", action="store_true",
                   help="skip matplotlib PNGs; print peak table only")
    args = p.parse_args()

    if args.iq or args.json:
        if not (args.iq and args.json):
            raise SystemExit("--iq and --json must be given together")
        iq_path = Path(args.iq)
        json_path = Path(args.json)
        if not iq_path.is_absolute():
            iq_path = REPO_ROOT / iq_path
        if not json_path.is_absolute():
            json_path = REPO_ROOT / json_path
        hdr, re_i, im_i = load_iq(iq_path)
        gt = load_ground_truth(json_path)
        out_dir = Path(args.out) if args.out else iq_path.parent
        if not out_dir.is_absolute():
            out_dir = REPO_ROOT / out_dir
        out_dir.mkdir(parents=True, exist_ok=True)
        return _render_from_iq_arrays(
            re_i, im_i, gt["targets"], gt["scenario"], gt["seed"], out_dir,
            args.pfb_phases, args.pfb_taps, not args.no_plot,
        )

    scen_name = args.scenario or "three_targets"
    cfg_path = Path(args.config)
    if not cfg_path.is_absolute():
        cfg_path = REPO_ROOT / cfg_path
    out_dir = Path(args.out) if args.out else gen.default_out_dir(scen_name, args.seed)
    if not out_dir.is_absolute():
        out_dir = REPO_ROOT / out_dir
    return run_scenario_flow(
        scen_name, args.seed, cfg_path, out_dir,
        args.pfb_phases, args.pfb_taps, not args.no_plot,
    )


if __name__ == "__main__":
    sys.exit(main())
