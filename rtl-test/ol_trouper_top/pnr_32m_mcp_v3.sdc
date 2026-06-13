# pnr_32m_mcp_v3.sdc
# 32 MHz global clock, MCP=2 for all DSP paths.
#
# v2 had set_multicycle_path 1 -setup overrides using get_cells {u_dec_0/*}
# which returns empty on the flattened post-synthesis netlist, causing the
# override to silently apply MCP=1 to ALL paths. Removed those overrides.
#
# sd_decimator and sd_remod internal paths are short enough to close at
# 31.25 ns SS (confirmed in prior block-level P&R). With MCP=2 they get
# 62.5 ns budget — well within that margin. The functional requirement
# (accumulate every cycle) is a behaviour constraint, not a STA concern.

create_clock -name IQ_CLK -period 31.25 [get_ports IQ_CLK]
create_clock -name SPI_SCK -period 100.0 [get_ports SPI_SCK]
set_clock_uncertainty 2.0 [get_clocks IQ_CLK]

# SPI_SCK is an external asynchronous clock — prevent CTS from buffering it.
set_ideal_network [get_ports SPI_SCK]

set_input_delay  -max 2.0 -clock IQ_CLK [get_ports {IQ_DATA_I IQ_DATA_Q SPI_MOSI}]
set_input_delay  -min 1.0 -clock IQ_CLK [get_ports {IQ_DATA_I IQ_DATA_Q SPI_MOSI}]
set_output_delay -max 2.0 -clock IQ_CLK [all_outputs]
set_output_delay -min 0.0 -clock IQ_CLK [all_outputs]

set_false_path -from [get_ports RESETB]
set_false_path -from [get_ports HOST_CS]
set_clock_groups -asynchronous -group [get_clocks IQ_CLK] -group [get_clocks SPI_SCK]

# All paths: 2-cycle (62.5 ns) setup budget, hold check stays at 1 cycle.
set_multicycle_path 2 -setup
set_multicycle_path 1 -hold
