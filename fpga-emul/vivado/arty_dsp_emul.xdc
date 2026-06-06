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
create_clock -period 10.000 -name sys_clk [get_ports clk100mhz]

# Active-low reset (BTN0)
set_property PACKAGE_PIN C2  [get_ports ext_resetn]
set_property IOSTANDARD  LVCMOS33 [get_ports ext_resetn]

# ============================================================================
# DSP clock (32 MHz derived from MMCM — internal, no pin needed)
# Timing constraint for MMCM output
# ============================================================================
create_generated_clock -name dsp_clk \
    -source [get_pins clk_wiz_0/inst/mmcme2_adv_inst/CLKIN1] \
    -multiply_by 8 -divide_by 25 \
    [get_pins clk_wiz_0/inst/mmcme2_adv_inst/CLKOUT1]

# ============================================================================
# Ethernet MII (Arty A7 on-board LAN8720)
# ============================================================================
set_property PACKAGE_PIN G18  [get_ports {MII_0_tx_en}]
set_property PACKAGE_PIN H16  [get_ports {MII_0_txd[0]}]
set_property PACKAGE_PIN H15  [get_ports {MII_0_txd[1]}]
set_property PACKAGE_PIN J15  [get_ports {MII_0_txd[2]}]   # NOTE: also JB[7] — no conflict when SPI NSS3 unused
set_property PACKAGE_PIN K15  [get_ports {MII_0_txd[3]}]   # NOTE: JB[6] NSS2 conflict — see note below
set_property PACKAGE_PIN F15  [get_ports {MII_0_tx_clk}]
set_property PACKAGE_PIN H17  [get_ports {MII_0_rx_dv}]
set_property PACKAGE_PIN K13  [get_ports {MII_0_rxd[0]}]
set_property PACKAGE_PIN K14  [get_ports {MII_0_rxd[1]}]
set_property PACKAGE_PIN G13  [get_ports {MII_0_rxd[2]}]   # NOTE: also JA[0] I_OUT chip0 — resolve in HW
set_property PACKAGE_PIN E16  [get_ports {MII_0_rxd[3]}]   # NOTE: also JB[1] SPI_MOSI — resolve in HW
set_property PACKAGE_PIN I17  [get_ports {MII_0_rx_clk}]
set_property PACKAGE_PIN C16  [get_ports {MII_0_rx_er}]
set_property PACKAGE_PIN D17  [get_ports {MII_0_col}]
set_property PACKAGE_PIN G14  [get_ports {MII_0_crs}]
set_property PACKAGE_PIN C17  [get_ports {PHY_RST_N}]
set_property PACKAGE_PIN D18  [get_ports {MII_0_mdc}]
set_property PACKAGE_PIN C18  [get_ports {MDIO_0_mdio_io}]

set_property IOSTANDARD LVCMOS33 [get_ports {MII_0_*}]
set_property IOSTANDARD LVCMOS33 [get_ports {PHY_RST_N}]
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
# JB[0] E15  SPI_SCK
set_property PACKAGE_PIN E15  [get_ports {SPI_0_sck_io}]
set_property IOSTANDARD LVCMOS33 [get_ports {SPI_0_sck_io}]
# JB[1] E16  SPI_MOSI  (NOTE: pin conflict with MII rxd[3] — do NOT use both)
set_property PACKAGE_PIN E16  [get_ports {SPI_0_io0_io}]
set_property IOSTANDARD LVCMOS33 [get_ports {SPI_0_io0_io}]
# JB[3] C15  SPI_MISO
set_property PACKAGE_PIN C15  [get_ports {SPI_0_io1_io}]
set_property IOSTANDARD LVCMOS33 [get_ports {SPI_0_io1_io}]
# JB[4] J17  NSS[0]
set_property PACKAGE_PIN J17  [get_ports {SPI_0_ss_io[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {SPI_0_ss_io[0]}]
# JB[5] J18  NSS[1]
set_property PACKAGE_PIN J18  [get_ports {SPI_0_ss_io[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {SPI_0_ss_io[1]}]
# JB[6] K15  NSS[2]
set_property PACKAGE_PIN K15  [get_ports {SPI_0_ss_io[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {SPI_0_ss_io[2]}]
# JB[7] J15  NSS[3]  (NOTE: pin conflict with MII txd[2])
set_property PACKAGE_PIN J15  [get_ports {SPI_0_ss_io[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {SPI_0_ss_io[3]}]

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
# I/Q input setup/hold relative to dsp_clk
# SX1257 changes IQ data on the output clock edge; sample ~half period later.
set_input_delay -clock dsp_clk -max 5.0 [get_ports {hw_iq_i[*] hw_iq_q[*]}]
set_input_delay -clock dsp_clk -min 1.0 [get_ports {hw_iq_i[*] hw_iq_q[*]}]

# REMOD output delay
set_output_delay -clock dsp_clk -max 5.0 [get_ports {remod_i remod_q}]
set_output_delay -clock dsp_clk -min 1.0 [get_ports {remod_i remod_q}]

# False paths for quasi-static config registers (written infrequently via AXI)
# The AXI clock converter handles the data path; these relax timing on config.
set_false_path -through [get_nets {*axi_cc_32m*}]
