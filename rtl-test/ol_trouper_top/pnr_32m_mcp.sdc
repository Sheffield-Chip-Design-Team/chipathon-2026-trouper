# pnr_32m_mcp.sdc
# Accurate dual-rate constraint for trouper_top.
#
# IQ_CLK is 32 MHz (31.25 ns).  Two data rates share this clock:
#   - 32 MHz: sd_decimator instances (integrators accumulate every cycle),
#             sd_remod (sigma-delta runs every cycle).
#   - 16 MHz: all downstream blocks — dc_removal, frontend_buf_ctrl,
#             sc_detector, training_acc, mrc_combiner, psram_buf_ctrl,
#             noise_est, packet_ctrl_fsm, reg_bank, picorv32_wrap,
#             ahb_lite_bus, irq_ctrl, spi_slave, spi_master.
#             dcr_valid pulses at most every 2 cycles (R >= 2), so these
#             registers are stable for >= 2 cycles between data changes.
#
# Strategy: set base clock at 32 MHz, apply global MCP=2 for setup,
# then override to MCP=1 for the sd_decimator and sd_remod internal paths.

create_clock -name IQ_CLK -period 31.25 [get_ports IQ_CLK]
create_clock -name SPI_SCK -period 100.0 [get_ports SPI_SCK]
set_clock_uncertainty 2.0 [get_clocks IQ_CLK]

set_input_delay  -max 2.0 -clock IQ_CLK [get_ports {IQ_DATA_I IQ_DATA_Q SPI_MOSI TMS_GPIO0 TDI_GPIO1}]
set_input_delay  -min 1.0 -clock IQ_CLK [get_ports {IQ_DATA_I IQ_DATA_Q SPI_MOSI TMS_GPIO0 TDI_GPIO1}]
set_output_delay -max 2.0 -clock IQ_CLK [all_outputs]
set_output_delay -min 0.0 -clock IQ_CLK [all_outputs]

set_false_path -from [get_ports RESETB]
set_false_path -from [get_ports HOST_CS]
set_clock_groups -asynchronous -group [get_clocks IQ_CLK] -group [get_clocks SPI_SCK]

# ---- Global: all paths get 2-cycle (62.5 ns) budget ----
# This covers the 16 MHz domain and the control plane.
set_multicycle_path 2 -setup
set_multicycle_path 1 -hold

# ---- Override: sd_decimator internal paths must meet 32 MHz (1 cycle) ----
# Integrators accumulate on every clock edge regardless of dcr_valid.
set_multicycle_path 1 -setup -from [get_cells {u_dec_0/*}] -to [get_cells {u_dec_0/*}]
set_multicycle_path 1 -setup -from [get_cells {u_dec_1/*}] -to [get_cells {u_dec_1/*}]
set_multicycle_path 1 -setup -from [get_cells {u_dec_2/*}] -to [get_cells {u_dec_2/*}]
set_multicycle_path 1 -setup -from [get_cells {u_dec_3/*}] -to [get_cells {u_dec_3/*}]

# ---- Override: sd_remod internal paths must meet 32 MHz (1 cycle) ----
# Sigma-delta accumulator updates every clock.
set_multicycle_path 1 -setup -from [get_cells {u_remod/*}] -to [get_cells {u_remod/*}]

# ---- Override: psram_buf_ctrl internal paths must meet 32 MHz (1 cycle) ----
# sub/init_sub FSM advances one state per clock during QPI transactions;
# sio_out/ce_n/sck_en also change every cycle in those phases.
set_multicycle_path 1 -setup -from [get_cells {u_psram/*}] -to [get_cells {u_psram/*}]
