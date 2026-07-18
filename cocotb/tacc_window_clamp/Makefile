# cocotb/tacc_window_clamp/Makefile
# training_acc window clamp (R3, dsp-block-review-changes-2026-07.md):
# tacc_window_syms < 8 clamps to 8 inside the module (matching reg_bank 0x27),
# so a direct-driven sub-8 window with a 4-symbol-late lock can no longer put
# acc_end before the lock instant and deadlock training_done. Unit-level
# bench driving sc_lock/timing_ref directly.
#
# Usage (inside the chipathon26 container):
#   make            # both testcases
#   make clean

SIM           ?= verilator
TOPLEVEL_LANG  = verilog
TOPLEVEL            = training_acc
COCOTB_TEST_MODULES = test_tacc_window_clamp

DESIGN_ROOT   ?= /foss/designs/lora-mimo
SRC            = $(DESIGN_ROOT)/src
TESTS          = $(DESIGN_ROOT)/cocotb/tests

VERILOG_SOURCES = $(SRC)/combiner/training_acc.v

EXTRA_ARGS += --timing -Wno-fatal --public-flat-rw

PYTHONPATH    := $(TESTS)

COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
