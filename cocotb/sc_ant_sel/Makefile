# cocotb/sc_ant_sel/Makefile
# BW_CFG.sc_ant_sel regression (test_sc_ant_sel.py): the new 0x0A[2:1] field
# that lets firmware route the SC correlator's cur_i0/cur_q0/del_i0/del_q0
# delay-line taps to any of the 4 antenna branches, instead of the previous
# hardcoded antenna 0. Mitigation for Open Risk #9 (SC acquisition has no
# diversity at lock time) -- not a fix for it, see planning/Register Map.md
# 0x0A.
#
# Runs on Verilator, same recipe as bypass_e2e (--timing, --public-flat-rw
# for the hierarchical dut.u_dut.u_psram.* / dut.u_dut.dcr_i[]/dcr_q[] reads).
#
# Usage (inside the chipathon26 container):
#   make            # all testcases
#   make clean

SIM           ?= verilator
TOPLEVEL_LANG  = verilog
TOPLEVEL            = tb_trouper_cocotb
COCOTB_TEST_MODULES = test_sc_ant_sel

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
    $(SRC)/debug/bringup_src.v           \
    $(SRC)/control/packet_ctrl_fsm.v     \
    $(SRC)/control/psram_buf_ctrl.v      \
    $(SRC)/control/spi_slave.v           \
    $(SRC)/control/reg_bank.v            \
    $(SRC)/remod/sd_remod.v              \
    $(HDL)/psram_model.v                 \
    $(HDL)/tb_trouper_cocotb.v

EXTRA_ARGS += --timing -Wno-fatal --public-flat-rw

# cocotb finds the Python test module via PYTHONPATH
PYTHONPATH    := $(TESTS)

COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
