# cocotb/psram_ops/Makefile
# PSRAM replay-miss + debug-readback content (test_psram_ops.py): late
# W_COMMIT -> REPLAY_MISSED sticky/clear/recovery, and debug reads compared
# bit-exact vs the behavioural model's stored nibbles (incl. AUTO_INC).
# TRPR-PSR-004/PSR-017 (+PSR-006/PSR-007 bits) -- see planning/Traceability.md.
#
# Runs on Verilator, same recipe as bypass_e2e (--timing, --public-flat-rw).
#
# Usage (inside the chipathon26 container):
#   make            # both testcases
#   make clean

SIM           ?= verilator
TOPLEVEL_LANG  = verilog
TOPLEVEL            = tb_trouper_cocotb
COCOTB_TEST_MODULES = test_psram_ops

DESIGN_ROOT   ?= /foss/designs/lora-mimo
SRC            = $(DESIGN_ROOT)/src
HDL            = $(DESIGN_ROOT)/cocotb/hdl
TESTS          = $(DESIGN_ROOT)/cocotb/tests
GF180_IO_MODEL ?= 0
IO_MODEL       ?= /foss/pdks/ciel/gf180mcu/versions/7b70722e33c03fcb5dabcf4d479fb0822d9251c9/gf180mcuD/libs.ref/gf180mcu_fd_io/verilog/gf180mcu_fd_io.v

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

ifeq ($(GF180_IO_MODEL),1)
VERILOG_SOURCES += $(IO_MODEL)
ifeq ($(SIM),icarus)
COMPILE_ARGS += -DGF180_IO_MODEL
else
EXTRA_ARGS += -DGF180_IO_MODEL
endif
endif

ifneq ($(SIM),icarus)
EXTRA_ARGS += --timing -Wno-fatal --public-flat-rw
endif

# cocotb finds the Python test module via PYTHONPATH
PYTHONPATH    := $(TESTS)

COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
