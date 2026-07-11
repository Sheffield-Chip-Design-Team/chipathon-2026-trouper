# pnr_32m_scoped_v9.sdc
# SCOPED honest multicycle — v9 (corrected scoping).
#
# v8 BUG: scoped via `get_cells -hierarchical {*u_dec*}`.  Yosys flattens the
#   register CELLS to anonymous names (_62705_), so that pattern matched NOTHING
#   and the MCP=3 was a no-op → the whole design ran at honest single-cycle and
#   the decimator HB2 MAC surfaced at SS WNS -39.97 ns (job 2156).
#
# v9 FIX: hierarchy survives on NET names (e.g. `u_dec.hb2_stream[1]`), so scope
#   with `-through [get_nets ...]`.  MCP=3 is confined to any path that passes
#   through a net inside the three PACED blocks (u_dec / u_sc / u_tacc); these
#   blocks were re-coded to hold their combinational MAC over 3 clocks, so the
#   relaxation is physically honest.  Everything else — INCLUDING u_comb, whose
#   state machine issues one registered 8x8 multiply PER CLOCK — must meet the
#   full 31.25 ns single-cycle budget.  If u_comb violates, that is a real path
#   the blanket v6 MCP=3 was masking and it needs pacing too.

create_clock -name IQ_CLK -period 31.25 [get_ports IQ_CLK]
set_clock_uncertainty 0.5 [get_clocks IQ_CLK]

set_input_delay  -max 2.0 -clock IQ_CLK [get_ports {IQ_DATA_I_* IQ_DATA_Q_* SPI_MOSI}]
set_input_delay  -min 1.0 -clock IQ_CLK [get_ports {IQ_DATA_I_* IQ_DATA_Q_* SPI_MOSI}]
set_output_delay -max 2.0 -clock IQ_CLK [all_outputs]
set_output_delay -min 0.0 -clock IQ_CLK [all_outputs]

set_false_path -from [get_ports RESETB]
set_false_path -from [get_ports HOST_CS]
set_false_path -from [get_ports SPI_SCK]

# --- Scoped multicycle: ONLY the three paced DSP blocks get 3 cycles ----------
# Net names retain hierarchy ('.' separator) after flatten; cell names do not.
set paced_nets [get_nets -hierarchical {u_dec.* u_sc.* u_tacc.*}]

set_multicycle_path 3 -setup -through $paced_nets
set_multicycle_path 2 -hold  -through $paced_nets

# u_comb (MRC combiner) is INTENTIONALLY left at single-cycle — honest test of
# its per-clock serialized multiply.  Register bank, SPI, IRQ, JTAG also MCP=1.
