# Constrained-random bit-exact regression of mrc_combiner (standalone):
# random x/W at every post_gain_shift, accumulator/product extremes, bypass
# routing, and input-latch isolation. Covers TRPR-MRC-001/002/003, TRPR-PCF-011.

SIM                  ?= verilator
TOPLEVEL_LANG        := verilog
TOPLEVEL             := mrc_combiner
COCOTB_TEST_MODULES  := test_mrc_golden

DESIGN_ROOT          ?= /foss/designs/lora-mimo
SRC                  := $(DESIGN_ROOT)/src
TESTS                := $(DESIGN_ROOT)/cocotb/tests

VERILOG_SOURCES      := $(SRC)/combiner/mrc_combiner.v
EXTRA_ARGS           += --timing -Wno-fatal
PYTHONPATH           := $(TESTS):$(DESIGN_ROOT)
COCOTB_RESULTS_FILE  := results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
