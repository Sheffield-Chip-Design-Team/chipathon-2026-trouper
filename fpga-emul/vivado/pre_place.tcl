# pre_place.tcl — pre-hook for the place_design step.
#
# Demote PLIO-9: the SX1257 sample clock (sx_clk_out) is hardwired by the MISO
# front-end test PCB to Arty pin C15 = JB pin 4 = CLK_OUT_4. On the
# xc7a100tcsg324 that pin is the N-side of a clock-capable (MRCC) pair, and
# Vivado's placer DRC PLIO-9 flags single-ended clocks placed on an N-type CCIO
# (Xilinx recommends the P-side). The board routing is fixed and C15 was chosen
# deliberately — it is the only 0-ohm (no series R) CLK_OUT, i.e. the cleanest
# edge of the four (see miso_frontend PCB review finding 7). The clock still
# drives a BUFG, so a 32 MHz sample clock on the N-side is functionally fine for
# this emulation. Demote to a warning so placement/bitgen proceed.
#
# NOTE: keep an eye out for a follow-on CLOCK_DEDICATED_ROUTE warning; with the
# BUFG present the clock reaches global routing normally, but if a future change
# breaks that path, set CLOCK_DEDICATED_ROUTE appropriately on the sx_clk net.
set_property SEVERITY {Warning} [get_drc_checks PLIO-9]
