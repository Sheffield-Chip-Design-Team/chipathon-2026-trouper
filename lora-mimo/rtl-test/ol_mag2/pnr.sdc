create_clock -name clk -period 31.25 [get_ports clk]
set_input_delay -max 2.0 -clock clk [get_ports {hc_i hc_q}]
set_input_delay -min 1.0 -clock clk [get_ports {hc_i hc_q}]
set_output_delay -max 2.0 -clock clk [all_outputs]
set_output_delay -min 0.0 -clock clk [all_outputs]
set_clock_uncertainty 0.25 [get_clocks clk]
# Leaf block IO hold is checked at the integrating parent boundary.
set_false_path -hold -from [all_inputs]
set_false_path -hold -to [all_outputs]
