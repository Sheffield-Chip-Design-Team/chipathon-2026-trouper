# cocotb/sc_acc_overflow/Makefile
# Open Risk #61 -- sc_detector full-symbol accumulators overflow and the
# delayed-energy snapshot drops the boundary sample.
#
# src/frontend/sc_detector.v keeps acc_ci0/acc_cq0/acc_E0cur/acc_E0del as
# signed [23:0] (line 159-160) while M reaches 16384. At the documented ~90-count
# AGC operating point a full symbol accumulates ~16.6 M energy counts for
# M=1024 -- past 2^23 -- and the symbol-boundary snapshot acc_*[22:10]
# (line 380-381) drops the sign bit [23], so a large positive accumulator is
# read as negative. The metric is then computed on sign-flipped garbage, and at
# some amplitudes (acc lands exactly on 2^23) the snapshot degenerates to 0 and
# sc_lock never fires for an otherwise clean, strong preamble.
#
# Unit-level bench, TOPLEVEL = sc_detector, cur==del (perfectly correlated
# preamble). The SF7/M=256 baseline case must PASS (no overflow); the
# SF9/M=1024 cases are EXPECTED TO FAIL until #61 is fixed.
#
# Usage (inside the chipathon26 container):
#   make
#   make clean

SIM           ?= verilator
TOPLEVEL_LANG  = verilog
TOPLEVEL            = sc_detector
COCOTB_TEST_MODULES = test_sc_acc_overflow

DESIGN_ROOT   ?= /foss/designs/lora-mimo
SRC            = $(DESIGN_ROOT)/src
TESTS          = $(DESIGN_ROOT)/cocotb/tests

VERILOG_SOURCES = $(SRC)/frontend/sc_detector.v

EXTRA_ARGS += --timing -Wno-fatal --public-flat-rw

PYTHONPATH    := $(TESTS)

COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
