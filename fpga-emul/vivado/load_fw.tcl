# load_fw.tcl — load MicroBlaze ELF via xsdb/xsct
#
# Run this with:
#   /home/timothyjabez/tools/Xilinx/2025.2/Vivado/bin/xsdb -source vivado/load_fw.tcl
#
# This matches the working fpga-eth flow: program the FPGA, wait for the clock
# and reset fabric to settle, then reset/download/run through the MDM target.
set elf_file [file normalize "[file dirname [info script]]/../sw/test_fw.elf"]
set bit_file [file normalize "[file dirname [info script]]/../arty_dsp_emul.bit"]

connect

# Program the base bitstream first.
targets -set -filter {name =~ "xc7a100t*"}
fpga $bit_file

# Let clock wizard / proc_sys_reset settle before touching the MDM.
after 5000

# Reset via the MicroBlaze Debug Module, then download and run the ELF.
targets -set -filter {name =~ "MicroBlaze Debug Module*"}
rst
after 1000
targets -set -filter {name =~ "MicroBlaze #0*"}
dow $elf_file
con

puts "ELF downloaded and MicroBlaze running."
after 2000
stop
puts "PC after 2s: [rrd pc]"
con
exit
