# pnr_32m_v7_analysis.sdc — trouper_top
#
# v7 fixes over pnr_32m_mcp_v6.sdc:
#   - Port set matches trouper_top (v6 referenced TMS_GPIO0/TDI_GPIO1, which only
#     exist on mimo_rx_top; OpenSTA dropped those constraints).
#   - PSRAM interface is constrained source-synchronously via a generated clock
#     on PSRAM_SCK (sck = sck_en & clk in psram_buf_ctrl).  PSRAM_SIO_IN was
#     previously unconstrained entirely.
#   - SPI_MOSI/SPI_MISO are constrained against SPI_SCK (their real clock), not
#     IQ_CLK.  SPI_SCK is no longer an ideal network.
#   - GRP_* bus constrained vs IQ_CLK.  ASSUMPTION: Grouper and Trouper share
#     the carrier 32 MHz clock (AHB-Lite is synchronous).  Revisit with the
#     Grouper team; if the link is async, replace with false paths + qualifier
#     synchronisers in RTL.
#
# *** ANALYSIS BASELINE: deliberately NO multicycle paths. ***
# The previous blanket "set_multicycle_path 3 -from IQ_CLK -to IQ_CLK" waived
# setup on full-rate logic (CIC integrators, sd_remod, QPI sub-cycle FSM,
# sample_count, SPI CDC) that transitions every 31.25 ns.  This file is used to
# enumerate the true single-cycle violations at SS so MCP exceptions can be
# scoped to genuinely iq_valid-gated paths only.

create_clock -name IQ_CLK  -period 31.25 [get_ports IQ_CLK]
create_clock -name SPI_SCK -period 100.0 [get_ports SPI_SCK]
set_clock_uncertainty 0.5 [get_clocks IQ_CLK]
set_clock_uncertainty 0.5 [get_clocks SPI_SCK]

# PSRAM_SCK is an AND-gated copy of IQ_CLK (psram_buf_ctrl: sck = sck_en & clk).
create_generated_clock -name PSRAM_SCK -source [get_ports IQ_CLK] \
    -divide_by 1 [get_ports PSRAM_SCK]

set_clock_groups -asynchronous \
    -group {IQ_CLK PSRAM_SCK} \
    -group {SPI_SCK}

# ---- IQ_CLK-domain inputs ----
set_input_delay -max 2.0 -clock IQ_CLK [get_ports {IQ_DATA_I[*] IQ_DATA_Q[*]}]
set_input_delay -min 1.0 -clock IQ_CLK [get_ports {IQ_DATA_I[*] IQ_DATA_Q[*]}]
set_input_delay -max 10.0 -clock IQ_CLK [get_ports {GRP_ADDR[*] GRP_WDATA[*] GRP_WE GRP_RE}]
set_input_delay -min 1.0  -clock IQ_CLK [get_ports {GRP_ADDR[*] GRP_WDATA[*] GRP_WE GRP_RE}]

# ---- PSRAM QPI read data: APS6404L drives tCO ≤ ~6.5 ns after PSRAM_SCK rising,
#      plus ~2.5 ns pads/board round trip ----
set_input_delay -max 9.0 -clock PSRAM_SCK [get_ports {PSRAM_SIO_IN[*]}]
set_input_delay -min 1.5 -clock PSRAM_SCK [get_ports {PSRAM_SIO_IN[*]}]

# ---- SPI inputs (Mode 0; 10 MHz max — margins are large, modelling is
#      deliberately conservative against the rising edge) ----
set_input_delay -max 15.0 -clock SPI_SCK [get_ports SPI_MOSI]
set_input_delay -min 0.0  -clock SPI_SCK [get_ports SPI_MOSI]

# ---- Asynchronous controls ----
set_false_path -from [get_ports RESETB]
set_false_path -from [get_ports HOST_CS]

# ---- IQ_CLK-domain outputs ----
set_output_delay -max 2.0 -clock IQ_CLK \
    [get_ports {REMOD_A_I REMOD_A_Q IRQ_OUT IRQ_GROUPER GRP_RDATA[*] GRP_READY}]
set_output_delay -min 0.0 -clock IQ_CLK \
    [get_ports {REMOD_A_I REMOD_A_Q IRQ_OUT IRQ_GROUPER GRP_RDATA[*] GRP_READY}]

# ---- PSRAM source-synchronous outputs: APS6404L tSP = 2 ns, tHD = 2 ns ----
set_output_delay -max 2.0  -clock PSRAM_SCK \
    [get_ports {PSRAM_SIO_OUT[*] PSRAM_SIO_OE[*] PSRAM_CE_N}]
set_output_delay -min -2.0 -clock PSRAM_SCK \
    [get_ports {PSRAM_SIO_OUT[*] PSRAM_SIO_OE[*] PSRAM_CE_N}]

# ---- SPI MISO: launched on falling SCK, master samples on next rising ----
set_output_delay -max 15.0 -clock SPI_SCK [get_ports SPI_MISO]
set_output_delay -min 0.0  -clock SPI_SCK [get_ports SPI_MISO]
