#!/usr/bin/env python3
"""Drive a SPEC 18 resource-calibration sweep and export one JSON record per point.

Governing spec: SPEC.md 18 (Resource-Calibration Phase), 15, 17, 23.

SPEC 18 requires representative kernels to be synthesized on their own before the
full design is built, swept over pipeline depth, register placement, multiplier
implementation and the rest, with DSP mapping, ALMs, Fmax, retiming and routing
delay MEASURED -- "Do not build the full design based solely on theoretical
DSP-count arithmetic." This script is the sweep driver. It is deliberately
kernel-agnostic: everything specific to a kernel lives in its parameter matrix
below and in its calibration project under ``quartus/calibration/``, so the nine
kernels that follow the complex multiplier add a matrix entry and a project, not
a script.

    python scripts/run_calibration.py --kernel cmult
    python scripts/run_calibration.py --kernel cmult --jobs 2
    python scripts/run_calibration.py --kernel cmult --points mult4_p3_round
    python scripts/run_calibration.py --kernel cmult --resume
    python scripts/run_calibration.py --kernel cmult --summary-only
    python scripts/run_calibration.py --kernel fft_stage      # SPEC 18 item 4
    python scripts/run_calibration.py --kernel fft_core       # SPEC 18 item 5

Windows side only, like every other Quartus entry point in this repository: this
host's WSL has Windows interop disabled, so quartus_sh.exe cannot be launched
from Linux (see the note at the top of the Makefile). ``make calibrate-cmult``
is the sanctioned invocation.

How a point is measured
-----------------------
Each point is one full compile of the kernel's calibration project with one set
of elaboration parameters:

    quartus_sh  -t quartus/scripts/calibrate.tcl compile <kernel> <point> ...
    quartus_sta -t quartus/scripts/calibrate.tcl sta     <kernel> <point>

The two phases exist because the data lives behind two different APIs; see the
header of calibrate.tcl. Each writes a flat key/value file, and this script
merges the pair into one JSON record, adds the derived comparisons, and appends
it to ``results/synthesis/calibration_<kernel>.json``.

Isolated working copies
-----------------------
With ``--jobs > 1`` each point compiles in its own copy of the calibration
project, because two Quartus compiles cannot share a project database. The copy
lives at ``results/calib_<kernel>_<point>/`` -- deliberately TWO levels below the
repository root, exactly like ``quartus/calibration/``, so that the ``../../rtl``
paths inside the copied qsf still resolve to the same source files. The copy is
byte-identical to the tracked project; only its location differs, and the
location is recorded in the point's record. Working copies are deleted after
each point unless ``--keep-work`` is given.

Everything under ``results/`` is generated and is never committed (PLAN.md
standing rule 3). What survives a sweep is the JSON record -- pasted into the
pull request -- and, compactly, the table in DECISIONS.md.

Runs on stdlib alone.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CALIB_DIR = REPO_ROOT / "quartus" / "calibration"
CALIB_TCL = REPO_ROOT / "quartus" / "scripts" / "calibrate.tcl"
RESULTS_DIR = REPO_ROOT / "results" / "synthesis"

SCHEMA_VERSION = 1

# Device totals, SPEC.md 2. Repeated from scripts/parse_quartus.py rather than
# imported so this script keeps working if that one is refactored; both are
# checked against the device string in every record.
DEVICE = "AGMF039R47B1E1VC"
TOTAL_ALMS = 1_305_600
TOTAL_DSP = 12_300
# M20K blocks on this device. Needed from issue #15 onward: the history sweep is
# the first kernel whose headline number is a memory count, and SPEC 2 states the
# M20K budget as a PERCENTAGE (55-80%), which a bare block count cannot be
# checked against. Same value as scripts/parse_quartus.py and
# quartus/scripts/common.tcl, repeated here for the reason given above.
TOTAL_M20K = 18_960


# ---------------------------------------------------------------------------
# Parameter matrices
# ---------------------------------------------------------------------------
# One entry per SPEC 18 kernel. `params` are the elaboration parameters passed
# to `set_parameter` on the calibration project's top-level entity; `label` is
# what the summary table prints.
#
# PRUNING (issue #9). The full complex-multiplier matrix is
#     {MULT4, MULT3} x PIPE_STAGES {2,3,4,5} x ROUND_OUT {1,0}  =  16 compiles,
# and one compile of this project on AGMF039R47B1E1VC measures at about nine
# minutes wall clock, so the full matrix is two and a half hours. It is pruned to
# ten, which is what the issue's wall-time budget allows:
#
#   * the pipeline axis is swept FULLY for both variants at ROUND_OUT=1 (8
#     points). That is the axis the downstream kernels have to choose from, and
#     it is the axis on which the two variants are being compared.
#   * the output-format axis is measured at ONE depth, PIPE_STAGES=4, for both
#     variants (2 points). Rounding is a fixed combinational network hanging off
#     the post-adder register; it does not interact with how many stages precede
#     it, so measuring it at every depth would buy four copies of one number.
#     PIPE_STAGES=4 is chosen because that is the depth at which the output
#     register exists, which is the configuration in which the rounding network
#     is actually a register-to-register path rather than part of a longer one.
#
# A point that is pruned is pruned in this table, in the open, with the reason
# beside it -- not by quietly not running it.
MATRICES: dict[str, dict] = {
    "cmult": {
        "description": "SPEC 6 complex multiplier: 4-mult vs 3-mult (Karatsuba)",
        "top": "cmult_wrap",
        "axes": {
            "variant": {"0": "MULT4", "1": "MULT3"},
            "pipe_stages": [2, 3, 4, 5],
            "round_out": [0, 1],
        },
        # Ordered so that the two variants ALTERNATE. A sweep stopped early then
        # still holds a like-for-like comparison at every depth it reached,
        # instead of holding every MULT4 point and no MULT3 point.
        "points": (
            [
                {
                    "id": f"{'mult3' if v else 'mult4'}_p{p}_round",
                    "label": f"{'MULT3' if v else 'MULT4'} stages={p} round",
                    "params": {
                        "VARIANT_SEL": v,
                        "PIPE_STAGES": p,
                        "ROUND_OUT": 1,
                    },
                }
                for p in (2, 3, 4, 5)
                for v in (0, 1)
            ]
            + [
                {
                    "id": f"{'mult3' if v else 'mult4'}_p4_full",
                    "label": f"{'MULT3' if v else 'MULT4'} stages=4 full",
                    "params": {
                        "VARIANT_SEL": v,
                        "PIPE_STAGES": 4,
                        "ROUND_OUT": 0,
                    },
                }
                for v in (0, 1)
            ]
        ),
    },

    # -----------------------------------------------------------------------
    # SPEC 18 item 2: one complex FIR lane (issue #10)
    # -----------------------------------------------------------------------
    # The question this kernel has to answer is which ACCUMULATION STRUCTURE
    # Agilex 7 and Quartus Pro 26.1 actually prefer for a 16-tap complex FIR:
    #
    #   TREE      a balanced adder tree in the fabric. 4 DSPs per tap for the
    #             multiplies, 15 fabric adders per output component.
    #   SYSTOLIC  a linear cascade, the shape a DSP chainout/chainin cascade
    #             wants -- the textbook answer -- at the cost of a delay line
    #             twice as deep (two stages per tap) and a coefficient-swap
    #             transition window TAPS-1 beats long.
    #
    # THREE POINTS, and the pruning is in the open:
    #
    #   * the two structures at the calibrated multiplier depth (PIPE_STAGES=4,
    #     issue #9's measured default). This is the comparison the issue exists
    #     for and it is the only axis swept at full width.
    #   * ONE pipeline-depth point, TREE at PIPE_STAGES=3. The multiplier's own
    #     depth axis was already swept exhaustively by the cmult sweep; what is
    #     not known is whether a lane whose multiplier is one stage shallower
    #     still clears the probe once an adder tree hangs off it. One point
    #     answers that; four would re-measure the cmult sweep through a lane.
    #   * the MULT3 axis is NOT swept here at all. Issue #9 measured it on the
    #     multiplier in isolation, where it is a pure arithmetic comparison; in
    #     a lane it would be sixteen copies of the same already-answered
    #     question. VARIANT_SEL stays 0 (MULT4) for every point.
    #
    # The delay-line storage axis is likewise not swept, and that is a finding
    # rather than an omission: a direct-form FIR taps its history at every stage,
    # a memory serves one read per cycle, and so a tapped delay line CANNOT be an
    # M20K at any depth (rtl/pfb/delay_line.sv). pfb_pkg resolves it to a shift
    # register and an explicit "MEM" is an elaboration error. What the records
    # below report is what Quartus did with that shift register -- ALM registers
    # or an MLAB -- which is the part that was genuinely unknown.
    "fir": {
        "description": "SPEC 7.1 complex FIR lane, 16 taps: adder tree vs "
                       "systolic cascade",
        "top": "fir_wrap",
        "axes": {
            "acc_style": {"0": "TREE", "1": "SYSTOLIC"},
            "mult_pipe_stages": [3, 4],
            "taps": [16],
        },
        "points": [
            {
                "id": "fir_t16_tree_p4",
                "label": "TAPS=16 TREE mult_pipe=4",
                "params": {"TAPS": 16, "MULT_PIPE_STAGES": 4,
                           "ACC_STYLE_SEL": 0, "VARIANT_SEL": 0},
            },
            {
                "id": "fir_t16_sys_p4",
                "label": "TAPS=16 SYSTOLIC mult_pipe=4",
                "params": {"TAPS": 16, "MULT_PIPE_STAGES": 4,
                           "ACC_STYLE_SEL": 1, "VARIANT_SEL": 0},
            },
            {
                "id": "fir_t16_tree_p3",
                "label": "TAPS=16 TREE mult_pipe=3",
                "params": {"TAPS": 16, "MULT_PIPE_STAGES": 3,
                           "ACC_STYLE_SEL": 0, "VARIANT_SEL": 0},
            },
        ],
    },

    # -----------------------------------------------------------------------
    # SPEC 18 item 4: "One FFT stage" (issue #11).
    #
    # One rtl/fft/fft_radix22_stage.sv — two delay-feedback butterflies, a
    # twiddle ROM and a complex_multiplier — at the geometry of the FIRST group
    # of the shipped 64-point / 2-samples-per-cycle lane: N_LANE = 5, S = 0, so
    # the delay lines are 16 and 8 words and the ROM has 32 entries. That is the
    # group with the largest memories in the shipped configuration, which is the
    # one whose mapping the calibration has to answer.
    #
    # Two axes, three points:
    #   * the twiddle multiplier's pipeline depth, 3 against 4. Issue #9
    #     measured 4 as the depth at which the multiplier alone clears the
    #     600 MHz probe; whether that still holds with a memory feeding it is a
    #     different question and is the reason this axis is swept here again.
    #   * the delay-feedback memory geometry, AUTO against forced MLAB. A 16-word
    #     by 32-bit line is exactly the size where the choice is not obvious, and
    #     SPEC 18 names "memory geometry" as a thing to sweep rather than assume.
    # -----------------------------------------------------------------------
    "fft_stage": {
        "description": "SPEC 7.2 radix-2^2 SDF stage: butterflies, delay "
                       "feedback, twiddle ROM and complex multiplier",
        "top": "fft_stage_wrap",
        "axes": {
            "tw_pipe": [3, 4],
            "mem_sel": {"0": "AUTO", "2": "MLAB"},
        },
        "points": [
            {
                "id": "stage_p3_auto",
                "label": "stage TW_PIPE=3 mem=AUTO",
                "params": {"TW_PIPE": 3, "MEM_SEL": 0, "TW_SEL": 0},
            },
            {
                "id": "stage_p4_auto",
                "label": "stage TW_PIPE=4 mem=AUTO",
                "params": {"TW_PIPE": 4, "MEM_SEL": 0, "TW_SEL": 0},
            },
            {
                "id": "stage_p4_mlab",
                "label": "stage TW_PIPE=4 mem=MLAB",
                "params": {"TW_PIPE": 4, "MEM_SEL": 2, "TW_SEL": 2},
            },
        ],
    },

    # -----------------------------------------------------------------------
    # SPEC 18 item 3: one eight-lane polyphase FIR bank (issue #10)
    # -----------------------------------------------------------------------
    # What this point prices that the lane point cannot:
    #
    #   * whether eight lanes' DSPs still cascade, or whether the Fitter runs
    #     out of column-adjacent blocks and falls back to fabric adders,
    #   * what the 8 x 16 x 2 x 32-bit coefficient store maps to and what its
    #     4096-bit output mux costs,
    #   * the per-BLOCK costs that do not scale with lanes: the credit gate, the
    #     metadata alignment path and the output elastic buffer,
    #   * whether the critical path is still inside a lane at eight-lane fanout.
    #     run_calibration records the critical path's hierarchy for every point
    #     and flags one whose register-to-register path does not touch u_kernel.
    #
    # TWO points, the same two structures. The pipeline axis is not repeated
    # here: it was answered at the lane, and an eight-lane compile is the most
    # expensive thing in this sweep.
    "pfb8": {
        "description": "SPEC 7.1 polyphase FIR bank, 8 phases x 16 taps",
        "top": "pfb8_wrap",
        "axes": {
            "acc_style": {"0": "TREE", "1": "SYSTOLIC"},
            "phases": [8],
            "taps": [16],
        },
        "points": [
            {
                "id": "pfb8_t16_tree",
                "label": "8 phases x 16 taps TREE",
                "params": {"PHASES": 8, "TAPS": 16, "MULT_PIPE_STAGES": 4,
                           "ACC_STYLE_SEL": 0},
            },
            {
                "id": "pfb8_t16_sys",
                "label": "8 phases x 16 taps SYSTOLIC",
                "params": {"PHASES": 8, "TAPS": 16, "MULT_PIPE_STAGES": 4,
                           "ACC_STYLE_SEL": 1},
            },
        ],
    },

    # -----------------------------------------------------------------------
    # SPEC 18 item 5: "One full FFT" (issue #11).
    #
    # rtl/fft/streaming_fft.sv at the shipped 64-point / 2-samples-per-cycle
    # configuration: the transform, the elastic boundary, the frame tracking,
    # the bit-reversal reorder and the credit-backed output FIFO.
    #
    # Three points, chosen so that each answers one question the design took a
    # position on and has to be able to defend:
    #   * TW_PIPE 3 against 4, the same axis as the stage sweep, now with six
    #     multipliers and the whole control network around them;
    #   * REORDER on against off, which prices the bit-reversal buffer and the
    #     one frame of latency it costs. Issue #15's corner turn can absorb the
    #     permutation for nothing, and this is the number that decides whether it
    #     should.
    # -----------------------------------------------------------------------
    "fft_core": {
        "description": "SPEC 7.2 full 64-point / 2-SPC streaming FFT block",
        "top": "fft_core_wrap",
        "axes": {
            "tw_pipe": [3, 4],
            "reorder": [0, 1],
        },
        "points": [
            {
                "id": "core64_p4_reorder",
                "label": "64-pt TW_PIPE=4 reorder",
                "params": {"TW_PIPE": 4, "REORDER": 1, "MEM_SEL": 0},
            },
            {
                "id": "core64_p3_reorder",
                "label": "64-pt TW_PIPE=3 reorder",
                "params": {"TW_PIPE": 3, "REORDER": 1, "MEM_SEL": 0},
            },
            {
                "id": "core64_p4_bitrev",
                "label": "64-pt TW_PIPE=4 no reorder",
                "params": {"TW_PIPE": 4, "REORDER": 0, "MEM_SEL": 0},
            },
            # The seventh point, and the only one added AFTER the other six had
            # been measured: the stage sweep found that the tool places a 16-word
            # delay feedback in an M20K and that the M20K's own internal path is
            # then the critical path of the whole block. fft_pkg's "DEFAULT"
            # placement rule is the answer to that, and this point measures the
            # answer at block level rather than inferring it from the stage.
            {
                "id": "core64_p4_default",
                "label": "64-pt TW_PIPE=4 reorder DEFAULT mem",
                "params": {"TW_PIPE": 4, "REORDER": 1, "MEM_SEL": 4},
            },
        ],
    },

    # -----------------------------------------------------------------------
    # SPEC 18 item 6: "One beamforming dot product" (issue #12).
    #
    # rtl/beamformer/bf_dot.sv at N_ANT = 16, the SPEC 7.5 nominal antenna
    # count. This is the design's DOMINANT DSP CONSUMER and the atom the
    # full-scale matrix is BIN_PAR x BEAM_PAR copies of, so the SPEC 18
    # projection — how many DSP blocks a 16-beam by 8-bin by 16-antenna matrix
    # costs — is this point's DSP count times that product. Measuring it rather
    # than multiplying the complex-multiplier point by sixteen is the whole
    # difference between calibration and arithmetic: issue #10 found that a
    # systolic FIR buys no DSP cascade because the complex multiply has already
    # consumed the block's adder, and whether a 37-bit accumulation tree hanging
    # off sixteen multipliers changes the mapping is exactly that kind of
    # question.
    #
    # ONE AXIS, TWO POINTS: ADD_REG_EVERY, 1 against 2. A register after every
    # tree level (four stages at 16 antennas) against a register after every
    # second level (two stages, two 37-bit adders in series). The two produce the
    # SAME INTEGER — there is no saturation inside the tree, so addition is
    # associative — which is what makes this a pure cost comparison, and
    # sim/verilator/tops/beamformer_top.sv proves the equality in the same run.
    #
    # NOT SWEPT, and in the open:
    #   * the multiplier pipeline depth. Issue #9 swept it exhaustively in
    #     isolation and issue #10 confirmed at the FIR lane that the calibrated
    #     default of 4 carries into an accumulating kernel at no cost. Repeating
    #     it here would be sixteen copies of an answered question.
    #   * MULT3. Same reason, and issue #9's answer was unambiguous on this
    #     device: one more DSP block placed, 29-35 more ALMs, slower at every
    #     depth.
    #   * N_ANT. 16 is the SPEC 7.5 maximum and the only value the full-scale
    #     projection needs; a smaller dot product is a smaller multiple of the
    #     same atom.
    # -----------------------------------------------------------------------
    "bf_dot": {
        "description": "SPEC 7.5 beamforming dot product, 16 antennas: "
                       "adder-tree pipelining stride",
        "top": "bf_dot_wrap",
        "axes": {
            "add_reg_every": [1, 2],
            "n_ant": [16],
        },
        "points": [
            {
                "id": "bfdot_a16_reg1",
                "label": "N_ANT=16 ADD_REG_EVERY=1",
                "params": {"N_ANT": 16, "MULT_PIPE_STAGES": 4,
                           "ADD_REG_EVERY": 1, "VARIANT_SEL": 0},
            },
            {
                "id": "bfdot_a16_reg2",
                "label": "N_ANT=16 ADD_REG_EVERY=2",
                "params": {"N_ANT": 16, "MULT_PIPE_STAGES": 4,
                           "ADD_REG_EVERY": 2, "VARIANT_SEL": 0},
            },
        ],
    },

    # -----------------------------------------------------------------------
    # SPEC 18 item 7: "One complete beam" (issue #12).
    #
    # rtl/beamformer/beamformer.sv as a matrix slice: BIN_PAR = 2 bins per beat
    # x BEAM_PAR = 4 beams per cycle over N_ANT = 16 antennas out of N_BEAMS = 8.
    # That is 8 dot products of 16 antennas — the same arithmetic as one complete
    # beam evaluated at 8 bins per cycle — but in the SHAPE the design actually
    # builds, which one isolated beam row would not price:
    #
    #   * whether BIN_PAR dot products sharing one antenna vector and BEAM_PAR
    #     sharing one weight row still map two multiplies per DSP block at width,
    #   * what the 8 x 16 x 2 x 32-bit weight store maps to and what the
    #     beam-group output mux over it costs,
    #   * the per-BLOCK costs that do not scale with dot products: the credit
    #     gate, the hold register, the metadata path, the output elastic buffer,
    #   * whether the critical path is still inside the arithmetic at this
    #     fanout, or has moved into the weight mux or the frame-boundary swap
    #     cone — issue #10 found that cone on the critical path of a FIR lane.
    #
    # BEAM_MUX = N_BEAMS / BEAM_PAR = 2, so this point also prices the time
    # multiplex machinery SPEC 7.5 requires to be visible. A point at
    # BEAM_PAR = N_BEAMS would optimise the mux away and report a matrix the
    # full-scale design will not build.
    #
    # TWO POINTS, the same axis as the dot product, so the block-level answer to
    # "does halving the tree registers pay" can be compared against the
    # atom-level one rather than assumed to carry.
    # -----------------------------------------------------------------------
    "bf_matrix": {
        "description": "SPEC 7.5 beamforming matrix slice, 2 bins x 4 beams "
                       "x 16 antennas out of 8 beams",
        "top": "bf_matrix_wrap",
        "axes": {
            "add_reg_every": [1, 2],
            "bin_par": [2],
            "beam_par": [4],
        },
        "points": [
            {
                "id": "bfmat_b2x4a16_reg1",
                "label": "2 bins x 4 beams x 16 ant ADD_REG_EVERY=1",
                "params": {"N_ANT": 16, "N_BEAMS": 8, "BIN_PAR": 2,
                           "BEAM_PAR": 4, "MULT_PIPE_STAGES": 4,
                           "ADD_REG_EVERY": 1, "VARIANT_SEL": 0},
            },
            {
                "id": "bfmat_b2x4a16_reg2",
                "label": "2 bins x 4 beams x 16 ant ADD_REG_EVERY=2",
                "params": {"N_ANT": 16, "N_BEAMS": 8, "BIN_PAR": 2,
                           "BEAM_PAR": 4, "MULT_PIPE_STAGES": 4,
                           "ADD_REG_EVERY": 2, "VARIANT_SEL": 0},
            },
        ],
    },

    # -----------------------------------------------------------------------
    # SPEC 18 item 8: "One M20K history bank" (issue #15).
    #
    # THE MEMORY GEOMETRY EXPERIMENT. All four points hold the SAME LOGICAL
    # CAPACITY, 16384 bits, so the aspect ratios are directly comparable and the
    # only thing varying between the first three is the SHAPE of the request.
    # That is the whole design of the experiment: an M20K holds 20480 bits, but
    # only at the widths its modes support, so "how many blocks does 16 kbit
    # cost" has a different answer at 512x32 than at 1Kx16 or 256x64, and the
    # answer decides the full-scale corner-turn M20K budget that SPEC 2 wants
    # held between 55% and 80%.
    #
    #   512x32   one complex sample per word — the history bank's natural shape,
    #            and the one the rest of the design would use by default.
    #   1024x16  half a sample per word. Deeper and narrower: does Quartus still
    #            spend one block, or does the narrower word let it pack better?
    #   256x64   two samples per word. Wider than any single M20K mode on this
    #            device, so this point measures what WIDTH STITCHING costs — the
    #            case where the tool must gang blocks side by side.
    #
    # The fourth point is the REGISTER-PLACEMENT axis, not a geometry: 512x32
    # again, with the bank's input and output registers removed. SPEC 18 names
    # "input and output register choices" as an axis and SPEC 23 requires
    # registers around M20Ks, so what this point prices is what that requirement
    # buys and what it costs — whether the registers are absorbed into the hard
    # block for free (in which case IN_REG/OUT_REG=1 is free and the no-reg point
    # is strictly worse) or paid for in ALM registers and a longer fabric path.
    # calibrate.tcl's unregistered_ram_paths and the reg2reg endpoint names are
    # the evidence; a `ram_block*~reg*` endpoint means absorbed.
    #
    # MEM_SEL is forced to 1 (m20k) at every point. The comparison is between
    # geometries inside one storage style; letting the tool choose would mean
    # comparing a geometry against a different decision.
    # -----------------------------------------------------------------------
    "history_bank": {
        "description": "SPEC 7.3 history bank: one memory at fixed 16384-bit "
                       "capacity across three aspect ratios, plus register "
                       "placement",
        "top": "history_bank_wrap",
        "axes": {
            "geometry": {
                "512x32": "512 words x 32 bits, one complex sample per word",
                "1024x16": "1024 words x 16 bits, half a sample per word",
                "256x64": "256 words x 64 bits, two samples per word",
            },
            "regs": [0, 1],
            "mem_sel": {"1": "M20K"},
        },
        "points": [
            {
                "id": "bank_512x32",
                "label": "512 x 32 (one complex sample/word)",
                "params": {"WIDTH": 32, "DEPTH": 512, "IN_REG": 1,
                           "OUT_REG": 1, "MEM_SEL": 1},
            },
            {
                "id": "bank_1024x16",
                "label": "1K x 16 (half a sample/word)",
                "params": {"WIDTH": 16, "DEPTH": 1024, "IN_REG": 1,
                           "OUT_REG": 1, "MEM_SEL": 1},
            },
            {
                "id": "bank_256x64",
                "label": "256 x 64 (two samples/word)",
                "params": {"WIDTH": 64, "DEPTH": 256, "IN_REG": 1,
                           "OUT_REG": 1, "MEM_SEL": 1},
            },
            {
                "id": "bank_512x32_noreg",
                "label": "512 x 32, no input/output regs",
                "params": {"WIDTH": 32, "DEPTH": 512, "IN_REG": 0,
                           "OUT_REG": 0, "MEM_SEL": 1},
            },
        ],
    },

    # -----------------------------------------------------------------------
    # SPEC 18 item 8, the block: a slice of the SPEC 7.3 corner turn (issue #15).
    #
    # The bank points above price the ATOM. These two price THE BLOCK'S FIXED
    # COST: the per-antenna write sequencers, the frame barrier, the rotation and
    # readable-set arithmetic, the registered read fanout, the three CDC
    # crossings and the counters — everything that exists once no matter how many
    # banks there are. The projection the pull request needs is then per-bank cost
    # times a count, plus this fixed number, which is arithmetic rather than
    # another compile.
    #
    # Both points are FOUR BANKS at 64 bins and 4 frames, arrived at two
    # different ways, and that is deliberate: 4 antennas x 1 lane and 2 antennas
    # x 2 lanes instantiate the same amount of memory but a different amount of
    # control, so the difference between the two records isolates what LANES
    # costs from what N_ANT costs. The second point also runs bit-reversed input,
    # which prices the address permutation the FFT would otherwise pay a reorder
    # buffer for (see fft_core's REORDER axis, which is the other half of that
    # trade).
    # -----------------------------------------------------------------------
    "history_core": {
        "description": "SPEC 7.3 corner-turn slice: four history banks with the "
                       "write sequencers, frame barrier, read fanout and CDC "
                       "crossings around them",
        "top": "history_core_wrap",
        "axes": {
            "shape": {"4x1": "4 antennas x 1 lane", "2x2": "2 antennas x 2 lanes"},
            "bit_reversed": [0, 1],
            "fft_size": [64],
            "frames_max": [4],
        },
        "points": [
            {
                "id": "core_a4_l1",
                "label": "4 antennas x 1 lane = 4 banks, 64 bins, 4 frames",
                "params": {"N_ANT": 4, "FFT_SIZE": 64, "LANES": 1,
                           "FRAMES_MAX": 4, "SAMPLE_W": 16,
                           "BIT_REVERSED": 0, "MEM_SEL": 1},
            },
            {
                "id": "core_a2_l2",
                "label": "2 antennas x 2 lanes = 4 banks, 64 bins, 4 frames, "
                         "bit-reversed",
                "params": {"N_ANT": 2, "FFT_SIZE": 64, "LANES": 2,
                           "FRAMES_MAX": 4, "SAMPLE_W": 16,
                           "BIT_REVERSED": 1, "MEM_SEL": 1},
            },
        ],
    },

    # -----------------------------------------------------------------------
    # SPEC 7.4, the mandated architecture comparison (issue #16).
    #
    # SPEC 7.4: "Compare at least two architectures: 1. Direct crossbar.
    # 2. Multistage or Clos-style pipelined network. Record area, congestion,
    # latency, and Fmax for both."
    #
    # THIS MATRIX IS THAT COMPARISON, and it measures the ROUTING FABRIC ALONE.
    # Everything else in rtl/align/align_net.sv — the scheduler, the ingress
    # decode, the reassembly buffer, the detector, the counters — is
    # byte-for-byte identical in both builds, and the reassembly buffer alone is
    # GROUPS x BIN_PAR x VEC_W flip-flops, which at the wide point is several
    # times either fabric. Sweeping the whole block twice would report two
    # numbers differing by a few percent, and the few percent would BE the
    # answer. The `align_net` matrix below prices that common part separately,
    # once per architecture, which is what the full-scale projection needs.
    #
    # FOUR POINTS: two architectures at two widths, and the widths are chosen so
    # the pair is LATENCY-MATCHED at each, which is the condition under which a
    # resource comparison means anything:
    #
    #     N = 4:  omega = log2(4) = 2 stages;  crossbar MUX_STAGES = 1 -> 2
    #     N = 8:  omega = log2(8) = 3 stages;  crossbar MUX_STAGES = 2 -> 3
    #
    # rtl/align/align_switch.sv checks the match at elaboration and prints a NOTE
    # if a caller ever breaks it, so a mismatched point cannot reach a table
    # unnoticed.
    #
    # The narrow point is 4 antennas and the wide one is 16 — the SPEC 7.5
    # maximum — so the wide point routes the full-scale 512-bit antenna vector
    # plus its 54-bit identity. That width is reachable here and NOT in the
    # block-level matrix, and the reason is in the align_net note below.
    #
    # NOT SWEPT, in the open: the crossbar's own MUX_STAGES axis (1 against 2 at
    # one width), which would price registers against LUT depth INSIDE one
    # architecture. It is a real question and it is deliberately left, because it
    # is a second-order refinement of whichever architecture wins and this
    # issue's budget is the head-to-head. GROUPS is not an axis either: it does
    # not appear in the fabric at all, only in the block.
    # -----------------------------------------------------------------------
    "align_sw": {
        "description": "SPEC 7.4 alignment routing fabric: direct registered "
                       "crossbar against a multistage omega network, at two "
                       "widths, latency-matched at both",
        "top": "align_sw_wrap",
        "axes": {
            "architecture": {"0": "direct crossbar", "1": "multistage omega"},
            "width": [4, 8],
            "n_ant": [4, 16],
            "mux_stages": [1, 2],
        },
        # Ordered so the two architectures ALTERNATE. A sweep stopped early then
        # still holds a like-for-like comparison at every width it reached,
        # instead of holding both crossbar points and no omega point.
        "points": [
            {
                "id": "sw_xbar_n4",
                "label": "crossbar, 4 lanes x 4 antennas (182-bit word)",
                "params": {"N_ANT": 4, "FFT_SIZE": 1024, "LANES": 8,
                           "FRAMES_MAX": 512, "SAMPLE_W": 16, "BIN_PAR": 4,
                           "GROUPS": 8, "NET_SEL": 0, "MUX_STAGES": 1},
            },
            {
                "id": "sw_clos_n4",
                "label": "omega, 4 lanes x 4 antennas (182-bit word)",
                "params": {"N_ANT": 4, "FFT_SIZE": 1024, "LANES": 8,
                           "FRAMES_MAX": 512, "SAMPLE_W": 16, "BIN_PAR": 4,
                           "GROUPS": 8, "NET_SEL": 1, "MUX_STAGES": 1},
            },
            {
                "id": "sw_xbar_n8",
                "label": "crossbar, 8 lanes x 16 antennas (566-bit word)",
                "params": {"N_ANT": 16, "FFT_SIZE": 1024, "LANES": 8,
                           "FRAMES_MAX": 512, "SAMPLE_W": 16, "BIN_PAR": 8,
                           "GROUPS": 8, "NET_SEL": 0, "MUX_STAGES": 2},
            },
            {
                "id": "sw_clos_n8",
                "label": "omega, 8 lanes x 16 antennas (566-bit word)",
                "params": {"N_ANT": 16, "FFT_SIZE": 1024, "LANES": 8,
                           "FRAMES_MAX": 512, "SAMPLE_W": 16, "BIN_PAR": 8,
                           "GROUPS": 8, "NET_SEL": 1, "MUX_STAGES": 2},
            },
        ],
    },

    # -----------------------------------------------------------------------
    # SPEC 7.4, the block around the fabric (issue #16).
    #
    # TWO POINTS, one per architecture, at 8 bins x 4 antennas. What they price
    # is exactly what the fabric points exclude: the GROUPS x BIN_PAR x VEC_W
    # reassembly buffer, the BIN_PAR identity comparators against it, the
    # scheduler's rotating bin arithmetic and its request holds, the five
    # saturating counters and the output elastic buffer. Both architectures
    # rather than one because the Fitter is allowed to place shared logic
    # differently around different neighbours, and "the fixed cost is
    # context-free" is a claim worth checking rather than assuming — the same
    # discipline, for the same reason, as history_core's two points.
    #
    # 8 x 4 x 32 IS 1024 BITS, WHICH IS THE POINT. The output beat must fit
    # stream_pkg::STREAM_MAX_DATA_W, raised to 1024 by issue #12 and deliberately
    # not to 4096. That bound is what stops this matrix from using the 16
    # antennas the fabric matrix does, and raising it belongs to issue #20 with
    # these measurements in hand: it multiplies the working type of every
    # stream_pack/stream_unpack in the design by four, for a geometry nothing yet
    # verifies. The full-scale block figure is this fixed cost plus the
    # full-scale fabric cost the align_sw matrix measures — arithmetic rather
    # than another compile.
    # -----------------------------------------------------------------------
    "align_net": {
        "description": "SPEC 7.4 alignment network, whole block: reassembly "
                       "buffer, detector, scheduler and counters around each "
                       "of the two routing fabrics",
        "top": "align_net_wrap",
        "axes": {
            "architecture": {"0": "direct crossbar", "1": "multistage omega"},
            "bin_par": [8],
            "n_ant": [4],
            "groups": [8],
        },
        "points": [
            {
                "id": "net_xbar",
                "label": "whole block, crossbar, 8 bins x 4 antennas",
                "params": {"N_ANT": 4, "FFT_SIZE": 1024, "LANES": 8,
                           "FRAMES_MAX": 512, "SAMPLE_W": 16, "BIN_PAR": 8,
                           "GROUPS": 8, "NET_SEL": 0, "MUX_STAGES": 2},
            },
            {
                "id": "net_clos",
                "label": "whole block, omega, 8 bins x 4 antennas",
                "params": {"N_ANT": 4, "FFT_SIZE": 1024, "LANES": 8,
                           "FRAMES_MAX": 512, "SAMPLE_W": 16, "BIN_PAR": 8,
                           "GROUPS": 8, "NET_SEL": 1, "MUX_STAGES": 2},
            },
        ],
    },
    # -----------------------------------------------------------------------
    # SPEC 18 item 9: "one packet-switch stage" (issue #18).
    #
    # rtl/packet/pkt_switch_stage.sv at the SPEC 7.8 NOMINAL SCALE: radix 4,
    # four virtual channels, 512-bit flits. This is the block SPEC 7.8 says "is
    # expected to create substantial ALM and routing pressure", and the switch is
    # where the pressure is: sixteen 517-bit buffers, a 4x4 crossbar 517 bits
    # wide, twenty arbiters and thirty-two credit counters, none of which exists
    # anywhere else in the design.
    #
    # THE AXIS: OUT_PIPE, 0 against 1 — one registered hop between the switch
    # allocator's grant and the outgoing link against two. The two produce
    # IDENTICAL traffic (the extra stage is a pure delay on a credit-controlled
    # link and the credit accounting already reserved the slot), which is what
    # makes it a pure cost comparison. The question is whether a second register
    # buys Fmax at 517-bit flits or whether HyperFlex retiming already recovers
    # it from the first.
    #
    # NOT SWEPT, and in the open:
    #   * PACKET_W. The point of measuring at 512 is that buffer storage,
    #     crossbar width and routing scale with it while arbitration and credit
    #     logic do not; a second width would be priced by the same argument the
    #     projection already makes, and the ports are sized for one geometry so
    #     a different width needs its own project.
    #   * VC_DEPTH. It moves storage linearly and arbitration not at all. What a
    #     later revision needs from it is the high-water mark the simulation
    #     reports, not a fitter run.
    #   * RADIX. 4 is the topology decision (packet_pkg section 5); a different
    #     radix is a different network, not a different point.
    # -----------------------------------------------------------------------
    "pkt_switch": {
        "description": "SPEC 7.8 packet-switch stage, 4x4 x 4 VC x 512-bit "
                       "flits: output pipelining depth",
        "top": "pkt_switch_wrap",
        "axes": {
            "out_pipe": [0, 1],
        },
        "points": [
            {
                "id": "pktsw_r4v4_w512_p0",
                "label": "radix 4, 4 VC, 512-bit, OUT_PIPE=0",
                "params": {"PACKET_W": 512, "N_VC": 4, "RADIX": 4,
                           "VC_DEPTH": 4, "OUT_PIPE": 0, "DEST_DIGIT": 1},
            },
            {
                "id": "pktsw_r4v4_w512_p1",
                "label": "radix 4, 4 VC, 512-bit, OUT_PIPE=1",
                "params": {"PACKET_W": 512, "N_VC": 4, "RADIX": 4,
                           "VC_DEPTH": 4, "OUT_PIPE": 1, "DEST_DIGIT": 1},
            },
        ],
    },

    # -----------------------------------------------------------------------
    # SPEC 18 item 9, second point: a TWO-STAGE fabric slice (issue #18).
    #
    # Two switch stages in series with the credit loop between them closed
    # locally, at the same 512-bit flit width. The difference between this and
    # pkt_switch is the cost of a HOP — the inter-stage flit bus and the credit
    # return path — which is the term the full-scale projection cannot get from
    # a single-stage measurement. See quartus/calibration/pkt_slice_wrap.sv for
    # what this point deliberately does NOT price (the butterfly's shuffle
    # permutation, which is placement rather than logic).
    #
    # ONE POINT. The OUT_PIPE axis was answered by pkt_switch above and the hop
    # cost is what is being isolated here; sweeping the same axis twice would
    # buy a copy of a number.
    # -----------------------------------------------------------------------
    "pkt_slice": {
        "description": "SPEC 7.8 two-stage packet-fabric slice, 4 ports x 4 VC "
                       "x 512-bit flits",
        "top": "pkt_slice_wrap",
        "axes": {
            "stages": [2],
        },
        "points": [
            {
                "id": "pktslice_2stage_w512",
                "label": "2 stages x radix 4 x 4 VC, 512-bit",
                "params": {"PACKET_W": 512, "N_VC": 4, "RADIX": 4,
                           "VC_DEPTH": 4, "OUT_PIPE": 0},
            },
        ],
    },


}

# Per-kernel note recorded in the exported JSON, explaining what was left out of
# the matrix and why. A point that is pruned is pruned in the open.
PRUNING_NOTES: dict[str, str] = {
    "cmult": (
        "Full matrix is 2 variants x 4 pipeline depths x 2 output formats = 16 "
        "compiles; one compile measures at about nine minutes on this host. "
        "Pruned to 10: the pipeline axis is swept fully for both variants at "
        "ROUND_OUT=1, and the output-format axis is measured at PIPE_STAGES=4 "
        "only, because the rounding network is a fixed combinational block on "
        "the post-adder register and does not interact with the number of "
        "stages ahead of it. See scripts/run_calibration.py."),
    "fir": (
        "Three points. The accumulation structure is swept at full width at the "
        "calibrated multiplier depth, because that is the comparison the kernel "
        "exists to make; the pipeline-depth axis contributes ONE point (TREE at "
        "MULT_PIPE_STAGES=3), because the multiplier's own depth axis was swept "
        "exhaustively by the cmult sweep and what is unknown is only whether a "
        "shallower multiplier still clears the probe with an adder tree hanging "
        "off it. MULT3 is not swept: issue #9 measured it in isolation, and in a "
        "lane it would be sixteen copies of an answered question. The delay-line "
        "storage axis is not swept because a tapped delay line cannot be an M20K "
        "at any depth. See scripts/run_calibration.py."),
    "pfb8": (
        "Two points: the two accumulation structures at the calibrated "
        "multiplier depth. The pipeline-depth axis is not repeated here — it was "
        "answered at the lane, and an eight-lane compile is the most expensive "
        "thing in this sweep. See scripts/run_calibration.py."),
    "fft_stage": (
        "Three points of a 2 x 4 (pipeline depth x memory style) matrix. The "
        "memory axis is measured at one pipeline depth only: the delay-feedback "
        "placement is a property of the memory's shape, not of how many "
        "registers follow the multiplier. M20K and LOGIC are not swept because "
        "a 16-word by 32-bit line is far below an M20K's useful geometry and "
        "far above what should be spent on ALM registers; AUTO against MLAB is "
        "the question that is actually open. See scripts/run_calibration.py."),
    "pkt_switch": (
        "Two points on one axis: the switch stage's output pipelining depth, "
        "OUT_PIPE 0 against 1, at the SPEC 7.8 nominal radix 4, four virtual "
        "channels and 512-bit flits. PACKET_W is not an axis because the whole "
        "point is to measure at full width rather than to extrapolate from the "
        "tiny 64, and the wrapper's ports are sized for one geometry. VC_DEPTH "
        "is not an axis because it moves storage linearly and arbitration not "
        "at all; the number a later revision needs from it is the high-water "
        "mark the simulation reports. RADIX is not an axis because a different "
        "radix is a different network. STORAGE was pruned on the same grounds "
        "as VC_DEPTH and the measured data says that was the wrong axis to "
        "prune: 42 788 of the switch's registers are buffer storage in ALMs, "
        "which is the largest single term in the full-scale projection, so "
        "MLAB against regs is the sweep issue #20 should run first. See "
        "scripts/run_calibration.py and DECISIONS.md (issue #18)."),
    "pkt_slice": (
        "One point. It exists to isolate the per-HOP cost — the inter-stage "
        "flit bus and the credit return path — which a single-stage compile "
        "cannot show; the output-pipelining axis was answered by the pkt_switch "
        "sweep and repeating it here would buy a copy of a number. The "
        "butterfly's shuffle permutation is deliberately not reproduced on a "
        "four-port slice: it is a fixed renaming of point-to-point wires whose "
        "cost is placement rather than logic, and a permutation of four "
        "elements is not the sixteen-element one the real fabric routes. See "
        "quartus/calibration/pkt_slice_wrap.sv. "),
    "bf_dot": (
        "Two points on one axis: the adder-tree pipelining stride, a register "
        "per level against a register per two levels, at the SPEC 7.5 nominal "
        "16 antennas. The multiplier pipeline depth and the MULT3 variant are "
        "not swept because issue #9 answered both exhaustively in isolation and "
        "issue #10 confirmed the depth answer carries into an accumulating "
        "kernel; repeating either here would be sixteen copies of an answered "
        "question. N_ANT is not an axis because 16 is the SPEC 7.5 maximum and "
        "the only value the full-scale DSP projection needs. See "
        "scripts/run_calibration.py."),
    "bf_matrix": (
        "Two points, the same adder-tree axis as the dot product, so the "
        "block-level answer can be compared against the atom-level one rather "
        "than assumed to carry. BIN_PAR and BEAM_PAR are not axes: the slice is "
        "chosen at 2 bins x 4 beams because that is 8 dot products, the same "
        "arithmetic as one complete beam at the full-scale 8 bins per cycle, "
        "and because BEAM_PAR < N_BEAMS is what keeps the time-multiplex "
        "machinery in the measured design. A wider slice would be a multiple of "
        "this one plus the same fixed block cost. See "
        "scripts/run_calibration.py."),
    "history_bank": (
        "Four points, all at the same 16384-bit logical capacity so the three "
        "aspect ratios are directly comparable, plus one register-placement "
        "variant at 512x32. Left out, in the open: TRUE DUAL PORT banks, which "
        "are not a different geometry but a different correctness argument — a "
        "second write port changes what the corner turn has to prove about "
        "read/write collisions, and that belongs to the verification, not to a "
        "resource sweep. MLAB and register storage at these depths, because a "
        "512-word by 32-bit bank in MLABs is known in advance to be absurd and "
        "measuring it would buy a large number nobody will use; the question "
        "that IS open, where the MLAB/M20K crossover falls, belongs to a "
        "shallower sweep whose depths straddle it. And the full-scale "
        "FRAMES_MAX=512 geometry, because it is hours of Fitter time for a "
        "number that is per-bank cost times a count — which is what these four "
        "points measure. See scripts/run_calibration.py."),
    "history_core": (
        "Two points, both four banks at 64 bins and 4 frames, reached as 4 "
        "antennas x 1 lane and as 2 antennas x 2 lanes so that the same memory "
        "with different control isolates the per-lane cost from the per-antenna "
        "one. The bank geometry axis is not repeated here: it was swept at the "
        "atom, and repeating it around a whole block would be four copies of an "
        "answered question at several times the compile cost. Full scale — SPEC "
        "11's 16 antennas x 1024 bins x 512 frames — is deliberately not a "
        "point: it is most of the device's M20K budget and hours of Fitter time "
        "for a figure that is this fixed cost plus the measured per-bank cost "
        "times a count. See scripts/run_calibration.py."),
    "fft_core": (
        "Three points. The scaling schedule is deliberately NOT an axis: it "
        "changes which quantisations saturate, not what they cost, and the "
        "shifts are wires. SAMPLES_PER_CYCLE is not an axis either — issue #11 "
        "verifies 2 and the 8-lane configuration belongs to issue #20, and "
        "calibrating an unverified geometry would be measuring something the "
        "design does not yet claim. See scripts/run_calibration.py."),
    "align_sw": (
        "Four points: the two SPEC 7.4 architectures at two widths, "
        "latency-matched at each (omega has log2(N) stages, so the crossbar is "
        "given MUX_STAGES = 1 at N = 4 and 2 at N = 8). Left out, in the open: "
        "the crossbar's own MUX_STAGES axis, which prices registers against LUT "
        "depth INSIDE one architecture and is a second-order refinement of "
        "whichever architecture wins; and GROUPS, which does not appear in the "
        "routing fabric at all. The block-level cost that both architectures "
        "share is not measured here on purpose — it is several times either "
        "fabric and would reduce the comparison to a few percent — it is the "
        "align_net matrix. See scripts/run_calibration.py."),
    "align_net": (
        "Two points, one per architecture, at 8 bins x 4 antennas. The width is "
        "bounded by stream_pkg::STREAM_MAX_DATA_W = 1024, which 8 x 4 x 32 hits "
        "exactly; the full-scale 8 x 16 beat is 4096 bits and raising that bound "
        "quadruples the working type of every stream_pack in the design for a "
        "geometry nothing yet verifies, so it belongs to issue #20. The "
        "full-scale block figure is this fixed cost plus the full-scale ROUTING "
        "cost, which the align_sw matrix does measure at 16 antennas because the "
        "fabric carries no SPEC 5 payload. Width and GROUPS are not axes here: "
        "what this matrix exists to measure is the fixed cost, and a second "
        "geometry would price the same structure twice. See "
        "scripts/run_calibration.py."),
}


# ---------------------------------------------------------------------------
# Tool location
# ---------------------------------------------------------------------------


def default_quartus_bin() -> Path:
    env = os.environ.get("QUARTUS_SH")
    if env:
        return Path(env).parent
    return Path("C:/altera_pro/26.1/quartus/bin64")


def tool(bindir: Path, name: str) -> Path:
    exe = bindir / f"{name}.exe"
    return exe if exe.exists() else bindir / name


# ---------------------------------------------------------------------------
# key/value files written by calibrate.tcl
# ---------------------------------------------------------------------------


def read_kv(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path.is_file():
        return out
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line or line.startswith("#"):
            continue
        if "\t" not in line:
            continue
        key, _, value = line.partition("\t")
        out[key.strip()] = value.strip()
    return out


def as_num(value: str | None):
    """A JSON number when the field holds one, else None. Never a bare string:
    a measurement that could not be taken is null, not the empty string, so a
    consumer never has to distinguish 'absent' from 'zero-length'."""
    if value is None:
        return None
    v = value.strip().replace(",", "")
    if not v:
        return None
    try:
        i = int(v)
        return i
    except ValueError:
        pass
    try:
        return float(v)
    except ValueError:
        return None


def as_text(value: str | None):
    if value is None:
        return None
    v = value.strip()
    return v or None


# ---------------------------------------------------------------------------
# One point
# ---------------------------------------------------------------------------


class PointResult:
    def __init__(self, point: dict) -> None:
        self.point = point
        self.ok = False
        self.record: dict = {}
        self.error = ""
        self.seconds = 0.0


def point_dir(kernel: str, point_id: str) -> Path:
    return RESULTS_DIR / "calibration" / kernel / point_id


def work_dir(kernel: str, point_id: str) -> Path:
    # TWO levels below the repository root, matching quartus/calibration/, so the
    # ../../rtl paths in the copied qsf resolve to the same sources.
    return REPO_ROOT / "results" / f"calib_{kernel}_{point_id}"


def make_work_copy(kernel: str, point_id: str) -> Path:
    dst = work_dir(kernel, point_id)
    if dst.exists():
        shutil.rmtree(dst, ignore_errors=True)
    dst.mkdir(parents=True, exist_ok=True)
    for pattern in ("*.qpf", "*.qsf", "*.sdc", "*.sv"):
        for src in sorted(CALIB_DIR.glob(pattern)):
            shutil.copy2(src, dst / src.name)
    return dst


def run_tool(exe: Path, args: list[str], log: Path) -> tuple[int, str]:
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("w", encoding="utf-8", errors="replace") as fh:
        proc = subprocess.run(
            [str(exe)] + args,
            cwd=str(REPO_ROOT),
            stdout=fh,
            stderr=subprocess.STDOUT,
            text=True,
        )
    tail = ""
    try:
        lines = log.read_text(encoding="utf-8", errors="replace").splitlines()
        tail = "\n".join(lines[-25:])
    except OSError:
        pass
    return proc.returncode, tail


def run_point(kernel: str, point: dict, bindir: Path, seed: int,
              isolate: bool, keep_work: bool, verbose: bool) -> PointResult:
    res = PointResult(point)
    pid = point["id"]
    started = time.time()

    pdir = point_dir(kernel, pid)
    pdir.mkdir(parents=True, exist_ok=True)

    proj = CALIB_DIR
    if isolate:
        proj = make_work_copy(kernel, pid)

    param_args = [f"{k}={v}" for k, v in sorted(point["params"].items())]
    common = [kernel, pid, "--seed", str(seed), "--projdir", str(proj)]

    print(f"[calib] {pid}: compile ({' '.join(param_args)})", flush=True)
    rc, tail = run_tool(
        tool(bindir, "quartus_sh"),
        ["-t", str(CALIB_TCL), "compile"] + common + param_args,
        pdir / "compile.log",
    )
    if rc != 0:
        res.error = f"compile failed (exit {rc})"
        if verbose:
            print(tail, flush=True)
        res.seconds = time.time() - started
        return res

    print(f"[calib] {pid}: sta", flush=True)
    rc, tail = run_tool(
        tool(bindir, "quartus_sta"),
        ["-t", str(CALIB_TCL), "sta"] + common,
        pdir / "sta.log",
    )
    if rc != 0:
        res.error = f"sta failed (exit {rc})"
        if verbose:
            print(tail, flush=True)
        res.seconds = time.time() - started
        return res

    res.record = build_record(kernel, point, pdir)
    res.ok = bool(res.record.get("compile_ok"))
    if not res.ok:
        res.error = res.record.get("fatal") or "no usable data in the point files"
    res.seconds = time.time() - started
    res.record["wall_seconds"] = round(res.seconds, 1)

    if isolate and not keep_work:
        shutil.rmtree(proj, ignore_errors=True)
    return res


def build_record(kernel: str, point: dict, pdir: Path) -> dict:
    """Merges compile.kv and timing.kv into one JSON record for the point."""
    c = read_kv(pdir / "compile.kv")
    t = read_kv(pdir / "timing.kv")

    params = {k[len("param_"):]: as_num(v) for k, v in c.items()
              if k.startswith("param_")}

    # Which DSP modes Quartus actually chose, under the labels Quartus used.
    # SPEC 18 asks for "DSP mapping"; a block count alone is not a mapping.
    dsp_modes = {k[len("dspmode_"):]: as_num(v) for k, v in c.items()
                 if k.startswith("dspmode_")}

    # PLACED blocks versus NEEDED blocks. The Fitter reports
    #     DSP Blocks Needed [=A+B+C-D]
    # where A is what it actually placed and D is its estimate of what dense
    # merging could recover. Those are different numbers and the difference is
    # the finding: a variant can place three blocks and still be reported as
    # needing two. Both are recorded, from the verbatim rows in dsp.txt, so the
    # comparison between variants is a comparison of the same quantity.
    dsp_placed = None
    dsp_recoverable = None
    dsp_txt = pdir / "dsp.txt"
    if dsp_txt.is_file():
        for line in dsp_txt.read_text(encoding="utf-8",
                                      errors="replace").splitlines():
            cells = [x.strip() for x in line.split("|")]
            if len(cells) < 2:
                continue
            label = cells[0].lstrip("[]ABCD ").strip()
            if label.startswith("Total Fixed Point DSP Blocks"):
                dsp_placed = as_num(cells[1])
            elif label.startswith("Estimate of DSP Blocks recoverable"):
                dsp_recoverable = as_num(cells[1])

    alm = as_num(c.get("alm_used"))
    dsp = as_num(c.get("dsp_used"))
    m20k = as_num(c.get("m20k_used"))

    # Memory BITS, added for SPEC 18 item 8 (issue #15). A block count cannot
    # distinguish one M20K used at full occupancy from one used at a twentieth of
    # it, and the history sweep asks exactly that question. `ram_bits` is the
    # total wherever it landed — the same quantity SPEC 17 calls "RAM bits" and
    # the same null-safe sum quartus/scripts/report_utilization.tcl computes: if
    # both halves are missing it stays None rather than becoming a misleading 0.
    m20k_bits = as_num(c.get("m20k_bits"))
    mlab_bits = as_num(c.get("mlab_bits"))
    ram_bits = None
    if m20k_bits is not None or mlab_bits is not None:
        ram_bits = (m20k_bits or 0) + (mlab_bits or 0)

    rec: dict = {
        "schema_version": SCHEMA_VERSION,
        "kernel": kernel,
        "point_id": point["id"],
        "label": point["label"],
        "parameters": params,
        "declared_parameters": point["params"],

        "device": as_text(c.get("device")),
        "quartus_version": as_text(c.get("quartus_version")),
        "commit": as_text(c.get("commit")),
        "timestamp": as_text(c.get("timestamp")),
        "seed": as_num(c.get("seed")),
        "top": as_text(c.get("top")),
        "project_dir": as_text(c.get("project_dir")),

        "compile_ok": c.get("stages_completed", "") == "syn,fit"
                      and not c.get("fatal"),
        "fatal": as_text(c.get("fatal")),
        "errors": as_num(c.get("errors")),
        "warnings": as_num(c.get("warnings")),
        "syn_seconds": as_num(c.get("syn_seconds")),
        "fit_seconds": as_num(c.get("fit_seconds")),

        # --- SPEC 17 utilization -------------------------------------------
        "utilization": {
            "alm_used": alm,
            "alm_percent": (round(100.0 * alm / TOTAL_ALMS, 6)
                            if alm is not None else None),
            "alm_reg_used": as_num(c.get("alm_reg_used")),
            "combinational_aluts": as_num(c.get("combinational_aluts")),
            "dsp_used": dsp,
            "dsp_percent": (round(100.0 * dsp / TOTAL_DSP, 6)
                            if dsp is not None else None),
            "m20k_used": m20k,
            "m20k_percent": (round(100.0 * m20k / TOTAL_M20K, 6)
                             if m20k is not None else None),
            "mlab_used": as_num(c.get("mlab_used")),
            "m20k_bits": m20k_bits,
            "mlab_bits": mlab_bits,
            "ram_bits": ram_bits,
            "pins_used": as_num(c.get("pins_used")),
            "virtual_pins": as_num(c.get("virtual_pins")),
            "source_stage": as_text(c.get("resource_source_stage")),
        },

        # --- SPEC 18 DSP mapping --------------------------------------------
        "dsp": {
            "blocks": dsp,                       # "DSP Blocks Needed", = placed - recoverable
            "blocks_placed": dsp_placed,         # what the Fitter actually placed
            "blocks_recoverable": dsp_recoverable,
            "mult_18x19": as_num(c.get("mult_18x19")),
            "mult_27x27": as_num(c.get("mult_27x27")),
            "modes": dsp_modes,
            "panel": as_text(c.get("dsp_panel")),
            "detail_file": "dsp.txt",
        },

        # --- SPEC 18 M20K mapping -------------------------------------------
        # The memory counterpart of the dsp{} object above, and for the history
        # kernels it is the headline rather than a footnote. `blocks` and `bits`
        # together answer "how much of each block did Quartus actually fill",
        # which neither answers alone; `detail_file` points at the verbatim
        # Fitter RAM Summary rows, which are where per-memory depth x width,
        # memory mode and block type live and are the primary evidence for the
        # aspect-ratio sweep.
        "memory": {
            "m20k_blocks": m20k,
            "mlab_blocks": as_num(c.get("mlab_used")),
            "m20k_bits": m20k_bits,
            "mlab_bits": mlab_bits,
            "ram_bits": ram_bits,
            "panel": as_text(c.get("ram_panel")),
            "detail_file": "ram.txt",
        },

        # --- the kernel instance alone, without the wrapper's boundary regs ---
        "kernel_entity": {
            "alm_used": as_num(c.get("kernel_alm_used")),
            "alm_reg_used": as_num(c.get("kernel_alm_reg_used")),
            "combinational_aluts": as_num(c.get("kernel_comb_aluts")),
            "dsp_used": as_num(c.get("kernel_dsp_used")),
            "m20k_used": as_num(c.get("kernel_m20k_used")),
            "mlab_used": as_num(c.get("kernel_mlab_used")),
            "row": as_text(c.get("kernel_entity_row")),
        },

        # --- SPEC 17 timing --------------------------------------------------
        # `fmax` is the register-to-register measurement and is THE calibration
        # number; `quartus_restricted_fmax_mhz` is Quartus's own whole-design
        # figure, which on a virtual-pin harness is dominated by output-port
        # clock-insertion skew. Both are recorded, named for what they are. See
        # the long note in quartus/scripts/calibrate.tcl.
        "timing": {
            "clock": as_text(t.get("clock_name")),
            "probe_constraint_mhz": as_num(t.get("constraint_mhz")),
            "probe_period_ns": as_num(t.get("period_ns")),
            "fmax_mhz": as_num(t.get("reg2reg_fmax_mhz")),
            "fmax_source": "register-to-register worst setup slack",
            "reg2reg_wns_ns": as_num(t.get("reg2reg_wns_ns")),
            "reg2reg_logic_depth": as_num(t.get("reg2reg_logic_depth")),
            "reg2reg_cell_delay_ns": as_num(t.get("reg2reg_cell_delay_ns")),
            "reg2reg_routing_delay_ns": as_num(t.get("reg2reg_routing_delay_ns")),
            "reg2reg_clock_skew_ns": as_num(t.get("reg2reg_clock_skew_ns")),
            "reg2reg_source": as_text(t.get("reg2reg_source")),
            "reg2reg_destination": as_text(t.get("reg2reg_destination")),
            "critical_path_in_kernel": (as_num(t.get("reg2reg_in_kernel")) == 1),
            "quartus_restricted_fmax_mhz": as_num(t.get("restricted_fmax_mhz")),
            "quartus_fmax_mhz": as_num(t.get("fmax_mhz")),
            "design_wns_ns": as_num(t.get("wns_ns")),
            "design_tns_ns": as_num(t.get("tns_ns")),
            "hold_wns_ns": as_num(t.get("hold_wns_ns")),
            "unconstrained_paths": as_num(t.get("unconstrained_paths")),
        },

        # --- SPEC 17 / 23 retiming ------------------------------------------
        "retiming": {
            "limit_domain": as_text(c.get("retiming_limit_domain")),
            "limit_reason": as_text(c.get("retiming_limiting_reason")
                                    or c.get("retiming_limit_reason")),
            "recommendation": as_text(c.get("retiming_recommendation")),
            "design_registers": as_num(t.get("design_registers")),
            "design_hyper_registers": as_num(t.get("design_hyper_regs")),
            "kernel_registers": as_num(t.get("kernel_registers")),
            "kernel_hyper_registers": as_num(t.get("kernel_hyper_regs")),
            "kernel_sync_reset_registers": as_num(t.get("kernel_sync_reset")),
            "kernel_async_reset_registers": as_num(t.get("kernel_async_reset")),
            "kernel_clock_enable_registers": as_num(t.get("kernel_clock_enable")),
            # Paths in the sampled set whose SOURCE is a memory output that did
            # NOT have a register absorbed into the hard block. SPEC 23 requires
            # registers around M20Ks and SPEC 18 names input/output register
            # choices as an axis, and this is the repository's one purpose-built
            # measurement of whether the tool actually took them: zero means
            # absorbed, non-zero means the read data came out into the fabric raw
            # and is being registered in ALMs. `ram_paths_sampled` is the
            # denominator, so the number is never read as a rate it is not.
            "unregistered_ram_paths": as_num(t.get("unregistered_ram_paths")),
            "ram_paths_sampled": as_num(t.get("ram_paths_sampled")),
            "detail_files": ["retiming.txt", "retiming_limits.txt"],
        },

        "evidence_dir": str(pdir.relative_to(REPO_ROOT)).replace("\\", "/"),
        "notes": [],
    }

    notes = rec["notes"]
    # A point whose register-to-register paths MET the probe constraint has not
    # been pushed as hard as the Fitter could push it: it stopped when the
    # fabric paths passed. Its Fmax is therefore a LOWER BOUND, not a limit, and
    # saying so is the difference between a measurement and a number. Raising the
    # probe and re-running resolves it; the record says which points need that.
    r2r = rec["timing"]["reg2reg_wns_ns"]
    if r2r is not None and r2r >= 0:
        notes.append(
            "the register-to-register paths MET the probe constraint "
            f"({rec['timing']['probe_constraint_mhz']} MHz, slack {r2r} ns), so "
            "fmax_mhz is a lower bound rather than a measured limit; re-run this "
            "point at a higher probe to resolve it")
    if rec["device"] != DEVICE:
        notes.append(f"device is {rec['device']}, expected {DEVICE}")
    if not rec["timing"]["critical_path_in_kernel"]:
        notes.append(
            "the register-to-register critical path does not touch the kernel "
            "instance; this point measured the wrapper, not the kernel")
    if rec["timing"]["unconstrained_paths"] not in (0, None):
        notes.append(
            f"{rec['timing']['unconstrained_paths']} unconstrained paths "
            "(SPEC 2 requires zero)")
    declared = {k: v for k, v in point["params"].items()}
    seen = {k: v for k, v in params.items()}
    if declared != seen:
        notes.append(
            f"Quartus elaborated {seen}, the sweep asked for {declared}")
    return rec


# ---------------------------------------------------------------------------
# JSON output
# ---------------------------------------------------------------------------


def summary_path(kernel: str) -> Path:
    return RESULTS_DIR / f"calibration_{kernel}.json"


def load_summary(kernel: str) -> dict:
    path = summary_path(kernel)
    if path.is_file():
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            pass
    return {}


def write_summary(kernel: str, matrix: dict, records: list[dict],
                  seed: int, pruned_note: str) -> Path:
    path = summary_path(kernel)
    path.parent.mkdir(parents=True, exist_ok=True)
    doc = {
        "schema_version": SCHEMA_VERSION,
        "kernel": kernel,
        "description": matrix["description"],
        "device": DEVICE,
        "top": matrix["top"],
        "seed": seed,
        "probe_constraint_note": (
            "The calibration project is constrained at 600 MHz "
            "(quartus/calibration/*_calib.sdc), deliberately above the SPEC 2 "
            "450 MHz design target, so that no point meets timing and every "
            "reported Fmax is a measurement of a critical path rather than of "
            "the constraint. The benchmark's own 450 MHz constraint in "
            "quartus/constraints/clocks.sdc is untouched."),
        "fmax_note": (
            "timing.fmax_mhz is the register-to-register measurement and is the "
            "calibration number. timing.quartus_restricted_fmax_mhz is Quartus's "
            "whole-design figure, which on a virtual-pin harness is dominated by "
            "output-port clock-insertion skew that no fitter can remove and that "
            "does not exist at a fabric-internal boundary."),
        "matrix_axes": matrix["axes"],
        "pruning": pruned_note,
        "point_count": len(records),
        "points": records,
    }
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)
    return path


# ---------------------------------------------------------------------------
# Summary table
# ---------------------------------------------------------------------------


def fmt(v, spec="{}"):
    return "--" if v is None else spec.format(v)


def print_table(records: list[dict]) -> str:
    """One row per point, in a shape that serves every kernel.

    The first column is the point's own LABEL rather than a fixed set of
    parameter columns: the complex multiplier's axes (variant, depth, output
    format) and the FFT's (depth, memory style, reorder) have nothing in common,
    and a table with a column per axis of every kernel would be mostly empty. The
    label is defined in the matrix beside the parameters it names, and the
    parameters themselves are in the JSON record.

    M20K and MLAB are columns because SPEC 18 asks for "M20K mapping" and the FFT
    is the first kernel in this database with memories at all. M20Kbits sits
    beside the block count for the reason issue #15 added it: one M20K at full
    occupancy and one M20K at a twentieth of it are the same block count and a
    twentyfold difference in what the full-scale design will cost, and the
    history sweep's whole question is which of the two a given geometry got.
    """
    cols = ("point", "DSP", "18x18", "M20K", "M20Kbits", "MLAB", "ALM",
            "ALM(kern)", "regs", "hyper", "Fmax MHz", "depth", "fit s")
    widths = (26, 4, 6, 5, 9, 5, 7, 9, 6, 6, 9, 5, 6)
    lines = []
    lines.append("  ".join(c.ljust(w) for c, w in zip(cols, widths)).rstrip())
    lines.append("  ".join("-" * w for w in widths))
    for r in sorted(records, key=lambda x: x["point_id"]):
        u = r.get("utilization", {})
        k = r.get("kernel_entity", {})
        t = r.get("timing", {})
        rt = r.get("retiming", {})
        d = r.get("dsp", {})
        modes = d.get("modes", {}) or {}
        sum2 = None
        for name, value in modes.items():
            if "sum_of_two" in name or "18x18" in name or "18x19" in name:
                sum2 = value
                break
        row = (
            r.get("label") or r.get("point_id"),
            fmt(u.get("dsp_used")),
            fmt(sum2),
            fmt(u.get("m20k_used")),
            fmt(u.get("m20k_bits")),
            fmt(u.get("mlab_used")),
            fmt(u.get("alm_used")),
            fmt(k.get("alm_used")),
            fmt(u.get("alm_reg_used")),
            fmt(rt.get("design_hyper_registers")),
            fmt(t.get("fmax_mhz")),
            fmt(t.get("reg2reg_logic_depth")),
            fmt(r.get("fit_seconds")),
        )
        lines.append("  ".join(str(c).ljust(w) for c, w in zip(row, widths)).rstrip())
    text = "\n".join(lines)
    print(text)
    return text


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--kernel", default="cmult",
                   help=f"kernel to sweep; one of {', '.join(MATRICES)}")
    p.add_argument("--jobs", type=int, default=1,
                   help="points to compile at once (each gets its own project "
                        "copy). MEASURED on this host: one Fitter run of this "
                        "project on AGMF039R47B1E1VC reports a ~19.5 GB peak "
                        "virtual memory, and TWO at once drove a 32 GB machine "
                        "to 0.6 GB free and into thrashing — the pair made less "
                        "progress in 30 minutes than one point makes in nine. "
                        "Raise this only with the RAM to match. Default 1.")
    p.add_argument("--seed", type=int, default=1,
                   help="Fitter seed, recorded in every record (SPEC 25)")
    p.add_argument("--points", nargs="*", default=None,
                   help="only these point ids (default: the whole matrix)")
    p.add_argument("--resume", action="store_true",
                   help="skip points already present in the summary JSON")
    p.add_argument("--keep-work", action="store_true",
                   help="keep the per-point project copies for inspection")
    p.add_argument("--summary-only", action="store_true",
                   help="rebuild the JSON and the table from existing point "
                        "directories; compile nothing")
    p.add_argument("--quartus-bin", default=None,
                   help="directory holding quartus_sh / quartus_sta")
    p.add_argument("--verbose", action="store_true",
                   help="print the tail of a failing tool log")
    args = p.parse_args()

    if args.kernel not in MATRICES:
        print(f"ERROR: no calibration matrix for kernel '{args.kernel}'. "
              f"Known: {', '.join(MATRICES)}", file=sys.stderr)
        return 2
    matrix = MATRICES[args.kernel]

    points = matrix["points"]
    if args.points:
        wanted = set(args.points)
        points = [pt for pt in points if pt["id"] in wanted]
        missing = wanted - {pt["id"] for pt in points}
        if missing:
            print(f"ERROR: unknown point id(s): {', '.join(sorted(missing))}",
                  file=sys.stderr)
            return 2

    pruned_note = PRUNING_NOTES.get(
        args.kernel, "See scripts/run_calibration.py for this kernel's matrix.")

    existing = load_summary(args.kernel)
    records: dict[str, dict] = {r["point_id"]: r
                                for r in existing.get("points", [])}

    if args.summary_only:
        rebuilt = []
        for pt in matrix["points"]:
            pdir = point_dir(args.kernel, pt["id"])
            if not (pdir / "compile.kv").is_file():
                continue
            rebuilt.append(build_record(args.kernel, pt, pdir))
        for r in rebuilt:
            records[r["point_id"]] = r
        out = write_summary(args.kernel, matrix, list(records.values()),
                            args.seed, pruned_note)
        print(f"[calib] rebuilt {out.relative_to(REPO_ROOT)} "
              f"from {len(rebuilt)} point directories")
        print()
        print_table([r for r in records.values() if r.get("compile_ok")])
        return 0

    if args.resume:
        before = len(points)
        points = [pt for pt in points
                  if not records.get(pt["id"], {}).get("compile_ok")]
        print(f"[calib] resume: {before - len(points)} point(s) already done")

    bindir = Path(args.quartus_bin) if args.quartus_bin else default_quartus_bin()
    sh = tool(bindir, "quartus_sh")
    if not sh.exists():
        print(f"ERROR: quartus_sh not found at {sh}. Set --quartus-bin or "
              "QUARTUS_SH.", file=sys.stderr)
        return 2

    print(f"[calib] kernel={args.kernel} device={DEVICE} top={matrix['top']}")
    print(f"[calib] quartus={sh}")
    print(f"[calib] points={len(points)} jobs={args.jobs} seed={args.seed}")
    # ALWAYS compile in an isolated copy, not only when running several points at
    # once. Two reasons, both learned the hard way: `project_close` exports the
    # in-memory assignment database over the qsf, so even a read-only STA run
    # writes tool bookkeeping into a hand-maintained tracked file; and a compile
    # leaves db/, qdb/ and output_files/ behind. Working in a copy keeps
    # quartus/calibration/ exactly as it is in the repository, which is the state
    # a clean checkout has to reproduce.
    isolate = True

    started = time.time()
    failures: list[tuple[str, str]] = []

    def finish(res: PointResult) -> None:
        pid = res.point["id"]
        if res.ok:
            records[pid] = res.record
            t = res.record["timing"]
            u = res.record["utilization"]
            print(f"[calib] {pid}: OK in {res.seconds/60:.1f} min "
                  f"(DSP={u['dsp_used']} ALM={u['alm_used']} "
                  f"Fmax={t['fmax_mhz']} MHz)", flush=True)
        else:
            failures.append((pid, res.error))
            print(f"[calib] {pid}: FAILED — {res.error} "
                  f"(log: {point_dir(args.kernel, pid)})", flush=True)
        write_summary(args.kernel, matrix, list(records.values()), args.seed,
                      pruned_note)

    if args.jobs <= 1:
        for pt in points:
            finish(run_point(args.kernel, pt, bindir, args.seed, isolate,
                             args.keep_work, args.verbose))
    else:
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as ex:
            futures = {
                ex.submit(run_point, args.kernel, pt, bindir, args.seed,
                          isolate, args.keep_work, args.verbose): pt
                for pt in points
            }
            for fut in concurrent.futures.as_completed(futures):
                finish(fut.result())

    out = write_summary(args.kernel, matrix, list(records.values()), args.seed,
                        pruned_note)
    elapsed = (time.time() - started) / 60.0

    good = [r for r in records.values() if r.get("compile_ok")]
    print()
    print(f"[calib] {len(good)} successful point(s) in {elapsed:.1f} min")
    print(f"[calib] record: {out.relative_to(REPO_ROOT)}")
    print()
    print_table(good)
    if failures:
        print()
        for pid, why in failures:
            print(f"[calib] FAILED {pid}: {why}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
