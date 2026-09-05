# cocotb/sc_dbg/Makefile
# SC debug/telemetry register readback regression (test_sc_dbg_flags.py):
# SC_DBG_FLAGS/SC_STAT/SC_FIRST_HIT/SC_LOCK_SNAP over SPI, including the
# held sc_hit_hold readback fix. TRPR-SCD-010 / TRPR-SCD-009 -- see
# planning/Traceability.md.
#
# Runs on Verilator, same recipe as bypass_e2e (--timing, --public-flat-rw).
#
# Usage (inside the chipathon26 container):
#   make            # single testcase (test_sc_dbg_flags_readback)
#   make clean

SIM           ?= verilator
TOPLEVEL_LANG  = verilog
TOPLEVEL            = tb_trouper_cocotb
COCOTB_TEST_MODULES = test_sc_dbg_flags

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

# cocotb finds the Python test module via PYTHONPATH
PYTHONPATH    := $(TESTS)

COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
