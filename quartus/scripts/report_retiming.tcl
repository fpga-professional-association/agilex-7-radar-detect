# ---------------------------------------------------------------------------
# report_retiming.tcl — HyperFlex retiming / pipelining extraction
# Governing spec: SPEC.md 17 (Physical implementation), 23 (HyperFlex rules).
#
# Usage:
#   quartus_sta -t report_retiming.tcl
#
# Collects: retiming restrictions, registers not retimed, DSP/RAM placement
# restrictions, pipelining information and Fast Forward / Design Assistant
# findings where the installed edition exposes them.
#
# Availability note (this is a real constraint of the Pro flow, not a
# shortcut): retiming data is produced BY THE FITTER. Nothing meaningful exists
# after Analysis & Synthesis alone. Fast Forward recommendations additionally
# require a retiming-enabled Fitter run and are only emitted for device
# families with HyperFlex registers. This script therefore probes each report
# command, records which ones produced data, and degrades to a clearly-labelled
# "requires fit" fragment instead of failing — so `make quartus-report` after a
# bare `make quartus-map` still yields a valid JSON record.
# ---------------------------------------------------------------------------

source [file join [file dirname [info script]] common.tcl]

package require ::quartus::project
package require ::quartus::sta
catch {package require ::quartus::report}

bench::ensure_dirs
bench::open_project

set retiming [dict create]
set notes {}
set sections [dict create]

# ---------------------------------------------------------------------------
# Fitter "Retiming Limit Summary" — the authoritative statement of WHY
# retiming stopped where it did, per clock domain. Read from the report
# database BEFORE the timing netlist is created, because load_report and the
# STA netlist do not coexist well in one session.
# ---------------------------------------------------------------------------
set limit_rows {}
set limit_panel ""
if {![catch {load_report}]} {
    catch {
        foreach n [get_report_panel_names] {
            if {[string match -nocase "*Retiming Limit Summary*" $n]} { set limit_panel $n; break }
        }
    }
    if {$limit_panel ne ""} {
        catch {
            set nrows [get_number_of_rows -name $limit_panel]
            for {set r 0} {$r < $nrows} {incr r} {
                lappend limit_rows [get_report_panel_row -name $limit_panel -row $r]
            }
        }
    }
    catch {unload_report}
}
if {[llength $limit_rows] <= 1} {
    lappend notes "Retiming Limit Summary panel unavailable (requires a completed fit with the Retime stage)"
}

# Per-clock limiting reason, keyed by the panel's "Clock Transfer" column.
set limits [dict create]
foreach row [lrange $limit_rows 1 end] {
    if {[llength $row] < 2} { continue }
    set domain [string trim [lindex $row 0]]
    dict set limits $domain [dict create \
        limiting_reason [string trim [lindex $row 1]] \
        recommendation  [expr {[llength $row] > 2 ? [string trim [lindex $row 2]] : ""}] \
    ]
}
dict set retiming retiming_limits       $limits
dict set retiming retiming_limit_panel  $limit_panel

# ---------------------------------------------------------------------------
# Timing netlist (post-fit)
# ---------------------------------------------------------------------------
set netlist_ok 1
if {[catch {create_timing_netlist} err]} {
    set netlist_ok 0
    lappend notes "requires fit: create_timing_netlist failed ($err)"
}
if {$netlist_ok} {
    catch {read_sdc}
    if {[catch {update_timing_netlist} err]} {
        set netlist_ok 0
        lappend notes "requires fit: update_timing_netlist failed ($err)"
    }
}

if {!$netlist_ok} {
    dict set retiming available 0
    dict set retiming notes [linsert $notes 0 \
        "retiming data requires a completed Fitter run — run `make quartus-fit` first"]
    bench::frag_save retiming $retiming
    set fh [bench::text_report_open retiming]
    puts $fh "Retiming report unavailable — requires a completed Fitter run."
    foreach n [dict get $retiming notes] { puts $fh "  - $n" }
    close $fh
    bench::close_project
    bench::log "retiming report degraded: requires fit"
    exit 0
}

dict set retiming available 1

# ---------------------------------------------------------------------------
# Probe each retiming-related report command.
# ---------------------------------------------------------------------------
# Each entry: <json key> <tcl command>. A command that does not exist in this
# edition, or that produces no data, is recorded as unavailable rather than
# silently dropped, so a later Quartus upgrade that adds data is visible as a
# change in the JSON.
#
# These commands emit through the message system and return nothing, so their
# text is only reachable via -file. A command that "succeeds" but writes no
# file produced no data and is recorded as unavailable — otherwise an empty
# section would masquerade as a clean result.
set probes {
    retiming_restrictions       report_retiming_restrictions
    hierarchical_restrictions   report_hierarchical_retiming_restrictions
    pipelining_info             report_pipelining_info
    register_statistics         report_register_statistics
    register_spread             report_register_spread
    reset_statistics            report_reset_statistics
    design_metrics              report_design_metrics
    logic_depth                 report_logic_depth
    max_clock_skew              report_max_clock_skew
}

set available {}
set unavailable {}

foreach {key cmd} $probes {
    set path [file join $bench::synth_dir "retiming_${key}.txt"]
    catch {file delete -force $path}
    set out ""
    set ok 1
    if {[catch {$cmd -file $path} err]} {
        set ok 0
        set out $err
    } elseif {[file exists $path]} {
        set fh [open $path r]
        set out [read $fh]
        close $fh
        if {[string trim $out] eq ""} {
            set ok 0
            set out "command ran but produced no data"
        }
    } else {
        set ok 0
        set out "command ran but wrote no report file"
    }
    if {$ok} {
        lappend available $key
    } else {
        lappend unavailable $key
        lappend notes "$key unavailable: [string range $out 0 200]"
    }
    dict set sections $key [dict create ok $ok text $out]
}

dict set retiming commands_available   $available
dict set retiming commands_unavailable $unavailable

# ---------------------------------------------------------------------------
# Registers not retimed / retiming deltas from the timing paths
# ---------------------------------------------------------------------------
# get_path_info exposes the per-endpoint retimer delta (how many registers the
# Fitter moved across a node). Counting nodes with a zero delta on the critical
# paths gives a direct "registers not retimed" signal without parsing text.
set retimed 0
set not_retimed 0
set unregistered_dsp 0
set unregistered_ram 0
set sampled 0

catch {
    set paths [get_timing_paths -setup -npaths 200 -detail path_only]
    foreach_in_collection p $paths {
        incr sampled
        set sd ""; set dd ""
        catch {set sd [get_path_info $p -src_node_retimer_dt]}
        catch {set dd [get_path_info $p -dst_node_retimer_dt]}
        foreach v [list $sd $dd] {
            if {$v eq "" || ![string is double -strict $v]} { continue }
            if {$v == 0} { incr not_retimed } else { incr retimed }
        }
        set u ""
        catch {set u [get_path_info $p -src_unregistered_dsp]}
        if {$u ne "" && $u} { incr unregistered_dsp }
        set u ""
        catch {set u [get_path_info $p -src_unregistered_ram]}
        if {$u ne "" && $u} { incr unregistered_ram }
    }
}

if {$sampled > 0 && $retimed == 0 && $not_retimed == 0} {
    lappend notes "per-endpoint retimer deltas (-src_node_retimer_dt / -dst_node_retimer_dt) returned no value for any sampled path; use the Fitter Retiming Limit Summary below as the authoritative retiming statement"
}

dict set retiming paths_sampled          $sampled
dict set retiming endpoints_retimed      $retimed
dict set retiming endpoints_not_retimed  $not_retimed
dict set retiming unregistered_dsp_paths $unregistered_dsp
dict set retiming unregistered_ram_paths $unregistered_ram

# ---------------------------------------------------------------------------
# Design Assistant findings — the Fitter writes these to DRC report files.
# ---------------------------------------------------------------------------
set da_files {}
foreach f [glob -nocomplain [file join $bench::out_dir *.drc.*.rpt]] {
    lappend da_files [file tail $f]
}
dict set retiming design_assistant_reports $da_files
if {[llength $da_files] == 0} {
    lappend notes "no Design Assistant DRC reports found in [file tail $bench::out_dir]"
}

dict set retiming notes $notes
bench::frag_save retiming $retiming

# ---------------------------------------------------------------------------
# Human-readable evidence report
# ---------------------------------------------------------------------------
set fh [bench::text_report_open retiming]
puts $fh "commands available   : [join $available {, }]"
puts $fh "commands unavailable : [join $unavailable {, }]"
puts $fh ""
puts $fh "paths sampled          : $sampled"
puts $fh "endpoints retimed      : $retimed"
puts $fh "endpoints not retimed  : $not_retimed"
puts $fh "unregistered DSP paths : $unregistered_dsp"
puts $fh "unregistered RAM paths : $unregistered_ram"
puts $fh ""
puts $fh ""
puts $fh "-- Fitter retiming limits (panel: $limit_panel) -----------------------"
if {[dict size $limits] == 0} {
    puts $fh "    (unavailable — requires a completed fit)"
} else {
    dict for {domain d} $limits {
        puts $fh "    $domain"
        puts $fh "        limiting reason : [dict get $d limiting_reason]"
        puts $fh "        recommendation  : [dict get $d recommendation]"
    }
}
puts $fh ""
puts $fh "Design Assistant DRC reports (quartus/project/output_files/):"
if {[llength $da_files] == 0} {
    puts $fh "    (none)"
} else {
    foreach f $da_files { puts $fh "    $f" }
}
dict for {key sec} $sections {
    puts $fh ""
    puts $fh "-- $key [string repeat - [expr {max(1, 68 - [string length $key])}]]"
    if {![dict get $sec ok]} { puts $fh "    UNAVAILABLE:" }
    puts $fh [dict get $sec text]
}
if {[llength $notes] > 0} {
    puts $fh ""
    puts $fh "-- notes --------------------------------------------------------------"
    foreach n $notes { puts $fh "    - $n" }
}
close $fh

bench::close_project
bench::log "retiming report complete"
exit 0
