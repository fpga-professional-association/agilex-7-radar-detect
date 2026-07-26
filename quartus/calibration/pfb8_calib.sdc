# ---------------------------------------------------------------------------
# pfb8_calib.sdc — timing constraints for the SPEC 18
# eight-lane polyphase FIR bank (SPEC.md 18 item 3) calibration project (issue #10).
#
# BYTE-FOR-BYTE THE SAME CONSTRAINT as quartus/calibration/cmult_calib.sdc, on
# purpose: a calibration sweep whose points were measured against different
# constraints is not a comparison. The rationale below is repeated rather than
# referenced so that a reader holding one file has the whole argument.
#
# THE PROBE CONSTRAINT, AND WHY IT IS 600 MHz AND NOT 450
# -------------------------------------------------------
# SPEC 2 sets the benchmark's primary clock target at 450 MHz, and
# quartus/constraints/clocks.sdc constrains the real design at exactly that.
# This file deliberately does NOT.
#
# The purpose of a calibration point is to measure what a kernel CAN do, so that
# SPEC 18's "use measured data to select the full-scale parameters" has real
# numbers to work from. A Fitter that meets its constraint stops optimising: it
# reports positive slack, the placement is whatever was good enough, and the
# reported Fmax becomes a statement about the constraint rather than about the
# kernel. Every point of a sweep constrained at 450 MHz on a two-DSP design would
# come back "met", and the sweep would have measured nothing — which is exactly
# the "theoretical DSP-count arithmetic" SPEC 18 forbids building on.
#
# The probe constraint is therefore set ABOVE the achievable range on purpose, at
# 600 MHz. Every point then fails its constraint, every point is pushed as hard
# as the Fitter knows how to push it, and the restricted Fmax that comes back is
# a measurement of the critical path. The comparison between points — MULT4 vs
# MULT3, PIPE_STAGES 2 vs 5 — is the deliverable, and it is only meaningful when
# no point was allowed to stop early.
#
# This is NOT the SPEC 24 prohibition in reverse. SPEC 24 forbids LOWERING a
# requested clock after seeing a poor result, in order to make a benchmark result
# look better. This raises it, before seeing any result, in a project that is not
# the benchmark and whose output is a measurement rather than a claim. The
# benchmark's own constraint is untouched at 450 MHz in clocks.sdc, and the
# calibration record carries both numbers so nothing can be confused later.
#
# 1.666 ns is 600.24 MHz — marginally tighter than 600 — so a point that somehow
# did meet timing would not have met it by a rounding artefact. That is the same
# convention clocks.sdc uses for the 450 MHz target.
# ---------------------------------------------------------------------------

set calib_probe_period_ns 1.666

create_clock \
    -name clk \
    -period $calib_probe_period_ns \
    [get_ports {clk}]

# No generated clocks and no asynchronous groups: the calibration wrapper is
# single-clock by construction. Adding either would mean measuring something
# other than the kernel.

derive_clock_uncertainty

# Same single-clock construction as the FIR-lane point, and the same statement:
# pfb8_wrap ties the coefficient bank's configuration clock to the core clock, so
# there is no asynchronous group to declare and none is declared (SPEC 24).

# ---------------------------------------------------------------------------
# Boundary budget
# ---------------------------------------------------------------------------
# Every data port is a virtual pin (see the qsf), so there is no package or board
# flight time to model. The delays exist for the two reasons io.sdc gives:
# SPEC 2 requires zero unconstrained paths, and an unconstrained virtual pin is
# still an unconstrained endpoint; and the boundary registers must stay inside
# the analysed graph.
#
# The budget is deliberately SMALL — 0.200 ns max, 0.050 ns min, i.e. 12% and 3%
# of the probe period. The wrapper puts a real register immediately inside every
# port, so the I/O paths are a virtual pin driving one flip-flop and must not be
# what limits the reported Fmax; if they were, the sweep would be comparing
# boundary budgets instead of arithmetic. The number to watch in the exported
# record is the critical path's source and destination hierarchy: it must be
# inside u_kernel, and run_calibration.py records it for every point so that it
# can be checked rather than assumed.
set calib_io_delay_max_ns 0.200
set calib_io_delay_min_ns 0.050

set clk_port     [get_ports {clk}]
set all_in_ports [remove_from_collection [all_inputs] $clk_port]

set_input_delay -clock [get_clocks clk] -max $calib_io_delay_max_ns $all_in_ports
set_input_delay -clock [get_clocks clk] -min $calib_io_delay_min_ns $all_in_ports

set_output_delay -clock [get_clocks clk] -max $calib_io_delay_max_ns [all_outputs]
set_output_delay -clock [get_clocks clk] -min $calib_io_delay_min_ns [all_outputs]

# No false paths, no multicycle paths, no clock groups. SPEC 24: none of these
# may be added to make a result look better, and a calibration project has even
# less excuse than the benchmark does.
