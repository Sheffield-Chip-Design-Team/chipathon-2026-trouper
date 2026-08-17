# cocotb/mcp_mrc_settle/Makefile
# Open Risks item 43 (paced_dsp MCP=3/2 settle proof, mrc_combiner leg):
# unit-level bench asserting the paced-MAC result registers (prod_i_r/
# prod_q_r, and the final y_i/y_q output) never change before mac_wait has
# reached its terminal MAC_WAIT count from state entry, plus a
# reset-mid-burst re-arm case. TOPLEVEL = mrc_combiner directly.
#
# Usage (inside the chipathon26 container):
#   make            # both testcases
#   make clean

SIM           ?= verilator
TOPLEVEL_LANG  = verilog
TOPLEVEL            = mrc_combiner
COCOTB_TEST_MODULES = test_mcp_mrc_settle

DESIGN_ROOT   ?= /foss/designs/lora-mimo
SRC            = $(DESIGN_ROOT)/src
TESTS          = $(DESIGN_ROOT)/cocotb/tests

VERILOG_SOURCES = $(SRC)/combiner/mrc_combiner.v

EXTRA_ARGS += --timing -Wno-fatal --public-flat-rw

PYTHONPATH    := $(TESTS)

COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
