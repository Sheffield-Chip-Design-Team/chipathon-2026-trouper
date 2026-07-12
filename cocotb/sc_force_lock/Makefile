# cocotb/sc_force_lock/Makefile
# SC_FORCE_LOCK regression (test_sc_force_lock.py): the new 0x19[0] W1P
# debug register that asserts sc_lock directly from reg_bank, bypassing the
# SC correlator's hit-count logic. Bring-up / catastrophic-detector-failure
# escape hatch -- register-only half of a future sc_lock_in pin design
# (planning/NR2-multi-ASIC-cascade.md), deferred until a spare pad exists
# (planning/Pinout.md).
#
# Runs on Verilator, same recipe as sc_ant_sel/bypass_e2e (--timing for the
# Timer()-based SPI bit-bang).
#
# Usage (inside the chipathon26 container):
#   make            # all testcases
#   make clean

SIM           ?= verilator
TOPLEVEL_LANG  = verilog
TOPLEVEL            = tb_trouper_cocotb
COCOTB_TEST_MODULES = test_sc_force_lock

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
