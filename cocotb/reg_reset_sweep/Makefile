# cocotb/reg_reset_sweep/Makefile
# Full reg_bank reset-value sweep, all 128 SPI addresses (test_reg_reset_sweep.py).
# TRPR-REG-001 -- see planning/Traceability.md.
#
# Usage (inside the chipathon26 container):
#   make            # both testcases (power-on + post-dirty reset)
#   make clean

SIM           ?= icarus
TOPLEVEL_LANG  = verilog
TOPLEVEL            = tb_trouper_cocotb
COCOTB_TEST_MODULES = test_reg_reset_sweep

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

# cocotb finds the Python test module via PYTHONPATH
PYTHONPATH    := $(TESTS)

COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
