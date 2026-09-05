# cocotb/dbg_qpi_busy/Makefile
# Open Risk #67 -- the debug probe's qpi_busy source is permanently asserted
# after PSRAM init.
#
# trouper_top.v:1201 feeds debug_probe_mux's qpi_busy input with
# `|psram_state_dbg`. The initialized PSRAM states S_QE_INIT/S_WRITE/S_REPLAY
# are all nonzero, so debug group 101 (G_PSRAM), selector 0, column d1 reports
# busy continuously after init instead of tracking individual QPI transactions.
# psram_buf_ctrl.v has the real transaction-level `qpi_busy` register
# (line 231, toggled per burst) but does not export it.
#
# Top-level bench, TOPLEVEL = tb_trouper_cocotb: point the shared IRQ_OUT/DBG1
# pad at group 101 / sel 0 and compare it against the (hierarchically read)
# internal qpi_busy. EXPECTED TO FAIL until #67 is fixed (export the real level,
# or rename/redocument the probe).
#
# Usage (inside the chipathon26 container):
#   make
#   make clean

SIM           ?= verilator
TOPLEVEL_LANG  = verilog
TOPLEVEL            = tb_trouper_cocotb
COCOTB_TEST_MODULES = test_dbg_qpi_busy

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

PYTHONPATH    := $(TESTS)

COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
