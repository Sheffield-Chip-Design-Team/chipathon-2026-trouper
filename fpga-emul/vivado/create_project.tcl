# create_project.tcl
# Creates the Vivado project for the LoRa MIMO DSP chain FPGA emulation.
# Target: Digilent Arty A7-100T (xc7a100tcsg324-1)
#
# Reuses the existing AFE eval block design (MicroBlaze + EthernetLite +
# AXI Quad SPI) and adds:
#   - Extra MMCM output at 32 MHz (dsp_clk)
#   - axi_dsp_ctrl peripheral (our RTL, clocked at 32 MHz)
#   - AXI SmartConnect / clock converter bridge from MB AXI bus to 32 MHz
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
set asic_rtl   [file normalize "[file dirname [info script]]/../../rtl-test/rtl"]
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
    "$rtl_dir/fpga_sram512x8.v"   \
    "$rtl_dir/sync_fifo.v"        \
    "$rtl_dir/fpga_dsp_wrap.v"    \
    "$rtl_dir/axi_dsp_ctrl.v"     \
]

# ASIC RTL (the modules under test — same files used by Verilator testbenches)
set asic_srcs [list \
    "$asic_rtl/sd_decimator.v"       \
    "$asic_rtl/dc_removal.v"         \
    "$asic_rtl/frontend_buf_ctrl.v"  \
    "$asic_rtl/noise_est.v"           \
    "$asic_rtl/sc_detector.v"        \
    "$asic_rtl/training_acc.v"       \
    "$asic_rtl/weight_gen.v"         \
    "$asic_rtl/packet_ctrl_fsm.v"    \
    "$asic_rtl/mrc_combiner.v"       \
    "$asic_rtl/sd_remod.v"           \
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

# --- Clock wizard (MMCM) — single 32 MHz output; MicroBlaze + DSP same domain,
#     eliminates AXI clock converter and cross-domain automation complexity.
set clk_wiz [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_0]
set_property -dict [list \
    CONFIG.PRIM_IN_FREQ              {100.000} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {32.000} \
    CONFIG.RESET_TYPE                {ACTIVE_LOW} \
    CONFIG.RESET_PORT                {resetn} \
] $clk_wiz

# Connect external 100 MHz board clock to clk_wiz primary input
create_bd_port -dir I -type clk -freq_hz 100000000 clk100mhz
connect_bd_net [get_bd_ports clk100mhz] [get_bd_pins clk_wiz_0/clk_in1]
create_bd_port -dir I -type rst ext_resetn
connect_bd_net [get_bd_ports ext_resetn] [get_bd_pins clk_wiz_0/resetn]

# Single proc_sys_reset for the 32 MHz domain
set psr [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_32m]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins rst_32m/slowest_sync_clk]
connect_bd_net [get_bd_pins clk_wiz_0/locked]   [get_bd_pins rst_32m/dcm_locked]
connect_bd_net [get_bd_ports ext_resetn]          [get_bd_pins rst_32m/ext_reset_in]

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
              axi_periph "Enabled" axi_intc "0" clk "/clk_wiz_0/clk_out1 (32 MHz)" } \
    [get_bd_cells microblaze_0]

# --- EthernetLite --------------------------------------------------------------
set eth [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_ethernetlite:3.0 axi_ethernetlite_0]
set_property -dict [list CONFIG.C_INCLUDE_GLOBAL_BUFFERS {1}] $eth
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config { Clk_master "/clk_wiz_0/clk_out1 (32 MHz)" \
              Clk_slave  "Auto" Clk_xbar "Auto" \
              Master "/microblaze_0 (Periph)" \
              intc_ip "New AXI SmartConnect" master_apm "0" } \
    [get_bd_intf_pins axi_ethernetlite_0/S_AXI]

# Expose Ethernet MII ports
make_bd_intf_pins_external [get_bd_intf_pins axi_ethernetlite_0/MII]
make_bd_pins_external [get_bd_pins axi_ethernetlite_0/PHY_RST_N]
make_bd_pins_external [get_bd_pins axi_ethernetlite_0/PHY_MDC]
make_bd_intf_pins_external [get_bd_intf_pins axi_ethernetlite_0/MDIO]

# --- AXI Quad SPI (for SX1257) -----------------------------------------------
set spi [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_quad_spi:3.2 axi_quad_spi_0]
set_property -dict [list \
    CONFIG.C_SCK_RATIO      {16} \
    CONFIG.C_NUM_SS_BITS    {4} \
    CONFIG.C_SPI_MODE       {0} \
] $spi
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config { Clk_master "/clk_wiz_0/clk_out1 (32 MHz)" \
              Clk_slave  "Auto" Master "/microblaze_0 (Periph)" \
              intc_ip "Auto" master_apm "0" } \
    [get_bd_intf_pins axi_quad_spi_0/AXI_LITE]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins axi_quad_spi_0/ext_spi_clk]
make_bd_intf_pins_external [get_bd_intf_pins axi_quad_spi_0/SPI_0]

# --- AXI UART Lite (debug) ----------------------------------------------------
set uart [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_uartlite:2.0 axi_uartlite_0]
set_property CONFIG.C_BAUDRATE {115200} $uart
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config { Clk_master "/clk_wiz_0/clk_out1 (32 MHz)" \
              Clk_slave  "Auto" Master "/microblaze_0 (Periph)" \
              intc_ip "Auto" master_apm "0" } \
    [get_bd_intf_pins axi_uartlite_0/S_AXI]
make_bd_intf_pins_external [get_bd_intf_pins axi_uartlite_0/UART]

# --- axi_dsp_ctrl (custom peripheral, same 32 MHz domain) --------------------
set dsp_ctrl [create_bd_cell -type module -reference axi_dsp_ctrl axi_dsp_ctrl_0]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins axi_dsp_ctrl_0/dsp_clk]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins axi_dsp_ctrl_0/s_axi_aclk]
connect_bd_net [get_bd_pins rst_32m/peripheral_aresetn] \
               [get_bd_pins axi_dsp_ctrl_0/s_axi_aresetn]

# Connect axi_dsp_ctrl to the MicroBlaze peripheral bus via automation
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config { Clk_master "/clk_wiz_0/clk_out1 (32 MHz)" \
              Clk_slave  "/clk_wiz_0/clk_out1 (32 MHz)" \
              Master "/microblaze_0 (Periph)" intc_ip "Auto" master_apm "0" } \
    [get_bd_intf_pins axi_dsp_ctrl_0/s_axi]

# --- I/Q input ports (SX1257 PMOD pins, synchronous to 32 MHz dsp_clk) ------
create_bd_port -dir I -from 3 -to 0 hw_iq_i
create_bd_port -dir I -from 3 -to 0 hw_iq_q
connect_bd_net [get_bd_ports hw_iq_i] [get_bd_pins axi_dsp_ctrl_0/hw_iq_i]
connect_bd_net [get_bd_ports hw_iq_q] [get_bd_pins axi_dsp_ctrl_0/hw_iq_q]

# --- REMOD output ports (JD PMOD for oscilloscope) ---------------------------
create_bd_port -dir O remod_i
create_bd_port -dir O remod_q
connect_bd_net [get_bd_pins axi_dsp_ctrl_0/remod_i] [get_bd_ports remod_i]
connect_bd_net [get_bd_pins axi_dsp_ctrl_0/remod_q] [get_bd_ports remod_q]

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
puts "      Address map target for axi_dsp_ctrl: 0x0002_0000 (64 KB segment)"
