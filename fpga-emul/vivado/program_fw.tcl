# program_fw.tcl — program firmware+bitstream combo, no debug core needed
set bit_file [file normalize "[file dirname [info script]]/../arty_dsp_emul_fw.bit"]

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

set dev [lindex [get_hw_devices xc7a100t_0] 0]
if {$dev eq ""} { set dev [lindex [get_hw_devices] 0] }
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

puts "Programming: $bit_file"
set_property PROGRAM.FILE $bit_file $dev
program_hw_devices $dev
puts "DONE=[get_property REGISTER.IR.BIT5_DONE $dev]"

disconnect_hw_server
close_hw_manager
puts "Programming complete. Firmware running from BRAM."
