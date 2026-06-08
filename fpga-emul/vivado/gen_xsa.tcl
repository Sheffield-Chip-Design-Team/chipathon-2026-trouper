# gen_xsa.tcl — export hardware platform (XSA) for Vitis BSP generation
set proj_dir  [file normalize "[file dirname [info script]]/../vivado_proj"]
set proj_name "arty_dsp_emul"
set xsa_out   [file normalize "[file dirname [info script]]/../sw/arty_dsp_emul.xsa"]

open_project [file normalize "$proj_dir/${proj_name}.xpr"]
open_run impl_1

write_hw_platform -fixed -include_bit -force -file $xsa_out
puts "XSA written to: $xsa_out"
