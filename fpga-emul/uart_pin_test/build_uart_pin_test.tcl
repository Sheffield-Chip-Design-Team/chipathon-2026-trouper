set script_dir [file normalize [file dirname [info script]]]
set proj_dir   [file normalize "$script_dir/vivado_proj"]
set proj_name  "uart_pin_test"
set part       "xc7a100tcsg324-1"

create_project $proj_name $proj_dir -part $part -force
add_files -norecurse "$script_dir/uart_tx_pattern.v"
add_files -fileset constrs_1 -norecurse "$script_dir/uart_pin_test.xdc"
set_property top uart_tx_pattern [current_fileset]
update_compile_order -fileset sources_1

launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    error "Synthesis failed"
}

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    error "Implementation failed"
}

open_run impl_1
report_timing_summary -file "$proj_dir/timing_summary.rpt" -max_paths 10

set bit_file [glob -nocomplain "$proj_dir/${proj_name}.runs/impl_1/*.bit"]
if {[llength $bit_file] == 0} {
    error "No bitstream found"
}

file copy -force [lindex $bit_file 0] "$script_dir/uart_pin_test.bit"
puts "Bitstream written to fpga-emul/uart_pin_test/uart_pin_test.bit"
exit
