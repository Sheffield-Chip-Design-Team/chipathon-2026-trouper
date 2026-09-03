# cocotb/pkt_timeout_states/Makefile
# Open Risk #64 -- packet timeout (PKT_TIMEOUT_SYMS) is ignored until
# ST_PAYLOAD_ACTIVE.
#
# packet_ctrl_fsm.v decrements pkt_cnt in ST_PREAMBLE_ACQ, ST_W_PENDING and
# ST_PAYLOAD_ACTIVE (line 164-170) but only tests pkt_cnt == 0 in
# ST_PAYLOAD_ACTIVE (line 290-297). If PKT_TIMEOUT_SYMS is shorter than the
# acquisition or weight-pending deadline, pkt_cnt reaches zero without forcing
# IDLE and packet_active stays asserted past the configured packet deadline,
# contrary to TRPR-PCF-007.
#
# Directed unit-level bench, TOPLEVEL = packet_ctrl_fsm. The PAYLOAD control
# case must PASS; the PREAMBLE_ACQ / W_PENDING cases are EXPECTED TO FAIL until
# #64 is fixed (or the register is explicitly redefined as payload-only).
#
# Usage (inside the chipathon26 container):
#   make
#   make clean

SIM                 ?= verilator
TOPLEVEL_LANG        = verilog
TOPLEVEL             = packet_ctrl_fsm
COCOTB_TEST_MODULES  = test_pkt_timeout_states

DESIGN_ROOT ?= /foss/designs/lora-mimo
SRC          = $(DESIGN_ROOT)/src
TESTS        = $(DESIGN_ROOT)/cocotb/tests

VERILOG_SOURCES = $(SRC)/control/packet_ctrl_fsm.v

EXTRA_ARGS += --timing -Wno-fatal --public-flat-rw

PYTHONPATH := $(TESTS)

COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
