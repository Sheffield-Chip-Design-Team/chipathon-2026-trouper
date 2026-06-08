set_property PACKAGE_PIN E3 [get_ports clk100mhz]
set_property IOSTANDARD LVCMOS33 [get_ports clk100mhz]
create_clock -period 10.000 -name sys_clk [get_ports clk100mhz]

set_property PACKAGE_PIN C2 [get_ports ext_resetn]
set_property IOSTANDARD LVCMOS33 [get_ports ext_resetn]

set_property PACKAGE_PIN A9 [get_ports uart_txd]
set_property IOSTANDARD LVCMOS33 [get_ports uart_txd]

set_property PACKAGE_PIN H5 [get_ports led0]
set_property IOSTANDARD LVCMOS33 [get_ports led0]
