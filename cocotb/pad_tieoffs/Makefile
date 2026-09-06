# A40 padframe pad-control tie-off contract (TRPR-PHY-004, TRPR-SPS-008).
# Checks the 96 constant tie-offs against planning/Pinout.md and the 4 dynamic
# PSRAM_SIO_n_IE lanes against ~OE, continuously through live QPI traffic.
SIM           ?= verilator
TOPLEVEL_LANG  = verilog
TOPLEVEL       = tb_trouper_cocotb
COCOTB_TEST_MODULES = test_pad_tieoffs

DESIGN_ROOT ?= /foss/designs/lora-mimo
SRC = $(DESIGN_ROOT)/src
HDL = $(DESIGN_ROOT)/cocotb/hdl
TESTS = $(DESIGN_ROOT)/cocotb/tests

VERILOG_SOURCES = \
    $(SRC)/top/trouper_top.v $(SRC)/decimator/sd_decimator_poly.v \
    $(SRC)/frontend/dc_removal.v $(SRC)/frontend/sc_detector.v \
    $(SRC)/combiner/training_acc.v $(SRC)/combiner/mrc_combiner.v \
    $(SRC)/debug/bringup_src.v \
    $(SRC)/control/packet_ctrl_fsm.v $(SRC)/control/psram_buf_ctrl.v \
    $(SRC)/control/spi_slave.v $(SRC)/control/reg_bank.v \
    $(SRC)/remod/sd_remod.v $(SRC)/remod/sd_remod_multiplierless.v $(HDL)/psram_model.v $(HDL)/tb_trouper_cocotb.v

EXTRA_ARGS += --timing -Wno-fatal --public-flat-rw
PYTHONPATH := $(TESTS)
COCOTB_RESULTS_FILE = results.xml
include $(shell cocotb-config --makefiles)/Makefile.sim
