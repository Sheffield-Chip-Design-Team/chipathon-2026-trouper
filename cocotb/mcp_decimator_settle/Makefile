# cocotb/mcp_decimator_settle/Makefile
# Open Risks item 43 (paced_dsp MCP=3/2 settle proof, sd_decimator_poly leg):
# unit-level bench asserting the HB1/HB2 paced-MAC result registers
# (hb1_hold_i/q, iq_out_i/q) never change before their hb1_wait/hb2_wait
# counter has reached its terminal MAC_WAIT count from burst entry, plus a
# reset-mid-burst re-arm case. TOPLEVEL = sd_decimator_poly directly (no
# trouper_top wrapper needed -- all paced signals are ports or module-scope
# regs).
#
# Usage (inside the chipathon26 container):
#   make            # both testcases
#   make clean

SIM           ?= verilator
TOPLEVEL_LANG  = verilog
TOPLEVEL            = sd_decimator_poly
COCOTB_TEST_MODULES = test_mcp_decimator_settle

DESIGN_ROOT   ?= /foss/designs/lora-mimo
SRC            = $(DESIGN_ROOT)/src
TESTS          = $(DESIGN_ROOT)/cocotb/tests

VERILOG_SOURCES = $(SRC)/decimator/sd_decimator_poly.v

EXTRA_ARGS += --timing -Wno-fatal --public-flat-rw

PYTHONPATH    := $(TESTS)

COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
