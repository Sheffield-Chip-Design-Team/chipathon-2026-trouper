# sta_crit_path.tcl — OpenSTA timing for isolated weight_gen critical paths
# Run once per top-level, re-read everything for a clean db each time.

set LIBERTY /foss/pdks/gf180mcuD/libs.ref/gf180mcu_fd_sc_mcu7t5v0/lib/gf180mcu_fd_sc_mcu7t5v0__tt_025C_3v30.lib
set NETLIST /work/out/netlist_crit_path.v
set TOP [lindex $argv 0]

read_liberty $LIBERTY
read_verilog $NETLIST
link_design $TOP

create_clock -name clk -period 31.25 [get_ports clk]
set_input_delay  2.0 -clock clk [all_inputs]
set_output_delay 2.0 -clock clk [all_outputs]

puts "\n====== $TOP — worst setup path ======"
report_checks -path_delay max -digits 3 -fields {slew cap input fanout}
