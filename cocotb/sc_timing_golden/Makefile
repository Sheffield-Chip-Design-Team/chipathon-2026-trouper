# cocotb/sc_timing_golden/Makefile
# Lock-for-lock / timing_ref-for-timing_ref diff of src/frontend/sc_detector.v
# against the integer model sim/models/sc_rtl.py (test_sc_timing_golden.py).
SIM ?= verilator
TOPLEVEL_LANG := verilog
TOPLEVEL := sc_detector
COCOTB_TEST_MODULES := test_sc_timing_golden
DESIGN_ROOT ?= /foss/designs/lora-mimo
SRC := $(DESIGN_ROOT)/src
TESTS := $(DESIGN_ROOT)/cocotb/tests
VERILOG_SOURCES := $(SRC)/frontend/sc_detector.v
EXTRA_ARGS += --timing -Wno-fatal
PYTHONPATH := $(TESTS):$(DESIGN_ROOT)
COCOTB_RESULTS_FILE := results.xml
include $(shell cocotb-config --makefiles)/Makefile.sim
