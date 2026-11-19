SIM ?= verilator
TOPLEVEL_LANG := verilog
TOPLEVEL := remod_amp_sweep
COCOTB_TEST_MODULES := test_remod_amp_sweep
DESIGN_ROOT ?= /foss/designs/lora-mimo
SRC := $(DESIGN_ROOT)/src
TESTS := $(DESIGN_ROOT)/cocotb/tests
VERILOG_SOURCES := $(CURDIR)/remod_amp_sweep.v $(SRC)/remod/sd_remod.v $(SRC)/remod/sd_remod_multiplierless.v
EXTRA_ARGS += --timing -Wno-fatal
PYTHONPATH := $(TESTS):$(DESIGN_ROOT)
COCOTB_RESULTS_FILE := results.xml
include $(shell cocotb-config --makefiles)/Makefile.sim
