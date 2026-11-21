# cocotb/sc_sample_count/Makefile
# sc_detector sample_count vs iq_valid across sc_clr re-arms
# (test_sc_sample_count.py): sc_clr phase sweep + multi-packet timing_ref
# against sim/models/sc_rtl.py without a reset between packets.
SIM ?= verilator
TOPLEVEL_LANG := verilog
TOPLEVEL := sc_detector
COCOTB_TEST_MODULES := test_sc_sample_count
DESIGN_ROOT ?= /foss/designs/lora-mimo
SRC := $(DESIGN_ROOT)/src
TESTS := $(DESIGN_ROOT)/cocotb/tests
VERILOG_SOURCES := $(SRC)/frontend/sc_detector.v
EXTRA_ARGS += --timing -Wno-fatal --public-flat-rw
PYTHONPATH := $(TESTS):$(DESIGN_ROOT)
COCOTB_RESULTS_FILE := results.xml
include $(shell cocotb-config --makefiles)/Makefile.sim
