# pnr_32m_scoped_v20.sdc
# v20 = v19 with the packet_ctrl_fsm MCP scope CORRECTED (same class of bug as
#   the v15 barrel-shift no-op below).
#   BUG in v19: scoped via `-through [get_nets -hierarchical {... u_pcfsm.*}]`.
#   u_pcfsm.acq_timeout_q[*]/wpend_timeout_q[*] DO exist as named nets post-
#   synthesis (verified: 855/173 occurrences in the post-CTS netlist), so the
#   wildcard was not literally empty — but the actual violating combinational
#   cone (the tacc_window_syms-driven barrel-shift + 32-bit adder computing
#   acq_timeout_next/wpend_timeout_next) is entirely anonymized to flat _NNNNN_
#   net names by synthesis; only the FF Q-side net keeps the hierarchical name,
#   and that net is never `-through` the arriving setup path. Result: WNS
#   -23.0809475842601 in job 3183, byte-identical to the unfixed job 3182 —
#   a silent no-op, confirmed (no STA-0361/STA-0472, no compile warnings; the
#   pattern just matched the wrong nets).
#   FIX: scope by the REGISTERED ENDPOINTS (acq_timeout_q/wpend_timeout_q,
#   which do survive synthesis) via `-to` the dff cells, exactly like the v18
#   psram_buf_ctrl fix below. Same quasi-static justification as u_tacc/rb_sf_cfg:
#   the source (rb_tacc_window_syms, reg_bank 0x27) is firmware-writable and
#   changes at host rate; timing_ref updates once per sc_lock event, not every
#   cycle. Relaxing the derived timeout compute to 3 cycles does not risk
#   latching a half-settled value because the FSM only reads acq_timeout_q/
#   wpend_timeout_q well after the sc_lock edge that seeds timing_ref.
set pcfsm_timeout_regs [get_cells -of_objects \
    [get_nets -hierarchical {u_pcfsm.acq_timeout_q[*] u_pcfsm.wpend_timeout_q[*]}] \
    -filter {ref_name =~ *dff*}]
set_multicycle_path 3 -setup -to $pcfsm_timeout_regs
set_multicycle_path 2 -hold  -to $pcfsm_timeout_regs
#
# v19 = v18 + u_pcfsm added to the scoped-MCP=3 wildcard. (SUPERSEDED — see above)
#
# v18 = v15 with the barrel-shift MCP=2 scope CORRECTED.
#   BUG in v15: scoped via `-through [get_nets {u_psram.del_n_c[*]
#   u_psram.del_offset_c[*]}]`.  Those are COMBINATIONAL barrel-shifter outputs;
#   synthesis optimizes them away, so the nets do not survive and STA reported
#   `STA-0361 net not found` + `STA-0472 no valid objects for -through` — the
#   MCP=2 was a SILENT NO-OP (SS WNS stayed at the unrelaxed ~-16 ns).
#   FIX: the REGISTERED endpoints del_n_r[*]/del_offset_r[*] DO survive synthesis
#   (verified in the post-route netlist).  Scope the cone by its register
#   endpoints with `-to`, filtering to the dff cells driving those nets.
# --- original v15 rationale (still valid) ---
# v15 = v14 + honest MCP=2 on the registered barrel-shift cone.
#   The rb_sf_cfg → '8<<(sf+shift)' / '1<<(sf+shift)' barrel shifter (~20 gates,
#   high-fanout weak-driven sf nets, terrible slew) was the routed worst path
#   (v12 -16.4, v14 -16.25 — registering del_offset_r/del_n_r only MOVED its
#   endpoint, it is still a 1-cycle compute from rb_sf_cfg into those FFs; the
#   whole top of the v14 violator list is rb_sf_cfg[0]→del_n_r[*]/del_offset_r[*],
#   TNS -6876).
#   This path is genuinely quasi-static: sf/sample_shift are write-locked during
#   a packet and only change at host (kHz) rate in IDLE, and del_offset_r/del_n_r
#   are re-read no sooner than the next iq_valid (>=64 clocks).  psram_buf_ctrl
#   now loads del_offset_r/del_n_r ONLY when sf==sf_prev (stable), giving the
#   shifter a >=2-cycle settle window before capture — so MCP=2 is HONEST (the
#   FF cannot latch a half-settled value on the config boundary), not the
#   blanket-MCP sin.  Scope = the del_n_r/del_offset_r REGISTER ENDPOINTS (which
#   survive synthesis), via `-to` the dff cells driving those nets.
set bshift_regs [get_cells -of_objects \
    [get_nets -hierarchical {u_psram.del_n_r[*] u_psram.del_offset_r[*]}] \
    -filter {ref_name =~ *dff*}]
set_multicycle_path 2 -setup -to $bshift_regs
set_multicycle_path 1 -hold  -to $bshift_regs
#
# SCOPED honest multicycle — v10 (adds paced u_comb).
#
# v8 BUG: scoped via `get_cells -hierarchical {*u_dec*}`.  Yosys flattens the
#   register CELLS to anonymous names (_62705_), so that pattern matched NOTHING
#   and the MCP=3 was a no-op → the whole design ran at honest single-cycle and
#   the decimator HB2 MAC surfaced at SS WNS -39.97 ns (job 2156).
#
# v9 FIX: hierarchy survives on NET names (e.g. `u_dec.hb2_stream[1]`), so scope
#   with `-through [get_nets ...]`.  v9 left u_comb at single-cycle and it
#   violated (its state machine has an 8x8 multiply + subtract in one state, ~50
#   ns at SS) — a real path the blanket v6 MCP=3 was masking.
#
# v10: u_comb is now PACED too (mrc_combiner.v: states 1..10 hold MAC_WAIT+1 = 3
#   clocks; 1 + 10x3 = 31 of the 64-clock window — idle-bound, fits).  So MCP=3
#   is honest for all four DSP blocks and u_comb.* is added to the scope.  Every
#   path OUTSIDE these (reg bank, SPI, IRQ, JTAG) still meets single-cycle.

create_clock -name IQ_CLK -period 31.25 [get_ports IQ_CLK]
set_clock_uncertainty 0.5 [get_clocks IQ_CLK]

set_input_delay  -max 2.0 -clock IQ_CLK [get_ports {IQ_DATA_I IQ_DATA_Q SPI_MOSI}]
set_input_delay  -min 1.0 -clock IQ_CLK [get_ports {IQ_DATA_I IQ_DATA_Q SPI_MOSI}]
set_output_delay -max 2.0 -clock IQ_CLK [all_outputs]
set_output_delay -min 0.0 -clock IQ_CLK [all_outputs]

set_false_path -from [get_ports RESETB]
set_false_path -from [get_ports HOST_CS]
set_false_path -from [get_ports SPI_SCK]

# --- Scoped multicycle: ONLY the four paced DSP blocks get 3 cycles ----------
# Net names retain hierarchy ('.' separator) after flatten; cell names do not.
# packet_ctrl_fsm (u_pcfsm) is scoped separately above via -to registered
# endpoints (v20 fix) — it does not belong in this -through wildcard because
# its violating cone doesn't survive synthesis as a named net (see v20 header).
set paced_nets [get_nets -hierarchical {u_dec.* u_sc.* u_tacc.* u_comb.*}]

set_multicycle_path 3 -setup -through $paced_nets
set_multicycle_path 2 -hold  -through $paced_nets

# --- 16 MHz clock-enable domain: reg_bank write decode (MCP=2) ----------------
# reg_bank is gated by ce_16m (updates every other cycle) and the bus (rb_we/
# rb_addr/rb_wdata) is CE-latched in the same phase, so the write-decode path is
# a GENUINE 2-cycle path (62.5 ns) — honest MCP=2, not optimistic.  reg_we is 2
# cycles wide so reg_bank writes exactly once per CE edge.  Scope = paths through
# the CE-latched bus nets (precisely the write decode into u_rb; does NOT touch
# u_rb's quasi-static config outputs, which stay single-cycle).
set rb_write_bus [get_nets {rb_we rb_addr[*] rb_wdata[*]}]
set_multicycle_path 2 -setup -through $rb_write_bus
set_multicycle_path 1 -hold  -through $rb_write_bus

# SPI master, IRQ controller, JTAG TAP stay at MCP=1.

# --- PSRAM debug readback: quasi-static, false_path -----------------------------
# u_psram.dbg_* is the host PSRAM debug-dump path (regs 0x72-0x76): reads happen
# at SPI speed (kHz) and are HARD-GATED to idle only (dbg_busy blocks them while
# packet_active=1, during pad handover, and before init).  Never a real-time
# path, so it has no business being a 31.25 ns single-cycle constraint.  This
# does NOT touch u_psram.state/sub — the LIVE QSPI engine, which stays MCP=1.
set dbg_nets [get_nets -hierarchical {u_psram.dbg_addr_cur[*] u_psram.dbg_buf[*] \
              u_psram.dbg_idx[*] u_psram.dbg_fetch_busy u_psram.dbg_mode u_psram.dbg_pend}]
set_false_path -through $dbg_nets
