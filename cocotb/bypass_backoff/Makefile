# cocotb/bypass_backoff/Makefile
# Open Risk #65 -- REMOD_BACKOFF_SHIFT attenuates the Mode-1 / no-W_valid
# bypass path despite the direct-stream contract.
#
# trouper_top.v:922-923 applies `>>> rb_remod_backoff_shift` to the combiner
# output for ALL modes (only psram_silence bypasses it), and reg_bank.v resets
# remod_backoff_shift to 1. So Mode 1 (passthrough) and the no-W_valid fallback
# lose ~6 dB instead of delivering the selected antenna's int8 sample directly
# to sd_remod, contrary to TRPR-PCF-011 / TRPR-RMD-008. The existing bypass
# end-to-end check hides this by programming the shift to 0 before comparing.
#
# Top-level bench, TOPLEVEL = tb_trouper_cocotb. This test keeps the RESET
# DEFAULT backoff shift (1) and is EXPECTED TO FAIL until #65 is fixed (gate the
# shift to active MRC only, or change the spec).
#
# Usage (inside the chipathon26 container):
#   make
#   make clean

SIM           ?= verilator
TOPLEVEL_LANG  = verilog
TOPLEVEL            = tb_trouper_cocotb
COCOTB_TEST_MODULES = test_bypass_backoff

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

PYTHONPATH    := $(TESTS)

COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
