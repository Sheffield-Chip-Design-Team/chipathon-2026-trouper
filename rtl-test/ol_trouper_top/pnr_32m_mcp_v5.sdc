# pnr_32m_mcp_v5.sdc
# v5: split setup/hold clock uncertainty.
#     set_clock_uncertainty 2.0 (single value) applies to both setup and hold,
#     creating 4700+ false hold violations after CTS buffer skew that overflow
#     placement during ResizerTimingPostCTS.  Hold uncertainty reduced to 0.1 ns.

create_clock -name IQ_CLK -period 31.25 [get_ports IQ_CLK]
create_clock -name SPI_SCK -period 100.0 [get_ports SPI_SCK]
set_clock_uncertainty -setup 2.0 [get_clocks IQ_CLK]
set_clock_uncertainty -hold  0.1 [get_clocks IQ_CLK]

set_ideal_network [get_ports SPI_SCK]

set_input_delay  -max 2.0 -clock IQ_CLK [get_ports {IQ_DATA_I_* IQ_DATA_Q_* SPI_MOSI}]
set_input_delay  -min 1.0 -clock IQ_CLK [get_ports {IQ_DATA_I_* IQ_DATA_Q_* SPI_MOSI}]
set_output_delay -max 2.0 -clock IQ_CLK [all_outputs]
set_output_delay -min 0.0 -clock IQ_CLK [all_outputs]

set_false_path -from [get_ports RESETB]
set_false_path -from [get_ports HOST_CS]
set_clock_groups -asynchronous -group [get_clocks IQ_CLK] -group [get_clocks SPI_SCK]

# MCP=2 explicitly scoped to IQ_CLK reg-to-reg paths.
set_multicycle_path 2 -setup -from [get_clocks IQ_CLK] -to [get_clocks IQ_CLK]
set_multicycle_path 1 -hold  -from [get_clocks IQ_CLK] -to [get_clocks IQ_CLK]
