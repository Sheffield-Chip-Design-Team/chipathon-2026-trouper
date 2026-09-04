# cocotb/remod_backoff/Makefile
# REMOD_BACKOFF_SHIFT (COMB_CFG 0x0F[5:4]) regression -- the RTL safety net
# between the MRC combiner and sd_remod.
#
# sd_remod is only stable below -3 dBFS (SX1257 6.2.3) and wrap-around causes
# PERMANENT instability, so the backoff shift (reset default 1 = -6 dB) is
# load-bearing. Checks the shift is applied bit-exactly for shift in {0..3},
# and demonstrates the degradation it prevents via the 1-bit output stuck-run
# (integrator states are NOT a valid instability signal -- they sit near-rail
# even when healthy; see the test's _monitor_remod docstring).
#
# cocotb/tests/test_remod_en.py cites this test for that stuck-run argument.
#
# Migrated out of rtl-test/tb (scratch, no runner) 2026-08-16.
# Stimulus is synthetic (sdm_driver) -- no capture file, no sim/models import.

SIM           ?= verilator
TOPLEVEL_LANG  = verilog
TOPLEVEL            = tb_trouper_cocotb
COCOTB_TEST_MODULES = test_remod_backoff

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
    $(HDL)/psram_model.v                 \
    $(HDL)/tb_trouper_cocotb.v

# --public-flat-rw: the test reads dut.u_dut.comb_y_i / remod_in_i and the
# sd_remod integrator states hierarchically.
EXTRA_ARGS += --timing -Wno-fatal --trace --public-flat-rw

PYTHONPATH    := $(TESTS)

COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
