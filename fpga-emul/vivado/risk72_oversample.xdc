# RISK72_OVERSAMPLE build only (added by create_project.tcl, implementation only).
# The 200 MHz ILA samples dsp_clk-domain nets (ps_ce_n, ps_sck, sio_out, context)
# and raw pad inputs asynchronously, as a logic analyser. Both clocks come from
# clk_wiz_0, so Vivado would otherwise time the 32 -> 200 MHz crossing as a
# synchronous path with a ~1 ns worst-case edge spacing.
set clk_ila [get_clocks -of_objects [get_pins -hierarchical -filter {NAME =~ */clk_wiz_0/clk_out4}]]
set clk_dsp [get_clocks -of_objects [get_pins -hierarchical -filter {NAME =~ */clk_wiz_0/clk_out2}]]
set_false_path -from $clk_dsp -to $clk_ila
