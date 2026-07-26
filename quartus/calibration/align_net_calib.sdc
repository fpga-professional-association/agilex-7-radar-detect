# ---------------------------------------------------------------------------
# align_net_calib.sdc — timing constraints for the SPEC 18 / SPEC 7.4 calibration
# of the whole frequency-bin alignment network (issue #16).
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
# IT MATTERS MORE HERE THAN ANYWHERE ELSE IN THIS DIRECTORY. This project's whole
# purpose is to compare two architectures' Fmax against each other. If both met
# the constraint, both records would report the constraint and the comparison
# would be between two identical numbers that mean nothing. The probe is above
# the achievable range precisely so that both points report a measured critical
# path.
#
# 1.666 ns is 600.24 MHz — marginally tighter than 600 — so a point that somehow
# did meet timing would not have met it by a rounding artefact.
# ---------------------------------------------------------------------------

set calib_probe_period_ns 1.666

create_clock     -name clk     -period $calib_probe_period_ns     [get_ports {clk}]

# No generated clocks and no asynchronous groups: the routing fabric is
# single-clock in the real design too (rtl/align/align_net.sv section 4 — both of
# its interfaces are already in history_clk), so unlike the other wrappers in
# this directory this one is not tying anything together for the sweep's
# convenience. What is measured is what is built.

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
# checked rather than assumed. On this kernel it is the number that decides the
# comparison — a point whose critical path is in the wrapper has measured the
# boundary, not the topology.
set calib_io_delay_max_ns 0.200
set calib_io_delay_min_ns 0.050

set clk_port     [get_ports {clk}]
set all_in_ports [remove_from_collection [all_inputs] $clk_port]

set_input_delay -clock [get_clocks clk] -max $calib_io_delay_max_ns $all_in_ports
set_input_delay -clock [get_clocks clk] -min $calib_io_delay_min_ns $all_in_ports

set_output_delay -clock [get_clocks clk] -max $calib_io_delay_max_ns [all_outputs]
set_output_delay -clock [get_clocks clk] -min $calib_io_delay_min_ns [all_outputs]

# No false paths, no multicycle paths, no clock groups. SPEC 24: none of these
# may be added to make a result look better, and a calibration project whose
# output is a head-to-head comparison has even less excuse than the benchmark
# does — a false path added to one architecture and not the other would be a
# fabricated result rather than a generous one.
