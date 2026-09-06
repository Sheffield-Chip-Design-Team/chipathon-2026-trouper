# cocotb/array_sync/Makefile
# Multi-ASIC acquisition sync (test_array_sync.py): two complete trouper_top
# instances sharing one ARRAY_ACQ_N wired-AND net.
#
# This is the only suite with two DUTs. TOPLEVEL is tb_array_pair, not the
# usual tb_trouper_cocotb, and the source list adds cocotb/hdl/tb_array_pair.v.
# Everything else follows the sc_force_lock recipe.
#
# Usage (inside the chipathon26 container):
#   make            # all testcases
#   make TESTCASE=test_peer_sync_starts_idle_chip
#   make clean

SIM           ?= verilator
TOPLEVEL_LANG  = verilog
TOPLEVEL            = tb_array_pair
COCOTB_TEST_MODULES = test_array_sync

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
    $(HDL)/tb_array_pair.v

EXTRA_ARGS += --timing -Wno-fatal --public-flat-rw

PYTHONPATH    := $(TESTS)

COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
