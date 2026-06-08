# arty_dsp_emul.xdc
# Pin constraints for Arty A7-100T — LoRa MIMO DSP emulation
#
# Reuses AFE eval board pin assignments (JA/JB/JC for SX1257 I/Q and SPI).
# Adds JD PMOD for REMOD output (combined sigma-delta output).
#
# ============================================================================
# Board clock (100 MHz)
# ============================================================================
set_property PACKAGE_PIN E3  [get_ports clk100mhz]
set_property IOSTANDARD  LVCMOS33 [get_ports clk100mhz]
create_clock -add -period 10.000 -name sys_clk_pin [get_ports clk100mhz]

# Active-low reset (BTN0)
set_property PACKAGE_PIN C2  [get_ports ext_resetn]
set_property IOSTANDARD  LVCMOS33 [get_ports ext_resetn]

# ============================================================================
# DSP clock (32 MHz = 100 MHz * 8 / 25, derived from MMCM — internal)
# Vivado auto-derives this from the clk_wiz_0 configuration; no explicit
# create_generated_clock needed. The alias is used for input/output delay refs.
# ============================================================================
# create_generated_clock inferred automatically by Vivado for clk_wiz_0/clk_out1

# ============================================================================
# Ethernet MII (Arty A7-100T on-board LAN8720A)
# Pin assignments from Digilent Arty-A7-100-Master.xdc
# ============================================================================
set_property PACKAGE_PIN H15  [get_ports {MII_0_tx_en}]
set_property PACKAGE_PIN H14  [get_ports {MII_0_txd[0]}]
set_property PACKAGE_PIN J14  [get_ports {MII_0_txd[1]}]
set_property PACKAGE_PIN J13  [get_ports {MII_0_txd[2]}]
set_property PACKAGE_PIN H17  [get_ports {MII_0_txd[3]}]
set_property PACKAGE_PIN H16  [get_ports {MII_0_tx_clk}]
set_property PACKAGE_PIN G16  [get_ports {MII_0_rx_dv}]
set_property PACKAGE_PIN D18  [get_ports {MII_0_rxd[0]}]
set_property PACKAGE_PIN E17  [get_ports {MII_0_rxd[1]}]
set_property PACKAGE_PIN E18  [get_ports {MII_0_rxd[2]}]
set_property PACKAGE_PIN G17  [get_ports {MII_0_rxd[3]}]
set_property PACKAGE_PIN F15  [get_ports {MII_0_rx_clk}]
set_property PACKAGE_PIN C17  [get_ports {MII_0_rx_er}]
set_property PACKAGE_PIN D17  [get_ports {MII_0_col}]
set_property PACKAGE_PIN G14  [get_ports {MII_0_crs}]
set_property PACKAGE_PIN C16  [get_ports {phy_rst_n_0}]
set_property PACKAGE_PIN F16  [get_ports {phy_mdc_0}]
set_property PACKAGE_PIN K13  [get_ports {MDIO_0_mdio_io}]

set_property IOSTANDARD LVCMOS33 [get_ports {MII_0_*}]
set_property IOSTANDARD LVCMOS33 [get_ports {phy_rst_n_0}]
set_property IOSTANDARD LVCMOS33 [get_ports {phy_mdc_0}]
set_property IOSTANDARD LVCMOS33 [get_ports {MDIO_0_*}]

# ============================================================================
# UART (USB-UART bridge, Arty A7)
# ============================================================================
set_property PACKAGE_PIN D10  [get_ports {UART_0_rxd}]
set_property PACKAGE_PIN A9   [get_ports {UART_0_txd}]
set_property IOSTANDARD LVCMOS33 [get_ports {UART_0_*}]

# ============================================================================
# JB PMOD — SPI bus to SX1257 chips
# ============================================================================
# JB[0] E15  SPI_SCK — driven internally by AXI Quad SPI; no BD port for SCK
# JB[1] E16  SPI_MOSI
set_property PACKAGE_PIN E16  [get_ports {SPI_0_0_io0_io}]
set_property IOSTANDARD LVCMOS33 [get_ports {SPI_0_0_io0_io}]
# JB[3] C15  SPI_MISO
set_property PACKAGE_PIN C15  [get_ports {SPI_0_0_io1_io}]
set_property IOSTANDARD LVCMOS33 [get_ports {SPI_0_0_io1_io}]
# JB[4] J17  NSS[0]
set_property PACKAGE_PIN J17  [get_ports {SPI_0_0_ss_io[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {SPI_0_0_ss_io[0]}]
# JB[5] J18  NSS[1]
set_property PACKAGE_PIN J18  [get_ports {SPI_0_0_ss_io[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {SPI_0_0_ss_io[1]}]
# JB[6] K15  NSS[2]
set_property PACKAGE_PIN K15  [get_ports {SPI_0_0_ss_io[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {SPI_0_0_ss_io[2]}]
# JB[7] J15  NSS[3]
set_property PACKAGE_PIN J15  [get_ports {SPI_0_0_ss_io[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {SPI_0_0_ss_io[3]}]

# ============================================================================
# JA PMOD — SX1257 chips 0 and 1 I/Q data
# ============================================================================
# JA[0] G13  I_OUT chip 0  (NOTE: conflict with MII rxd[2] — hardware resolve)
set_property PACKAGE_PIN G13  [get_ports {hw_iq_i[0]}]
# JA[1] B11  Q_OUT chip 0
set_property PACKAGE_PIN B11  [get_ports {hw_iq_q[0]}]
# JA[2] A11  I_OUT chip 1
set_property PACKAGE_PIN A11  [get_ports {hw_iq_i[1]}]
# JA[3] D12  Q_OUT chip 1
set_property PACKAGE_PIN D12  [get_ports {hw_iq_q[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {hw_iq_i[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {hw_iq_q[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {hw_iq_i[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {hw_iq_q[1]}]

# ============================================================================
# JC PMOD — SX1257 chips 2 and 3 I/Q data
# ============================================================================
set_property PACKAGE_PIN U12  [get_ports {hw_iq_i[2]}]
set_property PACKAGE_PIN V12  [get_ports {hw_iq_q[2]}]
set_property PACKAGE_PIN V10  [get_ports {hw_iq_i[3]}]
set_property PACKAGE_PIN V11  [get_ports {hw_iq_q[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {hw_iq_i[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {hw_iq_q[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {hw_iq_i[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {hw_iq_q[3]}]

# ============================================================================
# JD PMOD — REMOD output (sigma-delta combined output for oscilloscope/SX1302)
# ============================================================================
# JD[0] D4  REMOD_I (I_OUT combined)
set_property PACKAGE_PIN D4   [get_ports remod_i]
set_property IOSTANDARD LVCMOS33 [get_ports remod_i]
# JD[1] D3  REMOD_Q (Q_OUT combined)
set_property PACKAGE_PIN D3   [get_ports remod_q]
set_property IOSTANDARD LVCMOS33 [get_ports remod_q]

# ============================================================================
# Timing constraints
# ============================================================================
# Board-level PMOD timing is left unconstrained for bring-up. The previous
# generic delays were binding against multiple derived clocks and producing
# critical warnings during implementation.
