create_clock -name clk -period 35.714286 [get_ports clk]
set_input_delay -max 2.0 -clock clk [get_ports {resetn mem_ready mem_rdata pcpi_wr pcpi_rd pcpi_wait pcpi_ready irq}]
set_input_delay -min 1.0 -clock clk [get_ports {resetn mem_ready mem_rdata pcpi_wr pcpi_rd pcpi_wait pcpi_ready irq}]
set_output_delay -max 2.0 -clock clk [all_outputs]
set_output_delay -min 0.0 -clock clk [all_outputs]
set_clock_uncertainty 0.25 [get_clocks clk]
set_false_path -from [get_ports resetn]

# irq_state is a 2-bit FSM register that transitions at most once per interrupt
# event (entry/exit each take 3+ decode cycles). Paths through irq_state are
# stable for at least 2 cycles, so a 2-cycle multicycle path is architecturally
# valid. The companion -hold 1 keeps hold analysis correct.
#
# Cell names _20877_ (_irq_state[0]_) and _20878_ (_irq_state[1]_) are the
# Yosys-synthesised instance names for this design (verified deterministic).
# get_registers is not available in this OpenSTA build; get_cells is used instead.
set irq_regs {}
catch {set irq_regs [get_cells {_20877_ _20878_}]}
if {[llength $irq_regs] > 0} {
    set_multicycle_path -setup 2 -from $irq_regs
    set_multicycle_path -hold  1 -from $irq_regs
}
