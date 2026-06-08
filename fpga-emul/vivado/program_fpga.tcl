# program_fpga.tcl
# Programs the Arty A7-100T via USB-JTAG using Vivado hw_server.
set bit_file [file normalize "[file dirname [info script]]/../arty_dsp_emul.bit"]

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
set dev [lindex [get_hw_devices] 0]
puts "Device: [get_property NAME $dev]"
current_hw_device $dev
refresh_hw_device $dev
set_property PROGRAM.FILE $bit_file $dev
program_hw_devices $dev
refresh_hw_device $dev
puts "Programming complete. DONE=[get_property REGISTER.IR.BIT5_DONE $dev]"
close_hw_target
disconnect_hw_server
close_hw_manager
