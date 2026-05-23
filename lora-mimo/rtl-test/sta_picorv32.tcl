# sta_picorv32.tcl — OpenSTA timing analysis for PicoRV32 at 32 MHz, GF180 TT 3.3V 25C

set LIBERTY /foss/pdks/gf180mcuD/libs.ref/gf180mcu_fd_sc_mcu7t5v0/lib/gf180mcu_fd_sc_mcu7t5v0__ss_125C_3v00.lib

read_liberty $LIBERTY
read_verilog /work/out/netlist_picorv32.v
link_design picorv32

# 16 MHz = 62.5 ns period
create_clock -name clk -period 62.5 [get_ports clk]
set_output_delay 2.0 -clock clk [all_outputs]

puts "\n========== Setup (max-delay) worst paths =========="
report_checks -path_delay max -digits 3 -fields {slew cap input fanout}

puts "\n========== Hold (min-delay) worst paths =========="
report_checks -path_delay min -digits 3

puts "\n========== Summary =========="
report_wns
report_tns
