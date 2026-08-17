# Measure the true slack of the sc_clear MCP cone.
#
# `sc_clear` is the last unproven group in mcp_audit_manifest.json, and it is
# unsound for a different reason from the config groups: its source
# `packet_done_pulse` is a registered ONE-CYCLE pulse (trouper_top.v:594-596)
# into synchronous-clear registers that sample every cycle, so the capture
# happens at t+1 and no 3-cycle settling window exists to grant.
#
# That leaves two fixes: stretch the pulse (RTL change), or withdraw the
# exception and let the arc time honestly. Which one is right depends on
# whether the arc is actually slow -- so measure it, with the MCP-free SDC, on
# the routed netlist.
#
# Required env: as honest_sta.tcl (HSTA_LIBERTY/TECH_LEF/CELL_LEF/NETLIST/SDC/
# CORNER/REPORT), optional HSTA_SPEF.

foreach required {HSTA_LIBERTY HSTA_TECH_LEF HSTA_CELL_LEF HSTA_NETLIST HSTA_SDC HSTA_CORNER HSTA_REPORT} {
    if {![info exists ::env($required)] || $::env($required) eq ""} {
        puts stderr "sc_clr_slack: required environment variable $required is unset"
        exit 2
    }
}
read_lef $::env(HSTA_TECH_LEF)
read_lef $::env(HSTA_CELL_LEF)
read_liberty $::env(HSTA_LIBERTY)
read_verilog $::env(HSTA_NETLIST)
link_design trouper_top
if {[info exists ::env(HSTA_SPEF)] && $::env(HSTA_SPEF) ne ""} { read_spef $::env(HSTA_SPEF) }
source $::env(HSTA_SDC)

set report $::env(HSTA_REPORT)
set fp [open $report w]
proc emit {line} { global fp; puts $fp $line; puts $line }

emit "SC_CLR_SLACK|corner|$::env(HSTA_CORNER)"
emit "SC_CLR_SLACK|sdc|$::env(HSTA_SDC)"

# The clear cone's endpoints, named exactly as the SDC's sc_clr_regs does.
set clr_nets [get_nets -hierarchical {u_sc.hit_count[*] \
    u_sc.first_hit_sample[*] u_sc.acc_ci0[*] u_sc.acc_cq0[*] \
    u_sc.acc_E0cur[*] u_sc.acc_E0del[*] u_sc.sym_cnt[*] u_sc.tdm_busy \
    u_sc.tdm_wait[*] u_sc.iq_inc_pending u_sc.eval_busy u_sc.mul_start \
    u_sc.metric_valid_pulse}]
set clr_regs [get_cells -of_objects $clr_nets -filter {ref_name =~ *dff*}]
emit "SC_CLR_SLACK|endpoint_cells|[llength $clr_regs]"

set src [get_nets {packet_done_pulse}]
emit "SC_CLR_SLACK|source_nets|[llength $src]"

# Worst paths INTO the clear cone from the pulse specifically.
emit "SC_CLR_SLACK|--- packet_done_pulse -> sc_clr cone ---"
if {[catch {
    sta::report_file_begin $report
    report_checks -through $src -to $clr_regs -path_delay max \
                  -group_count 10 -slack_max 1e30 -format full_clock_expanded
    sta::report_file_end
} err]} {
    emit "SC_CLR_SLACK|report_file unavailable ($err) -- detail on stdout"
    report_checks -through $src -to $clr_regs -path_delay max \
                  -group_count 10 -slack_max 1e30 -format full_clock_expanded
}
exit 0
