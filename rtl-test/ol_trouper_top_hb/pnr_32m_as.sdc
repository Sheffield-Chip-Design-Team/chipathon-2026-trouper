# pnr_32m_as.sdc
# AS cells (gf180mcu_as_sc_mcu7t3v3) native 3.3V — no MCP needed.
# Single-cycle 32 MHz constraint.

create_clock -name IQ_CLK -period 31.25 [get_ports IQ_CLK]
set_clock_uncertainty 0.5 [get_clocks IQ_CLK]

set_input_delay  -max 2.0 -clock IQ_CLK [get_ports {IQ_DATA_I IQ_DATA_Q SPI_MOSI}]
set_input_delay  -min 1.0 -clock IQ_CLK [get_ports {IQ_DATA_I IQ_DATA_Q SPI_MOSI}]
set_output_delay -max 2.0 -clock IQ_CLK [all_outputs]
set_output_delay -min 0.0 -clock IQ_CLK [all_outputs]

set_false_path -from [get_ports RESETB]
set_false_path -from [get_ports HOST_CS]
set_false_path -from [get_ports SPI_SCK]
