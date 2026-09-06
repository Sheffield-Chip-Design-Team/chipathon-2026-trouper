# cocotb/psram_en_glitch/Makefile
# PSRAM_EN dropped mid-transaction, state==S_REPLAY, port driven directly
# (test_psram_en_glitch.py): TRPR-PSR-009, verification-plan row #19 -- see
# planning/verification-plan/psram-buf-ctrl-verification-plan.md.
#
# Runs on Verilator, same recipe as qspi_owner/bypass_e2e (--timing,
# --public-flat-rw -- the latter is what makes dut.u_dut.u_psram.psram_en
# force-writable from Python, bypassing spi_write/reg_bank entirely).
#
# Usage (inside the chipathon26 container):
#   make            # single testcase
#   make clean

SIM           ?= verilator
TOPLEVEL_LANG  = verilog
TOPLEVEL            = tb_trouper_cocotb
COCOTB_TEST_MODULES = test_psram_en_glitch

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
    $(SRC)/remod/sd_remod_multiplierless.v \
    $(HDL)/psram_model.v                 \
    $(HDL)/tb_trouper_cocotb.v

EXTRA_ARGS += --timing -Wno-fatal --public-flat-rw

# cocotb finds the Python test module via PYTHONPATH
PYTHONPATH    := $(TESTS)

COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
