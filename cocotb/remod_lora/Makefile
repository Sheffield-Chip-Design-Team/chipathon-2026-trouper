SIM ?= verilator
TOPLEVEL_LANG := verilog
TOPLEVEL := remod_lora
COCOTB_TEST_MODULES := test_remod_lora
DESIGN_ROOT ?= /foss/designs/lora-mimo
SRC := $(DESIGN_ROOT)/src
VERILOG_SOURCES := $(CURDIR)/remod_lora.v $(SRC)/remod/sd_remod.v $(SRC)/remod/sd_remod_multiplierless.v
EXTRA_ARGS += --timing -Wno-fatal
# $(DESIGN_ROOT)/sim on the path so `models.lora` / `models.decimator` resolve
# (same import style as rtl-test/tb/remod_compare); cocotb/tests for the module.
PYTHONPATH := $(DESIGN_ROOT)/cocotb/tests:$(DESIGN_ROOT)/sim
COCOTB_RESULTS_FILE := results.xml
include $(shell cocotb-config --makefiles)/Makefile.sim
