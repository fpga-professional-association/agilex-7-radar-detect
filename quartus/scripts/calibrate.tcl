# ---------------------------------------------------------------------------
# calibrate.tcl — one SPEC 18 resource-calibration point
# Governing spec: SPEC.md 15, 17, 18, 23.
#
# Usage:
#   quartus_sh  -t calibrate.tcl compile <kernel> <point_id> [NAME=VALUE ...] [--seed N]
#   quartus_sta -t calibrate.tcl sta     <kernel> <point_id>
#
# <kernel>    names a calibration project under quartus/calibration/:
#             quartus/calibration/<kernel>_calib.{qpf,qsf,sdc}. The top-level
#             entity is read FROM the project, not hardcoded here, so adding the
#             SPEC 18 kernels that follow the complex multiplier — a FIR lane, a
#             PFB, an FFT stage, a beam, an M20K bank, a packet stage, an async
#             FIFO — is a new qpf/qsf/sdc triple and nothing else. Nothing below
#             this line mentions the complex multiplier.
# <point_id>  a filesystem-safe label for this parameter combination. Names the
#             output directory; the parameters themselves are recorded in it.
# NAME=VALUE  elaboration parameters applied to the top-level entity with
#             `set_parameter`. Integers only, by convention: see
#             quartus/calibration/cmult_wrap.sv for why a string parameter is
#             not swept directly.
#
# Two phases because the data lives behind two different APIs. Resource panels
# need `load_report`, which is a quartus_sh facility; Fmax, slack and the
# critical path need the ::quartus::sta timing netlist. This is the same split
# the Makefile already makes between report_utilization.tcl (quartus_sh) and
# report_sta.tcl (quartus_sta), and scripts/run_calibration.py drives both.
#
# Output: results/synthesis/calibration/<kernel>/<point_id>/
#     compile.kv       key<TAB>value, one per line, from the compile phase
#     timing.kv        the same from the STA phase
#     resource.txt     every row of the resource panel, verbatim
#     entity.txt       resource utilization by entity, verbatim
#     panels.txt       every report panel name (so a missing number can be found)
#     retiming.txt     retiming limits, restrictions and pipelining info
#     sta_*.txt        the raw Quartus tables the numbers were parsed out of
#
# A flat key/value text file rather than a Tcl dict fragment because the consumer
# is Python (scripts/run_calibration.py) and a tab-separated line is the one
# format both languages read without a parser. The raw panels are kept beside the
# parsed numbers so that "Quartus mapped it differently than expected" is
# answerable from the evidence rather than by re-running the sweep — which is the
# entire point of a calibration phase.
#
# EVERYTHING under results/ is generated and is never committed (PLAN.md standing
# rule 3). The summary that survives is the JSON record and, compactly,
# DECISIONS.md.
# ---------------------------------------------------------------------------

source [file join [file dirname [info script]] common.tcl]

package require ::quartus::project

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
if {[llength $quartus(args)] < 3} {
    puts stderr "ERROR: usage: calibrate.tcl <compile|sta> <kernel> <point_id> \[NAME=VALUE ...\] \[--seed N\]"
    exit 2
}

set phase    [string tolower [lindex $quartus(args) 0]]
set kernel   [lindex $quartus(args) 1]
set point_id [lindex $quartus(args) 2]
set rest     [lrange $quartus(args) 3 end]

if {[lsearch -exact {compile sta} $phase] < 0} {
    puts stderr "ERROR: unknown phase '$phase'. Expected 'compile' or 'sta'"
    exit 2
}

set calib_seed 1
set calib_projdir ""
set params [dict create]
for {set i 0} {$i < [llength $rest]} {incr i} {
    set tok [lindex $rest $i]
    if {$tok eq "--seed"} {
        incr i
        set calib_seed [lindex $rest $i]
        continue
    }
    # --projdir lets the driver point at a per-point COPY of the calibration
    # project so that several points can compile at once without sharing a
    # database directory. The copy is byte-identical to the tracked project; only
    # its location differs, and the location is recorded in the point's record.
    if {$tok eq "--projdir"} {
        incr i
        set calib_projdir [lindex $rest $i]
        continue
    }
    set eq [string first "=" $tok]
    if {$eq < 1} {
        puts stderr "ERROR: cannot parse argument '$tok'; expected NAME=VALUE"
        exit 2
    }
    dict set params [string range $tok 0 [expr {$eq - 1}]] \
                    [string range $tok [expr {$eq + 1}] end]
}
if {![string is integer -strict $calib_seed]} {
    puts stderr "ERROR: seed must be an integer, got '$calib_seed'"
    exit 2
}

# ---------------------------------------------------------------------------
# Paths — the calibration project overrides the bench:: defaults, which point at
# the benchmark project. Everything else in common.tcl (version detection, the
# numeric scrubber, rounding, the qsf snapshot) is reused unchanged.
# ---------------------------------------------------------------------------
if {$calib_projdir ne ""} {
    set bench::proj_dir [file normalize $calib_projdir]
} else {
    set bench::proj_dir [file join $bench::repo_root quartus calibration]
}
set bench::project  ${kernel}_calib
set bench::revision ${kernel}_calib
set bench::qsf      [file join $bench::proj_dir ${bench::project}.qsf]
set bench::out_dir  [file join $bench::proj_dir output_files]

set point_dir [file join $bench::repo_root results synthesis calibration \
                         $kernel $point_id]
file mkdir $point_dir

namespace eval calib {}
proc calib::log {msg} { puts "\[calib\] $msg" }

# --- key/value output -------------------------------------------------------
set KV [dict create]

proc kv {key value} {
    # Newlines and tabs would break the one-record-per-line contract.
    set v [string map [list "\n" " " "\t" " " "\r" " "] $value]
    dict set ::KV $key [string trim $v]
}

proc kv_write {path} {
    set fh [open $path w]
    fconfigure $fh -translation lf
    puts $fh "# generated by quartus/scripts/calibrate.tcl — do not edit"
    puts $fh "# format: key<TAB>value, one per line"
    foreach k [lsort [dict keys $::KV]] {
        puts $fh "$k\t[dict get $::KV $k]"
    }
    close $fh
    calib::log "wrote [file tail $path] ([dict size $::KV] keys)"
}

proc text_write {path header lines} {
    set fh [open $path w]
    fconfigure $fh -translation lf
    puts $fh "# $header"
    foreach l $lines { puts $fh $l }
    close $fh
}

kv phase           $phase
kv kernel          $kernel
kv point_id        $point_id
kv seed            $calib_seed
kv device          $bench::device
kv quartus_version [bench::quartus_version_short]
kv quartus_version_full [bench::quartus_version]
kv commit          [bench::git_commit]
kv timestamp       [clock format [clock seconds] -format {%Y-%m-%dT%H:%M:%S}]
kv project_dir     $bench::proj_dir
dict for {k v} $params { kv "param_$k" $v }

# ===========================================================================
# Phase: compile
# ===========================================================================
if {$phase eq "compile"} {

    package require ::quartus::flow

    # qsf preservation.
    #
    # Unlike quartus/scripts/compile.tcl, this phase MUST let Quartus export the
    # in-memory assignment database: exporting it is how a `set_parameter` value
    # reaches the quartus_syn process. So the byte-level snapshot/restore is the
    # primary defence here rather than the backup one, and it runs on the error
    # path too. What is restored is the hand-maintained file, with no parameter,
    # no seed and no tool bookkeeping left behind.
    bench::qsf_snapshot

    set rc 0
    set fatal ""
    set stages {}
    set syn_seconds ""
    set fit_seconds ""

    if {[catch {
        bench::open_project

        set top [get_global_assignment -name TOP_LEVEL_ENTITY]
        kv top $top
        calib::log "kernel=$kernel point=$point_id top=$top device=$bench::device"

        # Elaboration parameters for this point.
        dict for {name value} $params {
            calib::log "set_parameter $name = $value"
            set_parameter -name $name $value
        }

        # --- Analysis & Synthesis. Assignments ARE exported here (see above).
        set t0 [clock milliseconds]
        execute_module -tool syn
        set syn_seconds [bench::round [expr {([clock milliseconds] - $t0) / 1000.0}] 1]
        lappend stages syn

        # --- Fitter. The seed is a command-line argument, never an assignment,
        # and the Fitter is forbidden from writing settings back.
        set t0 [clock milliseconds]
        execute_module -tool fit -dont_export_assignments \
            -args "--seed=$calib_seed --write_settings_files=off"
        set fit_seconds [bench::round [expr {([clock milliseconds] - $t0) / 1000.0}] 1]
        lappend stages fit
    } err]} {
        set fatal $err
        set rc 1
        calib::log "FATAL: $err"
    }

    kv syn_seconds      $syn_seconds
    kv fit_seconds      $fit_seconds
    kv stages_completed [join $stages ","]
    kv fatal            $fatal

    # --- error / warning counts, from the module reports ---------------------
    set errors 0
    set warnings 0
    foreach tool {syn fit} {
        foreach name [list ${bench::revision}.${tool}.rpt] {
            set p [file join $bench::out_dir $name]
            if {![file exists $p]} { continue }
            set fh [open $p r]
            set txt [read $fh]
            close $fh
            if {[regexp {([0-9]+) error[s]?, ([0-9]+) warning[s]?} $txt -> e w]} {
                incr errors $e
                incr warnings $w
            }
        }
    }
    kv errors   $errors
    kv warnings $warnings

    # --- report panels -------------------------------------------------------
    package require ::quartus::report

    set panels {}
    if {[catch {load_report} lerr]} {
        calib::log "WARNING: load_report failed: $lerr"
        kv report_note "load_report failed: $lerr"
    } else {
        catch {set panels [get_report_panel_names]}
    }
    text_write [file join $point_dir panels.txt] \
        "every report panel name after syn+fit" $panels

    proc find_panel {panels patterns} {
        foreach pat $patterns {
            foreach n $panels {
                if {[string match -nocase $pat $n]} { return $n }
            }
        }
        return ""
    }

    proc panel_rows {panel} {
        set rows {}
        if {$panel eq ""} { return $rows }
        set nrows 0
        if {[catch {set nrows [get_number_of_rows -name $panel]}]} { return $rows }
        for {set r 0} {$r < $nrows} {incr r} {
            if {[catch {set row [get_report_panel_row -name $panel -row $r]}]} { continue }
            lappend rows $row
        }
        return $rows
    }

    set fit_panel [find_panel $panels {
        {*Fitter*Resource Usage Summary*}
        {*Fitter Resource Usage Summary*}
        {*Fitter*Summary*Resource*}
    }]
    set syn_panel [find_panel $panels {
        {*Synthesis*Resource Usage Summary*}
        {*Analysis & Synthesis Resource Usage Summary*}
    }]
    set ent_panel [find_panel $panels {
        {*Fitter*Resource Utilization by Entity*}
        {*Resource Utilization by Entity*}
    }]
    set par_panel [find_panel $panels {
        {*Parameter Settings by Entity Instance*}
        {*Parameter Settings*}
    }]

    set panel $fit_panel
    set source_stage fit
    if {$panel eq ""} {
        set panel $syn_panel
        set source_stage syn
    }
    kv resource_panel $panel
    kv resource_source_stage $source_stage

    set rows [panel_rows $panel]
    set flat {}
    set kvmap [dict create]
    foreach row $rows {
        lappend flat [join $row " | "]
        if {[llength $row] < 2} { continue }
        dict set kvmap [string trim [lindex $row 0]] [string trim [lindex $row 1]]
    }
    text_write [file join $point_dir resource.txt] \
        "resource panel: $panel" $flat

    proc kv_num_of {kvmap patterns} {
        foreach pat $patterns {
            dict for {label value} $kvmap {
                if {[string match -nocase $pat $label]} {
                    set n [bench::num $value]
                    if {$n ne ""} { return $n }
                }
            }
        }
        return ""
    }

    kv alm_used     [kv_num_of $kvmap {{Logic utilization (ALMs needed*} {ALMs needed*} \
                                       {*ALMs used*} {*Total ALMs*}}]
    kv alm_reg_used [kv_num_of $kvmap {{Dedicated logic registers} {*Dedicated logic registers*} \
                                       {*ALM registers*} {*Total registers*}}]
    kv dsp_used     [kv_num_of $kvmap {{DSP Blocks Needed*} {*Total DSP Blocks*} {*DSP Blocks*}}]
    kv m20k_used    [kv_num_of $kvmap {{M20K blocks} {*M20K blocks*}}]
    kv mlab_used    [kv_num_of $kvmap {{*Memory LABs*} {*MLAB blocks*}}]
    kv pins_used    [kv_num_of $kvmap {{I/O pins} {*I/O pins*}}]
    kv combinational_aluts [kv_num_of $kvmap {{*Combinational ALUT*}}]

    # Total port count, from Analysis & Synthesis, so the virtual-pin count is
    # the difference rather than an assumption.
    if {$syn_panel ne "" && $syn_panel ne $panel} {
        set syn_rows [panel_rows $syn_panel]
        set syn_kv [dict create]
        set syn_flat {}
        foreach row $syn_rows {
            lappend syn_flat [join $row " | "]
            if {[llength $row] < 2} { continue }
            dict set syn_kv [string trim [lindex $row 0]] [string trim [lindex $row 1]]
        }
        text_write [file join $point_dir resource_syn.txt] \
            "synthesis resource panel: $syn_panel" $syn_flat
        set syn_pins [kv_num_of $syn_kv {{I/O pins} {*I/O pins*}}]
        kv syn_pins $syn_pins
        set fit_pins [dict get $::KV pins_used]
        if {$syn_pins ne "" && $fit_pins ne ""} {
            kv virtual_pins [expr {int($syn_pins) - int($fit_pins)}]
        }
    }

    # --- DSP detail ----------------------------------------------------------
    # SPEC 18 asks for "DSP mapping", not just a block count: how many 18x19
    # multipliers, in which mode, fused or not. The label set differs between
    # device families and Quartus releases, so every row whose label mentions a
    # multiplier or a DSP mode is captured VERBATIM alongside the parsed numbers.
    # "Report what it did" is the deliverable when the mapping is a surprise.
    set dsp_rows {}
    foreach row $rows {
        if {[llength $row] < 1} { continue }
        set label [string trim [lindex $row 0]]
        if {[string match -nocase "*DSP*" $label] ||
            [string match -nocase "*Mult*" $label] ||
            [string match -nocase "*18x19*" $label] ||
            [string match -nocase "*19x18*" $label] ||
            [string match -nocase "*27x27*" $label]} {
            lappend dsp_rows [join $row " | "]
        }
    }
    set dsp_panel [find_panel $panels {
        {*DSP Block Usage Summary*}
        {*DSP Blocks*Summary*}
        {*Multiplier*Summary*}
    }]
    if {$dsp_panel ne ""} {
        kv dsp_panel $dsp_panel
        # Every mode row becomes its own key, named after the label Quartus used.
        # Measured on this device and release the labels are "Sum of Two 18x18",
        # "Total number of DSP blocks" and "Fixed Point Signed Multiplier"; on
        # another device or release they will be different, and recording them by
        # their own names is what keeps this script from having to be right about
        # them in advance.
        foreach row [panel_rows $dsp_panel] {
            lappend dsp_rows "\[dsp panel\] [join $row { | }]"
            if {[llength $row] < 2} { continue }
            set label [string trim [lindex $row 0]]
            set value [bench::num [lindex $row 1]]
            if {$label eq "" || $value eq "" ||
                [string equal -nocase $label "Statistic"]} { continue }
            set key [string tolower $label]
            regsub -all {[^a-z0-9]+} $key "_" key
            set key [string trim $key "_"]
            kv "dspmode_$key" $value
        }
    }
    text_write [file join $point_dir dsp.txt] \
        "every resource row mentioning a DSP block or a multiplier" $dsp_rows
    kv dsp_detail_rows [llength $dsp_rows]

    # The named quantities SPEC 18 asks for by name. Both label families are
    # tried because the native DSP multiplier width is spelled differently in
    # different Quartus reports (18x18 in the synthesis mode summary, 18x19 in
    # the architecture documentation); whichever exists is recorded, and dsp.txt
    # holds the verbatim rows either way.
    kv mult_18x19 [kv_num_of $kvmap {{*18x19*} {*19x18*} {*18x18*}}]
    kv mult_27x27 [kv_num_of $kvmap {{*27x27*}}]

    # --- resource by entity --------------------------------------------------
    set ent_rows [panel_rows $ent_panel]
    set ent_flat {}
    foreach row $ent_rows { lappend ent_flat [join $row " | "] }
    text_write [file join $point_dir entity.txt] \
        "resource utilization by entity: $ent_panel" $ent_flat
    kv entity_panel $ent_panel
    kv entity_rows  [llength $ent_rows]

    # The kernel instance's own row, so the wrapper's constant boundary-register
    # overhead can be separated from the kernel's own cost. Matched on the
    # instance name the wrapper gives it, which is the same in both generate
    # branches. Columns are located by their HEADER LABEL rather than by index:
    # the by-entity table has nineteen columns on this release and there is no
    # reason to bet on that number.
    if {[llength $ent_rows] > 1} {
        set hdr [lindex $ent_rows 0]
        foreach row [lrange $ent_rows 1 end] {
            if {[llength $row] < 2} { continue }
            if {![string match -nocase "*u_kernel*" [lindex $row 0]]} { continue }
            kv kernel_entity_row [join $row " | "]
            foreach {key pat} {kernel_alm_used     {ALMs needed*}
                               kernel_comb_aluts   {Combinational ALUT*}
                               kernel_alm_reg_used {Dedicated Logic Register*}
                               kernel_m20k_used    {M20K*}
                               kernel_dsp_used     {DSP Blocks needed*}} {
                for {set c 0} {$c < [llength $hdr]} {incr c} {
                    if {[string match -nocase $pat [string trim [lindex $hdr $c]]]} {
                        kv $key [bench::num [lindex $row $c]]
                        break
                    }
                }
            }
            break
        }
    }

    # --- parameter settings, as Quartus actually elaborated them -------------
    # Evidence that the sweep's `set_parameter` calls took effect. Without this a
    # sweep whose parameters silently did not apply would produce twelve
    # identical records and look like a result.
    set par_rows [panel_rows $par_panel]
    set par_flat {}
    foreach row $par_rows { lappend par_flat [join $row " | "] }
    text_write [file join $point_dir parameters.txt] \
        "parameter settings by entity instance: $par_panel" $par_flat
    kv parameter_panel $par_panel
    kv parameter_rows  [llength $par_rows]

    # --- retiming limits, read HERE and not in the STA phase ------------------
    # The Fitter's "Retiming Limit Summary" is a report panel, and the report
    # database is a quartus_sh facility: measured on this install, `load_report`
    # in a quartus_sta session finds no panels at all. So the authoritative
    # statement of WHY retiming stopped where it did is read in the compile
    # phase, where the panel exists, rather than being reported as unavailable
    # from a session that was never going to see it.
    set limit_panel [find_panel $panels {{*Retiming Limit Summary*}}]
    kv retiming_limit_panel $limit_panel
    set limit_rows [panel_rows $limit_panel]
    set limit_flat {}
    foreach row $limit_rows { lappend limit_flat [join $row " | "] }
    text_write [file join $point_dir retiming_limits.txt] \
        "Fitter retiming limit summary: $limit_panel" $limit_flat
    if {[llength $limit_rows] > 1} {
        set hdr [lindex $limit_rows 0]
        set row [lindex $limit_rows 1]
        kv retiming_limit_domain [string trim [lindex $row 0]]
        for {set c 1} {$c < [llength $hdr]} {incr c} {
            set h [string trim [lindex $hdr $c]]
            if {$h eq ""} { continue }
            set key [string tolower $h]
            regsub -all {[^a-z0-9]+} $key "_" key
            kv "retiming_[string trim $key _]" [string trim [lindex $row $c]]
        }
    } else {
        kv retiming_note "Retiming Limit Summary panel unavailable or empty"
    }

    catch {unload_report}
    bench::close_project
    bench::qsf_restore
    calib::log "restored pristine qsf"

    kv_write [file join $point_dir compile.kv]

    if {$rc != 0} {
        puts stderr "ERROR: calibration compile failed for point '$point_id': $fatal"
    }
    exit $rc
}

# ===========================================================================
# Phase: sta
# ===========================================================================
package require ::quartus::sta

# The STA phase needs the qsf snapshot too, and for a reason that is easy to
# miss: `project_close` exports the in-memory assignment database, and by the
# time a project has been opened that database carries Quartus's own defaults
# (LAST_QUARTUS_VERSION, PWRMGT_*, AUTO_OPEN_DRAIN_PINS). Measured during
# development: without this, a read-only STA run left four assignments behind in
# a hand-maintained file it never intended to modify. Snapshot here, restore just
# before exit, on every path.
bench::qsf_snapshot

bench::open_project
kv top [get_global_assignment -name TOP_LEVEL_ENTITY]

# The Fitter's Retiming Limit Summary is read in the COMPILE phase, where the
# report database lives; see the note there. This phase contributes the retiming
# evidence that only the timing netlist can produce: the register statistics
# (including the Hyper-Register count, which is how much of the pipeline the
# retimer moved into the routing), the restriction table, and the pipelining
# report.

set netlist_ok 1
if {[catch {create_timing_netlist} err]} {
    set netlist_ok 0
    kv sta_note "create_timing_netlist failed: $err"
}
if {$netlist_ok} {
    catch {read_sdc}
    if {[catch {update_timing_netlist} err]} {
        set netlist_ok 0
        kv sta_note "update_timing_netlist failed: $err"
    }
}
kv sta_available $netlist_ok

proc capture {name cmd} {
    set path [file join $::point_dir "sta_${name}.txt"]
    catch {file delete -force $path}
    if {[catch {eval [concat $cmd [list -file $path]]} err]} { return "" }
    if {![file exists $path]} { return "" }
    set fh [open $path r]
    set txt [read $fh]
    close $fh
    return $txt
}

proc table_rows {txt} {
    set out {}
    foreach line [split $txt \n] {
        set line [string trim $line]
        if {[string index $line 0] ne ";"} { continue }
        set cells {}
        foreach c [split $line ";"] { lappend cells [string trim $c] }
        lappend out [lrange $cells 1 end-1]
    }
    return $out
}

if {$netlist_ok} {
    # --- constraint ----------------------------------------------------------
    foreach_in_collection clk [get_clocks] {
        set name [get_clock_info $clk -name]
        set period ""
        catch {set period [get_clock_info $clk -period]}
        kv clock_name  $name
        kv period_ns   [bench::round $period 4]
        if {$period ne "" && [string is double -strict $period] && $period > 0} {
            kv constraint_mhz [bench::round [expr {1000.0 / $period}] 3]
        }
        break
    }

    # --- Fmax (SPEC 17 names this API explicitly) ---------------------------
    if {![catch {set fmax_rows [get_clock_fmax_info]}]} {
        foreach row $fmax_rows {
            kv fmax_clock           [lindex $row 0]
            kv fmax_mhz             [bench::round [bench::num [lindex $row 1]] 3]
            kv restricted_fmax_mhz  [bench::round [bench::num [lindex $row 2]] 3]
            if {[llength $row] > 3} { kv fmax_note [lindex $row 3] }
            break
        }
    } else {
        kv fmax_note "get_clock_fmax_info failed"
    }

    # --- slack ---------------------------------------------------------------
    foreach {kind wns tns} {setup wns_ns tns_ns hold hold_wns_ns hold_tns_ns} {
        set txt [capture "summary_$kind" [list create_timing_summary -$kind]]
        foreach row [table_rows $txt] {
            if {[llength $row] < 2} { continue }
            set cname [lindex $row 0]
            if {$cname eq "" || [string equal -nocase $cname "Clock"]} { continue }
            set slack [bench::num [lindex $row 1]]
            if {$slack eq ""} { continue }
            kv $wns [bench::round $slack 4]
            if {[llength $row] >= 3} { kv $tns [bench::round [bench::num [lindex $row 2]] 4] }
            break
        }
    }

    # --- critical path -------------------------------------------------------
    # Source and destination hierarchy are recorded so that "the reported Fmax is
    # a property of the kernel" can be CHECKED rather than assumed: a critical
    # path that starts or ends at a boundary register means the sweep measured
    # the wrapper, and run_calibration.py flags that.
    set path ""
    catch {
        set c [get_timing_paths -setup -npaths 1 -detail full_path]
        foreach_in_collection p $c { set path $p; break }
    }
    if {$path ne ""} {
        proc pinfo {p opt} {
            set v ""
            catch {set v [get_path_info $p $opt]}
            return $v
        }
        proc nname {id} {
            set n ""
            catch {set n [get_node_info -name $id]}
            return $n
        }
        set from [nname [pinfo $path -from]]
        set to   [nname [pinfo $path -to]]
        kv critical_slack_ns     [bench::round [pinfo $path -slack] 4]
        kv logic_depth           [pinfo $path -num_logic_levels]
        kv data_delay_ns         [bench::round [pinfo $path -data_delay] 4]
        kv cell_delay_ns         [bench::round [pinfo $path -cell_delay] 4]
        kv routing_delay_ns      [bench::round [pinfo $path -ic_delay] 4]
        kv clock_skew_ns         [bench::round [pinfo $path -clock_skew] 4]
        kv critical_source       $from
        kv critical_destination  $to
    }

    # --- register-to-register Fmax: THE calibration number -------------------
    #
    # Quartus's own restricted Fmax is computed from the worst setup slack in the
    # whole design, and in a virtual-pin harness that is an OUTPUT-PORT path, not
    # a fabric path. The reason is structural and is not a constraint bug: a
    # port is timed against the clock at the clk pin, while the register driving
    # it sees the clock after the global network's insertion delay, so every
    # output path carries that insertion delay as negative clock skew. Measured
    # here: about -2.5 ns against a 1.666 ns period. No fitter can fix it,
    # because there is no pin — and in the real design there is no pin either:
    # the block on the other side of this boundary is on the same clock network
    # and sees the same insertion delay.
    #
    # So the sweep's headline Fmax is the REGISTER-TO-REGISTER number below,
    # computed from the worst setup slack over paths whose two ends are both
    # registers. That is the fabric measurement SPEC 18 asks for. Quartus's
    # whole-design number is recorded too, unaltered and clearly named, so
    # nothing is hidden and the two can be compared.
    #
    # Note what is NOT done here: no false path, no multicycle path, no clock
    # group, and no relaxation of the port constraints (SPEC 24). The ports stay
    # fully constrained — unconstrained_paths below is checked to be zero — and
    # the I/O paths keep failing. They are simply not what is being measured.
    set r2r_path ""
    catch {
        set c [get_timing_paths -setup -from [all_registers] -to [all_registers] \
                   -npaths 1 -detail full_path]
        foreach_in_collection p $c { set r2r_path $p; break }
    }
    if {$r2r_path ne ""} {
        set r2r_slack [get_path_info $r2r_path -slack]
        kv reg2reg_wns_ns [bench::round $r2r_slack 4]
        set per [dict get $::KV period_ns]
        if {$per ne "" && [string is double -strict $per] &&
            [string is double -strict $r2r_slack] && ($per - $r2r_slack) > 0} {
            kv reg2reg_fmax_mhz [bench::round [expr {1000.0 / ($per - $r2r_slack)}] 3]
        }
        set rfrom ""
        set rto ""
        catch {set rfrom [get_node_info -name [get_path_info $r2r_path -from]]}
        catch {set rto   [get_node_info -name [get_path_info $r2r_path -to]]}
        kv reg2reg_source        $rfrom
        kv reg2reg_destination   $rto
        kv reg2reg_logic_depth   [get_path_info $r2r_path -num_logic_levels]
        kv reg2reg_cell_delay_ns [bench::round [get_path_info $r2r_path -cell_delay] 4]
        kv reg2reg_routing_delay_ns [bench::round [get_path_info $r2r_path -ic_delay] 4]
        kv reg2reg_clock_skew_ns [bench::round [get_path_info $r2r_path -clock_skew] 4]
        # Whether the measured path actually touches the kernel. If it does not,
        # the point measured the wrapper and the record says so rather than
        # letting the number stand unqualified.
        kv reg2reg_in_kernel [expr {([string match "*u_kernel*" $rfrom] ||
                                     [string match "*u_kernel*" $rto]) ? 1 : 0}]
    } else {
        kv reg2reg_note "no register-to-register path found"
    }

    # --- retiming detail -----------------------------------------------------
    set retiming_text ""
    foreach {key cmd} {restrictions report_retiming_restrictions \
                       pipelining   report_pipelining_info \
                       registers    report_register_statistics} {
        set txt [capture "retiming_$key" [list $cmd]]
        if {[string trim $txt] ne ""} {
            append retiming_text "-- $key ------------------------------------\n"
            append retiming_text $txt
            append retiming_text "\n"
        }
    }
    set fh [open [file join $point_dir retiming.txt] w]
    fconfigure $fh -translation lf
    puts $fh "# retiming evidence for point $point_id"
    puts $fh "# (the Fitter Retiming Limit Summary is in retiming_limits.txt,"
    puts $fh "#  written by the compile phase where the report database exists)"
    puts $fh ""
    puts $fh $retiming_text
    close $fh

    # --- register statistics: how much did the Hyper-Retimer actually move? ---
    # SPEC 17 asks for retiming data and SPEC 23 makes it load-bearing. The row
    # for the whole design and the row for the kernel instance are both recorded:
    # a kernel whose registers all became Hyper-Registers has been retimed into
    # the routing, and one whose registers stayed put has not.
    set reg_txt [capture retiming_registers_parsed {report_register_statistics}]
    set reg_rows [table_rows $reg_txt]
    # The table's first ';' line is its TITLE, not its header; the header is the
    # row whose first cell names the hierarchy column. Finding it by name rather
    # than by position is what keeps this working when a release adds a line.
    set hdr {}
    set hdr_idx -1
    for {set r 0} {$r < [llength $reg_rows]} {incr r} {
        set cand [lindex $reg_rows $r]
        if {[llength $cand] > 1 &&
            [string match -nocase "*Compilation Hierarchy Node*" [lindex $cand 0]]} {
            set hdr $cand
            set hdr_idx $r
            break
        }
    }
    if {$hdr_idx >= 0} {
        foreach row [lrange $reg_rows [expr {$hdr_idx + 1}] end] {
            if {[llength $row] < 2} { continue }
            set node [string trim [lindex $row 0]]
            set prefix ""
            if {$node eq "|"} {
                set prefix "design"
            } elseif {[string match "*u_kernel*" $node]} {
                set prefix "kernel"
            } else {
                continue
            }
            foreach {key pat} {registers   {Register Count}
                               hyper_regs  {Hyper-Register Count}
                               sync_reset  {Synchronous Reset}
                               async_reset {Asynchronous Reset}
                               clock_enable {Clock Enable}} {
                for {set c 0} {$c < [llength $hdr]} {incr c} {
                    if {[string match -nocase $pat [string trim [lindex $hdr $c]]]} {
                        kv "${prefix}_$key" [bench::num [lindex $row $c]]
                        break
                    }
                }
            }
        }
    }

    # --- unconstrained endpoints (SPEC 2: must be zero) ----------------------
    set ucp_txt [capture ucp {report_ucp}]
    set total 0
    set seen 0
    foreach row [table_rows $ucp_txt] {
        if {[llength $row] < 2} { continue }
        set label [lindex $row 0]
        foreach want {{Illegal Clocks} {Unconstrained Clocks} \
                      {Unconstrained Input Ports} {Paths from Unconstrained Input Ports*} \
                      {Unconstrained Output Ports} {Paths to Unconstrained Output Ports*}} {
            if {[string match -nocase $want $label]} {
                foreach v [lrange $row 1 end] {
                    set n [bench::num $v]
                    if {$n ne ""} { set total [expr {$total + int($n)}]; set seen 1 }
                }
            }
        }
    }
    if {$seen} { kv unconstrained_paths $total }
}

bench::close_project
bench::qsf_restore
calib::log "restored pristine qsf"
kv_write [file join $point_dir timing.kv]
exit 0
