# Program the FPGA and run the continuous bare-metal UART transmitter.
set elf_file [file normalize "[file dirname [info script]]/../sw/uart_smoke.elf"]
set bit_file [file normalize "[file dirname [info script]]/../arty_dsp_emul.bit"]

connect
targets -set -filter {name =~ "xc7a100t*"}
fpga $bit_file
after 5000
targets -set -filter {name =~ "MicroBlaze Debug Module*"}
rst
after 1000
targets -set -filter {name =~ "MicroBlaze #0*"}
dow $elf_file
con
puts "Continuous UART smoke transmitter running."
exit
