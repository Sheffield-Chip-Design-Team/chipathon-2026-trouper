# sta_weight_gen.tcl — OpenSTA timing analysis for weight_gen
# Run after synth_weight_gen_timing.ys produces out/netlist_weight_gen.v

set LIBERTY /foss/pdks/gf180mcuD/libs.ref/gf180mcu_fd_sc_mcu7t5v0/lib/gf180mcu_fd_sc_mcu7t5v0__tt_025C_3v30.lib

read_liberty $LIBERTY
read_verilog /work/out/netlist_weight_gen.v
link_design weight_gen

# 32 MHz clock on both clock ports
create_clock -name clk -period 31.25 [get_ports clk]

# Conservative I/O delays (2 ns each side)
set_input_delay  2.0 -clock clk [remove_from_collection [all_inputs]  [get_ports clk]]
set_output_delay 2.0 -clock clk [all_outputs]

puts "\n========== Setup (max-delay) worst paths =========="
report_checks -path_delay max -nworst 5 -digits 3 \
    -fields {slew cap input nets fanout}

puts "\n========== Hold (min-delay) worst paths =========="
report_checks -path_delay min -nworst 3 -digits 3

puts "\n========== Summary =========="
report_wns
report_tns
report_check_types -max_slew -max_cap -max_fanout -violators
