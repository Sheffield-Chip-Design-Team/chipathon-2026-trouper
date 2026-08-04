# cocotb/spi_slave/Makefile
# Standalone spi_slave.v protocol regression (test_spi_slave.py).
#
# Instantiates spi_slave.v directly (not trouper_top.v) and services its
# register-bank ports with an independent Python stub -- see the
# test_spi_slave.py module docstring. Distinct from cocotb/spi_cdc, which
# targets full-top CDC/timing through trouper_top.v.
#
# Rows covered in planning/verification-plan/spi-slave-verification-plan.md:
#   #11 read-byte atomicity under a live register change
#   #12 SCK-while-deselected and command-only-frame recovery
#   #14 standalone randomized protocol reference-model regression
#
# Usage (inside the chipathon26 container):
#   make
#   make clean

SIM           ?= icarus
TOPLEVEL_LANG  = verilog
TOPLEVEL             = spi_slave
COCOTB_TEST_MODULES  = test_spi_slave

DESIGN_ROOT ?= /foss/designs/lora-mimo
SRC          = $(DESIGN_ROOT)/src
TESTS        = $(DESIGN_ROOT)/cocotb/tests

VERILOG_SOURCES = $(SRC)/control/spi_slave.v

PYTHONPATH := $(TESTS)

COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
