# pnr_32m_scoped_v25_b6.sdc
# v25_b6 = v20_baseline_minff adapted for the B6 packet_ctrl_fsm rewrite
#   (area roadmap 7/8): the three 32-bit absolute deadline registers
#   acq_timeout_q/wpend_timeout_q/pkt_end_q are now narrow DOWN-COUNTERS
#   acq_cnt[19:0]/wpend_cnt[19:0]/pkt_cnt[22:0], loaded once in ST_ACQ_SETUP
#   and decremented per captured sample (iq_tick).
#   SDC deltas vs v20_baseline_minff:
#     * pcfsm_timeout_regs re-pointed at the new counter register nets.
#     * The three -through exception blocks (qs_srcs / lat_timing_ref / M_val)
#       are KEPT: they now relax only the one-shot ST_ACQ_SETUP load arc.
#       The per-tick decrement path (cnt -> cnt-1 -> cnt) does NOT traverse
#       any -through net, so it stays honestly MCP=1 IN THIS P&R SDC; likewise
#       the live sample_count (elapsed-correction) operand into the load.
#       [2026-08-27] Both were revisited once test_mcp_iq_samp_cnt_settle.py
#       (job 5120) proved iq_tick == dcr_valid is 1-in-64: they are now MCP=3
#       in the SIGNOFF SDC only (pnr_32m_scoped_v25_b6_signoff.sdc, group
#       pcfsm_tick_decrement, v30). Kept single-cycle here so the P&R route
#       stays the job-5105 build -- see the NOTE further below.
#   VERIFY after STA: no STA-0361/0472 on the u_pcfsm.*_cnt patterns (the
#   silent-no-op failure mode this file's history documents).
#
# pnr_32m_scoped_v20.sdc
# v24 = v23 + the RTL fix for Open Risk #39's write-arc dishonesty.
#   packet_ctrl_fsm.v previously computed acq_timeout_q/wpend_timeout_q/
#   pkt_end_q combinationally from the LIVE `timing_ref` input on the very
#   same edge as `sc_lock` -- a genuine single-cycle arc that the v20 blanket
#   relaxation (superseded by v21) had dishonestly budgeted at 3 cycles.
#   Once v21 narrowed the relaxation to only quasi-static rb_* sources, this
#   arc was left honestly single-cycle and STA correctly exposed it as a real
#   violation (`timing_ref[7] -> acq_timeout_q[31]`, -15.69 ns, job 3367).
#   FIX (RTL, not SDC): packet_ctrl_fsm.v now only latches `lat_timing_ref
#   <= timing_ref` on the sc_lock edge (a plain register copy), and computes
#   acq_timeout_q/wpend_timeout_q/pkt_end_q ONE CYCLE LATER, in a dedicated
#   `ST_ACQ_SETUP` state, from `lat_timing_ref` -- which does not change again
#   until the next sc_lock edge (thousands of cycles away). That makes the
#   `lat_timing_ref -> {acq_timeout_q, wpend_timeout_q, pkt_end_q}` arc
#   genuinely tolerant of a multicycle exception, same honest-quasi-static
#   justification as every other relaxation in this file -- not a blanket
#   `-to` over a fast-changing operand. See `src/control/packet_ctrl_fsm.v`.
#
# v23 = v22 + a fourth missed cone found while verifying v22 (job 3368,
#   RUN_2026-07-13_00-39-09): with the two v22 clusters (packet_active ->
#   u_sc.acc_ci0, rb_bw_sel -> u_sc.eval_step/mul_start) gone from the worst-
#   path position, the new worst SS path (-16.60 ns) is rb_bw_sel ->
#   u_sc.timing_ref[31] directly -- untouched by either v21 or v22.
#   sc_detector.v:449 computes `sc_off = n_hits_p1 << (sf + sample_shift)`,
#   which feeds `timing_ref` alongside eval_sample_mark. v21's
#   `timing_ref_reg` scoping only covered the `rb_sc_hits_req` source (the
#   n_hits_p1 operand); it never covered the `sf`/`sample_shift` operand of
#   the SAME shift expression, because that gap wasn't visible until v22
#   cleared the two bigger violators masking it -- same "-through wildcard
#   leaves an unscoped sibling arc" pattern as every entry in this file.
#   FIX: reuse the already-defined `timing_ref_reg` (v21, further below --
#   the executable set_multicycle_path commands for this cone live right
#   after that definition, not here, since Tcl requires $timing_ref_reg to
#   be `set` before it's referenced) and add rb_sf_cfg/rb_sample_shift/
#   rb_bw_sel as an additional quasi-static `-through` source, same honest
#   justification as every other rb_sf_cfg/rb_bw_sel scoping in this file
#   (write-gated to !packet_active, Open Risk #31/#32).
#
# v22 = v21 + two more missed cones inside sc_detector (u_sc), Open Risk #40.
#   Same "-through <hierarchy-wildcard> misses a cross-boundary/optimized-
#   away net" bug class as every entry in this file's history. Netlist
#   cross-check (job 3367, RUN_2026-07-12_21-56-16) traced the worst SS path
#   (-16.01 ns) as packet_active -> packet_done_pulse -> u_sc.acc_ci0[19]:
#   packet_active/packet_done_pulse are TOP-LEVEL nets (trouper_top.v,
#   sourced from packet_ctrl_fsm), not `u_sc.*`-prefixed, so the existing
#   `-through u_sc.*` paced_nets wildcard (below) never matches this path --
#   the destination register's own Q net happens to be named
#   u_sc.acc_ci0[19], but that's downstream of the violating arc, not part
#   of it. A second cluster (200 violators) is the same failure mode:
#   rb_bw_sel feeds sc_detector's M_val (case(sf)<<sample_shift,
#   sc_detector.v:141-149), which gates the symbol-boundary condition at
#   sc_detector.v:364 -- rb_bw_sel is also a top-level net, never
#   `u_sc.*`-prefixed.
#   Two genuinely quasi-static sources, two honest fixes:
#   (1) sc_clr (= packet_done_pulse, falling edge of packet_active) only
#       pulses once per packet re-arm (TRPR-SCD-014, Open Risk #2's fix).
#       The registers it resets (sc_detector.v:492-507) aren't touched again
#       until the next real correlation event -- Open Risk #27 item 4
#       measures a minimum ~256-sample (many-thousand-clock) SC hold-off
#       after del_rdy, so a 3-cycle setup budget is trivially safe, same
#       justification class as the v15 del_offset_r / v21 pcfsm fixes.
#   (2) rb_sf_cfg/rb_sample_shift/rb_bw_sel are packet-active write-gated
#       (Open Risk #31/#32) -- quasi-static, host (kHz) rate, the same
#       source class already scoped for pcfsm/tacc above. They drive M_val,
#       which gates the symbol-boundary snapshot/reset block
#       (sc_detector.v:364-385).
#   Scope = -through <quasi-static source net> -to <specific dff cells>,
#   never a bare `-to` or a hierarchy wildcard alone (same discipline as
#   v21). A fast/real path into any of these registers that does NOT route
#   through the named quasi-static source (e.g. eval_step's own mul_done-
#   driven increment at sc_detector.v:426) is untouched and stays honestly
#   single-cycle.
# v26 (2026-08-15): the sc_clear exception is WITHDRAWN, not narrowed.
#
# It was unsound in a way none of the other groups are: `packet_done_pulse` is
# a registered ONE-CYCLE pulse (trouper_top.v:594-596) into synchronous-clear
# registers that sample every cycle, so the capture is at t+1 and there was
# never a 3-cycle settling window to grant.  It also bought no timing -- with
# the exception removed the cone MEETS across all 148 endpoint cells:
#
#     max_ss_125C_3v00   +3.94 ns    (SGE job 4374)
#     max_ss_125C_4v50  +13.29 ns    (SGE job 4373)
#
# measured on job 3738's routed netlist under an MCP-free SDC
# (rtl-test/ol_trouper_top/sc_clr_slack.tcl).  A single pulse into clear
# enables has trivial logic depth despite the 107-flop-bit fanout, so this arc
# times honestly.  Deleting it removes risk for zero timing cost; the
# alternative considered and rejected was stretching the pulse to >=3 cycles,
# which would have needed a dedicated signal (packet_done_pulse also drives
# packet_end into u_psram and an IRQ set bit).  See Open Risks #43.

set sc_qs_srcs [get_nets -hierarchical {rb_sf_cfg* rb_sample_shift* rb_bw_sel*}]
set sc_boundary_regs [get_cells -of_objects \
    [get_nets -hierarchical {u_sc.sym_cnt[*] \
        u_sc.eval_ci0[*] u_sc.eval_cq0[*] u_sc.eval_E0cur[*] u_sc.eval_E0del[*] \
        u_sc.eval_mag_acc[*] u_sc.eval_e_acc[*] u_sc.eval_step[*] \
        u_sc.eval_busy u_sc.mul_start u_sc.eval_sample_mark[*] \
        u_sc.acc_ci0[*] u_sc.acc_cq0[*] u_sc.acc_E0cur[*] u_sc.acc_E0del[*]}] \
    -filter {ref_name =~ *dff*}]
set_multicycle_path 3 -setup -through $sc_qs_srcs -to $sc_boundary_regs
set_multicycle_path 2 -hold  -through $sc_qs_srcs -to $sc_boundary_regs
#
# v21 = v20 + three missed rb_* -> derived-register cones scoped (Open Risk
#   #39), plus the pcfsm timeout-register relaxation narrowed from a blanket
#   `-to` (which silently also covered the timing_ref-driven operand) to
#   `-from <quasi-static rb_* srcs> -to <regs>`.
#   BUG: the v20 blanket `-to pcfsm_timeout_regs` MCP=3 relaxes ALL paths
#   landing on acq_timeout_q/wpend_timeout_q, including the operand that
#   begins at `timing_ref` (sc_detector.v:441/450, set on the SAME edge as
#   sc_lock). packet_ctrl_fsm latches these timeout regs on the very next
#   edge (`sc_lock && !sc_lock_prev`, 1 cycle after sc_detector's write) -- so
#   the timing_ref -> adder -> {acq_timeout_q, wpend_timeout_q, pkt_end_q} arc
#   has only 1 REAL cycle of margin, not the 3 the blanket relaxation grants
#   it. Silicon could latch a corrupt per-packet timeout if the adder's
#   physical delay lands between 1 and 3 clock periods.
#   Separately, `pkt_end_q` (same always-block, same edge, same
#   timing_ref-plus-quasi-static-shift arithmetic as acq_timeout_q/
#   wpend_timeout_q) was simply omitted from the v20 `get_nets` list below --
#   its rb_sf_cfg-sourced worst path (-20.4 ns, current SS floor) never got
#   scoped at all.
#   Same class of miss on two more cones: `rb_sc_hits_req -> timing_ref`
#   (inside u_sc; the destination net keeps its top-level name `timing_ref`,
#   not `u_sc.timing_ref`, because it wires straight through to a top-level
#   net of the same name -- the `u_sc.*` wildcard further below never matches
#   it) and `rb_tacc_window_syms -> u_tacc.acc_end`/`acc_start` (the arriving
#   cone is fully anonymized by synthesis, so `-through [get_nets
#   -hierarchical u_tacc.*]` never sees it either -- same failure mode as the
#   v20 pcfsm bug this header describes).
#   FIX: scope all four cones by `-from <the specific quasi-static reg_bank
#   net(s)> -to <the specific destination register(s)>`, never by a blanket
#   `-to` alone. This is deliberately narrower than the superseded v20 pcfsm
#   fix below: it relaxes only the timing arcs that actually originate at a
#   quasi-static rb_* source (host-writable, kHz-rate, long-settled by the
#   time any hit/lock event samples it) and leaves every path from a
#   fast-changing operand (timing_ref, eval_sample_mark, sample_count) at
#   honest single-cycle, where STA will now correctly flag it if it is a real
#   violation instead of hiding it under someone else's multicycle budget.
# NOTE: OpenSTA's set_multicycle_path -from only accepts clock/instance/pin
# objects, not Net objects ("unsupported object type Net" at STA time, caught
# in the v21 job-3365 signoff attempt) -- unlike -through, which does accept
# nets (see the dbg_nets/rb_write_bus/paced_nets precedent below). So the
# quasi-static-source scoping below uses -through, not -from, for the source
# side; -to stays on the destination register cells as before. A path is only
# relaxed if it both routes through the quasi-static net AND lands on the
# scoped register, so a timing_ref/sample_count-only path (never touching the
# quasi-static net) is untouched and stays honestly single-cycle.
# rb_bw_sel is included alongside rb_sample_shift because synthesis merged
# the `rb_sample_shift = rb_bw_sel ? 2'd2 : 2'd1` ternary straight into
# rb_bw_sel's fanout -- rb_sample_shift never survives as its own net on the
# worst path (confirmed: job 3366 signoff, the -27.19 ns SS violator's
# post-register net is literally named `rb_bw_sel`, not `rb_sample_shift`),
# so -through rb_sample_shift* alone silently missed it, the same failure
# mode as every other bug documented in this file's history.
set pcfsm_qs_srcs [get_nets -hierarchical {rb_sf_cfg* rb_sample_shift* rb_bw_sel* \
    rb_pkt_timeout_syms* rb_tacc_window_syms*}]
set pcfsm_timeout_regs [get_cells -of_objects \
    [get_nets -hierarchical {u_pcfsm.acq_cnt[*] u_pcfsm.wpend_cnt[*] \
                              u_pcfsm.pkt_cnt[*]}] \
    -filter {ref_name =~ *dff*}]
set_multicycle_path 3 -setup -through $pcfsm_qs_srcs -to $pcfsm_timeout_regs
set_multicycle_path 2 -hold  -through $pcfsm_qs_srcs -to $pcfsm_timeout_regs

# v24: lat_timing_ref -> {acq_timeout_q, wpend_timeout_q, pkt_end_q} (Open Risk
# #39 write-arc fix, see v24 header at top of file). packet_ctrl_fsm.v now
# computes these three registers from lat_timing_ref one cycle after it is
# latched, in ST_ACQ_SETUP, instead of combinationally from the live
# timing_ref input on the same edge as sc_lock. lat_timing_ref is stable from
# the moment it's latched until the next sc_lock edge (thousands of cycles
# later), so -- unlike the superseded v20 blanket relaxation this replaces --
# this exception is honest: the source genuinely cannot arrive with a
# different value mid-relaxation-window.
set pcfsm_lat_timing_ref [get_nets -hierarchical {u_pcfsm.lat_timing_ref[*]}]
set_multicycle_path 3 -setup -through $pcfsm_lat_timing_ref -to $pcfsm_timeout_regs
set_multicycle_path 2 -hold  -through $pcfsm_lat_timing_ref -to $pcfsm_timeout_regs

# v24: u_pcfsm.M_val -> {acq_timeout_q, wpend_timeout_q} (Open Risk #40's
# "M_val not itself explicitly scoped" residual, confirmed as the new worst
# path (-5.15 ns) once the lat_timing_ref fix above closed the write arc).
# packet_ctrl_fsm.v:46-49 has its OWN M_val register (`M_val <= 1 <<
# (sf+sample_shift)`), separate from sc_detector's, recomputed every cycle
# from sf/sample_shift -- but sf/sample_shift are themselves rb_sf_cfg/
# rb_bw_sel-derived and write-gated to !packet_active (Open Risk #31/#32), so
# M_val only actually changes at host rate, same quasi-static class as every
# other exception in this file. M_val's own registered Q net is the source of
# this cone (not rb_sf_cfg directly -- the path never touches the rb_*  nets,
# only M_val's), which is why the existing $pcfsm_qs_srcs -through list (rb_*
# nets) never matched it.
set pcfsm_mval [get_nets -hierarchical {u_pcfsm.M_val[*]}]
set_multicycle_path 3 -setup -through $pcfsm_mval -to $pcfsm_timeout_regs
set_multicycle_path 2 -hold  -through $pcfsm_mval -to $pcfsm_timeout_regs

# v27: rb_sf_cfg -> u_pcfsm.M_val itself (Open Risk #46/1117sq-margin follow-up,
# job 4501: SS worst path -22.25 ns, `rb_sf_cfg[3]` -> clkinv/nand4/nand2/nor4
# -> `u_pcfsm.M_val[3]` D pin -- i.e. the WRITE arc into M_val, not the read
# arc out of it that $pcfsm_mval above already covers). This is the converse
# gap from the one the v24 block above closed: $pcfsm_qs_srcs's -through list
# already includes rb_sf_cfg*/rb_sample_shift*/rb_bw_sel*, so it DOES match
# this path -- but its -to list is $pcfsm_timeout_regs (acq_cnt/wpend_cnt/
# pkt_cnt), which M_val's own register is not a member of. The path was never
# excepted by either block: $pcfsm_qs_srcs matches-through-but-not-to, $pcfsm_mval
# matches-to-but-not-through (M_val is that group's SOURCE, not its destination).
# Same justification as both: M_val is combinationally recomputed every cycle
# from sf/sample_shift (packet_ctrl_fsm.v:46-49, `M_val <= 1 << (sf+sample_shift)`,
# no load enable), but sf/sample_shift only change at host write rate and are
# write-gated to !packet_active (Open Risk #31/#32) -- M_val genuinely differs
# from its previous value only in the handful of cycles after a legitimate
# config write, same quasi-static class as every exception in this file.
# cocotb/tests/test_mcp_pcfsm_settle.py's SettleMonitor already includes M_val
# in its monitored source set and asserts it (like sf/sample_shift) is stable
# for >=3 cycles before the ST_ACQ_SETUP capture -- that is the architectural
# half of this exception's proof (nothing downstream needs a correct M_val
# before 3 settled cycles have passed); this SDC change is what makes STA
# actually check the physical implementation meets that same budget on the
# write side. Not yet re-run post-change -- see mcp_audit_manifest.json entry.
set pcfsm_mval_regs [get_cells -of_objects \
    [get_nets -hierarchical {u_pcfsm.M_val[*]}] -filter {ref_name =~ *dff*}]
set_multicycle_path 3 -setup -through $pcfsm_qs_srcs -to $pcfsm_mval_regs
set_multicycle_path 2 -hold  -through $pcfsm_qs_srcs -to $pcfsm_mval_regs

# v21: rb_tacc_window_syms -> u_tacc.acc_start/acc_end. Same arithmetic shape
# as the pcfsm block above (a fast operand -- timing_ref or sample_count --
# plus a quasi-static shifted window width), same narrow -through/-to scope so
# the timing_ref/sample_count-sourced paths stay honestly single-cycle.
set tacc_qs_srcs [get_nets -hierarchical {rb_tacc_window_syms* rb_sf_cfg* rb_sample_shift* rb_bw_sel*}]
set tacc_window_regs [get_cells -of_objects \
    [get_nets -hierarchical {u_tacc.acc_start[*] u_tacc.acc_end[*]}] \
    -filter {ref_name =~ *dff*}]
set_multicycle_path 3 -setup -through $tacc_qs_srcs -to $tacc_window_regs
set_multicycle_path 2 -hold  -through $tacc_qs_srcs -to $tacc_window_regs

# NOTE (2026-08-27): three more paced/idle-bound cones -- the training_acc
# Zpair_i*/Zpair_q*/Zdiag_* accumulate recurrence (group tacc_accumulate, v28),
# dcr_valid -> iq_samp_cnt[*] (group iq_samp_cnt, v29), and the packet_ctrl_fsm
# B6 down-counter load(sample_count operand)+decrement arcs (group
# pcfsm_tick_decrement, v30) -- are ALSO MCP=3/2 class, but their `-to`
# exceptions live in the SIGNOFF SDC only (pnr_32m_scoped_v25_b6_signoff.sdc),
# NOT here. Reason: adding paced MCPs to the P&R SDC perturbs the post-GRT
# resizer enough to strand the IQ_CLK root clkbuf with no routing access point
# (DRT-0073, job 5112). Keeping the P&R SDC identical to job 5105 keeps that
# route reproducible while letting signoff STA report all three cones honestly
# at MCP=3. Applying them P&R-wide would also let the resizer under-build those
# paths against the 3-cycle budget; leaving them single-cycle for P&R is the
# conservative choice.

# v21: rb_sc_hits_req -> timing_ref (inside u_sc, but the destination net
# survives synthesis under its top-level name -- see bug note above -- so
# match both forms). sc_hits_req only feeds the small (<=4x M) offset
# subtracted from eval_sample_mark; eval_sample_mark's own path into
# timing_ref is NOT in this -through list and stays honestly single-cycle.
set timing_ref_reg [get_cells -of_objects \
    [get_nets -hierarchical {timing_ref[*]}] \
    -filter {ref_name =~ *dff*}]
set timing_ref_hits_srcs [get_nets -hierarchical {rb_sc_hits_req*}]
set_multicycle_path 3 -setup -through $timing_ref_hits_srcs -to $timing_ref_reg
set_multicycle_path 2 -hold  -through $timing_ref_hits_srcs -to $timing_ref_reg

# v23: rb_sf_cfg/rb_sample_shift/rb_bw_sel -> timing_ref (see v23 header at
# top of file). Same $timing_ref_reg endpoint as the v21 rb_sc_hits_req fix
# immediately above -- this is the OTHER operand of sc_detector.v:449's
# `sc_off = n_hits_p1 << (sf + sample_shift)` shift, missed by v21/v22.
set timing_ref_cfg_srcs [get_nets -hierarchical {rb_sf_cfg* rb_sample_shift* rb_bw_sel*}]
set_multicycle_path 3 -setup -through $timing_ref_cfg_srcs -to $timing_ref_reg
set_multicycle_path 2 -hold  -through $timing_ref_cfg_srcs -to $timing_ref_reg
#
# v20 = v19 with the packet_ctrl_fsm MCP scope CORRECTED (same class of bug as
#   the v15 barrel-shift no-op below). (SUPERSEDED BY v21 ABOVE -- header kept
#   for the v19 bug history; the active set_multicycle_path commands for this
#   cone now live in the v21 block above.)
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
#   CORRECTION (v21, Open Risk #39): that last sentence was wrong for the
#   timing_ref operand specifically -- the FSM reads/re-derives from
#   timing_ref on the very next cycle (see v21 header above), so a blanket
#   `-to` here was dishonest. The active commands for this cone now live in
#   the v21 `-from $pcfsm_qs_srcs -to $pcfsm_timeout_regs` block above; no
#   set_multicycle_path is issued here to avoid a conflicting/duplicate
#   (and wider) constraint on the same endpoints.
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

# Host SPI is a separate 2 MHz Mode-0 clock domain.  SPI_MOSI is synchronous
# to SPI_SCK, never IQ_CLK; SPI_SCK and IQ_CLK communicate only through the
# explicit toggle/mailbox CDC in spi_slave.v.
# SPI_SCK is deliberately NOT declared a clock in this P&R SDC, so TritonCTS
# builds no clock tree for it and SPI_SCK routes as an ordinary net.  It is
# still a clock in the SIGNOFF SDC, so the domain is fully constrained at
# signoff STA -- only the P&R-time tree is suppressed.
#
# Why: SPI_SCK is a 2 MHz clock with 51 sinks.  CTS expanded it into 5 clock
# nets driven by four clkbuf_16 -- the widest cell in the set -- on leaf nets
# of 2-7 sinks, and detailed routing could not reach the I pin of one of them
# (DRT-1231).  Jobs 5281/5282/5283 failed at densities 65/63/60 (63 and 60 on
# the identical buffer, so it is deterministic, not a placement lottery), and
# job 5285 showed the buffer list is not the constraint: adding clkbuf_4 left
# CTS still choosing clkbuf_16.  Dropping the tree fixed it outright --
# job 5284 routes 78/78, DRC 0 / XOR 0 / LVS clean / antenna 0.
#
# Verified not to cost SPI timing (job 5284 signoff STA vs job 5279 baseline):
# worst SPI_SCK setup 241.77 ns MET (was 241.14), worst hold 2.10 ns MET
# (was 1.69), against a 500 ns period.  A 2 MHz clock needs no balanced tree.
#
# Do NOT re-add the create_clock here without re-testing routing; do NOT remove
# it from the signoff SDC.  See Open Risks #6 and #54.
# create_clock -name SPI_SCK -period 500.0 [get_ports SPI_SCK]
# set_clock_groups -asynchronous -group [get_clocks IQ_CLK] -group [get_clocks SPI_SCK]
set_false_path -from [get_ports SPI_SCK]

# Zero board-delay baseline: this checks the ASIC's SPI-clocked logic but is
# NOT pad-interface signoff.  Replace these with the selected RPi's launch/
# sample requirements and measured PCB flight-time before tapeout.
# Dropped with the create_clock above -- a -clock reference to an undeclared
# clock is an error.  Present unchanged in the signoff SDC, which is where
# these are actually checked.
set_false_path -from [get_ports SPI_MOSI]
set_false_path -to   [get_ports SPI_MISO_OUT]

# IQ vectors are reassembled inside trouper_top; the physical top-level ports
# are scalar per antenna.  Constrain the actual pad ports, not the internal
# IQ_DATA_I/Q vector nets (which get_ports cannot see).
#
# Open Risk #70: the SX1257 presents its 1-bit I/Q streams valid around the
# FALLING edge of the shared clock, so trouper_top samples these pads on
# `negedge IQ_CLK` (mid data-eye) and retimes onto `posedge IQ_CLK` before the
# datapath consumes them.  This constraint is the pad -> negedge-FF half-period
# input path: data launches on the SX1257's rising IQ_CLK edge, -max 6.0 is a
# baseline covering SX1257 clock-to-data + PCB flight (replace with the
# datasheet tCK-to-data and measured flight time before tapeout), and it is
# checked against the falling capture edge ~15.6 ns later.
set iq_input_ports [get_ports {IQ_DATA_I_0 IQ_DATA_I_1 IQ_DATA_I_2 IQ_DATA_I_3 \
                               IQ_DATA_Q_0 IQ_DATA_Q_1 IQ_DATA_Q_2 IQ_DATA_Q_3}]
set_input_delay  -max 6.0 -clock IQ_CLK $iq_input_ports
set_input_delay  -min 0.0 -clock IQ_CLK $iq_input_ports
# SPI_MISO_OUT is constrained to SPI_SCK above, so it must be excluded here.
# OpenSTA has no remove_from_collection (Synopsys-only; it errors out with
# "invalid command name" and kills pre-PNR STA -- probed on the chipathon26
# image, job 5211).  OpenSTA collections are plain Tcl lists and get_full_name
# works on a port, so filter by name instead.
set core_output_ports {}
foreach p [all_outputs] {
    if {[get_full_name $p] ne "SPI_MISO_OUT"} {
        lappend core_output_ports $p
    }
}
set_output_delay -max 2.0 -clock IQ_CLK $core_output_ports
set_output_delay -min 0.0 -clock IQ_CLK $core_output_ports

set_false_path -from [get_ports RESETB]
set_false_path -from [get_ports HOST_CS]

# --- Scoped multicycle: ONLY the four paced DSP blocks get 3 cycles ----------
# Net names retain hierarchy ('.' separator) after flatten; cell names do not.
# packet_ctrl_fsm (u_pcfsm) is scoped separately above via -from/-to registered
# endpoints (v21 fix) — it does not belong in this -through wildcard because
# its violating cone doesn't survive synthesis as a named net (see v21 header).
# Same reason u_tacc.acc_start/acc_end and u_sc's timing_ref write arc get
# their own -from/-to blocks above instead of relying on this wildcard.
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

# MCP audit contract.  mcp_audit.tcl sources this SDC and reads these named
# collections; do not make a new set_multicycle_path without adding its group
# to mcp_audit_manifest.json and this table.
set mcp_audit_groups {
    {sc_quasi_static          3 2 sc_qs_srcs           sc_boundary_regs}
    {pcfsm_quasi_static       3 2 pcfsm_qs_srcs        pcfsm_timeout_regs}
    {pcfsm_latched_timing_ref 3 2 pcfsm_lat_timing_ref pcfsm_timeout_regs}
    {pcfsm_mval               3 2 pcfsm_mval           pcfsm_timeout_regs}
    {pcfsm_mval_write         3 2 pcfsm_qs_srcs        pcfsm_mval_regs}
    {training_window          3 2 tacc_qs_srcs         tacc_window_regs}
    {timing_ref_hits          3 2 timing_ref_hits_srcs timing_ref_reg}
    {timing_ref_config        3 2 timing_ref_cfg_srcs  timing_ref_reg}
    {psram_barrel_shift       2 1 {}                   bshift_regs}
    {paced_dsp                3 2 paced_nets           {}}
    {regbank_write            2 1 rb_write_bus         {}}
}

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
