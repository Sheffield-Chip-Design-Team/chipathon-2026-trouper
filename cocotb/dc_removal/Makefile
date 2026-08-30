# Direct RTL regression for the DC-removal block.
# Covers TRPR-DCR-006 (256-sample residual) and TRPR-DCR-013 (one-time-
# constant settling reduction after reset) without involving the rest of the
# receive chain.

SIM                  ?= verilator
TOPLEVEL_LANG        := verilog
TOPLEVEL             := dc_removal
COCOTB_TEST_MODULES  := test_dc_removal

DESIGN_ROOT          ?= /foss/designs/lora-mimo
SRC                  := $(DESIGN_ROOT)/src
TESTS                := $(DESIGN_ROOT)/cocotb/tests

VERILOG_SOURCES      := $(SRC)/frontend/dc_removal.v
EXTRA_ARGS           += --timing -Wno-fatal
PYTHONPATH           := $(TESTS)
COCOTB_RESULTS_FILE  := results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
