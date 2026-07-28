# ---------------------------------------------------------------------------
# export_results.tcl — merge every report fragment into ONE JSON record
# Governing spec: SPEC.md 17 ("Export one JSON record per compile").
#
# Usage:
#   quartus_sh -t export_results.tcl [seed]
#
# Reads the fragments written by compile.tcl and the report_*.tcl scripts and
# emits a single JSON record matching the SPEC.md 17 schema:
#
#   commit, quartus_version, device, seed, configuration, verification_passed,
#   unconstrained_paths, utilization{alm_percent,m20k_percent,dsp_percent,...},
#   clocks{<name>{constraint_mhz,restricted_fmax_mhz,wns_ns,tns_ns,...}},
#   compile_seconds, notes[]
#
# plus the additional SPEC.md 17 collection fields (peak memory, stages
# completed, errors/warnings, resource-by-hierarchy, congestion, retiming).
#
# Output:
#   results/timing/compile_<timestamp>_seed<seed>.json   immutable per-compile
#   results/timing/latest.json                           stable copy for tools
#
# Schema tolerance: a field that the stage in question cannot produce is
# emitted as JSON null and the reason is appended to "notes". A map-only
# compile therefore produces a complete, valid record with null timing —
# scripts/parse_quartus.py accepts that and says so.
#
# Utilization percentages are computed against the SPEC.md 2 device totals:
#   1,305,600 ALMs / 5,222,400 ALM registers / 18,960 M20K / 12,300 DSP.
# ---------------------------------------------------------------------------

source [file join [file dirname [info script]] common.tcl]

set seed_arg ""
if {[info exists quartus(args)] && [llength $quartus(args)] >= 1} {
    set seed_arg [lindex $quartus(args) 0]
}

bench::ensure_dirs

# ---------------------------------------------------------------------------
# Minimal JSON writer
# ---------------------------------------------------------------------------
# Values are typed explicitly at the call site rather than guessed, so a device
# string that happens to look numeric never turns into a JSON number, and a
# missing measurement is null rather than an empty string that a consumer would
# have to special-case.
namespace eval json {}

proc json::esc {s} {
    set out ""
    foreach ch [split $s ""] {
        scan $ch %c code
        switch -- $ch {
            "\"" { append out "\\\"" }
            "\\" { append out "\\\\" }
            "\n" { append out "\\n" }
            "\r" { append out "\\r" }
            "\t" { append out "\\t" }
            default {
                if {$code < 32 || $code > 126} {
                    append out [format "\\u%04x" $code]
                } else {
                    append out $ch
                }
            }
        }
    }
    return $out
}

proc json::str {v}  { return "\"[json::esc $v]\"" }
proc json::null {}  { return "null" }

# A number, or null when the measurement is absent.
proc json::num {v} {
    if {$v eq "" || ![string is double -strict $v]} { return "null" }
    return $v
}

# An integer, or null.
proc json::int {v} {
    if {$v eq "" || ![string is double -strict $v]} { return "null" }
    return [expr {int(double($v))}]
}

proc json::bool {v} {
    if {$v eq "" } { return "null" }
    if {$v} { return "true" }
    return "false"
}

# A string, or null when empty.
proc json::strn {v} {
    if {$v eq ""} { return "null" }
    return [json::str $v]
}

proc json::array_of_str {lst} {
    if {[llength $lst] == 0} { return "\[\]" }
    set parts {}
    foreach e $lst { lappend parts [json::str $e] }
    return "\[[join $parts {, }]\]"
}

# Render a Tcl dict of already-rendered JSON values at the given indent.
proc json::obj {pairs indent} {
    if {[llength $pairs] == 0} { return "{}" }
    set pad [string repeat " " $indent]
    set inner [string repeat " " [expr {$indent + 2}]]
    set parts {}
    foreach {k v} $pairs {
        lappend parts "${inner}[json::str $k]: $v"
    }
    return "{\n[join $parts ",\n"]\n${pad}}"
}

# ---------------------------------------------------------------------------
# Load fragments
# ---------------------------------------------------------------------------
set REPORT [bench::frag_load_all]
set notes {}

proc frag {section {key ""} {default ""}} {
    global REPORT
    if {![dict exists $REPORT $section]} { return $default }
    set d [dict get $REPORT $section]
    if {$key eq ""} { return $d }
    if {![dict exists $d $key]} { return $default }
    return [dict get $d $key]
}

if {![dict exists $REPORT compile]} {
    lappend notes "no compile fragment found — run `make quartus-map` or `make quartus-fit` before exporting"
}

# ---------------------------------------------------------------------------
# Compilation section
# ---------------------------------------------------------------------------
set seed [frag compile seed $seed_arg]
if {$seed eq ""} { set seed 1 }

set stages_completed [frag compile stages_completed {}]
set stage_requested  [frag compile stage_requested ""]
set errors           [frag compile errors ""]
set warnings         [frag compile warnings ""]
set fatal            [frag compile fatal ""]
set compile_seconds  [frag compile compile_seconds ""]
set peak_memory_mb   [frag compile peak_memory_mb ""]
set stage_seconds    [frag compile stage_seconds {}]
set qver             [frag compile quartus_version ""]
set qver_full        [frag compile quartus_version_full ""]

# The exporter runs in its own quartus_sh process, so it can always report the
# live tool version even if no compile fragment exists.
if {$qver eq ""}      { set qver      [bench::quartus_version_short] }
if {$qver_full eq ""} { set qver_full [bench::quartus_version] }

if {$fatal ne ""} { lappend notes "compile reported a fatal error: $fatal" }

# ---------------------------------------------------------------------------
# Utilization section
# ---------------------------------------------------------------------------
set util_present [dict exists $REPORT utilization]
if {!$util_present} {
    lappend notes "utilization unavailable: report_utilization.tcl has not run for this compile"
}
foreach n [frag utilization notes {}] { lappend notes "utilization: $n" }

set util_source [frag utilization source_stage ""]

set utilization_json [json::obj [list \
    alm_percent      [json::num  [frag utilization alm_percent ""]] \
    m20k_percent     [json::num  [frag utilization m20k_percent ""]] \
    dsp_percent      [json::num  [frag utilization dsp_percent ""]] \
    alm_reg_percent  [json::num  [frag utilization alm_reg_percent ""]] \
    alm_used         [json::int  [frag utilization alm_used ""]] \
    alm_total        [json::int  $bench::total_alms] \
    alm_registers    [json::int  [frag utilization alm_reg_used ""]] \
    alm_registers_total [json::int $bench::total_alm_regs] \
    mlab             [json::int  [frag utilization mlab_used ""]] \
    mlab_memory_bits [json::int  [frag utilization mlab_memory_bits ""]] \
    block_memory_bits [json::int [frag utilization block_memory_bits ""]] \
    m20k             [json::int  [frag utilization m20k_used ""]] \
    m20k_total       [json::int  $bench::total_m20k] \
    dsp              [json::int  [frag utilization dsp_used ""]] \
    dsp_total        [json::int  $bench::total_dsp] \
    ram_bits         [json::int  [frag utilization ram_bits ""]] \
    pins             [json::int  [frag utilization pins_used ""]] \
    virtual_pins     [json::int  [frag utilization virtual_pins ""]] \
    max_fanout       [json::int  [frag utilization max_fanout ""]] \
    global_signals   [json::int  [frag utilization global_signals ""]] \
    peak_interconnect_percent [json::num [frag utilization peak_interconnect_percent ""]] \
    avg_interconnect_percent  [json::num [frag utilization avg_interconnect_percent ""]] \
    source_stage     [json::strn $util_source] \
] 2]

# --- resource by hierarchy --------------------------------------------------
set hier_rows [frag utilization by_hierarchy {}]
set hier_cols [frag utilization by_hierarchy_columns {}]
if {[llength $hier_rows] == 0} {
    set by_hier_json "null"
} else {
    set entries {}
    foreach row $hier_rows { lappend entries "    [json::array_of_str $row]" }
    set by_hier_json "{\n  \"columns\": [json::array_of_str $hier_cols],\n  \"rows\": \[\n[join $entries ",\n"]\n  \]\n}"
}

# ---------------------------------------------------------------------------
# Timing section
# ---------------------------------------------------------------------------
set timing_present [expr {[dict exists $REPORT timing] && [frag timing available 0]}]
if {![dict exists $REPORT timing]} {
    lappend notes "timing unavailable: report_sta.tcl has not run for this compile"
} elseif {!$timing_present} {
    lappend notes "timing unavailable: STA requires a completed fit (stage '$stage_requested' did not produce one)"
}
foreach n [frag timing notes {}] { lappend notes "timing: $n" }

set clocks [frag timing clocks {}]
if {[llength $clocks] == 0} {
    set clocks_json "null"
    lappend notes "clocks: no per-clock timing data in this record"
} else {
    set parts {}
    dict for {cname cd} $clocks {
        set cjson [json::obj [list \
            constraint_mhz        [json::num [dict_get_or $cd constraint_mhz]] \
            period_ns             [json::num [dict_get_or $cd period_ns]] \
            fmax_mhz              [json::num [dict_get_or $cd fmax_mhz]] \
            restricted_fmax_mhz   [json::num [dict_get_or $cd restricted_fmax_mhz]] \
            wns_ns                [json::num [dict_get_or $cd wns_ns]] \
            tns_ns                [json::num [dict_get_or $cd tns_ns]] \
            hold_wns_ns           [json::num [dict_get_or $cd hold_wns_ns]] \
            hold_tns_ns           [json::num [dict_get_or $cd hold_tns_ns]] \
            recovery_wns_ns       [json::num [dict_get_or $cd recovery_wns_ns]] \
            recovery_tns_ns       [json::num [dict_get_or $cd recovery_tns_ns]] \
            removal_wns_ns        [json::num [dict_get_or $cd removal_wns_ns]] \
            removal_tns_ns        [json::num [dict_get_or $cd removal_tns_ns]] \
            failing_paths_setup   [json::int [dict_get_or $cd failing_paths_setup]] \
            failing_paths_hold    [json::int [dict_get_or $cd failing_paths_hold]] \
            failing_paths_recovery [json::int [dict_get_or $cd failing_paths_recovery]] \
            failing_paths_removal [json::int [dict_get_or $cd failing_paths_removal]] \
            logic_depth           [json::int [dict_get_or $cd logic_depth]] \
            routing_delay_ns      [json::num [dict_get_or $cd routing_delay_ns]] \
            cell_delay_ns         [json::num [dict_get_or $cd cell_delay_ns]] \
            clock_skew_ns         [json::num [dict_get_or $cd clock_skew_ns]] \
            source_hierarchy      [json::strn [dict_get_or $cd source_hierarchy]] \
            destination_hierarchy [json::strn [dict_get_or $cd destination_hierarchy]] \
        ] 4]
        lappend parts "    [json::str $cname]: $cjson"
    }
    set clocks_json "{\n[join $parts ",\n"]\n  }"
}

# --- constraints integrity (SPEC.md 24) -------------------------------------
# Two-source merge: report_sta.tcl scans the SDC files, constraints_report.tcl
# queries the Quartus timing analyzer. The Quartus record is authoritative for
# `disabled_arcs` (SDC scan cannot see them) and for the clock-name list; the
# SDC scan is authoritative for counts of directives in the checked-in SDCs.
# Values from the Quartus record override the SDC scan when both are present.
set integ [frag timing integrity {}]
set qs_integ [frag constraints_report integrity {}]
set qs_clocks {}
if {[dict exists $qs_integ clocks]} { set qs_clocks [dict get $qs_integ clocks] }

# Merge: start with the Tcl-scan values, then overwrite from the Quartus
# record when a key is present in both.
foreach k {false_paths multicycle_paths clock_groups max_delays min_delays
           unconstrained_paths ignored_sdc_constraints disabled_arcs} {
    if {[dict exists $qs_integ $k]} {
        dict set integ $k [dict get $qs_integ $k]
    }
}
if {[llength $integ] == 0 && [llength $qs_integ] == 0} {
    set integrity_json "null"
} else {
    set integrity_json [json::obj [list \
        false_paths             [json::int [dict_get_or $integ false_paths]] \
        multicycle_paths        [json::int [dict_get_or $integ multicycle_paths]] \
        clock_groups            [json::int [dict_get_or $integ clock_groups]] \
        max_delays              [json::int [dict_get_or $integ max_delays]] \
        min_delays              [json::int [dict_get_or $integ min_delays]] \
        disabled_arcs           [json::int [dict_get_or $integ disabled_arcs]] \
        unconstrained_paths     [json::int [dict_get_or $integ unconstrained_paths]] \
        ignored_sdc_constraints [json::int [dict_get_or $integ ignored_sdc_constraints]] \
        clocks                  [json::array_of_str $qs_clocks] \
    ] 2]
}

set unconstrained [frag timing unconstrained_paths ""]

# ---------------------------------------------------------------------------
# Physical implementation sections
# ---------------------------------------------------------------------------
set cong_present [expr {[dict exists $REPORT congestion] && [frag congestion available 0]}]
if {![dict exists $REPORT congestion]} {
    lappend notes "congestion unavailable: report_congestion.tcl has not run for this compile"
} elseif {!$cong_present} {
    lappend notes "congestion unavailable: requires a completed fit"
}

if {!$cong_present} {
    set congestion_json "null"
} else {
    set congestion_json [json::obj [list \
        paths_sampled             [json::int [frag congestion paths_sampled ""]] \
        max_congestion_level      [json::strn [frag congestion max_congestion_level ""]] \
        max_fanout                [json::int [frag congestion max_fanout ""]] \
        mean_routing_delay_ratio  [json::num [frag congestion mean_routing_delay_ratio ""]] \
    ] 2]
}

# The Fitter's per-clock-domain statement of why retiming stopped. This is the
# primary input to the SPEC.md 20 timing-closure loop, so it is carried through
# verbatim rather than reduced to a flag.
proc retiming_limits_json {limits} {
    if {[llength $limits] == 0} { return "null" }
    set parts {}
    dict for {domain d} $limits {
        lappend parts "      [json::str $domain]: [json::obj [list \
            limiting_reason [json::strn [dict_get_or $d limiting_reason]] \
            recommendation  [json::strn [dict_get_or $d recommendation]] \
        ] 6]"
    }
    return "{\n[join $parts ",\n"]\n    }"
}

set ret_present [expr {[dict exists $REPORT retiming] && [frag retiming available 0]}]
if {![dict exists $REPORT retiming]} {
    lappend notes "retiming unavailable: report_retiming.tcl has not run for this compile"
} elseif {!$ret_present} {
    lappend notes "retiming unavailable: requires a completed fit"
}

if {!$ret_present} {
    set retiming_json "null"
} else {
    set retiming_json [json::obj [list \
        paths_sampled          [json::int [frag retiming paths_sampled ""]] \
        endpoints_retimed      [json::int [frag retiming endpoints_retimed ""]] \
        endpoints_not_retimed  [json::int [frag retiming endpoints_not_retimed ""]] \
        unregistered_dsp_paths [json::int [frag retiming unregistered_dsp_paths ""]] \
        unregistered_ram_paths [json::int [frag retiming unregistered_ram_paths ""]] \
        commands_available     [json::array_of_str [frag retiming commands_available {}]] \
        commands_unavailable   [json::array_of_str [frag retiming commands_unavailable {}]] \
        limits                 [retiming_limits_json [frag retiming retiming_limits {}]] \
    ] 2]
}

# ---------------------------------------------------------------------------
# Verification status
# ---------------------------------------------------------------------------
# SPEC.md 17's schema carries verification_passed, but the Verilator regression
# (issue #2) is what sets it. This flow never fabricates it: null means "not
# evaluated by this compile", which is honest and distinguishable from false.
set verification_passed ""
lappend notes "verification_passed is null: the Verilator regression (issue #2) owns that field; this record is Quartus-only"

if {$stage_requested eq "map"} {
    lappend notes "stage 'map' = Analysis & Synthesis only; timing, congestion and retiming fields are null by construction"
}

set stage_seconds_json "null"
if {[llength $stage_seconds] > 0} {
    set parts {}
    dict for {k v} $stage_seconds { lappend parts "    [json::str $k]: [json::num $v]" }
    set stage_seconds_json "{\n[join $parts ",\n"]\n  }"
}

set dirty [bench::git_dirty]
if {$dirty} { lappend notes "working tree was dirty at export time; result is not reproducible from the recorded commit alone" }

# ---------------------------------------------------------------------------
# Assemble
# ---------------------------------------------------------------------------
set record [json::obj [list \
    commit               [json::str  [bench::git_commit]] \
    commit_dirty         [json::bool $dirty] \
    quartus_version      [json::str  $qver] \
    quartus_version_full [json::str  $qver_full] \
    device               [json::str  $bench::device] \
    revision             [json::str  $bench::revision] \
    seed                 [json::int  $seed] \
    configuration        [json::str  "phase0_minimal_top"] \
    stage                [json::strn $stage_requested] \
    stages_completed     [json::array_of_str $stages_completed] \
    verification_passed  [json::bool $verification_passed] \
    errors               [json::int  $errors] \
    warnings             [json::int  $warnings] \
    unconstrained_paths  [json::int  $unconstrained] \
    compile_seconds      [json::num  $compile_seconds] \
    stage_seconds        $stage_seconds_json \
    peak_memory_mb       [json::int  $peak_memory_mb] \
    utilization          $utilization_json \
    utilization_by_hierarchy $by_hier_json \
    clocks               $clocks_json \
    constraints_integrity $integrity_json \
    congestion           $congestion_json \
    retiming             $retiming_json \
    timestamp            [json::str [clock format [clock seconds] -format {%Y-%m-%dT%H:%M:%SZ} -gmt 1]] \
    schema_version       [json::str "1"] \
    notes                [json::array_of_str $notes] \
] 0]

# ---------------------------------------------------------------------------
# Write
# ---------------------------------------------------------------------------
set stamp [clock format [clock seconds] -format {%Y%m%dT%H%M%S} -gmt 1]
set out_path    [file join $bench::timing_dir "compile_${stamp}_seed${seed}.json"]
set latest_path [file join $bench::timing_dir "latest.json"]

foreach path [list $out_path $latest_path] {
    set fh [open $path w]
    fconfigure $fh -translation lf
    puts $fh $record
    close $fh
}

bench::log "wrote $out_path"
bench::log "wrote $latest_path"
exit 0
