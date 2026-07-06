# cocotb/bypass_e2e/Makefile
# Mode-1 passthrough end-to-end regression (test_bypass_e2e.py).
# TRPR-RMD-008 / TRPR-MRC-005 / TRPR-PCF-011 -- see planning/Traceability.md.
#
# Runs on Verilator: three full reset->lock->training cycles at 32 MS/s are
# slow under Icarus. Same recipe as trouper_capture: --timing for the
# Timer()-based SPI bit-bang, --public-flat-rw for hierarchical reads
# (dut.u_dut.u_comb.*, comb_y_*, psram_silence, remod_in_*).
#
# Usage (inside the chipathon26 container):
#   make            # all three testcases
#   make TESTCASE=test_mode1_e2e_ant0
#   make clean

SIM           ?= verilator
TOPLEVEL_LANG  = verilog
TOPLEVEL            = tb_trouper_cocotb
COCOTB_TEST_MODULES = test_bypass_e2e

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

# cocotb finds the Python test module via PYTHONPATH
PYTHONPATH    := $(TESTS)

COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
