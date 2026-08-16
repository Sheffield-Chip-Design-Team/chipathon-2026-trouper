# cocotb/bypass_antenna/Makefile
# Open Risks #4 regression: bypass_ant must select the LOWEST enabled antenna.
#
# trouper_top.v's bypass_ant mux originally tested active_antenna_en[1..3] and
# fell back to 0, never testing bit0 first -- so with all antennas enabled it
# selected antenna 1. Fixed 2026-07-05.
#
# NOT subsumed by cocotb/bypass_e2e: that suite drives ANTENNA_EN masks 0xF and
# 0xC only, and asserts on the end-to-end mode-1 datapath. This one drives
# 0xF/0xE/0xC/0x8 and asserts directly on the mux, so the 0xE->1 and 0x8->3
# cases -- exactly the ones that catch a "skips bit0" or wrong-priority
# regression -- exist only here. bypass_e2e's own header says as much.
#
# Each mask needs a FULL reset + drive-to-sc_lock cycle: active_antenna_en is
# latched from the ANTENNA_EN shadow only on the sc_lock rising edge while the
# packet FSM is in ST_IDLE, so writing ANTENNA_EN alone does not take effect.
#
# Migrated out of rtl-test/tb (scratch, no runner) 2026-08-16.
# Stimulus is synthetic (sdm_driver) -- no capture file, no sim/models import.

SIM           ?= verilator
TOPLEVEL_LANG  = verilog
TOPLEVEL            = tb_trouper_cocotb
COCOTB_TEST_MODULES = test_bypass_antenna

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

# --public-flat-rw: the test reads dut.u_dut.bypass_ant / active_antenna_en.
EXTRA_ARGS += --timing -Wno-fatal --trace --public-flat-rw

PYTHONPATH    := $(TESTS)

COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
