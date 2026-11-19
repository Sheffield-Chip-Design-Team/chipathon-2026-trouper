# cocotb/remod_stability/Makefile
# Long constrained-random + adversarial stability confirmation for the
# canonical sd_remod (2x interpolator + 4th-order CIFF multiplierless core).
# Unit-level bench: TOPLEVEL = sd_remod directly, no trouper_top. Internals
# (s1_i..s4_q) visible via --public-flat-rw for the sat16-wrap sanity check.
#
# Millions of output clocks -- slower than the other remod suites (~2-3 min).
# Kept in SUITES_CORE alongside remod_en/remod_backoff/remod_sqnr/remod_flatness.

SIM           ?= verilator
TOPLEVEL_LANG  = verilog
TOPLEVEL            = sd_remod
COCOTB_TEST_MODULES = test_remod_stability

DESIGN_ROOT   ?= /foss/designs/lora-mimo
SRC            = $(DESIGN_ROOT)/src
TESTS          = $(DESIGN_ROOT)/cocotb/tests

VERILOG_SOURCES = $(SRC)/remod/sd_remod.v $(SRC)/remod/sd_remod_multiplierless.v

EXTRA_ARGS += --timing -Wno-fatal --public-flat-rw

PYTHONPATH    := $(TESTS):$(DESIGN_ROOT)

COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
