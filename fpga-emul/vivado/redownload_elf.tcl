# redownload_elf.tcl -- reset MicroBlaze and download a fresh ELF WITHOUT
# reprogramming the FPGA bitstream (which stays loaded, including the ILA).
# Much faster than run_eth_fw.tcl's full `fpga $bit_file` when only main.c
# changed.
set elf_file [file normalize "[file dirname [info script]]/../sw/lora_mimo_fw.elf"]

connect
targets -set -filter {name =~ "MicroBlaze Debug Module*"}
rst
after 1000
targets -set -filter {name =~ "MicroBlaze #0*"}
dow $elf_file
con
puts "ELF downloaded and MicroBlaze running."
after 1000
exit
