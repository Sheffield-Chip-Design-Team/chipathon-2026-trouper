# cocotb/dbg_write_collision/Makefile
# Debug-fetch vs. capture-write collision at the real R=64 iq_valid rate
# (test_dbg_write_collision.py): Open Risks #30, verification-plan row #16
# -- see planning/verification-plan/psram-buf-ctrl-verification-plan.md.
#
# Runs on Verilator, same recipe as psram_ops/psram_en_glitch (--timing,
# --public-flat-rw -- needed to read dut.u_dut.u_psram.{dbg_mode,qpi_busy,
# iq_valid,wr_ptr,sample_skip} cycle-accurately from Python).
#
# Usage (inside the chipathon26 container):
#   make            # single testcase
#   make clean

SIM           ?= verilator
TOPLEVEL_LANG  = verilog
TOPLEVEL            = tb_trouper_cocotb
COCOTB_TEST_MODULES = test_dbg_write_collision

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
