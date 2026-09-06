# run_synth_only.tcl -- synthesis only (no impl / no bitstream).
# Usage (from fpga-emul/):
#   /path/to/vivado -mode batch -source vivado/run_synth_only.tcl
open_project [file normalize "[file dirname [info script]]/../vivado_proj/arty_dsp_emul.xpr"]

if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    reset_run synth_1
    launch_runs synth_1 -jobs 8
    wait_on_run synth_1
}
set prog [get_property PROGRESS [get_runs synth_1]]
set stat [get_property STATUS   [get_runs synth_1]]
puts "SYNTH_1 PROGRESS=$prog STATUS=$stat"
if {$prog != "100%"} {
    error "Synthesis did not complete -- see runs/synth_1/runme.log"
}

open_run synth_1 -name synth_1
report_utilization -file [file normalize "[file dirname [info script]]/../vivado_proj/synth_only_util.rpt"]
puts "SYNTH_ONLY_OK"
