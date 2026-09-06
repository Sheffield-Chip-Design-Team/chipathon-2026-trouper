# cocotb/bringup_src/Makefile
# Deterministic bring-up sample source (test_bringup_src.py): the
# BRINGUP_CTRL/BRINGUP_AMPL register pair, reset-to-normal selection, the
# RX_HOLD && !PACKET_ACTIVE arming gate, every generator mode, amplitude
# clamping, deterministic restart, and the proof that the disabled source
# cannot perturb the combiner input stream.
# See planning/foundational-block-bringup-plan.md.
#
# Usage (inside the chipathon26 container):
#   make            # all testcases
#   make TESTCASE=test_disabled_source_does_not_perturb_the_path
#   make clean

SIM           ?= verilator
TOPLEVEL_LANG  = verilog
TOPLEVEL            = tb_trouper_cocotb
COCOTB_TEST_MODULES = test_bringup_src

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

# cocotb finds the Python test module via PYTHONPATH.  DESIGN_ROOT is on the
# path too: the end-to-end re-modulator checks reconstruct the 1-bit output
# with sim.tests.remod_order_sweep.brickwall_lp_decim, the same R=64
# decimation the remod SQNR model uses.
PYTHONPATH    := $(DESIGN_ROOT):$(TESTS)

COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
