# cocotb/noise_window_edge/Makefile
# Open Risk #66 -- a same-cycle SC hit can falsely qualify a noise window as
# clean.
#
# In trouper_top.v's noise-window qualification block a contaminating
# sc_hit_dbg sets noise_window_sc_seen and, in the same sequential block,
# `training_done` qualifies sigma2_valid_r as `~noise_window_sc_seen && !sc_lock`.
# If a non-locking hit arrives on the completion edge, the non-blocking
# expression reads the stale noise_window_sc_seen == 0 and asserts NOISE_READY
# for a contaminated window. Earlier hits and same-cycle *locks* are handled
# correctly; only the non-locking hit exactly on `training_done` slips through.
#
# TOPLEVEL = noise_window_qual, a VERBATIM copy of that block (see the .v header)
# so the same-cycle race can be driven directly. The clean / hit-before /
# lock-on-edge cases must PASS; test_nonlocking_hit_on_completion_edge is
# EXPECTED TO FAIL until #66 is fixed.
#
# Usage (inside the chipathon26 container):
#   make
#   make clean

SIM           ?= verilator
TOPLEVEL_LANG  = verilog
TOPLEVEL            = noise_window_qual
COCOTB_TEST_MODULES = test_noise_window_edge

DESIGN_ROOT   ?= /foss/designs/lora-mimo
TESTS          = $(DESIGN_ROOT)/cocotb/tests

VERILOG_SOURCES = $(DESIGN_ROOT)/cocotb/noise_window_edge/noise_window_qual.v

EXTRA_ARGS += --timing -Wno-fatal --public-flat-rw

PYTHONPATH    := $(TESTS)

COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
