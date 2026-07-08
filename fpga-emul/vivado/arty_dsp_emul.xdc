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
# 25 MHz reference clock driven from FPGA to the DP83848 PHY (Sch=eth_ref_clk).
# Required for the PHY to run; without it there is no link and no link LED.
set_property PACKAGE_PIN G18  [get_ports {eth_ref_clk}]

set_property IOSTANDARD LVCMOS33 [get_ports {MII_0_*}]
set_property IOSTANDARD LVCMOS33 [get_ports {phy_rst_n_0}]
set_property IOSTANDARD LVCMOS33 [get_ports {phy_mdc_0}]
set_property IOSTANDARD LVCMOS33 [get_ports {MDIO_0_*}]
set_property IOSTANDARD LVCMOS33 [get_ports {eth_ref_clk}]

# ============================================================================
# UART (USB-UART bridge, Arty A7)
# Digilent schematic net names (FPGA perspective):
#   D10 = uart_rxd_out -> FPGA OUTPUT to host  => FPGA TX  (UART_0_txd)
#   A9  = uart_txd_in  -> FPGA INPUT from host => FPGA RX  (UART_0_rxd)
# NOTE: these were previously swapped (TX on A9), so the FPGA was driving the
# FTDI's own TXD pin and the host received 0 bytes. Corrected per master XDC.
# ============================================================================
set_property PACKAGE_PIN A9   [get_ports {UART_0_rxd}]
set_property PACKAGE_PIN D10  [get_ports {UART_0_txd}]
set_property IOSTANDARD LVCMOS33 [get_ports {UART_0_*}]

# ============================================================================
# MISO front-end test PCB pin map  (re-pinned per tmp/miso_frontend_pcb_review_2026-07-08.md)
# ============================================================================
# The daughterboard mounts over the Arty with the HEADER ORDER REVERSED:
#     PCB J5 -> Arty JD,   PCB J6 -> Arty JC,
#     PCB J7 -> Arty JB,   PCB J8 -> Arty JA
# (pin 1 mates with pin 1 within each header; pins 5/11 = GND, 6/12 = 3V3_IN).
#
# Consequences of the real PCB net list (review findings 6 & 7):
#   * SX1257 I/Q data is scattered by chip across ALL FOUR headers, not grouped
#     JA=chip0/1, JC=chip2/3 as before. Re-pinned below to the physical nets.
#   * NSS is a 2-bit ENCODED address (RFFE_NSS_A0/A1) feeding an on-board
#     SN74LVC1G139 2-to-4 decoder — NOT four one-hot selects. Only ss_io[0]/[1]
#     have a pin; the BD is now built with 2 SS bits so ss_io[2]/[3] no longer
#     exist. Firmware still emits a one-hot select on the two lines; reworking it
#     to a true 2-bit ENCODED address is the open TODO (fpga-emul/TODO.md).
#   * PSRAM is a REAL external APS6404L on JA (was the internal psram_model).
#     DONE: fpga_dsp_wrap USE_EXT_PSRAM=1 + IOBUFs; pins constrained below.
#   * CLK_OUT_1..4 are the SX1257 I/Q sampling clocks (MRCC pins). DONE: the DSP
#     domain is now clocked from CLK_OUT_4 (C15) via a BUFG, matching silicon
#     (IQ_CLK = SX1257 CLK_OUT); the MMCM 32 MHz is unused. See bottom + BD.
#   * remod_i/remod_q have NO net on this receive-only PCB — their old pins
#     (D4/D3) now carry RFFE_SCK/CLK_OUT_3. DONE: dropped from the BD (no port).
#
# ---------------------------------------------------------------------------
# SX1257 I/Q data  (FPGA reads I_OUT_n / Q_OUT_n; index n-1 -> hw_iq_*[n-1])
# ---------------------------------------------------------------------------
# chip 1  (PCB J5 -> JD pin 10 / 9)
set_property PACKAGE_PIN G2   [get_ports {hw_iq_i[0]}] ;# I_OUT_1
set_property PACKAGE_PIN H2   [get_ports {hw_iq_q[0]}] ;# Q_OUT_1
# chip 2  (PCB J6 -> JC pin 4 / 10)
set_property PACKAGE_PIN V11  [get_ports {hw_iq_i[1]}] ;# I_OUT_2
set_property PACKAGE_PIN U13  [get_ports {hw_iq_q[1]}] ;# Q_OUT_2
# chip 3  (PCB J6 -> JC pin 2 / 8)
set_property PACKAGE_PIN V12  [get_ports {hw_iq_i[2]}] ;# I_OUT_3
set_property PACKAGE_PIN V14  [get_ports {hw_iq_q[2]}] ;# Q_OUT_3
# chip 4  (PCB J7 -> JB pin 2 / 8)
set_property PACKAGE_PIN E16  [get_ports {hw_iq_i[3]}] ;# I_OUT_4
set_property PACKAGE_PIN J18  [get_ports {hw_iq_q[3]}] ;# Q_OUT_4
set_property IOSTANDARD LVCMOS33 [get_ports {hw_iq_i[*]}]
set_property IOSTANDARD LVCMOS33 [get_ports {hw_iq_q[*]}]

# ---------------------------------------------------------------------------
# SX1257 SPI  (PCB J5 -> JD)
# ---------------------------------------------------------------------------
# RFFE_MOSI  J5 pin 7 -> JD  E2
set_property PACKAGE_PIN E2   [get_ports {SPI_0_0_io0_io}]
set_property IOSTANDARD LVCMOS33 [get_ports {SPI_0_0_io0_io}]
# RFFE_MISO  J5 pin 8 -> JD  D2
set_property PACKAGE_PIN D2   [get_ports {SPI_0_0_io1_io}]
set_property IOSTANDARD LVCMOS33 [get_ports {SPI_0_0_io1_io}]
# RFFE_SCK   J5 pin 1 -> JD  D4  — AXI Quad SPI drives SCK internally (no BD port).
#            The board routes SCK to D4; expose a SCK port in the BD to constrain it.
#
# NSS: 2-bit encoded address into the on-board SN74LVC1G139 (review finding 4/6).
# Map the two available select bits to the address pins as a stop-gap; firmware
# must be reworked to emit a 2-bit code rather than a one-hot select.
# RFFE_NSS_A0  PCB J8 -> JA  A18
set_property PACKAGE_PIN A18  [get_ports {SPI_0_0_ss_io[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {SPI_0_0_ss_io[0]}]
# RFFE_NSS_A1  PCB J8 -> JA  B18
set_property PACKAGE_PIN B18  [get_ports {SPI_0_0_ss_io[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {SPI_0_0_ss_io[1]}]
# ss_io[2] / ss_io[3]: no longer exist — the BD now builds axi_quad_spi_0 with
# 2 SS bits (C_NUM_SS_BITS=2), matching the two board pins above.

# ---------------------------------------------------------------------------
# remod_i / remod_q: NO net on this receive-only PCB. Dropped from the BD (no
# top-level port, no constraint). Their former pins D4/D3 are now RFFE_SCK /
# CLK_OUT_3. Re-add a BD port + pin here if a TX/remod path is added.
# ---------------------------------------------------------------------------

# ============================================================================
# External APS6404L PSRAM QPI bus (PCB J8 -> JA, 200 ohm series)
# Active build: fpga_dsp_wrap USE_EXT_PSRAM=1 (BD sets it), IOBUFs on psram_sio.
# 200 ohm series into ~15 pF adds ~3 ns/crossing; folds into psram_buf_ctrl's
# read-timing budget at 32 MHz SCLK (see PCB review finding 7).
# ---------------------------------------------------------------------------
set_property PACKAGE_PIN D12  [get_ports {psram_sck}]     ;# PSRAM_SCLK  JA pin 4
set_property PACKAGE_PIN D13  [get_ports {psram_ce_n}]    ;# PSRAM_nCE   JA pin 7
set_property PACKAGE_PIN A11  [get_ports {psram_sio[0]}]  ;# SI  / SIO0  JA pin 3
set_property PACKAGE_PIN G13  [get_ports {psram_sio[1]}]  ;# SO  / SIO1  JA pin 1
set_property PACKAGE_PIN B11  [get_ports {psram_sio[2]}]  ;# SIO2        JA pin 2
set_property PACKAGE_PIN K16  [get_ports {psram_sio[3]}]  ;# SIO3        JA pin 10
set_property IOSTANDARD LVCMOS33 [get_ports {psram_sck psram_ce_n}]
set_property IOSTANDARD LVCMOS33 [get_ports {psram_sio[*]}]

# ============================================================================
# SX1257 CLK_OUT — the DSP-domain sample clock (32 MHz)
# ============================================================================
# The real ASIC's IQ_CLK is the SX1257 CLK_OUT, so the emulator clocks its whole
# DSP domain from CLK_OUT (see create_project.tcl: sx_clk_out -> BUFG -> dsp_clk).
# CLK_OUT_4 lands on JB C15 — 0-ohm series, MRCC clock-capable, cleanest edge of
# the four (CLK_OUT_1..3 sit behind JD's 200-ohm resistors). All four radios
# share one TCXO, so this single clock is coherent for every branch.
set_property PACKAGE_PIN C15  [get_ports {sx_clk_out}]
set_property IOSTANDARD LVCMOS33 [get_ports {sx_clk_out}]
create_clock -period 31.250 -name sx_clk_out [get_ports {sx_clk_out}]

# The SX1257 sample clock and the MMCM-derived clocks (100 MHz MicroBlaze/AXI,
# 25 MHz PHY ref) come from independent oscillators — the board TCXO vs the Arty
# crystal. Declare them asynchronous; the AXI clock converters and reset
# synchronisers in the BD handle the CDC. Without this the tool would time false
# paths between the two unrelated domains.
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks sys_clk_pin] \
    -group [get_clocks sx_clk_out]

# ============================================================================
# Timing constraints
# ============================================================================
# Board-level PMOD data timing (hw_iq, SPI, PSRAM) is left unconstrained for
# bring-up. The previous generic delays were binding against multiple derived
# clocks and producing critical warnings during implementation.
