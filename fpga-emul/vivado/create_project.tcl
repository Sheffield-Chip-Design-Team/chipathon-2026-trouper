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
    "$asic_rtl/control/spi_slave.v"           \
    "$asic_rtl/control/reg_bank.v"            \
]

add_files -norecurse $emul_srcs
add_files -norecurse $asic_srcs
set_property file_type {Verilog} [get_files *.v]

# Constraints
add_files -fileset constrs_1 -norecurse \
    "[file dirname [info script]]/arty_dsp_emul.xdc"

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
set clk_wiz [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_0]
set_property -dict [list \
    CONFIG.PRIM_IN_FREQ              {100.000} \
    CONFIG.NUM_OUT_CLKS             {3} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {100.000} \
    CONFIG.CLKOUT2_USED              {true} \
    CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {32.000} \
    CONFIG.CLKOUT3_USED              {true} \
    CONFIG.CLKOUT3_REQUESTED_OUT_FREQ {25.000} \
    CONFIG.RESET_TYPE                {ACTIVE_LOW} \
    CONFIG.RESET_PORT                {resetn} \
] $clk_wiz

# Connect external 100 MHz board clock to clk_wiz primary input
create_bd_port -dir I -type clk -freq_hz 100000000 clk100mhz
connect_bd_net [get_bd_ports clk100mhz] [get_bd_pins clk_wiz_0/clk_in1]
create_bd_port -dir I -type rst ext_resetn
connect_bd_net [get_bd_ports ext_resetn] [get_bd_pins clk_wiz_0/resetn]

# --- SX1257 CLK_OUT — the DSP-domain sample clock ---------------------------
# On silicon there is NO MMCM 32 MHz: trouper_top's IQ_CLK is the SX1257
# CLK_OUT (32 MHz), so the whole DSP chain runs on the front-end sample clock.
# Mirror that here — bring CLK_OUT in through a BUFG and clock the DSP domain
# from it, so the emulator samples hw_iq on the very clock that produced the
# data (a free-running MMCM 32 MHz would bit-slip against the board TCXO). All
# four radios share one TCXO (coherent), so any CLK_OUT works; the XDC picks
# CLK_OUT_4 on JB C15 (0-ohm MRCC, cleanest edge). The MMCM's own 32 MHz output
# (clk_wiz clk_out2) is intentionally left unused after this.
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
# dsp_clk: the 32 MHz sample-clock net used across the whole DSP domain.
set dsp_clk [get_bd_pins sx_clk_bufg/BUFG_O]

# Keep the MicroBlaze reset fabric inactive by default, matching the working
# fpga-eth bring-up flow. The board reset still resets the clock wizard.
set rst_const [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant xlconstant_1]
set_property -dict [list CONFIG.CONST_VAL {1} CONFIG.CONST_WIDTH {1}] $rst_const

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

# --- MicroBlaze — created after clock wizard so automation can resolve the clock
set mb [create_bd_cell -type ip -vlnv xilinx.com:ip:microblaze:11.0 microblaze_0]
set_property -dict [list \
    CONFIG.C_DEBUG_ENABLED     {1} \
    CONFIG.C_D_AXI             {1} \
    CONFIG.C_D_LMB             {1} \
    CONFIG.C_I_LMB             {1} \
    CONFIG.C_USE_ICACHE        {0} \
    CONFIG.C_USE_DCACHE        {0} \
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
# address (RFFE_NSS_A0/A1 -> on-board SN74LVC1G139), so ss_io[3:2] have no board
# pin. Two bits keeps the SPI_0 interface matched to the constrained pins in the
# XDC (A18/B18) and avoids unconstrained-port warnings on ss_io[3:2].
# NOTE: this still emits a ONE-HOT select on the two lines. Reworking firmware to
# drive a true 2-bit ENCODED address into the 1G139 is the separate open TODO
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
set_property -dict [list \
    CONFIG.C_SCK_RATIO      {16} \
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
# USE_EXT_PSRAM=1: drive the real external APS6404L on the daughterboard (JA)
# via the wrapper's IOBUFs, instead of the internal BRAM model. The QPI pads
# are exposed as top-level ports and constrained in arty_dsp_emul.xdc below.
set dsp_wrap [create_bd_cell -type module -reference fpga_dsp_wrap fpga_dsp_wrap_0]
set_property CONFIG.USE_EXT_PSRAM {1} [get_bd_cells fpga_dsp_wrap_0]
connect_bd_net $dsp_clk [get_bd_pins fpga_dsp_wrap_0/clk]
connect_bd_net [get_bd_pins rst_32m/peripheral_aresetn] \
               [get_bd_pins fpga_dsp_wrap_0/rst_n]

# Internal SPI link: axi_quad_spi_1 (master) <-> fpga_dsp_wrap_0 (slave pins)
connect_bd_net [get_bd_pins axi_quad_spi_1/sck_o]  [get_bd_pins fpga_dsp_wrap_0/spi_sck]
connect_bd_net [get_bd_pins axi_quad_spi_1/ss_o]   [get_bd_pins fpga_dsp_wrap_0/host_cs]
connect_bd_net [get_bd_pins axi_quad_spi_1/io0_o]  [get_bd_pins fpga_dsp_wrap_0/spi_mosi]
connect_bd_net [get_bd_pins fpga_dsp_wrap_0/spi_miso] [get_bd_pins axi_quad_spi_1/io1_i]

# --- axi_inj_ctrl (custom peripheral, 32 MHz DSP domain) -------------------
# Injection FIFO + rate-matching pacer feeding fpga_dsp_wrap's SD-modulator
# injection path (replaces the old int8-level INJECT mode). Firmware pushes
# int8 I/Q over Ethernet; this peripheral paces samples out at the
# decimator's R=64 output rate for fpga_dsp_wrap to ΣΔ-modulate back onto
# hw_iq_i/hw_iq_q.
# axi_inj_ctrl shares the DSP-domain sample clock (dsp_clk) with fpga_dsp_wrap so
# the paced inj_* handoff stays single-clock (no CDC on those nets). Its AXI-Lite
# slave crosses from the 100 MHz MicroBlaze bus into dsp_clk via the clock
# converter that the axi4 automation inserts; the Clk_slave below must therefore
# name the sample clock, not the (now unused) MMCM clk_out2.
# NOTE: apply_bd_automation resolves Clk_slave by the exact clock label. The BUFG
# output on the 32 MHz input reads "/sx_clk_bufg/BUFG_O (32 MHz)" — verified to
# validate clean in Vivado 2025.2. If a future Vivado rejects the string, run the
# automation with Clk_slave "Auto" and verify the converter's slave clock is
# dsp_clk (sx_clk_bufg/BUFG_O), not clk_out2.
set inj_ctrl [create_bd_cell -type module -reference axi_inj_ctrl axi_inj_ctrl_0]
connect_bd_net $dsp_clk [get_bd_pins axi_inj_ctrl_0/s_axi_aclk]
connect_bd_net [get_bd_pins rst_32m/peripheral_aresetn] \
               [get_bd_pins axi_inj_ctrl_0/s_axi_aresetn]
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config { Clk_master "/clk_wiz_0/clk_out1 (100 MHz)" \
              Clk_slave  "/sx_clk_bufg/BUFG_O (32 MHz)" \
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
