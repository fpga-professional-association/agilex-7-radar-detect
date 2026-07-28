# ---------------------------------------------------------------------------
# constraints_report.tcl -- Quartus-side constraints-integrity dump (SPEC.md 24)
#
# Complements the local scripts/constraints_report.py by dumping what the
# Quartus timing analyzer ACTUALLY SAW at the fitted netlist, as opposed to
# what the SDC files say. Both need to agree: mismatches are the SPEC.md 24
# alarm.
#
# Usage:
#   quartus_sta -t constraints_report.tcl [output-txt]
#
# Runs on a completed compile (fit + sta), using the existing quartus project
# database. Does not modify the qsf.
#
# Outputs (default paths, all under results/synthesis/):
#   frag_constraints_report.tcl        machine-readable fragment
#   constraints_report_qs.txt          human-readable text
#
# The fragment is merged by export_results.tcl into the SPEC.md 17 JSON record
# under a "constraints_report" key. The text file is copied verbatim into
# evidence/baseline/quartus_reports/ (SPEC.md 27).
# ---------------------------------------------------------------------------

source [file join [file dirname [info script]] common.tcl]

package require ::quartus::sta

set out_txt [file join $bench::synth_dir "constraints_report_qs.txt"]
if {[llength $quartus(args)] >= 1} {
    set out_txt [lindex $quartus(args) 0]
}

bench::ensure_dirs
bench::qsf_snapshot

set rc 0
set notes {}
set integrity [dict create]
set unconstrained_paths ""
set clock_names {}

if {[catch {
    bench::open_project

    # SPEC 24 requires post-fit STA on the actual netlist, so read the
    # post-fit netlist (create_timing_netlist follows the current
    # compilation's Fitter output).
    create_timing_netlist -model slow
    read_sdc
    update_timing_netlist

    # ---- counts of every timing-exception directive the analyzer saw -----
    # get_timing_exceptions returns one collection entry per directive on the
    # versions of Quartus Pro that expose it. Older/other versions do not, so
    # each count falls back to "" with a documented note and the SDC-side count
    # from scripts/constraints_report.py becomes the authoritative source for
    # this record.
    proc _count_collection {cmd} {
        set n 0
        set col [eval $cmd]
        set it [$col get_iterator]
        while {[$it next]} { incr n }
        $col destroy
        return $n
    }

    foreach {label subcmd} {
        false_paths       {get_timing_exceptions -type false_path}
        multicycle_paths  {get_timing_exceptions -type multicycle}
        max_delays        {get_timing_exceptions -type max_delay}
        min_delays        {get_timing_exceptions -type min_delay}
    } {
        if {[catch { _count_collection $subcmd } n]} {
            dict set integrity $label ""
            lappend notes "$label unavailable via get_timing_exceptions ($n)"
        } else {
            dict set integrity $label $n
        }
    }

    # Clock groups: no direct collection API. Use report_clock_groups; the
    # ignored-return string from the collector is fine, we just count the
    # `set_clock_groups` occurrences.
    if {[catch {
        set cg_txt [report_clock_groups]
        dict set integrity clock_groups \
            [regexp -all {(?:^|\s)set_clock_groups(?:\s|$)} $cg_txt]
    }]} {
        dict set integrity clock_groups 0
        lappend notes "report_clock_groups unavailable"
    }

    # Ignored SDC constraints: the analyzer's own "these constraints did not
    # apply" list. That is the SPEC 24 quiet failure: an exception written
    # but not honoured.
    if {[catch {
        set sdc_txt [report_sdc -ignored]
        set ignored 0
        foreach line [split $sdc_txt \n] {
            set line [string trim $line]
            if {[string index $line 0] eq ";" && [regexp {set_[a-z_]+} $line]} {
                incr ignored
            }
        }
        dict set integrity ignored_sdc_constraints $ignored
    }]} {
        dict set integrity ignored_sdc_constraints 0
        lappend notes "report_sdc -ignored unavailable"
    }

    # Disabled timing arcs: report_disable_timing enumerates every disabled
    # arc in the netlist. Count non-comment lines that describe an arc.
    if {[catch {
        set dt_txt [report_disable_timing]
        set arcs 0
        foreach line [split $dt_txt \n] {
            set line [string trim $line]
            if {$line eq "" || [string index $line 0] eq "#"} { continue }
            if {[regexp {\|.+\|.+\|} $line]} { incr arcs }
        }
        dict set integrity disabled_arcs $arcs
    }]} {
        dict set integrity disabled_arcs 0
        lappend notes "report_disable_timing unavailable"
    }

    # Unconstrained paths: same accounting the report_sta.tcl main script
    # already does. Fold in here for completeness.
    if {[catch {
        set ucp_txt [report_ucp]
        set total 0
        set seen 0
        foreach label {
            {Illegal Clocks}
            {Unconstrained Clocks}
            {Unconstrained Input Ports}
            {Paths from Unconstrained Input Ports*}
            {Unconstrained Output Ports}
            {Paths to Unconstrained Output Ports*}
        } {
            foreach line [split $ucp_txt \n] {
                if {[string first $label $line] >= 0} {
                    foreach m [regexp -all -inline {[0-9]+} $line] {
                        set total [expr {$total + int($m)}]
                        set seen 1
                    }
                    break
                }
            }
        }
        if {$seen} { set unconstrained_paths $total }
    }]} {
        lappend notes "report_ucp unavailable"
    }
    dict set integrity unconstrained_paths $unconstrained_paths

    # Clock domains (SPEC 24: "every clock in the design is either constrained
    # or its endpoints are false-pathed"). List the clock names the analyzer
    # sees.
    if {[catch {
        set clock_col [get_clocks]
        set it [$clock_col get_iterator]
        while {[$it next]} {
            lappend clock_names [get_clock_info -name $it]
        }
        $clock_col destroy
    }]} {
        lappend notes "get_clocks unavailable"
    }
    dict set integrity clocks $clock_names

    delete_timing_netlist
} outer_err]} {
    lappend notes "constraints_report.tcl fatal: $outer_err"
    set rc 1
    bench::log "FATAL: $outer_err"
}

catch {bench::close_project}
bench::qsf_restore

# ---------------------------------------------------------------------------
# Fragment
# ---------------------------------------------------------------------------
set d [dict create \
    quartus_version   [bench::quartus_version_short] \
    integrity         $integrity \
    notes             $notes \
]
bench::frag_save constraints_report $d

# ---------------------------------------------------------------------------
# Human-readable text report
# ---------------------------------------------------------------------------
set fh [open $out_txt w]
puts $fh "constraints_report_qs.txt -- SPEC.md 24 Quartus-side audit"
puts $fh "quartus  : [bench::quartus_version]"
puts $fh "clocks   : [join $clock_names {, }]"
puts $fh ""
puts $fh "-- integrity counts (Quartus timing analyzer) ---------------------------"
dict for {k v} $integrity {
    if {$k eq "clocks"} { continue }
    puts $fh [format "  %-24s %s" $k $v]
}
if {[llength $notes] > 0} {
    puts $fh ""
    puts $fh "-- notes ----------------------------------------------------------------"
    foreach n $notes { puts $fh "  * $n" }
}
close $fh
bench::log "wrote $out_txt"

exit $rc
