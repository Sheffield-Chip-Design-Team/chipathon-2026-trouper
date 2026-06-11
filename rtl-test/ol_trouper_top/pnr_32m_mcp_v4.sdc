# pnr_32m_mcp_v4.sdc
# v3: global set_multicycle_path without -from/-to is silently ignored by
# OpenSTA in this LibreLane build. Worst path still captured at 31.25 ns.
# v4: bind MCP explicitly to IQ_CLK register-to-register paths.

create_clock -name IQ_CLK -period 31.25 [get_ports IQ_CLK]
create_clock -name SPI_SCK -period 100.0 [get_ports SPI_SCK]
set_clock_uncertainty 2.0 [get_clocks IQ_CLK]

set_ideal_network [get_ports SPI_SCK]

set_input_delay  -max 2.0 -clock IQ_CLK [get_ports {IQ_DATA_I IQ_DATA_Q SPI_MOSI TMS_GPIO0 TDI_GPIO1}]
set_input_delay  -min 1.0 -clock IQ_CLK [get_ports {IQ_DATA_I IQ_DATA_Q SPI_MOSI TMS_GPIO0 TDI_GPIO1}]
set_output_delay -max 2.0 -clock IQ_CLK [all_outputs]
set_output_delay -min 0.0 -clock IQ_CLK [all_outputs]

set_false_path -from [get_ports RESETB]
set_false_path -from [get_ports HOST_CS]
set_clock_groups -asynchronous -group [get_clocks IQ_CLK] -group [get_clocks SPI_SCK]

# MCP=2 explicitly scoped to IQ_CLK reg-to-reg paths.
# Global form (no -from/-to) is ignored by OpenSTA in this build.
set_multicycle_path 2 -setup -from [get_clocks IQ_CLK] -to [get_clocks IQ_CLK]
set_multicycle_path 1 -hold  -from [get_clocks IQ_CLK] -to [get_clocks IQ_CLK]
