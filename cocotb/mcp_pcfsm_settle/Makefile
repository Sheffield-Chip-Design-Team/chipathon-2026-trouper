# cocotb/mcp_pcfsm_settle/Makefile
# Open Risks item 43 settling proof for the pcfsm_quasi_static / pcfsm_mval
# MCP groups: asserts every quasi-static operand feeding the ST_ACQ_SETUP
# counter-load cone is stable for the 3 cycles the SDC exception claims.
# TOPLEVEL = packet_ctrl_fsm directly (no trouper_top wrapper).
#
# Usage (inside the chipathon26 container):
#   make            # all testcases
#   make clean

SIM           ?= verilator
TOPLEVEL_LANG  = verilog
TOPLEVEL            = packet_ctrl_fsm
COCOTB_TEST_MODULES = test_mcp_pcfsm_settle

DESIGN_ROOT   ?= /foss/designs/lora-mimo
SRC            = $(DESIGN_ROOT)/src
TESTS          = $(DESIGN_ROOT)/cocotb/tests

VERILOG_SOURCES = $(SRC)/control/packet_ctrl_fsm.v

EXTRA_ARGS += --timing -Wno-fatal --public-flat-rw

PYTHONPATH    := $(TESTS)

COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
