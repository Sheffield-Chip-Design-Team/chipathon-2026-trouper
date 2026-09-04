# cocotb/tacc_acc_overflow/Makefile
# Open Risk #63 -- training_acc signed cross-pairs (and unsigned diagonals)
# overflow at a legal TACC_WINDOW_SYMS=15 window.
#
# training_acc.v accumulates the six complex cross-pair outputs into signed
# [31:0] registers (line 55-60) and the four diagonals into unsigned [31:0]
# (line 62). TACC_WINDOW_SYMS exposes 8..15 and M reaches 16384, so the legal
# maximum is 15 * 16384 = 245760 accumulated samples (line 248-249). Two
# correlated branches at int8 full scale add 127*127*2 = 32258 per sample to a
# real cross-pair -> the signed-int32 range is exhausted after ~66573 samples,
# well inside the window, and the accumulator wraps negative -- corrupting the
# firmware MRC / eigenvector weight computation. The unsigned diagonals wrap
# after ~133147 samples at the same amplitude.
#
# Unit-level bench, TOPLEVEL = training_acc, noise mode (fully-forward window),
# constant correlated int8 stimulus. EXPECTED TO FAIL until #63 is fixed.
#
# Usage (inside the chipathon26 container):
#   make
#   make clean

SIM           ?= verilator
TOPLEVEL_LANG  = verilog
TOPLEVEL            = training_acc
COCOTB_TEST_MODULES = test_tacc_acc_overflow

DESIGN_ROOT   ?= /foss/designs/lora-mimo
SRC            = $(DESIGN_ROOT)/src
TESTS          = $(DESIGN_ROOT)/cocotb/tests

VERILOG_SOURCES = $(SRC)/combiner/training_acc.v

EXTRA_ARGS += --timing -Wno-fatal --public-flat-rw

PYTHONPATH    := $(TESTS)

COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
