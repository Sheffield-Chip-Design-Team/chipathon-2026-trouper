# cocotb/dbg_write/Makefile
# PSRAM debug WRITE port (test_dbg_write.py): 0x79 PSRAM_DBG_WDATA + 0x75[2]
# WR_TRIG -- commit an 8-byte line to PSRAM over host SPI and verify it both
# against the behavioural model's stored nibbles and through the debug read
# path.  Mirror of the psram_ops debug-readback recipe.
# See planning/Register Map.md "0x72-0x76, 0x79 -- PSRAM Debug Access Registers".
#
# Runs on Verilator, same recipe as psram_ops (--timing, --public-flat-rw --
# _model_byte reads dut.u_psram.mem[] hierarchically).
#
# Usage (inside the chipathon26 container):
#   make            # all testcases
#   make clean

SIM           ?= verilator
TOPLEVEL_LANG  = verilog
TOPLEVEL            = tb_trouper_cocotb
COCOTB_TEST_MODULES = test_dbg_write

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

PYTHONPATH    := $(TESTS)

COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
