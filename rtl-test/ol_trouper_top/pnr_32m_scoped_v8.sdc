# pnr_32m_scoped_v8.sdc
# SCOPED honest multicycle (replaces blanket pnr_32m_mcp_v6.sdc).
#
# Rationale:
#   The blanket `set_multicycle_path 3 -from IQ_CLK -to IQ_CLK` (v6) relaxed
#   EVERY reg→reg path to 3 cycles.  That is only honest for the three 500 kS/s
#   DSP blocks that were re-coded to PACE their combinational MAC over 3 clocks
#   (one combinational result soaks all 3 cycles):
#       u_dec   — HB1/HB2 const-MAC (3-cycle MAC_WAIT pacing + h1bc snapshot)
#       u_sc    — Schmidl-Cox autocorr (3-cycle TDM_WAIT pacing + deferred count)
#       u_tacc  — all-pairs cross-correlator (dual-mult, 3-cycle active-cycle freeze)
#   Every OTHER reg advances its datapath EVERY clock and MUST meet the full
#   31.25 ns single-cycle budget.  Granting them 3 cycles is "functionally
#   optimistic" — it would pass STA but break in silicon.
#
#   This SDC therefore confines MCP=3 to paths INTERNAL to those three blocks
#   and forces honest single-cycle timing everywhere else (incl. u_comb, whose
#   per-clock state-machine multiply was previously hiding under the blanket).
#
# Expected fallout: any block that genuinely runs single-cycle but can't meet
#   31.25 ns at SS will now appear as a violator.  That is the POINT — those are
#   real bugs the blanket relaxation was masking.

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
# Match both '.' and '/' hierarchy separators that the flattened netlist may use.
set dec_cells  [get_cells -hierarchical {*u_dec*}]
set sc_cells   [get_cells -hierarchical {*u_sc*}]
set tacc_cells [get_cells -hierarchical {*u_tacc*}]

# Internal reg→reg paths of each paced block (the paced combinational MAC).
set_multicycle_path 3 -setup -from $dec_cells  -to $dec_cells
set_multicycle_path 2 -hold  -from $dec_cells  -to $dec_cells
set_multicycle_path 3 -setup -from $sc_cells   -to $sc_cells
set_multicycle_path 2 -hold  -from $sc_cells   -to $sc_cells
set_multicycle_path 3 -setup -from $tacc_cells -to $tacc_cells
set_multicycle_path 2 -hold  -from $tacc_cells -to $tacc_cells

# NOTE: paths CROSSING a block boundary (e.g. u_dec out → u_sc in) fall back to
# the default single-cycle check.  Those crossings are registered sample handoffs
# (reg→reg wire, no logic) so they meet 1 cycle trivially.
