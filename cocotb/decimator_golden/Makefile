# Bit-exact regression of sd_decimator_poly against sim/models/decimator.py
# (CIC-3 R=16 -> HB1 -> HB2) on all 8 TDM streams, plus int8 saturation and the
# R=64 output cadence. Covers TRPR-DEC-001/002/004/006.

SIM                  ?= verilator
TOPLEVEL_LANG        := verilog
TOPLEVEL             := sd_decimator_poly
COCOTB_TEST_MODULES  := test_decimator_golden

DESIGN_ROOT          ?= /foss/designs/lora-mimo
SRC                  := $(DESIGN_ROOT)/src
TESTS                := $(DESIGN_ROOT)/cocotb/tests

VERILOG_SOURCES      := $(SRC)/decimator/sd_decimator_poly.v
EXTRA_ARGS           += --timing -Wno-fatal
PYTHONPATH           := $(TESTS):$(DESIGN_ROOT)
COCOTB_RESULTS_FILE  := results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
