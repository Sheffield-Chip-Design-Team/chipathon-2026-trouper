# cocotb/trouper_top/Makefile
# All SF7-SF12 × BW250/125 integration tests via cocotb + Verilator.
# Production trouper_top: HB decimator chain (sd_decimator_poly, R=64, 500 kS/s).
# test_startup.py adds power-on/reset-ordering coverage (Open Risks item 27).
#
# Default switched icarus -> verilator 2026-07-12: full 18-test sweep runs in
# ~73 s compiled vs 1 h+ interpreted (SF11/SF12 dominate). SIM=icarus still
# works if an event-driven cross-check is ever wanted.
#
# Usage:
#   make                                          # run all tests (sweep + startup)
#   make TESTCASE=test_sf7_bw250,test_sf7_bw125   # subset
#   make TESTCASE=test_psram_init_has_no_tpu_wait,test_qe_init_trst_margin
#   make clean
#
# Inside the chipathon26 Docker container the repo root is mounted at
# /foss/designs/lora-mimo; DESIGN_ROOT points there.

SIM           ?= verilator
TOPLEVEL_LANG  = verilog
TOPLEVEL            = tb_trouper_cocotb
COCOTB_TEST_MODULES = test_trouper_top,test_startup

# --timing: Timer()-based SPI bit-bang in the tests
# --public-flat-rw: hierarchical dut.u_dut.* reads
ifeq ($(SIM),verilator)
EXTRA_ARGS += --timing -Wno-fatal --public-flat-rw
endif

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

# cocotb finds the Python test module via PYTHONPATH
PYTHONPATH    := $(TESTS)

COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
