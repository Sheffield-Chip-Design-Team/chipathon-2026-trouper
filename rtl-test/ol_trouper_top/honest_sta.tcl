# Reload a routed netlist and re-time it under a supplied SDC.
#
# Used to ask whether the 4.5 V-core closure survives withdrawal of the
# multicycle exceptions. Loads the SAME routed netlist + SPEF that produced the
# original result, so the only variable is the SDC.
#
# Required env: HSTA_LIBERTY HSTA_TECH_LEF HSTA_CELL_LEF HSTA_NETLIST HSTA_SDC
#               HSTA_CORNER HSTA_REPORT
# Optional env: HSTA_SPEF

foreach required {HSTA_LIBERTY HSTA_TECH_LEF HSTA_CELL_LEF HSTA_NETLIST HSTA_SDC HSTA_CORNER HSTA_REPORT} {
    if {![info exists ::env($required)] || $::env($required) eq ""} {
        puts stderr "honest_sta: required environment variable $required is unset"
        exit 2
    }
}
set liberty  $::env(HSTA_LIBERTY)
set tech_lef $::env(HSTA_TECH_LEF)
set cell_lef $::env(HSTA_CELL_LEF)
set netlist  $::env(HSTA_NETLIST)
set sdc      $::env(HSTA_SDC)
set corner   $::env(HSTA_CORNER)
set report   $::env(HSTA_REPORT)
set spef ""
if {[info exists ::env(HSTA_SPEF)]} { set spef $::env(HSTA_SPEF) }

read_lef $tech_lef
read_lef $cell_lef
read_liberty $liberty
read_verilog $netlist
link_design trouper_top
if {$spef ne ""} {
    read_spef $spef
} else {
    puts "honest_sta: WARNING no SPEF -- wire delay is estimated, not extracted"
}
source $sdc

set fp [open $report w]
proc emit {line} {
    global fp
    puts $fp $line
    puts $line
}

emit "HONEST_STA|corner|$corner"
emit "HONEST_STA|netlist|$netlist"
emit "HONEST_STA|sdc|$sdc"
emit "HONEST_STA|spef|$spef"

# Setup (max) is the question; hold (min) is reported too so a withdrawn
# multicycle hold exception cannot quietly turn into a hold problem.
# The slack accessors live in the sta:: namespace in some builds and are
# exported as bare commands in others; try both rather than assume.
proc slack_value {kind path_delay} {
    foreach cmd [list "sta::${kind} -${path_delay}" "${kind} -${path_delay}"] {
        if {![catch {uplevel #0 $cmd} result]} { return $result }
    }
    return "UNAVAILABLE"
}
foreach {label path_delay} {setup max hold min} {
    emit "HONEST_STA|${label}_wns|[slack_value worst_slack $path_delay]"
    emit "HONEST_STA|${label}_tns|[slack_value total_negative_slack $path_delay]"
}

# The violating endpoints themselves: with the exceptions withdrawn, these name
# exactly which cones would need a real fix rather than a relaxation.
#
# NB: report_checks PRINTS to stdout and returns the empty string -- assigning
# it to a variable captures nothing. Close the summary file first, then reopen
# it as stdout's destination so the path detail lands in the report alongside
# the slack numbers instead of only in the job log.
emit "HONEST_STA|--- path detail follows ---"
close $fp

if {[catch {
    sta::report_file_begin $report
    report_checks -path_delay max -slack_max 0 -group_count 25 -format full_clock_expanded
    report_checks -path_delay min -slack_max 0 -group_count 10
    sta::report_file_end
} err]} {
    # If this build does not expose report_file_begin, the detail still reaches
    # the job log via stdout -- record why the report is short rather than
    # failing an otherwise-good run.
    set fp2 [open $report a]
    puts $fp2 "HONEST_STA|path detail unavailable in report ($err) -- see the .log"
    close $fp2
    report_checks -path_delay max -slack_max 0 -group_count 25 -format full_clock_expanded
    report_checks -path_delay min -slack_max 0 -group_count 10
}
exit 0
