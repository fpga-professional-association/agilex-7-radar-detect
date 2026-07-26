# ---------------------------------------------------------------------------
# history_bank_calib.sdc — timing constraints for the SPEC 18 history-bank
# calibration (issue #15).
#
# THE PROBE CONSTRAINT IS 600 MHz, NOT 450, and the reasoning is unchanged from
# quartus/calibration/cmult_calib.sdc — read that file for the full argument. In
# one paragraph: SPEC 2 targets 450 MHz and quartus/constraints/clocks.sdc
# constrains the real design at exactly that. A Fitter that MEETS its constraint
# stops optimising, so a sweep constrained at the target measures the constraint
# rather than the kernel. The probe is therefore set deliberately above the
# achievable range, before any result is seen, in a project that is not the
# benchmark and whose output is a measurement rather than a claim. This is not
# SPEC 24's prohibition in reverse: SPEC 24 forbids LOWERING a requested clock
# after seeing a poor result. The benchmark's own 450 MHz constraint is untouched
# and the exported record carries both numbers.
#
# 1.666 ns is 600.24 MHz — marginally tighter than 600 — so a point that somehow
# did meet timing would not have met it by a rounding artefact.
# ---------------------------------------------------------------------------

set calib_probe_period_ns 1.666

create_clock     -name clk     -period $calib_probe_period_ns     [get_ports {clk}]

# No generated clocks and no asynchronous groups: the calibration wrapper is
# single-clock by construction. history_bank has independent write and read
# clocks in the real system, but this wrapper ties wr_clk and rd_clk to the one
# `clk` (see history_bank_wrap.sv, which states at length what that costs and
# what it does not), so the memory is still elaborated and still costs what it
# costs while the point stays a single-clock fabric measurement. Adding a second
# clock here would mean measuring something other than the kernel.

derive_clock_uncertainty

# ---------------------------------------------------------------------------
# Boundary budget
# ---------------------------------------------------------------------------
# Every data port is a virtual pin (see the qsf), so there is no package or board
# flight time to model. The delays exist for the two reasons io.sdc gives: SPEC 2
# requires zero unconstrained paths, and an unconstrained virtual pin is still an
# unconstrained endpoint; and the boundary registers must stay inside the
# analysed graph.
#
# The budget is deliberately SMALL — 0.200 ns max, 0.050 ns min, i.e. 12% and 3%
# of the probe period. The wrapper puts a real register immediately inside every
# port, so the I/O paths are a virtual pin driving one flip-flop and must not be
# what limits the reported Fmax. The number to watch in the exported record is
# the critical path's source and destination hierarchy: it must be inside
# u_kernel, and run_calibration.py records it for every point so that it can be
# checked rather than assumed.
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
