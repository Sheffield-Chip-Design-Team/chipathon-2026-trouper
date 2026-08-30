SIM ?= verilator
TOPLEVEL_LANG := verilog
TOPLEVEL := comb_remod_transfer
COCOTB_TEST_MODULES := test_comb_remod_transfer
DESIGN_ROOT ?= /foss/designs/lora-mimo
SRC := $(DESIGN_ROOT)/src
TESTS := $(DESIGN_ROOT)/cocotb/tests
VERILOG_SOURCES := $(CURDIR)/comb_remod_transfer.v $(SRC)/combiner/mrc_combiner.v $(SRC)/remod/sd_remod.v
EXTRA_ARGS += --timing -Wno-fatal
PYTHONPATH := $(TESTS)
COCOTB_RESULTS_FILE := results.xml
include $(shell cocotb-config --makefiles)/Makefile.sim
