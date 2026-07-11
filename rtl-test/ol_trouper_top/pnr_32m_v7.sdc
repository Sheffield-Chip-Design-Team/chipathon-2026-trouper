# pnr_32m_v7.sdc — trouper_top  (production)
#
# v7 over v6 (pnr_32m_mcp_v6.sdc):
#   - MCP=3 scoped to paths THROUGH iq_valid-gated nets only; blanket
#     "-from IQ_CLK -to IQ_CLK" removed (it waived CIC integrators,
#     sd_remod, PSRAM QPI sub-FSM, sample_count, SPI CDC — all full-rate).
#   - Port set matches trouper_top (removed TMS_GPIO0/TDI_GPIO1 which only
#     exist on mimo_rx_top; OpenSTA was silently dropping those constraints).
#   - PSRAM_SIO_IN_* now constrained vs PSRAM_SCK (was entirely unconstrained).
#   - SPI_MOSI/MISO constrained vs SPI_SCK (not IQ_CLK).
#   - GRP_* constrained vs IQ_CLK. ASSUMPTION: Grouper shares the 32 MHz
#     carrier clock (AHB-Lite link is synchronous). If the link is async,
#     replace with false_path + synchroniser qualification in RTL.
#   - No set_ideal_network; SPI_SCK treated as a real clock.
#
# Derived from pnr_32m_v7_analysis.sdc run (sta_v7_analysis, no-MCP baseline).
# SS WNS = -63.94 ns; 3037 setup violations audited across 24 unique startpoints.
# MCP applicability analysis:
#
#   COVERED by MCP=3 (iq_valid-gated nets, ~3000 violations):
#     cic_strobe ×4  (980) — IS the iq_valid strobe from each CIC branch
#     sc_lock        (827) — set/cleared only on iq_valid cycles
#     iq_valid       (136) — global iq_valid registered at trouper_top level
#     u_sc.tdm_busy  (163) — SC TDM active flag; transitions at iq_valid rate
#     u_sc.tdm_a/b_r  (90) — SC TDM correlation buffers A and B; updated at iq_valid
#     *eval_mul.*_q*  (20) — SC autocorr multiplier A+B input regs; loaded at iq_valid
#     u_sc.eval_hit   (77) — SC evaluation hit flag; set at iq_valid rate
#     comb1_valid ×4 (176) — CIC comb stage 1 valid; fires 1-in-128 (= cic_strobe+1)
#     comb2_valid ×4 (135) — CIC comb stage 2 valid; fires 1-in-128 (= cic_strobe+2)
#     training_armed  (66) — training_acc noise-armed flag; set at iq_valid rate
#     training_done    (4) — training_acc done flag; fired at iq_valid rate
#     timing_ref[*]    (1) — SC timing reference counter; updated at iq_valid
#     u_comb.*        (36) — MRC combiner FSM + weight regs; all x_valid=iq_valid gated
#     u_tacc.*        (80) — training_acc accumulators + sample_count; iq_valid gated
#
#   NOT COVERED (full-rate or timing-uncertain, ~1500 violations):
#     rb_noise_trig  (594) — reg_bank W1P noise-trig; fires for 1 cycle at any time
#                            (not iq_valid-synchronous); drives training_acc every-cycle
#                            check.  High-fanout pre-PNR artifact; expected to close
#                            post-P&R (MAX_FANOUT_CONSTRAINT=8 → buffer tree ~4 levels).
#     psram_replay   (188) — persistent PSRAM replay flag; timing uncertain vs iq_valid.
#     u_psram.state/sub (279) — PSRAM FSM + QPI sub-cycle counter; full-rate in S_QPI.
#     rb_decim_ratio (128) — drives CIC full-rate integration-stage count logic.
#     rb_sf_cfg[*]   (250) — config reg driving sc_detector SF-counter; may be full-rate.
#     REMOD_A_*/cic_bit* (33)— sd_remod output + CIC 1-bit pipeline; genuinely full-rate.
#     GRP_WE [in-reg] (254)— Grouper input port; 10 ns conservative input-delay assumption.
#
# MCP=3 safety argument (applies to all covered nets):
#   cic_strobe fires 1-in-128 cycles. Downstream blocks gate register updates with
#   "if (iq_valid) reg <= new_val", synthesised as D = iq_valid ? new_val : Q.
#   The DFF clocks every cycle; it only CAPTURES new data at iq_valid.
#   Launch at cycle N (iq_valid), next real capture at cycle N+128.
#   MCP=3 setup check: data must arrive by cycle N+3 (93.75 ns) — feasible at SS.
#   MCP=2 hold  check: data stable from cycle N+2 — satisfied since the launch
#   signal is stable for 127 cycles after the iq_valid pulse.

# ---- Clocks ----
create_clock -name IQ_CLK  -period 31.25 [get_ports IQ_CLK]
create_clock -name SPI_SCK -period 100.0 [get_ports SPI_SCK]
set_clock_uncertainty 0.5 [get_clocks IQ_CLK]
set_clock_uncertainty 0.5 [get_clocks SPI_SCK]

# PSRAM_SCK is an AND-gated copy of IQ_CLK (psram_buf_ctrl: assign sck = sck_en & clk_32m).
# Modelled as a generated clock so PSRAM_SIO_IN_* can be constrained source-synchronously.
# Known limitation: the AND-gate creates runt-pulse risk on disable; see design review note.
create_generated_clock -name PSRAM_SCK -source [get_ports IQ_CLK] \
    -divide_by 1 [get_ports PSRAM_SCK]

set_clock_groups -asynchronous \
    -group {IQ_CLK PSRAM_SCK} \
    -group {SPI_SCK}

# ---- IQ_CLK-domain inputs ----
set_input_delay -max 2.0 -clock IQ_CLK [get_ports {IQ_DATA_I_* IQ_DATA_Q_*}]
set_input_delay -min 1.0 -clock IQ_CLK [get_ports {IQ_DATA_I_* IQ_DATA_Q_*}]

# GRP_* — shared 32 MHz carrier clock assumed; 10 ns max is conservative.
set_input_delay -max 10.0 -clock IQ_CLK [get_ports {GRP_ADDR_* GRP_WDATA_* GRP_WE GRP_RE}]
set_input_delay -min 1.0  -clock IQ_CLK [get_ports {GRP_ADDR_* GRP_WDATA_* GRP_WE GRP_RE}]

# ---- PSRAM QPI read data: APS6404L tCO ≤ ~6.5 ns + ~2.5 ns board/pad ----
set_input_delay -max 9.0 -clock PSRAM_SCK [get_ports {PSRAM_SIO_IN_*}]
set_input_delay -min 1.5 -clock PSRAM_SCK [get_ports {PSRAM_SIO_IN_*}]

# ---- SPI inputs (Mode 0, 10 MHz max) ----
set_input_delay -max 15.0 -clock SPI_SCK [get_ports SPI_MOSI]
set_input_delay -min 0.0  -clock SPI_SCK [get_ports SPI_MOSI]

# ---- Asynchronous controls ----
set_false_path -from [get_ports RESETB]
set_false_path -from [get_ports HOST_CS]

# ---- IQ_CLK-domain outputs ----
set_output_delay -max 2.0 -clock IQ_CLK \
    [get_ports {REMOD_A_I REMOD_A_Q IRQ_OUT IRQ_GROUPER GRP_RDATA_* GRP_READY}]
set_output_delay -min 0.0 -clock IQ_CLK \
    [get_ports {REMOD_A_I REMOD_A_Q IRQ_OUT IRQ_GROUPER GRP_RDATA_* GRP_READY}]

# ---- PSRAM source-synchronous outputs: APS6404L tSP = 2 ns, tHD = 2 ns ----
set_output_delay -max 2.0  -clock PSRAM_SCK \
    [get_ports {PSRAM_SIO_OUT_* PSRAM_SIO_OE_* PSRAM_CE_N}]
set_output_delay -min -2.0 -clock PSRAM_SCK \
    [get_ports {PSRAM_SIO_OUT_* PSRAM_SIO_OE_* PSRAM_CE_N}]

# ---- SPI MISO: launched on falling SCK, master samples on next rising ----
set_output_delay -max 15.0 -clock SPI_SCK [get_ports SPI_MISO]
set_output_delay -min 0.0  -clock SPI_SCK [get_ports SPI_MISO]

# ---- Scoped multicycle paths ----
#
# All patterns below use -through [get_nets {...}] so that the constraint applies
# only to paths that TRAVERSE these specific nets.  This avoids incorrectly
# waiving the PSRAM QPI sub-cycle counter, the CIC integrators, the ΣΔ
# remodulator, and the SPI CDC — all of which are full-rate and must close
# single-cycle.
#
# Net name convention (Yosys flat synthesis): hierarchical names use dot notation,
# e.g. u_dec_0.cic_strobe, u_tacc.acc_diag_k[0].  Wildcards below cover all
# relevant bits without also matching unrelated full-rate signals.

# cic_strobe: the 1-in-128 decimation strobe from each of the 4 CIC branches.
# This IS the iq_valid signal before it is registered at trouper_top level.
set_multicycle_path 3 -setup -through [get_nets {*cic_strobe*}]
set_multicycle_path 2 -hold  -through [get_nets {*cic_strobe*}]

# iq_valid: the registered global enable strobe at trouper_top level.
set_multicycle_path 3 -setup -through [get_nets {iq_valid}]
set_multicycle_path 2 -hold  -through [get_nets {iq_valid}]

# sc_lock: the Schmidl-Cox packet-detected flag.  SET when iq_valid fires and
# the sliding autocorrelation exceeds SC_THR; CLEARED by packet_done_pulse
# (itself iq_valid-synchronous).  Transitions only on iq_valid cycle boundaries.
set_multicycle_path 3 -setup -through [get_nets {sc_lock}]
set_multicycle_path 2 -hold  -through [get_nets {sc_lock}]

# SC detector TDM busy and TDM correlation buffers A and B: updated at iq_valid rate
# (tdm_busy set when iq_valid fires; tdm_a_r/tdm_b_r are the two TDM correlation
# windows, both loaded from sample memory on each iq_valid pulse).
set_multicycle_path 3 -setup -through [get_nets {*tdm_busy* *tdm_a_r* *tdm_b_r*}]
set_multicycle_path 2 -hold  -through [get_nets {*tdm_busy* *tdm_a_r* *tdm_b_r*}]

# SC detector autocorrelation multiplier input pipeline registers (A and B inputs):
# loaded from the input sample buffer on each iq_valid pulse.
set_multicycle_path 3 -setup -through [get_nets {*eval_mul.a_q* *eval_mul.b_q*}]
set_multicycle_path 2 -hold  -through [get_nets {*eval_mul.a_q* *eval_mul.b_q*}]

# SC detector eval_hit flag: asserted when the SC correlation exceeds threshold
# during TDM evaluation; transitions at iq_valid rate.
set_multicycle_path 3 -setup -through [get_nets {*eval_hit*}]
set_multicycle_path 2 -hold  -through [get_nets {*eval_hit*}]

# CIC comb (differentiator) stage valid signals: comb1_valid = cic_strobe delayed 1
# cycle; comb2_valid = cic_strobe delayed 2 cycles.  Both fire 1-in-128 cycles and
# gate the CIC differentiator register updates identically to cic_strobe.
set_multicycle_path 3 -setup -through [get_nets {*comb1_valid* *comb2_valid*}]
set_multicycle_path 2 -hold  -through [get_nets {*comb1_valid* *comb2_valid*}]

# Training accumulator control flags: armed and done are set/cleared only when
# iq_valid fires (training_acc FSM is iq_valid-gated).  timing_ref is the SC
# timing reference counter output, updated once per iq_valid cycle.
set_multicycle_path 3 -setup -through [get_nets {training_armed training_done timing_ref*}]
set_multicycle_path 2 -hold  -through [get_nets {training_armed training_done timing_ref*}]

# MRC combiner: all state and weight registers are gated by x_valid = iq_valid.
set_multicycle_path 3 -setup -through [get_nets {u_comb.*}]
set_multicycle_path 2 -hold  -through [get_nets {u_comb.*}]

# Training accumulator: acc_diag_k, z_pair, sample_count — all iq_valid-gated.
set_multicycle_path 3 -setup -through [get_nets {u_tacc.*}]
set_multicycle_path 2 -hold  -through [get_nets {u_tacc.*}]
