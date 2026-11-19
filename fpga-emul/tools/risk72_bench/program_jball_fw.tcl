set elf_file "/home/timothyjabez/Documents/chipathon-2026/chipathon-2026-trouper/fpga-emul/sw/lora_mimo_fw.elf"
set bit_file "/home/timothyjabez/Documents/chipathon-2026/chipathon-2026-trouper/fpga-emul/arty_dsp_emul_extpsram_jball.bit"

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
puts "ELF downloaded and MicroBlaze running."
after 2000
stop
puts "PC after 2s: [rrd pc]"
con
exit
