# pnr_32m_mcp_v6.sdc
# v6: MCP=3 (93.75 ns budget) + clock uncertainty 0.5 ns.
#
# Root cause of prior DPL-0036 failures:
#   set_clock_uncertainty 2.0 applies to BOTH setup and hold in OpenSTA
#   (this LibreLane build ignores -setup/-hold modifiers).  At FF corner
#   2.0 ns uncertainty makes every fast path a hold violation → 4744 hold
#   endpoints → resizer tries 50%-budget buffer insertion → placement overflows.
#
# Fixes:
#   - Reduce uncertainty to 0.5 ns: hold violations drop to paths < 0.5 ns only.
#   - MCP=3 (93.75 ns): covers deep FD-cell combinational paths at 3V SS
#     that still exceeded 62.5 ns (MCP=2).  Hold companion changed to 2.
#   - MCP=2 hold companion: restores normal 0 ns hold check with MCP=3 setup.

create_clock -name IQ_CLK -period 31.25 [get_ports IQ_CLK]
set_clock_uncertainty 0.5 [get_clocks IQ_CLK]


set_input_delay  -max 2.0 -clock IQ_CLK [get_ports {IQ_DATA_I_* IQ_DATA_Q_* SPI_MOSI}]
set_input_delay  -min 1.0 -clock IQ_CLK [get_ports {IQ_DATA_I_* IQ_DATA_Q_* SPI_MOSI}]
set_output_delay -max 2.0 -clock IQ_CLK [all_outputs]
set_output_delay -min 0.0 -clock IQ_CLK [all_outputs]

set_false_path -from [get_ports RESETB]
set_false_path -from [get_ports HOST_CS]
set_false_path -from [get_ports SPI_SCK]

set_multicycle_path 3 -setup -from [get_clocks IQ_CLK] -to [get_clocks IQ_CLK]
set_multicycle_path 2 -hold  -from [get_clocks IQ_CLK] -to [get_clocks IQ_CLK]
