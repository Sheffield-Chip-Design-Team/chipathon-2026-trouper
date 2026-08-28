# cocotb/mcp_iq_samp_cnt_settle/Makefile
# Open Risks item 43: paced-DSP MCP=3/2 settle proof for the dcr_valid ->
# iq_samp_cnt cone. iq_samp_cnt is a top-level trouper_top reg, outside the
# SDC paced_nets ({u_dec.* u_sc.* u_tacc.* u_comb.*}) wildcard, so neither
# test_mcp_decimator_settle.py nor test_mcp_tacc_settle.py can reach it --
# this bench is the honest bar for adding an iq_samp_cnt group at
# `set_multicycle_path 3 -setup / 2 -hold`.
#
# TOPLEVEL = tb_trouper_cocotb (same wrapper the other top-level MCP benches
# use). The bench asserts the load-bearing fact that dcr_valid is never high
# on two consecutive IQ_CLK edges, that iq_samp_cnt only ever moves on a
# post-dcr_valid edge by exactly +1, and a reset-mid-stream re-arm case.
#
# Usage (inside the chipathon26 container):
#   make            # all testcases
#   make clean

SIM           ?= verilator
TOPLEVEL_LANG  = verilog
TOPLEVEL            = tb_trouper_cocotb
COCOTB_TEST_MODULES = test_mcp_iq_samp_cnt_settle

DESIGN_ROOT   ?= /foss/designs/lora-mimo
SRC            = $(DESIGN_ROOT)/src
HDL            = $(DESIGN_ROOT)/cocotb/hdl
TESTS          = $(DESIGN_ROOT)/cocotb/tests

VERILOG_SOURCES = \
    $(SRC)/top/trouper_top.v             \
    $(SRC)/decimator/sd_decimator_poly.v \
    $(SRC)/frontend/dc_removal.v         \
    $(SRC)/frontend/sc_detector.v        \
    $(SRC)/combiner/training_acc.v       \
    $(SRC)/combiner/mrc_combiner.v       \
    $(SRC)/control/packet_ctrl_fsm.v     \
    $(SRC)/control/psram_buf_ctrl.v      \
    $(SRC)/control/spi_slave.v           \
    $(SRC)/control/reg_bank.v            \
    $(SRC)/remod/sd_remod.v              \
    $(HDL)/psram_model.v                 \
    $(HDL)/tb_trouper_cocotb.v

EXTRA_ARGS += --timing -Wno-fatal --public-flat-rw

PYTHONPATH    := $(TESTS)

COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
