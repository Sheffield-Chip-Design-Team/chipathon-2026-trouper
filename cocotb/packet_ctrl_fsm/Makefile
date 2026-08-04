# cocotb/packet_ctrl_fsm/Makefile
# Standalone, cycle-accurate packet_ctrl_fsm regression.
#
# Rows covered in planning/verification-plan/packet-ctrl-fsm-verification-plan.md:
#   #1 reset values and IDLE quiescence
#   #2 lock edge, packet-parameter latch, and one-cycle ST_ACQ_SETUP residency
#   #9-#12 deferred commits and deadline precedence
#   #18-#20 counter behavior, configuration extremes, and wrap
#
# Usage (inside the chipathon26 container):
#   make
#   make clean

SIM                 ?= verilator
TOPLEVEL_LANG        = verilog
TOPLEVEL             = packet_ctrl_fsm
COCOTB_TEST_MODULES  = test_packet_ctrl_fsm

DESIGN_ROOT ?= /foss/designs/lora-mimo
SRC          = $(DESIGN_ROOT)/src
TESTS        = $(DESIGN_ROOT)/cocotb/tests

VERILOG_SOURCES = $(SRC)/control/packet_ctrl_fsm.v

# --public-flat-rw exposes the state/counter registers used for cycle-exact
# comparison against the Python reference model.
EXTRA_ARGS += --timing -Wno-fatal --public-flat-rw

PYTHONPATH := $(TESTS)

COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
