# cocotb/mrc_absent_branch/Makefile
# Full end-to-end MRC firmware flow (capture -> decimate -> DC-removal ->
# SC lock -> training_acc -> Z read over SPI -> firmware eigenvector ->
# W shadow write -> W_COMMIT -> combiner) with 1 or 2 antenna branches
# carrying no signal. Combiner output checked bit-exactly against the
# sim/models oracle.
#
# Like weight_gen_spi_flow this suite imports the bit-true reference models
# from sim/, so DESIGN_ROOT must point at a tree with BOTH src/ and sim/
# synced -- a src-only sync makes this fail at import.
#
# Usage (inside the chipathon26 container):
#   make            # uses the shared-mount default capture
#   make CAPTURE_NPY=... CAPTURE_START=... CAPTURE_NSAMP=...

SIM           ?= verilator
TOPLEVEL_LANG  = verilog
TOPLEVEL            = tb_trouper_cocotb
COCOTB_TEST_MODULES = test_mrc_absent_branch

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

EXTRA_ARGS += --timing -Wno-fatal --trace --public-flat-rw

PYTHONPATH    := $(TESTS)

export CAPTURE_NPY
export CAPTURE_START
export CAPTURE_NSAMP
export SHARED_DIR

COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
