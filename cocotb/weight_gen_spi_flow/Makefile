# cocotb/weight_gen_spi_flow/Makefile
# Firmware weight-generation flow over the real SPI register interface,
# verified bit-exactly against the sim/models oracle:
#   IRQ -> read Z over SPI -> firmware weight compute -> write W shadow ->
#   W_COMMIT -> combiner output vs nonfft_combine_rtl_int8w
#
# Three tests: plain eigenvector, de-biased (nw), and SNR-weighted (snrw).
# Migrated out of rtl-test/tb (scratch, no runner) 2026-08-16.
#
# Unlike the other cocotb suites this one imports the bit-true reference
# models from sim/, so DESIGN_ROOT must point at a tree with BOTH src/ and
# sim/ synced -- a src-only sync makes this fail at import.
#
# Usage (inside the chipathon26 container):
#   make            # uses the shared-mount default capture
#   make CAPTURE_NPY=... CAPTURE_START=... CAPTURE_NSAMP=...

SIM           ?= verilator
TOPLEVEL_LANG  = verilog
TOPLEVEL            = tb_trouper_cocotb
COCOTB_TEST_MODULES = test_weight_gen_spi_flow

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

EXTRA_ARGS += --timing -Wno-fatal --trace --public-flat-rw

# cocotb finds the test + iq_capture helper here; the test itself prepends
# DESIGN_ROOT to sys.path so `import sim.models...` resolves.
PYTHONPATH    := $(TESTS)

export CAPTURE_NPY
export CAPTURE_START
export CAPTURE_NSAMP
export SHARED_DIR

COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
