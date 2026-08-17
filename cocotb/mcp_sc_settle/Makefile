# cocotb/mcp_sc_settle/Makefile
# Open Risks item 43 (paced_dsp MCP=3/2 settle proof, sc_detector leg):
# unit-level bench asserting the TDM 8x8 multiply result register
# (tdm_mul_r) never changes before tdm_wait has reached its terminal
# TDM_WAIT count from burst entry, plus a reset-mid-burst re-arm case.
# TOPLEVEL = sc_detector directly.
#
# Usage (inside the chipathon26 container):
#   make            # both testcases
#   make clean

SIM           ?= verilator
TOPLEVEL_LANG  = verilog
TOPLEVEL            = sc_detector
COCOTB_TEST_MODULES = test_mcp_sc_settle

DESIGN_ROOT   ?= /foss/designs/lora-mimo
SRC            = $(DESIGN_ROOT)/src
TESTS          = $(DESIGN_ROOT)/cocotb/tests

VERILOG_SOURCES = $(SRC)/frontend/sc_detector.v

EXTRA_ARGS += --timing -Wno-fatal --public-flat-rw

PYTHONPATH    := $(TESTS)

COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
