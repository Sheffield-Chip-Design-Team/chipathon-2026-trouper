# cocotb/mcp_tacc_settle/Makefile
# Open Risks item 43 (paced_dsp MCP=3/2 settle proof, training_acc leg):
# unit-level bench asserting the dual-multiplier result registers
# (mul_out/mulB_out) never change before tdm_wait has reached its terminal
# TDM_WAIT count from the active pipeline entering, plus a reset-mid-burst
# re-arm case (training_acc's mul_out/mulB_out are deliberately resetless --
# see below -- so the case verifies the *consuming* counters re-arm cleanly,
# not that mul_out itself clears). TOPLEVEL = training_acc directly.
#
# Usage (inside the chipathon26 container):
#   make            # both testcases
#   make clean

SIM           ?= verilator
TOPLEVEL_LANG  = verilog
TOPLEVEL            = training_acc
COCOTB_TEST_MODULES = test_mcp_tacc_settle

DESIGN_ROOT   ?= /foss/designs/lora-mimo
SRC            = $(DESIGN_ROOT)/src
TESTS          = $(DESIGN_ROOT)/cocotb/tests

VERILOG_SOURCES = $(SRC)/combiner/training_acc.v

EXTRA_ARGS += --timing -Wno-fatal --public-flat-rw

PYTHONPATH    := $(TESTS)

COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
