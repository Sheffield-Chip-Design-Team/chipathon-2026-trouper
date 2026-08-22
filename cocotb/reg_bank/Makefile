# cocotb/reg_bank/Makefile
# Standalone, direct-DUT reg_bank regression -- no SPI/CDC framing, drives
# the register-bus slave ports directly.
#
# Rows covered in planning/verification-plan/reg-bank-verification-plan.md:
#   #2 exhaustive address/access-permission/mask sweep
#      (test_reg_bank_rw_map.py::test_exhaustive_address_permission_mask_sweep)
#   #3 fixed IDs and all reserved addresses read zero/write ignored
#      (test_reg_bank_rw_map.py::test_reserved_addresses_zero_and_ignored,
#       test_reg_bank_rw_map.py::test_fixed_chip_ids)
#   #4 all RW field storage, reserved-bit masking, and packed output mapping
#      (test_reg_bank_rw_map.py + reg_bank_map_oracle.py)
#   #5 every RO/status input decode and reserved-bit zeroing
#      (test_reg_bank_ro_status.py)
#   #6 multi-byte big-endian ordering and truncation
#      (test_reg_bank_ro_status.py)
#   #7 TACC_WINDOW_SYMS clamp for all inputs, full 0..255 sweep
#      (test_reg_bank_clamp_and_gates.py::test_tacc_window_syms_full_clamp_sweep)
#   #8 packet-active write locks, table-driven blocked/ungated check
#      (test_reg_bank_clamp_and_gates.py)
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
COCOTB_TEST_MODULES  = test_reg_bank_rw_map,test_reg_bank_rx_hold,test_reg_bank_ro_status,test_reg_bank_clamp_and_gates

DESIGN_ROOT ?= /foss/designs/lora-mimo
SRC          = $(DESIGN_ROOT)/src
TESTS        = $(DESIGN_ROOT)/cocotb/tests

VERILOG_SOURCES = $(SRC)/control/reg_bank.v

PYTHONPATH := $(TESTS)

COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
