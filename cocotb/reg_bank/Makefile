# cocotb/reg_bank/Makefile
# Standalone, direct-DUT reg_bank regression -- no SPI/CDC framing, drives
# the register-bus slave ports directly.
#
# Rows covered in planning/verification-plan/reg-bank-verification-plan.md:
#   #4 all RW field storage, reserved-bit masking, and packed output mapping
#      (test_reg_bank_rw_map.py + reg_bank_map_oracle.py)
#
# The table-driven map oracle (reg_bank_map_oracle.py) is checked in for
# reuse by later rows per Sec 2a step 2 of the plan.
#
# Usage (inside the chipathon26 container):
#   make
#   make clean

SIM                 ?= icarus
TOPLEVEL_LANG        = verilog
TOPLEVEL             = reg_bank
COCOTB_TEST_MODULES  = test_reg_bank_rw_map,test_reg_bank_rx_hold

DESIGN_ROOT ?= /foss/designs/lora-mimo
SRC          = $(DESIGN_ROOT)/src
TESTS        = $(DESIGN_ROOT)/cocotb/tests

VERILOG_SOURCES = $(SRC)/control/reg_bank.v

PYTHONPATH := $(TESTS)

COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
