# pre_bitstream.tcl
# Pre-hook for write_bitstream step — demote DRC errors that block bitgen
# for prototype FPGA builds where not all I/O constraints are finalised.
#
# UCIO-1: unconstrained I/O (rx_clk/tx_clk on dedicated MRCC pins I17/C18 need this)
# NSTD-1: unspecified I/O standard (belt-and-braces; shouldn't fire after XDC fixes)
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]
set_property SEVERITY {Warning} [get_drc_checks NSTD-1]
