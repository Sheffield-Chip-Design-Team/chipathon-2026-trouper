# Bit-exact regression of training_acc against sim/models/training_accumulator.py
# (training_accumulate_allpairs): packet windows with timing_ref behind/ahead of
# the lock, the >=8-symbol clamp, W=15, full-scale int8, noise mode, re-arm.
# Covers TRPR-TAC-001/002/003/007/009.

SIM                  ?= verilator
TOPLEVEL_LANG        := verilog
TOPLEVEL             := training_acc
COCOTB_TEST_MODULES  := test_tacc_golden

DESIGN_ROOT          ?= /foss/designs/lora-mimo
SRC                  := $(DESIGN_ROOT)/src
TESTS                := $(DESIGN_ROOT)/cocotb/tests

VERILOG_SOURCES      := $(SRC)/combiner/training_acc.v
EXTRA_ARGS           += --timing -Wno-fatal
PYTHONPATH           := $(TESTS):$(DESIGN_ROOT)
COCOTB_RESULTS_FILE  := results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
