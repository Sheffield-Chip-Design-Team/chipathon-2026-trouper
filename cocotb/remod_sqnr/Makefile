SIM ?= verilator
TOPLEVEL_LANG := verilog
TOPLEVEL := remod_sqnr
COCOTB_TEST_MODULES := test_remod_sqnr
DESIGN_ROOT ?= /foss/designs/lora-mimo
SRC := $(DESIGN_ROOT)/src
TESTS := $(DESIGN_ROOT)/cocotb/tests
VERILOG_SOURCES := $(CURDIR)/remod_sqnr.v $(SRC)/remod/sd_remod.v $(SRC)/remod/sd_remod_multiplierless.v
EXTRA_ARGS += --timing -Wno-fatal
PYTHONPATH := $(TESTS):$(DESIGN_ROOT)
COCOTB_RESULTS_FILE := results.xml
include $(shell cocotb-config --makefiles)/Makefile.sim
