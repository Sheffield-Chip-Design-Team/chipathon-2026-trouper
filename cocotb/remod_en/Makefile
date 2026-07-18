# cocotb/remod_en/Makefile
# sd_remod enable/disable behaviour (R1, dsp-block-review-changes-2026-07.md):
# integrators held at reset while en=0 (pre-fix: railed +32767 via -127
# feedback), re-enable bit-identical to fresh reset. Unit-level bench --
# trouper_top ties en to 1'b1, so the port is only reachable directly.
#
# Usage (inside the chipathon26 container):
#   make            # both testcases
#   make clean

SIM           ?= verilator
TOPLEVEL_LANG  = verilog
TOPLEVEL            = sd_remod
COCOTB_TEST_MODULES = test_remod_en

DESIGN_ROOT   ?= /foss/designs/lora-mimo
SRC            = $(DESIGN_ROOT)/src
TESTS          = $(DESIGN_ROOT)/cocotb/tests

VERILOG_SOURCES = $(SRC)/remod/sd_remod.v

EXTRA_ARGS += --timing -Wno-fatal --public-flat-rw

PYTHONPATH    := $(TESTS)

COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
