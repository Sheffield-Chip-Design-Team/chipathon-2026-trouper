# sta_3v3.tcl — post-route STA for dut_nr_outer at one 3.3V corner
# Usage: openroad -exit sta_3v3.tcl  (set LIB env var before calling)
# LIB = liberty file path

set LIB $env(LIB3V3)
set ODB /work/ol_nr_outer/runs/run2/44-openroad-detailedrouting/dut_nr_outer.odb
set TLEF /foss/pdks/gf180mcuD/libs.ref/gf180mcu_fd_sc_mcu7t5v0/techlef/gf180mcu_fd_sc_mcu7t5v0__nom.tlef
set LEF  /foss/pdks/gf180mcuD/libs.ref/gf180mcu_fd_sc_mcu7t5v0/lef/gf180mcu_fd_sc_mcu7t5v0.lef

read_liberty $LIB
read_lef $TLEF
read_lef $LEF
read_db $ODB

create_clock -name clk -period 31.25 [get_ports clk]
set_input_delay  2.0 -clock clk [all_inputs]
set_output_delay 2.0 -clock clk [all_outputs]
set_clock_uncertainty 0.25 [get_clocks clk]

estimate_parasitics -global_routing

puts "\n====== $LIB — worst setup path ======"
report_checks -path_delay max -digits 3 -fields {slew cap input fanout}
puts "\n====== $LIB — worst hold path ======"
report_checks -path_delay min -digits 3
