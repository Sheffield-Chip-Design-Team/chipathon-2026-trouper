# create_project.tcl
# Creates the Vivado project for the LoRa MIMO DSP chain FPGA emulation.
# Target: Digilent Arty A7-100T (xc7a100tcsg324-1)
#
# Reuses the existing AFE eval block design (MicroBlaze + EthernetLite +
# AXI Quad SPI for SX1257) and adds:
#   - DSP domain clocked from the SX1257 CLK_OUT (sx_clk_out -> BUFG -> dsp_clk),
#     matching silicon where IQ_CLK is the front-end sample clock
#   - fpga_dsp_wrap (plain-Verilog module, not AXI) instantiating trouper_top.v
#     directly — spi_slave + reg_bank included, so the ASIC's real host-SPI
#     register interface is what gets exercised, not a parallel register file
#   - A second AXI Quad SPI core (axi_quad_spi_1) acting as the SPI MASTER
#     driving fpga_dsp_wrap's host_cs/spi_sck/spi_mosi/spi_miso internally
#     (no external pins) — MicroBlaze firmware issues real SPI transactions
#     against trouper_top's spi_slave exactly as the real RPi host would
#   - REMOD output pins on JD PMOD for oscilloscope / SX1302 connection
#
# Usage (from Vivado Tcl console):
#   source <path>/create_project.tcl
#
# Adjust the path variables below to match your installation.

# ============================================================================
# Paths
# ============================================================================
set proj_name  "arty_dsp_emul"
set proj_dir   [file normalize "[file dirname [info script]]/../vivado_proj"]
set rtl_dir    [file normalize "[file dirname [info script]]/../rtl"]
set asic_rtl   [file normalize "[file dirname [info script]]/../../src"]
# ASIC_SRC_DIR env override: build the ASIC RTL from another src/ tree, e.g. a
# `git archive <commit> src` extract, for A/B bench tests of an older revision
# (2026-11-19: /final's commit 7d0e749 vs the working tree). Unset = repo src/.
if {[info exists ::env(ASIC_SRC_DIR)] && $::env(ASIC_SRC_DIR) ne ""} {
    set asic_rtl [file normalize $::env(ASIC_SRC_DIR)]
    puts "## ASIC_SRC_DIR override: $asic_rtl"
}
set afe_bd_dir [file normalize "[file dirname [info script]]/../../../claude/fpga-afe-eval/build/vivado/arty_afe_eval/arty_afe_eval.srcs"]
set part       "xc7a100tcsg324-1"

# ============================================================================
# Create project
# ============================================================================
create_project $proj_name $proj_dir -part $part -force

# ============================================================================
# Add FPGA emulation RTL sources
# ============================================================================
set emul_srcs [list \
    "$rtl_dir/sync_fifo.v"        \
    "$rtl_dir/psram_model.v"      \
    "$rtl_dir/axi_inj_ctrl.v"     \
    "$rtl_dir/axi_clk_sync_mon.v" \
    "$rtl_dir/fpga_dsp_wrap.v"    \
]

# ASIC RTL (the modules under test — pulled from src/, the definitive ASIC
# source tree). fpga_dsp_wrap instantiates trouper_top.v directly, so the full
# tapeout module list is needed: fixed R=64 half-band decimator, no weight_gen
# (firmware weights), no noise_est (noise via training_acc Zdiag), SC delay
# via PSRAM (psram_buf_ctrl + on-chip BRAM psram_model in place of the
# APS6404L chip), plus spi_slave + reg_bank for the real host-SPI interface.
set asic_srcs [list \
    "$asic_rtl/top/trouper_top.v"              \
    "$asic_rtl/decimator/sd_decimator_poly.v" \
    "$asic_rtl/frontend/dc_removal.v"         \
    "$asic_rtl/frontend/sc_detector.v"        \
    "$asic_rtl/control/psram_buf_ctrl.v"      \
    "$asic_rtl/combiner/training_acc.v"       \
    "$asic_rtl/control/packet_ctrl_fsm.v"     \
    "$asic_rtl/combiner/mrc_combiner.v"       \
    "$asic_rtl/remod/sd_remod.v"              \
    "$asic_rtl/remod/sd_remod_multiplierless.v" \
    "$asic_rtl/debug/bringup_src.v"           \
    "$asic_rtl/control/spi_slave.v"           \
    "$asic_rtl/control/reg_bank.v"            \
]

# Bench-only override (Open Risks #72 slow-QPI test): PSRAM_BUF_CTRL_SRC swaps
# in a scratch copy of psram_buf_ctrl.v without touching src/. Unset = src/.
if {[info exists ::env(PSRAM_BUF_CTRL_SRC)] && $::env(PSRAM_BUF_CTRL_SRC) ne ""} {
    set pbc_src [file normalize $::env(PSRAM_BUF_CTRL_SRC)]
    puts "## PSRAM_BUF_CTRL_SRC override: $pbc_src"
    set asic_srcs [lreplace $asic_srcs 4 4 $pbc_src]
}

add_files -norecurse $emul_srcs
add_files -norecurse $asic_srcs
set_property file_type {Verilog} [get_files *.v]

# Constraints
add_files -fileset constrs_1 -norecurse \
    "[file dirname [info script]]/arty_dsp_emul.xdc"
# PSRAM_PIN_XDC env override: an extra XDC read AFTER arty_dsp_emul.xdc, so its
# PACKAGE_PIN/SLEW/DRIVE settings win -- e.g. the JB/JC breadboard pinout in
# tools/risk72_bench/breadboard_psram_pins_jball.xdc. Unset = JA pinout as before.
if {[info exists ::env(PSRAM_PIN_XDC)] && $::env(PSRAM_PIN_XDC) ne ""} {
    set pin_xdc [file normalize $::env(PSRAM_PIN_XDC)]
    puts "## PSRAM_PIN_XDC override: $pin_xdc"
    add_files -fileset constrs_1 -norecurse $pin_xdc
}
# RISK72_OVERSAMPLE (see the clk_wiz and ILA sections): 200 MHz pad-sampling ILA.
set risk72_oversample 0
if {[info exists ::env(RISK72_OVERSAMPLE)] && $::env(RISK72_OVERSAMPLE) ne "" && $::env(RISK72_OVERSAMPLE) ne "0"} {
    set risk72_oversample 1
    set os_xdc "[file dirname [info script]]/risk72_oversample.xdc"
    add_files -fileset constrs_1 -norecurse $os_xdc
    set_property USED_IN_SYNTHESIS false [get_files $os_xdc]
}

# ============================================================================
# Create block design
# NOTE: If the AFE eval BD already exists as a checkpoint, import it here.
# Otherwise build a minimal equivalent from scratch below.
# ============================================================================

# Option A: Import the existing AFE eval BD as a starting point.
# Uncomment if $afe_bd_dir points to a valid exported checkpoint.
#
# open_bd_design "$afe_bd_dir/sources_1/bd/system/system.bd"
# validate_bd_design
# save_bd_design

# Option B: Script-create a minimal BD (recommended for fresh builds)
create_bd_design "system"
current_bd_design [get_bd_designs system]

# --- Clock wizard (MMCM) — three outputs:
#   CLKOUT1 = 100 MHz  MicroBlaze + AXI peripherals (EmacLite, SPI, UART) bus.
#             EmacLite needs a comfortable AXI:MII clock ratio. At 32 MHz AXI
#             (1.28:1 over the 25 MHz MII clock) the EmacLite AXI↔MII CDC is
#             marginal and produces MII bit-slips → CRC/alignment errors. 100 MHz
#             (4:1) matches the proven Arty A7 EmacLite ping design.
#   CLKOUT2 = 32 MHz   LEGACY — no longer drives the DSP chain. The DSP domain is
#             now clocked from the SX1257 CLK_OUT (dsp_clk) to match silicon, so
#             this output is unused. Kept only to avoid renumbering CLKOUT3 (the
#             25 MHz PHY ref); safe to remove if that ref is also renumbered.
#   CLKOUT3 = 25 MHz   reference clock driven OUT to the Arty A7 Ethernet PHY
#             (TI DP83848, MII mode) on eth_ref_clk / pin G18. Without it the PHY
#             PLL never starts → no link, no link LED.
# VCO = 100*8 = 800 MHz gives integer divides for all three (8, 25, 32).
# BENCH_CLK_MHZ env override: rerate CLKOUT2 (the bench-mode dsp_clk, which
# psram_sck is directly gated from -- PSRAM_SCK_OUT = psram_sck_en_q & clk in
# trouper_top.v) to something other than 32 MHz. Added for the 2026-09-13
# external-PSRAM cable-margin diagnostic: does the debug write/read-back
# one-byte shift go away at a lower SCLK, confirming it's propagation delay
# over the flying leads rather than an RTL bug (the RTL was independently
# cleared by cocotb/psram_ops::test_dbg_write_readback_roundtrip, which is
# bit-exact at zero cable delay regardless of frequency). 800 MHz VCO divides
# integer-clean at 8/16/32; other values may not -- check the Vivado log for
# an achieved-vs-requested frequency mismatch warning.
set bench_clk_mhz 32.000
if {[info exists ::env(BENCH_CLK_MHZ)] && $::env(BENCH_CLK_MHZ) ne ""} {
    set bench_clk_mhz $::env(BENCH_CLK_MHZ)
    puts "## BENCH_CLK_MHZ set: CLKOUT2 (bench dsp_clk / psram_sck) <- ${bench_clk_mhz} MHz"
}
set clk_wiz [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_0]
set_property -dict [list \
    CONFIG.PRIM_IN_FREQ              {100.000} \
    CONFIG.NUM_OUT_CLKS             {3} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {100.000} \
    CONFIG.CLKOUT2_USED              {true} \
    CONFIG.CLKOUT2_REQUESTED_OUT_FREQ $bench_clk_mhz \
    CONFIG.CLKOUT3_USED              {true} \
    CONFIG.CLKOUT3_REQUESTED_OUT_FREQ {25.000} \
    CONFIG.RESET_TYPE                {ACTIVE_LOW} \
    CONFIG.RESET_PORT                {resetn} \
] $clk_wiz
# RISK72_OVERSAMPLE: add CLKOUT4 = 200 MHz (VCO 800 / 4) to clock the pad-sampling
# ILA. Only in that build, so every other image keeps the 3-output MMCM.
if {$risk72_oversample} {
    puts "## RISK72_OVERSAMPLE set: clk_wiz CLKOUT4 = 200 MHz for the pad-sampling ILA"
    set_property -dict [list \
        CONFIG.NUM_OUT_CLKS              {4} \
        CONFIG.CLKOUT4_USED              {true} \
        CONFIG.CLKOUT4_REQUESTED_OUT_FREQ {200.000} \
    ] $clk_wiz
}

# Connect external 100 MHz board clock to clk_wiz primary input
create_bd_port -dir I -type clk -freq_hz 100000000 clk100mhz
connect_bd_net [get_bd_ports clk100mhz] [get_bd_pins clk_wiz_0/clk_in1]

# Keep reset inputs inactive by default. C2 is the ChipKit ck_rst net, not an
# Arty pushbutton, and can be held low by attached hardware; using it as the
# MMCM reset prevents LOCKED and leaves the entire AXI fabric in reset. JTAG
# supplies the MicroBlaze debug reset used during firmware download.
set rst_const [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant xlconstant_1]
set_property -dict [list CONFIG.CONST_VAL {1} CONFIG.CONST_WIDTH {1}] $rst_const
connect_bd_net [get_bd_pins xlconstant_1/dout] [get_bd_pins clk_wiz_0/resetn]

# --- SX1257 CLK_OUT — the DSP-domain sample clock ---------------------------
# On silicon there is NO MMCM 32 MHz: trouper_top's IQ_CLK is the SX1257
# CLK_OUT (32 MHz), so the whole DSP chain runs on the front-end sample clock.
# Mirror that here — bring CLK_OUT in through a BUFG and clock the DSP domain
# from it, so the emulator samples hw_iq on the very clock that produced the
# data (a free-running MMCM 32 MHz would bit-slip against the board TCXO). All
# four radios share one TCXO (coherent), so any CLK_OUT works electrically; the
# XDC picks CLK_OUT_2 on JD F4 — the only one of the four on a P-side MRCC pin,
# i.e. the only pin usable as a single-ended clock input (F3/D3/C15 are N-side
# and the placer rejects them, Place 30-876). The MMCM's own 32 MHz output is
# retained as a free-running FPGA control clock; it does not clock Trouper DSP.
#
# Bring-up ordering (same as the real chip): CLK_OUT only appears once the
# SX1257 is configured, and that config goes over the RFFE SPI (axi_quad_spi_0,
# 100 MHz domain — independent of this clock). Until CLK_OUT toggles, rst_32m
# holds the DSP domain in reset (its sync flops never clock), which is exactly
# the desired power-up behaviour.
create_bd_port -dir I -type clk -freq_hz 32000000 sx_clk_out
set clkbuf [create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 sx_clk_bufg]
set_property CONFIG.C_BUF_TYPE {BUFG} $clkbuf
connect_bd_net [get_bd_ports sx_clk_out] [get_bd_pins sx_clk_bufg/BUFG_I]

set ctrl_clk [get_bd_pins clk_wiz_0/clk_out2]

# --- BENCH_CLK: no-AFE-board bench clocking --------------------------------
# When the BENCH_CLK env var is set (non-empty, != 0), clock the whole Trouper
# DSP domain from the on-board MMCM 32 MHz (clk_wiz_0/clk_out2) instead of the
# SX1257 CLK_OUT on F4. rst_32m then releases at power-up with no AFE board
# attached, so trouper_top's register interface + the injection->DSP->combiner
# ->remod chain run on the bench (drivable over the firmware's UDP 5007 I/Q
# inject path). This restores the pre-2026-07 emulator clocking.
#   NOT silicon-accurate -- a free-running MMCM 32 MHz bit-slips against a real
#   board TCXO, so this is bring-up / smoke-test only. The default build (env
#   unset) keeps dsp_clk = SX1257 CLK_OUT. The sx_clk_out port + BUFG are still
#   created either way so arty_dsp_emul.xdc stays valid; in bench mode the F4
#   BUFG output is simply unused.
#   BENCH_CLK also implies USE_EXT_PSRAM=0 (on-chip BRAM psram_model, JA pads
#   tied off -- see below) unless FORCE_EXT_PSRAM overrides it. Standalone
#   external-APS6404L bring-up (no AFE board, real chip on JA) needs BOTH env
#   vars: `BENCH_CLK=1 FORCE_EXT_PSRAM=1`. Verified against real hardware
#   2026-09-10/13 on the Arty A7 + APS6404L breakout on JA (see
#   fpga-emul/HARDWARE_SETUP.md) -- full QPI round-trip bit-exact once all
#   four SIO lines were seated; CE#/SCK/SIO measured directly on JA.
set bench_clk 0
if {[info exists ::env(BENCH_CLK)] && $::env(BENCH_CLK) ne "" && $::env(BENCH_CLK) ne "0"} {
    set bench_clk 1
}
if {$bench_clk} {
    puts "############################################################"
    puts "## BENCH_CLK set: Trouper DSP domain <- MMCM 32 MHz         "
    puts "##   (clk_wiz_0/clk_out2). NO AFE board required.           "
    puts "##   NOT silicon-accurate -- bench bring-up only.           "
    puts "############################################################"
    # dsp_clk: the 32 MHz sample-clock net used across the whole DSP domain.
    set dsp_clk $ctrl_clk
} else {
    # dsp_clk: the 32 MHz sample-clock net used across the whole DSP domain.
    set dsp_clk [get_bd_pins sx_clk_bufg/BUFG_O]
}

# proc_sys_reset for the 100 MHz AXI bus domain
set psr100 [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_100m]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins rst_100m/slowest_sync_clk]
connect_bd_net [get_bd_pins clk_wiz_0/locked]   [get_bd_pins rst_100m/dcm_locked]
connect_bd_net [get_bd_pins xlconstant_1/dout]  [get_bd_pins rst_100m/ext_reset_in]
connect_bd_net [get_bd_pins xlconstant_1/dout]  [get_bd_pins rst_100m/aux_reset_in]

# proc_sys_reset for the 32 MHz DSP domain — clocked by the SX1257 sample clock
# (dsp_clk), so it releases the DSP domain only once CLK_OUT is actually running.
# dcm_locked still gates on the MMCM lock (the 100 MHz infrastructure).
set psr32 [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_32m]
connect_bd_net $dsp_clk                          [get_bd_pins rst_32m/slowest_sync_clk]
connect_bd_net [get_bd_pins clk_wiz_0/locked]   [get_bd_pins rst_32m/dcm_locked]
connect_bd_net [get_bd_pins xlconstant_1/dout]  [get_bd_pins rst_32m/ext_reset_in]
connect_bd_net [get_bd_pins xlconstant_1/dout]  [get_bd_pins rst_32m/aux_reset_in]

# Free-running 32 MHz reset domain for FPGA-only AXI helpers. These peripherals
# must be reachable before SX1257 CLK_OUT exists, otherwise their clock
# converters stall the shared SmartConnect and firmware cannot configure the
# radios that generate CLK_OUT.
set psrctrl [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_ctrl32m]
connect_bd_net $ctrl_clk                        [get_bd_pins rst_ctrl32m/slowest_sync_clk]
connect_bd_net [get_bd_pins clk_wiz_0/locked]   [get_bd_pins rst_ctrl32m/dcm_locked]
connect_bd_net [get_bd_pins xlconstant_1/dout]  [get_bd_pins rst_ctrl32m/ext_reset_in]
connect_bd_net [get_bd_pins xlconstant_1/dout]  [get_bd_pins rst_ctrl32m/aux_reset_in]

# --- MicroBlaze — created after clock wizard so automation can resolve the clock
set mb [create_bd_cell -type ip -vlnv xilinx.com:ip:microblaze:11.0 microblaze_0]
set_property -dict [list \
    CONFIG.C_DEBUG_ENABLED     {1} \
    CONFIG.C_D_AXI             {1} \
    CONFIG.C_D_LMB             {1} \
    CONFIG.C_I_LMB             {1} \
    CONFIG.C_USE_ICACHE        {0} \
    CONFIG.C_USE_DCACHE        {0} \
    CONFIG.C_USE_HW_MUL        {1} \
    CONFIG.C_USE_DIV           {1} \
    CONFIG.C_USE_BARREL        {1} \
    CONFIG.C_USE_FPU           {0} \
] $mb

# MicroBlaze MCS-style automation (creates LMB BRAM, debug, AXI interconnect)
apply_bd_automation -rule xilinx.com:bd_rule:microblaze \
    -config { local_mem "64KB" ecc "None" cache "None" debug_module "Debug Only" \
              axi_periph "Enabled" axi_intc "0" clk "/clk_wiz_0/clk_out1 (100 MHz)" } \
    [get_bd_cells microblaze_0]

# --- EthernetLite --------------------------------------------------------------
set eth [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_ethernetlite:3.0 axi_ethernetlite_0]
set_property -dict [list CONFIG.C_INCLUDE_GLOBAL_BUFFERS {1}] $eth
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config { Clk_master "/clk_wiz_0/clk_out1 (100 MHz)" \
              Clk_slave  "Auto" Clk_xbar "Auto" \
              Master "/microblaze_0 (Periph)" \
              intc_ip "New AXI SmartConnect" master_apm "0" } \
    [get_bd_intf_pins axi_ethernetlite_0/S_AXI]

# Expose Ethernet MII ports
make_bd_intf_pins_external [get_bd_intf_pins axi_ethernetlite_0/MII]
make_bd_pins_external [get_bd_pins axi_ethernetlite_0/PHY_RST_N]
make_bd_pins_external [get_bd_pins axi_ethernetlite_0/PHY_MDC]
make_bd_intf_pins_external [get_bd_intf_pins axi_ethernetlite_0/MDIO]

# 25 MHz reference clock OUT to the PHY (pin G18), driven directly from clk_wiz
# CLKOUT3 — matching the proven-good Arty A7 EmacLite ping design.
create_bd_port -dir O -type clk eth_ref_clk
connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_ports eth_ref_clk]

# --- AXI Quad SPI (for SX1257) -----------------------------------------------
# Only 2 select bits: the MISO front-end board decodes chip-select from a 2-bit
# address (RFFE_NSS_A0/A1 -> on-board SN74LVC139A), so ss_io[3:2] have no board
# pin. Two bits keeps the SPI_0 interface matched to the constrained pins in the
# XDC (A18/B18) and avoids unconstrained-port warnings on ss_io[3:2].
# NOTE: this still emits a ONE-HOT select on the two lines. Reworking firmware to
# drive a true 2-bit ENCODED address into the 139A is the separate open TODO
# item (see fpga-emul/TODO.md "2-bit encoded NSS").
set spi [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_quad_spi:3.2 axi_quad_spi_0]
set_property -dict [list \
    CONFIG.C_SCK_RATIO      {16} \
    CONFIG.C_NUM_SS_BITS    {2} \
    CONFIG.C_SPI_MODE       {0} \
] $spi
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config { Clk_master "/clk_wiz_0/clk_out1 (100 MHz)" \
              Clk_slave  "Auto" Master "/microblaze_0 (Periph)" \
              intc_ip "Auto" master_apm "0" } \
    [get_bd_intf_pins axi_quad_spi_0/AXI_LITE]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins axi_quad_spi_0/ext_spi_clk]
make_bd_intf_pins_external [get_bd_intf_pins axi_quad_spi_0/SPI_0]

# --- AXI GPIO (1-bit output) for the NSS decoder enable (SN74LVC139A 1E-bar) -
# PCB review finding 4 (2026-07-08): the decoder had no enable pin routed, so
# it could never deselect all four radios. The 2026-07-12 schematic fix
# replaced the decoder with a 139A (has a per-decoder active-low enable, 1E)
# and routed 1E to a spare header pin (PCB J7 pin 10 = Arty J15, JB header) —
# confirmed via netlist export against miso_frontend commit 97d4322
# (2026-07-13): net RFFE_NSS_nEN ties U6 pin 1 (~1E) to J7.10 and the R21
# pull-up. That board-side fix had no FPGA-side counterpart until now: this
# GPIO is that counterpart. Idle/default is HIGH (decoder disabled, all four
# radios deselected) to match R21's pull-up power-up state; firmware drives it
# LOW once RFFE SPI is ready to talk to the radios (see rffe_nss_enable() in
# sw/main.c). Constrained to J15 in arty_dsp_emul.xdc.
set nss_en_gpio [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_nss_en_0]
set_property -dict [list \
    CONFIG.C_GPIO_WIDTH   {1} \
    CONFIG.C_ALL_OUTPUTS  {1} \
    CONFIG.C_DOUT_DEFAULT {0x00000001} \
] $nss_en_gpio
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config { Clk_master "/clk_wiz_0/clk_out1 (100 MHz)" \
              Clk_slave  "Auto" Master "/microblaze_0 (Periph)" \
              intc_ip "Auto" master_apm "0" } \
    [get_bd_intf_pins axi_gpio_nss_en_0/S_AXI]
create_bd_port -dir O rffe_nss_en
connect_bd_net [get_bd_pins axi_gpio_nss_en_0/gpio_io_o] [get_bd_ports rffe_nss_en]

# --- AXI Quad SPI (SPI MASTER driving trouper_top's host-SPI slave) --------
# Internal-only: standard (1-wire-each) master mode, single slave. Its
# sck_o/ss_o[0]/io0_o pins drive fpga_dsp_wrap's spi_sck/host_cs/spi_mosi, and
# fpga_dsp_wrap's spi_miso feeds back into io1_i. No external pins — this
# link never leaves the fabric.
#
# C_USE_STARTUP must be 0: the default (1) routes SCK through the 7-series
# STARTUP primitive (for booting off an SPI config flash) and does NOT expose
# sck_i/sck_o/sck_t as ordinary fabric pins at all — confirmed by generating
# this IP's instantiation template with each setting. We need a plain
# discrete SCK pin to wire straight to fpga_dsp_wrap, not the STARTUP path.
set spi_host [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_quad_spi:3.2 axi_quad_spi_1]
# HOST_SPI_SCK_RATIO env override (2026-09-13 harness-vs-hardware isolation):
# default 16 (100 MHz ext_spi_clk / 16 = 6.25 MHz host-SPI). Valid C_SCK_RATIO
# values are powers of 2 from 2 to 1024. Used to test whether the PSRAM debug
# port's read-pop (0x76) needs more margin between host-SPI bytes than 6.25 MHz
# gives it -- unrelated to psram_sck/the PSRAM's own QPI bus, which this does
# not touch.
set host_spi_sck_ratio 16
if {[info exists ::env(HOST_SPI_SCK_RATIO)] && $::env(HOST_SPI_SCK_RATIO) ne ""} {
    set host_spi_sck_ratio $::env(HOST_SPI_SCK_RATIO)
    puts "## HOST_SPI_SCK_RATIO set: axi_quad_spi_1 C_SCK_RATIO <- $host_spi_sck_ratio"
}
set_property -dict [list \
    CONFIG.C_SCK_RATIO      $host_spi_sck_ratio \
    CONFIG.C_NUM_SS_BITS    {1} \
    CONFIG.C_SPI_MODE       {0} \
    CONFIG.C_USE_STARTUP    {0} \
] $spi_host
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config { Clk_master "/clk_wiz_0/clk_out1 (100 MHz)" \
              Clk_slave  "Auto" Master "/microblaze_0 (Periph)" \
              intc_ip "Auto" master_apm "0" } \
    [get_bd_intf_pins axi_quad_spi_1/AXI_LITE]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins axi_quad_spi_1/ext_spi_clk]

# --- fpga_dsp_wrap (plain Verilog, not AXI) — instantiates trouper_top.v ----
# The hardware build drives the real APS6404L on the daughterboard (JA). The
# BENCH_CLK build is specifically for no-AFE replay, so select the wrapper's
# BRAM-backed PSRAM model as well as the MMCM DSP clock; otherwise the SC
# delay line has no memory and acquisition can never lock.
set dsp_wrap [create_bd_cell -type module -reference fpga_dsp_wrap fpga_dsp_wrap_0]
# FORCE_EXT_PSRAM env override: keep the MMCM 32 MHz bench clock (no AFE board)
# but still bring the real APS6404L pads out on JA, for standalone external-PSRAM
# bring-up. Without it, BENCH_CLK implies the on-chip BRAM psram_model.
set force_ext_psram 0
if {[info exists ::env(FORCE_EXT_PSRAM)] && $::env(FORCE_EXT_PSRAM) ne "" && $::env(FORCE_EXT_PSRAM) ne "0"} {
    set force_ext_psram 1
    puts "## FORCE_EXT_PSRAM set: external APS6404L pads on JA despite BENCH_CLK"
}
set_property CONFIG.USE_EXT_PSRAM [expr {($bench_clk && !$force_ext_psram) ? 0 : 1}] [get_bd_cells fpga_dsp_wrap_0]
set psram_qpi_clk_div 1
if {[info exists ::env(PSRAM_QPI_CLK_DIV)] && $::env(PSRAM_QPI_CLK_DIV) ne ""} {
    set psram_qpi_clk_div $::env(PSRAM_QPI_CLK_DIV)
    puts "## PSRAM_QPI_CLK_DIV set: external QPI pin rate <- dsp_clk / ${psram_qpi_clk_div}"
}
set_property CONFIG.PSRAM_QPI_CLK_DIV $psram_qpi_clk_div [get_bd_cells fpga_dsp_wrap_0]
connect_bd_net $dsp_clk [get_bd_pins fpga_dsp_wrap_0/clk]
connect_bd_net [get_bd_pins rst_32m/peripheral_aresetn] \
               [get_bd_pins fpga_dsp_wrap_0/rst_n]

# Internal SPI link: axi_quad_spi_1 (master) <-> fpga_dsp_wrap_0 (slave pins)
connect_bd_net [get_bd_pins axi_quad_spi_1/sck_o]  [get_bd_pins fpga_dsp_wrap_0/spi_sck]
connect_bd_net [get_bd_pins axi_quad_spi_1/ss_o]   [get_bd_pins fpga_dsp_wrap_0/host_cs]
connect_bd_net [get_bd_pins axi_quad_spi_1/io0_o]  [get_bd_pins fpga_dsp_wrap_0/spi_mosi]
connect_bd_net [get_bd_pins fpga_dsp_wrap_0/spi_miso] [get_bd_pins axi_quad_spi_1/io1_i]

# External host-SPI slave pins (real RPi host). Selected over the internal link
# by spi_sel (a board slide switch). The ASIC's host<->SPI interface (spi_slave)
# is exercised on real pins/timing when spi_sel=1; spi_sel=0 keeps the internal
# MicroBlaze-as-host path for CI. See fpga_dsp_wrap.v.
create_bd_port -dir I spi_sel
create_bd_port -dir I ext_host_cs
create_bd_port -dir I ext_spi_sck
create_bd_port -dir I ext_spi_mosi
create_bd_port -dir O ext_spi_miso
create_bd_port -dir O ext_irq
connect_bd_net [get_bd_ports spi_sel]      [get_bd_pins fpga_dsp_wrap_0/spi_sel]
connect_bd_net [get_bd_ports ext_host_cs]  [get_bd_pins fpga_dsp_wrap_0/ext_host_cs]
connect_bd_net [get_bd_ports ext_spi_sck]  [get_bd_pins fpga_dsp_wrap_0/ext_spi_sck]
connect_bd_net [get_bd_ports ext_spi_mosi] [get_bd_pins fpga_dsp_wrap_0/ext_spi_mosi]
connect_bd_net [get_bd_pins fpga_dsp_wrap_0/ext_spi_miso] [get_bd_ports ext_spi_miso]
connect_bd_net [get_bd_pins fpga_dsp_wrap_0/ext_irq]      [get_bd_ports ext_irq]

# --- axi_inj_ctrl (custom peripheral, 32 MHz DSP domain) -------------------
# Injection FIFO + rate-matching pacer feeding fpga_dsp_wrap's SD-modulator
# injection path (replaces the old int8-level INJECT mode). Firmware pushes
# int8 I/Q over Ethernet; this peripheral paces samples out at the
# decimator's R=64 output rate for fpga_dsp_wrap to ΣΔ-modulate back onto
# hw_iq_i/hw_iq_q.
# Keep this FPGA-only AXI helper on free-running MMCM 32 MHz so it is reachable
# before the SX1257 sample clock starts. Its inj_* outputs cross into dsp_clk;
# they are only enabled after front-end bring-up and require explicit CDC review.
set inj_ctrl [create_bd_cell -type module -reference axi_inj_ctrl axi_inj_ctrl_0]
connect_bd_net $ctrl_clk [get_bd_pins axi_inj_ctrl_0/s_axi_aclk]
connect_bd_net [get_bd_pins rst_ctrl32m/peripheral_aresetn] \
               [get_bd_pins axi_inj_ctrl_0/s_axi_aresetn]
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config { Clk_master "/clk_wiz_0/clk_out1 (100 MHz)" \
              Clk_slave  "/clk_wiz_0/clk_out2 (32 MHz)" \
              Master "/microblaze_0 (Periph)" intc_ip "Auto" master_apm "0" } \
    [get_bd_intf_pins axi_inj_ctrl_0/s_axi]

connect_bd_net [get_bd_pins axi_inj_ctrl_0/inj_en]    [get_bd_pins fpga_dsp_wrap_0/inj_en]
connect_bd_net [get_bd_pins axi_inj_ctrl_0/inj_valid] [get_bd_pins fpga_dsp_wrap_0/inj_valid]
connect_bd_net [get_bd_pins axi_inj_ctrl_0/inj_i0] [get_bd_pins fpga_dsp_wrap_0/inj_i0]
connect_bd_net [get_bd_pins axi_inj_ctrl_0/inj_q0] [get_bd_pins fpga_dsp_wrap_0/inj_q0]
connect_bd_net [get_bd_pins axi_inj_ctrl_0/inj_i1] [get_bd_pins fpga_dsp_wrap_0/inj_i1]
connect_bd_net [get_bd_pins axi_inj_ctrl_0/inj_q1] [get_bd_pins fpga_dsp_wrap_0/inj_q1]
connect_bd_net [get_bd_pins axi_inj_ctrl_0/inj_i2] [get_bd_pins fpga_dsp_wrap_0/inj_i2]
connect_bd_net [get_bd_pins axi_inj_ctrl_0/inj_q2] [get_bd_pins fpga_dsp_wrap_0/inj_q2]
connect_bd_net [get_bd_pins axi_inj_ctrl_0/inj_i3] [get_bd_pins fpga_dsp_wrap_0/inj_i3]
connect_bd_net [get_bd_pins axi_inj_ctrl_0/inj_q3] [get_bd_pins fpga_dsp_wrap_0/inj_q3]

# --- Digital-debug trace ----------------------------------------------------
# The receive-only PCB has no routed DBG0 test point, while DBG1 shares IRQ.
# Keep the ASIC mux semantics intact and observe both final pad values with an
# on-chip ILA.  probe2 is the replay/live injector sample strobe, letting a
# hardware capture be triggered and time-aligned to the replay stream.
set dbg_ila [create_bd_cell -type ip -vlnv xilinx.com:ip:ila:6.2 ila_debug_pins]
# Three 1-bit probes fit in one RAMB36 at 4096 samples.  The bench image
# already consumes 134/135 RAMB36 sites, so 16k samples (two RAMB36s)
# over-utilises the Arty A7-100T by one block.
set risk72_ila 0
if {[info exists ::env(RISK72_ILA)] && $::env(RISK72_ILA) ne "" && $::env(RISK72_ILA) ne "0"} {
    set risk72_ila 1
}
set risk73_sc_trace 0
if {[info exists ::env(RISK73_SC_TRACE)] && $::env(RISK73_SC_TRACE) ne "" && $::env(RISK73_SC_TRACE) ne "0"} {
    set risk73_sc_trace 1
}
set risk72_spi_trace 0
if {[info exists ::env(RISK72_SPI_TRACE)] && $::env(RISK72_SPI_TRACE) ne "" && $::env(RISK72_SPI_TRACE) ne "0"} {
    set risk72_spi_trace 1
}
set risk72_qpi_trace 0
if {[info exists ::env(RISK72_QPI_TRACE)] && $::env(RISK72_QPI_TRACE) ne "" && $::env(RISK72_QPI_TRACE) ne "0"} {
    set risk72_qpi_trace 1
}
if {$risk72_oversample} {
    # Open Risks #72, 2026-11-18: the stuck-high readback fault is read-side, so
    # look at what the FPGA input buffers actually see between SCK edges.
    # Same risk72_trace bus as RISK72_QPI_TRACE ([31] ce_n, [30] sck, [29:26]
    # sio_out, [25:22] sio_in straight off the IOBUF O pins, [2:0] context),
    # but sampled on a 200 MHz MMCM clock (6.25 samples per 32 MHz SCK
    # period, 5 ns resolution) instead of once per dsp_clk. The dsp_clk ->
    # 200 MHz crossing is false-pathed in risk72_oversample.xdc -- it is a logic
    # analyser, not a synchronous path. 2048 samples = 10.24 us.
    puts "## RISK72_OVERSAMPLE set: 2048-sample QPI pad capture at 200 MHz (RD_TRIG-triggered)"
    set_property -dict [list \
        CONFIG.C_DATA_DEPTH {2048} \
        CONFIG.C_NUM_OF_PROBES {2} \
        CONFIG.C_PROBE0_WIDTH {1} \
        CONFIG.C_PROBE1_WIDTH {32} \
    ] $dbg_ila
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out4] [get_bd_pins ila_debug_pins/clk]
    connect_bd_net [get_bd_pins fpga_dsp_wrap_0/risk72_trigger] [get_bd_pins ila_debug_pins/probe0]
    connect_bd_net [get_bd_pins fpga_dsp_wrap_0/risk72_trace] [get_bd_pins ila_debug_pins/probe1]
} elseif {$risk72_qpi_trace} {
    # Open Risks #72 follow-up, part 3: the host-SPI wire was already proven
    # clean (RISK72_SPI_TRACE build) -- the wrong debug-read byte is already
    # on MISO before axi_quad_spi_1/firmware touch it. This variant traces
    # one layer deeper: psram_buf_ctrl's own dbg_idx/dbg_addr_cur read
    # pointer plus the raw QPI SIO pins to the PSRAM chip (fpga_dsp_wrap_0/
    # risk72_trace retargeted -- see fpga_dsp_wrap.v). All native to
    # dsp_clk (32 MHz, same domain as ps_sck), so sample dsp_clk directly --
    # no CDC, no oversampling needed. 16384 samples @ 32 MHz = 512 us.
    puts "## RISK72_QPI_TRACE set: 16384-sample QPI/dbg_idx capture at 32 MHz (RD_TRIG-triggered)"
    set_property -dict [list \
        CONFIG.C_DATA_DEPTH {16384} \
        CONFIG.C_NUM_OF_PROBES {2} \
        CONFIG.C_PROBE0_WIDTH {1} \
        CONFIG.C_PROBE1_WIDTH {32} \
    ] $dbg_ila
    connect_bd_net $dsp_clk [get_bd_pins ila_debug_pins/clk]
    connect_bd_net [get_bd_pins fpga_dsp_wrap_0/risk72_trigger] [get_bd_pins ila_debug_pins/probe0]
    connect_bd_net [get_bd_pins fpga_dsp_wrap_0/risk72_trace] [get_bd_pins ila_debug_pins/probe1]
} elseif {$risk72_spi_trace} {
    # Open Risks #72 follow-up: host-SPI bus trace (fpga_dsp_wrap_0/risk72_trace
    # retargeted to sel_spi_sck/sel_spi_mosi/miso_w/sel_host_cs -- see
    # fpga_dsp_wrap.v). Sampled at 100 MHz (axi_quad_spi_1's ext_spi_clk),
    # ~16x oversampling the 6.25 MHz host SCK. 2026-09-14: doubling depth to
    # 32768 to fit the whole write+read burst blew the ILA's BRAM budget
    # ("more instantiated block-RAMs than device capacity"); switched the
    # trigger to the READ debug op specifically (risk72_trigger now =
    # dbg_mode && !dbg_wr_mode) so the write side (already proven clean) no
    # longer eats into the window -- back to the known-good 16384 depth.
    puts "## RISK72_SPI_TRACE set: 16384-sample host-SPI capture at 100 MHz (RD_TRIG-triggered)"
    set_property -dict [list \
        CONFIG.C_DATA_DEPTH {16384} \
        CONFIG.C_NUM_OF_PROBES {2} \
        CONFIG.C_PROBE0_WIDTH {1} \
        CONFIG.C_PROBE1_WIDTH {32} \
    ] $dbg_ila
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins ila_debug_pins/clk]
    connect_bd_net [get_bd_pins fpga_dsp_wrap_0/risk72_trigger] [get_bd_pins ila_debug_pins/probe0]
    connect_bd_net [get_bd_pins fpga_dsp_wrap_0/risk72_trace] [get_bd_pins ila_debug_pins/probe1]
} elseif {$risk73_sc_trace} {
    # Open Risks #73: SC-detector path (fpga_dsp_wrap_0/risk72_trace is
    # retargeted to sc_stat/sc_lock/sc_pipe_active/dcr_valid/... for this
    # build -- see fpga_dsp_wrap.v). These are all native dsp_clk-domain
    # (32 MHz) signals, so sample at dsp_clk directly (no CDC, no oversample
    # needed) to maximise real-time window: 4096 samples @ 32 MHz = 128 us.
    puts "## RISK73_SC_TRACE set: 4096-sample SC-detector capture at 32 MHz"
    set_property -dict [list \
        CONFIG.C_DATA_DEPTH {4096} \
        CONFIG.C_NUM_OF_PROBES {2} \
        CONFIG.C_PROBE0_WIDTH {1} \
        CONFIG.C_PROBE1_WIDTH {32} \
    ] $dbg_ila
    connect_bd_net $dsp_clk [get_bd_pins ila_debug_pins/clk]
    connect_bd_net [get_bd_pins fpga_dsp_wrap_0/risk72_trigger] [get_bd_pins ila_debug_pins/probe0]
    connect_bd_net [get_bd_pins fpga_dsp_wrap_0/risk72_trace] [get_bd_pins ila_debug_pins/probe1]
} elseif {$risk72_ila} {
    puts "## RISK72_ILA set: 1024-sample QPI capture at 100 MHz"
    set_property -dict [list \
        CONFIG.C_DATA_DEPTH {1024} \
        CONFIG.C_NUM_OF_PROBES {2} \
        CONFIG.C_PROBE0_WIDTH {1} \
        CONFIG.C_PROBE1_WIDTH {32} \
    ] $dbg_ila
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins ila_debug_pins/clk]
    connect_bd_net [get_bd_pins fpga_dsp_wrap_0/risk72_trigger] [get_bd_pins ila_debug_pins/probe0]
    connect_bd_net [get_bd_pins fpga_dsp_wrap_0/risk72_trace] [get_bd_pins ila_debug_pins/probe1]
} else {
    set_property -dict [list \
        CONFIG.C_DATA_DEPTH {4096} \
        CONFIG.C_NUM_OF_PROBES {3} \
        CONFIG.C_PROBE0_WIDTH {1} \
        CONFIG.C_PROBE1_WIDTH {1} \
        CONFIG.C_PROBE2_WIDTH {1} \
    ] $dbg_ila
    connect_bd_net $dsp_clk [get_bd_pins ila_debug_pins/clk]
    connect_bd_net [get_bd_pins fpga_dsp_wrap_0/dbg0] [get_bd_pins ila_debug_pins/probe0]
    connect_bd_net [get_bd_pins fpga_dsp_wrap_0/dbg1] [get_bd_pins ila_debug_pins/probe1]
    connect_bd_net [get_bd_pins axi_inj_ctrl_0/inj_valid] [get_bd_pins ila_debug_pins/probe2]
}

# --- axi_clk_sync_mon (CLK_OUT phase-lock measurement, 32 MHz DSP domain) ---
# De-risks the single-clock ASIC: the DSP domain is clocked from one SX1257
# CLK_OUT (F4). This peripheral samples the OTHER three CLK_OUTs against that
# clock and counts toggles over a window — ~0 toggles => frequency-locked,
# large => not locked. Runs on dsp_clk (same domain), so the measured clocks are
# sampled by the free-running FPGA control clock. It still detects frequency
# lock and exposes a coarse sampled phase, without blocking pre-clock boot.
set clksync [create_bd_cell -type module -reference axi_clk_sync_mon axi_clk_sync_mon_0]
connect_bd_net $ctrl_clk [get_bd_pins axi_clk_sync_mon_0/s_axi_aclk]
connect_bd_net [get_bd_pins rst_ctrl32m/peripheral_aresetn] \
               [get_bd_pins axi_clk_sync_mon_0/s_axi_aresetn]
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config { Clk_master "/clk_wiz_0/clk_out1 (100 MHz)" \
              Clk_slave  "/clk_wiz_0/clk_out2 (32 MHz)" \
              Master "/microblaze_0 (Periph)" intc_ip "Auto" master_apm "0" } \
    [get_bd_intf_pins axi_clk_sync_mon_0/s_axi]

# Measured CLK_OUT inputs (ordinary sampled inputs — NOT clocks, so N-side pins
# are fine): [0]=CLK_OUT_1 (F3), [1]=CLK_OUT_3 (D3), [2]=CLK_OUT_4 (C15/D15).
create_bd_port -dir I -from 2 -to 0 clk_meas
connect_bd_net [get_bd_ports clk_meas] [get_bd_pins axi_clk_sync_mon_0/clk_meas]

# --- AXI GPIO (1-bit input) for firmware to poll trouper_top's sticky IRQ --
set irq_gpio [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_irq]
set_property -dict [list \
    CONFIG.C_GPIO_WIDTH   {1} \
    CONFIG.C_ALL_INPUTS   {1} \
] $irq_gpio
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config { Clk_master "/clk_wiz_0/clk_out1 (100 MHz)" \
              Clk_slave  "Auto" Master "/microblaze_0 (Periph)" \
              intc_ip "Auto" master_apm "0" } \
    [get_bd_intf_pins axi_gpio_irq/S_AXI]
connect_bd_net [get_bd_pins fpga_dsp_wrap_0/irq] [get_bd_pins axi_gpio_irq/gpio_io_i]

# --- AXI UART Lite (debug) ----------------------------------------------------
set uart [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_uartlite:2.0 axi_uartlite_0]
set_property CONFIG.C_BAUDRATE {115200} $uart
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config { Clk_master "/clk_wiz_0/clk_out1 (100 MHz)" \
              Clk_slave  "Auto" Master "/microblaze_0 (Periph)" \
              intc_ip "Auto" master_apm "0" } \
    [get_bd_intf_pins axi_uartlite_0/S_AXI]
make_bd_intf_pins_external [get_bd_intf_pins axi_uartlite_0/UART]

# --- AXI Timer (100 MHz benchmark timebase) ---------------------------------
# Provides a deterministic cycle counter for separating eigenvector-kernel,
# SPI-transfer, and end-to-end TRAINING_DONE -> W_COMMIT latency.
set timer [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_timer:2.0 axi_timer_0]
set_property CONFIG.enable_timer2 {0} $timer
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config { Clk_master "/clk_wiz_0/clk_out1 (100 MHz)" \
              Clk_slave  "Auto" Master "/microblaze_0 (Periph)" \
              intc_ip "Auto" master_apm "0" } \
    [get_bd_intf_pins axi_timer_0/S_AXI]

# --- I/Q input ports (SX1257 PMOD pins, synchronous to 32 MHz dsp_clk) ------
create_bd_port -dir I -from 3 -to 0 hw_iq_i
create_bd_port -dir I -from 3 -to 0 hw_iq_q
connect_bd_net [get_bd_ports hw_iq_i] [get_bd_pins fpga_dsp_wrap_0/hw_iq_i]
connect_bd_net [get_bd_ports hw_iq_q] [get_bd_pins fpga_dsp_wrap_0/hw_iq_q]

# --- REMOD outputs: no board net --------------------------------------------
# The MISO front-end test PCB is receive-only; remod_i/remod_q have no pad
# (their former JD pins D4/D3 now carry RFFE_SCK / CLK_OUT_3). The wrapper still
# exposes them, but they are left as unconnected cell pins here (no top-level
# port, no XDC constraint) so no unconstrained-port warning is raised. Re-add a
# port + pin here if a TX/remod path is ever added to the board.

# --- External APS6404L PSRAM QPI bus (PCB J8 -> Arty JA) --------------------
# psram_sio[3:0] is bidirectional; make_bd_intf/pins_external on an inout module
# pin yields an inout top-level port that the XDC constrains to the JA pins.
create_bd_port -dir O psram_sck
create_bd_port -dir O psram_ce_n
create_bd_port -dir IO -from 3 -to 0 psram_sio
connect_bd_net [get_bd_pins fpga_dsp_wrap_0/psram_sck]  [get_bd_ports psram_sck]
connect_bd_net [get_bd_pins fpga_dsp_wrap_0/psram_ce_n] [get_bd_ports psram_ce_n]
connect_bd_net [get_bd_pins fpga_dsp_wrap_0/psram_sio]  [get_bd_ports psram_sio]

# Keep the AXI fabric and peripherals on rst_100m/peripheral_aresetn as wired by
# block automation. They need its configuration-time reset pulse for defined
# FIFO and state-machine power-up. The earlier boot deadlock attributed to this
# reset net was actually caused by clock converters whose slave clock came from
# absent-at-boot SX1257 CLK_OUT; those helpers now use free-running ctrl_clk.

# --- Validate and save --------------------------------------------------------
validate_bd_design
save_bd_design

# ============================================================================
# Generate block design wrapper
# ============================================================================
make_wrapper -files [get_files system.bd] -top
add_files -norecurse "$proj_dir/${proj_name}.srcs/sources_1/bd/system/hdl/system_wrapper.v"
set_property top system_wrapper [current_fileset]

# ============================================================================
# Synthesis / implementation settings
# ============================================================================
set_property strategy "Vivado Implementation Defaults" [get_runs impl_1]
set_property STEPS.WRITE_BITSTREAM.ARGS.BIN_FILE true [get_runs impl_1]

puts "Project created: $proj_dir"
puts "Next: open the block design, complete address assignment, then run synthesis."
puts "      axi_quad_spi_1 is the SPI master driving trouper_top's host-SPI slave;"
puts "      firmware talks to the ASIC register map (reg_bank) through it."
