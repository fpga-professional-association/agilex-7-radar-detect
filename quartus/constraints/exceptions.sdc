# ---------------------------------------------------------------------------
# exceptions.sdc — timing exceptions for the Agilex 7 wideband benchmark
#
# THIS FILE IS INTENTIONALLY EMPTY. It contains no set_false_path, no
# set_multicycle_path, no set_clock_groups, and no set_max_delay.
#
# The Phase 0 minimal top is a single-clock, fully synchronous design. It needs
# no exception, and SPEC.md 24 forbids adding one speculatively.
#
# ---------------------------------------------------------------------------
# SPEC.md 24 — Constraints Integrity Rules
# ---------------------------------------------------------------------------
# Prohibited unless fully justified:
#   * Broad wildcard false paths.
#   * False paths through active datapaths.
#   * Multicycle paths added because a path fails timing.
#   * Clock groups that hide real synchronous crossings.
#   * Disabling timing analysis for difficult hierarchy.
#   * Lowering the requested clock after seeing a poor result without
#     preserving the original benchmark.
#
# "Never add a false path or multicycle path merely to improve timing reports."
# (SPEC.md 15). A path that fails timing is a result to report, not a
# constraint to delete.
#
# ---------------------------------------------------------------------------
# Required documentation for EVERY future exception
# ---------------------------------------------------------------------------
# SPEC.md 15 requires all five fields, as a comment block immediately above the
# constraint. An exception without all five is a review failure, not a nit:
#
#   1. Source        — the exact source collection (get_registers/get_pins/...),
#                      written out, not a wildcard that happens to match it.
#   2. Destination   — the exact destination collection, same rule.
#   3. Functional reason
#                    — WHY the path is not a real single-cycle synchronous
#                      path: quasi-static configuration register, Gray-coded
#                      pointer crossing a declared async boundary, N-cycle
#                      handshake with a proven N, etc.
#   4. Verification method
#                    — how the claim is proven, not asserted: the simulation
#                      test that exercises it, the CDC assertion that fires on
#                      violation, the register-map attribute that pins it
#                      quasi-static.
#   5. Reviewer-facing explanation
#                    — plain-language paragraph a reviewer can check against
#                      the RTL without reverse-engineering the constraint.
#
# Template (copy, fill in every field, then add the constraint):
#
#   # -----------------------------------------------------------------------
#   # Exception: <short name>
#   # Source:        <collection>
#   # Destination:   <collection>
#   # Functional reason:      <why this is not a real synchronous path>
#   # Verification method:    <test / assertion / property that proves it>
#   # Reviewer explanation:   <plain-language justification>
#   # -----------------------------------------------------------------------
#   set_false_path -from <collection> -to <collection>
#
# quartus/scripts/report_sta.tcl reports every false path, multicycle path,
# asynchronous clock group, disabled timing arc, and unconstrained endpoint
# found in the compiled design (SPEC.md 24). That report is part of the final
# evidence package, so an undocumented exception added here will surface there.
# ---------------------------------------------------------------------------
