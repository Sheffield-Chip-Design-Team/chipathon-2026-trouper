# run_synth.tcl
# Runs synthesis, implementation, and bitstream generation for the arty_dsp_emul project.
# Opens the project created by create_project.tcl.
#
# Usage (from fpga-emul/):
#   /path/to/vivado -mode batch -source vivado/run_synth.tcl

set proj_dir  [file normalize "[file dirname [info script]]/../vivado_proj"]
set proj_name "arty_dsp_emul"

open_project [file normalize "[file dirname [info script]]/../vivado_proj/${proj_name}.xpr"]

# Synthesis (BD addresses already assigned by create_project.tcl)
# Only re-run synthesis if not already complete.
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    launch_runs synth_1 -jobs 4
    wait_on_run synth_1
    if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
        error "Synthesis failed — check vivado_synth.log"
    }
}
puts "Synthesis complete."

# Reset impl_1 so it picks up the updated XDC
reset_run impl_1

# Attach pre-place hook to demote PLIO-9 (sample clock sx_clk_out is hardwired to
# C15, an N-type CCIO pin) — must run before place_design, where the DRC fires.
set pre_place [file normalize "[file dirname [info script]]/pre_place.tcl"]
set_property STEPS.PLACE_DESIGN.TCL.PRE $pre_place [get_runs impl_1]

# Attach pre-bitstream hook to demote UCIO-1/NSTD-1 DRC errors on MRCC clock pins
set pre_hook [file normalize "[file dirname [info script]]/pre_bitstream.tcl"]
set_property STEPS.WRITE_BITSTREAM.TCL.PRE $pre_hook [get_runs impl_1]

# Implementation
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    error "Implementation failed — check vivado_synth.log"
}
puts "Implementation complete."

# Report timing
open_run impl_1
report_timing_summary -file "$proj_dir/timing_summary.rpt" -max_paths 10
report_utilization -file "$proj_dir/utilization.rpt"

# Copy bitstream to a known location
set bit_file [glob -nocomplain "$proj_dir/${proj_name}.runs/impl_1/*.bit"]
if {[llength $bit_file] > 0} {
    file copy -force [lindex $bit_file 0] "[file dirname [info script]]/../arty_dsp_emul.bit"
    puts "Bitstream written to fpga-emul/arty_dsp_emul.bit"
} else {
    puts "WARNING: no .bit file found"
}

puts "Done."
