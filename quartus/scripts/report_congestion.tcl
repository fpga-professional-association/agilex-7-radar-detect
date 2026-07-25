# ---------------------------------------------------------------------------
# report_congestion.tcl — routing congestion / high-fanout / interconnect
# Governing spec: SPEC.md 17 (Physical implementation), 21 (bottleneck
# classification).
#
# Usage:
#   quartus_sta -t report_congestion.tcl
#
# Collects: congestion regions, high-fanout nets, longest interconnect paths.
#
# Availability note (a real Pro-flow constraint, not a shortcut): all three come
# from placement and routing, so nothing exists before the Fitter has run.
# Quartus Pro exposes no "congestion map" Tcl API; what IS scriptable is
# per-path physical data from the post-fit timing netlist —
# get_path_info -congestion_level / -max_fanout / -num_wires / -ic_delay — plus
# report_bottleneck, which ranks the nodes that dominate the failing-path
# population. Those are used here. Without a fit the script writes a clearly
# labelled "requires fit" fragment and exits 0, so `make quartus-report` after a
# bare `make quartus-map` still yields a valid JSON record.
# ---------------------------------------------------------------------------

source [file join [file dirname [info script]] common.tcl]

package require ::quartus::project
package require ::quartus::sta

bench::ensure_dirs
bench::open_project

set congestion [dict create]
set notes {}

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
    dict set congestion available 0
    dict set congestion notes [linsert $notes 0 \
        "congestion data requires a completed Fitter run — run `make quartus-fit` first"]
    bench::frag_save congestion $congestion
    set fh [bench::text_report_open congestion]
    puts $fh "Congestion report unavailable — requires a completed Fitter run."
    foreach n [dict get $congestion notes] { puts $fh "  - $n" }
    close $fh
    bench::close_project
    bench::log "congestion report degraded: requires fit"
    exit 0
}

dict set congestion available 1

proc node_name {id} {
    set n ""
    catch {set n [get_node_info -name $id]}
    return $n
}
proc pinfo {p opt} {
    set v ""
    catch {set v [get_path_info $p $opt]}
    return $v
}

# Severity order for the -congestion_level ordinal. Unknown labels rank above
# everything named here so a new Quartus label is never silently ignored.
proc congestion_rank {level} {
    if {$level eq ""} { return -1 }
    set order {none low moderate medium high critical}
    set i [lsearch -exact $order [string tolower [string trim $level]]]
    if {$i < 0} { return 99 }
    return $i
}

# ---------------------------------------------------------------------------
# Per-path physical data over the worst setup paths
# ---------------------------------------------------------------------------
set sample_n 200
set rows {}
set max_congestion ""
set max_fanout_seen ""
set ic_ratio_sum 0.0
set ic_ratio_n 0

catch {
    set paths [get_timing_paths -setup -npaths $sample_n -detail path_only]
    foreach_in_collection p $paths {
        set ic   [pinfo $p -ic_delay]
        set cell [pinfo $p -cell_delay]
        set cong [pinfo $p -congestion_level]
        set fo   [pinfo $p -max_fanout]
        set nw   [pinfo $p -num_wires]
        set slack [pinfo $p -slack]
        set from [node_name [pinfo $p -from]]
        set to   [node_name [pinfo $p -to]]

        if {$ic ne "" && $cell ne "" && [string is double -strict $ic] \
            && [string is double -strict $cell] && ($ic + $cell) > 0} {
            set ic_ratio_sum [expr {$ic_ratio_sum + ($ic / ($ic + $cell))}]
            incr ic_ratio_n
        }
        # -congestion_level is an ordinal STRING ("Low"/"Moderate"/"High"/...),
        # not a number, so rank it explicitly instead of comparing text.
        if {$cong ne ""} {
            set r [congestion_rank $cong]
            if {$r > [congestion_rank $max_congestion]} { set max_congestion $cong }
        }
        if {$fo ne "" && [string is double -strict $fo]} {
            if {$max_fanout_seen eq "" || $fo > $max_fanout_seen} { set max_fanout_seen $fo }
        }
        lappend rows [dict create \
            slack_ns         [bench::round $slack 4] \
            ic_delay_ns      [bench::round $ic 4] \
            cell_delay_ns    [bench::round $cell 4] \
            congestion_level $cong \
            max_fanout       $fo \
            num_wires        $nw \
            source_node      $from \
            destination_node $to \
        ]
    }
}

set paths_sampled [llength $rows]
if {$paths_sampled == 0} {
    lappend notes "no timing paths returned; the design may be trivially small or unrouted"
}

set mean_ic_ratio ""
if {$ic_ratio_n > 0} {
    set mean_ic_ratio [bench::round [expr {$ic_ratio_sum / $ic_ratio_n}] 4]
}

# --- longest interconnect paths (top 10 by routing delay) -------------------
set pairs {}
foreach r $rows {
    set ic [dict get $r ic_delay_ns]
    if {$ic eq ""} { set ic 0 }
    lappend pairs [list $ic $r]
}
set pairs [lsort -real -decreasing -index 0 $pairs]
set longest {}
foreach pr [lrange $pairs 0 9] { lappend longest [lindex $pr 1] }

# --- high-fanout paths (top 10 by max fanout) -------------------------------
set pairs {}
foreach r $rows {
    set fo [dict get $r max_fanout]
    if {$fo eq "" || ![string is double -strict $fo]} { set fo 0 }
    lappend pairs [list $fo $r]
}
set pairs [lsort -real -decreasing -index 0 $pairs]
set high_fanout {}
foreach pr [lrange $pairs 0 9] { lappend high_fanout [lindex $pr 1] }

# ---------------------------------------------------------------------------
# Bottleneck ranking (nodes dominating the failing-path population)
# ---------------------------------------------------------------------------
set bottleneck_txt ""
if {[catch {set bottleneck_txt [report_bottleneck -stdout]} err]} {
    set bottleneck_txt "unavailable: $err"
    lappend notes "report_bottleneck unavailable: [string range $err 0 200]"
}

set net_delay_txt ""
catch {set net_delay_txt [report_net_delay -stdout]}

dict set congestion paths_sampled           $paths_sampled
dict set congestion max_congestion_level    $max_congestion
dict set congestion max_fanout              $max_fanout_seen
dict set congestion mean_routing_delay_ratio $mean_ic_ratio
dict set congestion longest_interconnect_paths $longest
dict set congestion high_fanout_paths       $high_fanout
dict set congestion notes                   $notes

bench::frag_save congestion $congestion

# ---------------------------------------------------------------------------
# Human-readable evidence report
# ---------------------------------------------------------------------------
proc dump_rows {fh title rowlist} {
    puts $fh ""
    puts $fh "-- $title ---------------------------------------------------------"
    if {[llength $rowlist] == 0} {
        puts $fh "    (none)"
        return
    }
    foreach r $rowlist {
        puts $fh [format "    slack=%-9s ic=%-9s cell=%-9s cong=%-6s fanout=%-6s wires=%-5s" \
            [dict get $r slack_ns] [dict get $r ic_delay_ns] [dict get $r cell_delay_ns] \
            [dict get $r congestion_level] [dict get $r max_fanout] [dict get $r num_wires]]
        puts $fh "        from: [dict get $r source_node]"
        puts $fh "        to  : [dict get $r destination_node]"
    }
}

set fh [bench::text_report_open congestion]
puts $fh "paths sampled              : $paths_sampled"
puts $fh "max congestion level       : $max_congestion"
puts $fh "max fanout                 : $max_fanout_seen"
puts $fh "mean routing/total delay   : $mean_ic_ratio"
dump_rows $fh "longest interconnect paths (top 10 by routing delay)" $longest
dump_rows $fh "high-fanout paths (top 10)" $high_fanout
puts $fh ""
puts $fh "-- report_bottleneck --------------------------------------------------"
puts $fh $bottleneck_txt
puts $fh ""
puts $fh "-- report_net_delay ---------------------------------------------------"
puts $fh $net_delay_txt
if {[llength $notes] > 0} {
    puts $fh ""
    puts $fh "-- notes --------------------------------------------------------------"
    foreach n $notes { puts $fh "    - $n" }
}
close $fh

bench::close_project
bench::log "congestion report complete"
exit 0
