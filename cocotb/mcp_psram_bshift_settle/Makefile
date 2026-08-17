# cocotb/mcp_psram_bshift_settle/Makefile
# Open Risks #43: settling proof for the psram_barrel_shift MCP group
# (MCP=2 setup / 1 hold -to u_psram.del_n_r[*]/del_offset_r[*]).
#
# This is the one group whose guarantee was already structural before the
# config-settle work: psram_buf_ctrl.v:314 loads the registers only when
# sf == sf_prev && sample_shift == sample_shift_prev, giving the variable-shift
# cone two settled cycles. No RTL change; this bench is the missing evidence.
#
# TOPLEVEL = psram_buf_ctrl directly -- the load gate depends only on
# clk/rst_n/sf/sample_shift, so no PSRAM model or trouper_top wrapper is needed.
#
# Usage (inside the chipathon26 container):
#   make            # all testcases
#   make clean

SIM           ?= verilator
TOPLEVEL_LANG  = verilog
TOPLEVEL            = psram_buf_ctrl
COCOTB_TEST_MODULES = test_mcp_psram_bshift_settle

DESIGN_ROOT   ?= /foss/designs/lora-mimo
SRC            = $(DESIGN_ROOT)/src
TESTS          = $(DESIGN_ROOT)/cocotb/tests

VERILOG_SOURCES = $(SRC)/control/psram_buf_ctrl.v

EXTRA_ARGS += --timing -Wno-fatal --public-flat-rw

PYTHONPATH    := $(TESTS)

COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
