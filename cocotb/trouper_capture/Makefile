# cocotb/trouper_capture/Makefile
# Drive trouper_top with a MEASURED IQ capture (test_capture_playback.py).
# Runs on Verilator (not Icarus) — millions of 32 MS/s clocks bit-by-bit are
# impractical under Icarus. Clip the capture with CAPTURE_START/CAPTURE_NSAMP.
#
# Usage (inside the chipathon26 container). Real captures are available via
# the hlab-sge shared_data_dir mount (read-only, present in every job
# automatically): $SHARED_DIR/lora-mimo-captures/captures/<file>.npy — see
# rtl-test/scripts/run_capture_playback.sh for the SGE-submitted wrapper.
#   make CAPTURE_NPY=$SHARED_DIR/lora-mimo-captures/captures/<file>.npy \
#        CAPTURE_SF=7 CAPTURE_BW=250 CAPTURE_NSAMP=60000
#   make clean

SIM           ?= verilator
TOPLEVEL_LANG  = verilog
TOPLEVEL            = tb_trouper_cocotb
COCOTB_TEST_MODULES = test_capture_playback
# 16 bits models 64 KiB and is adequate for short captures.  A full SF12/
# BW125 replay writes beyond that range, so its SGE run requests 21 (2 MiB).
PSRAM_ADDR_BITS ?= 16

DESIGN_ROOT   ?= /foss/designs/lora-mimo
SRC            = $(DESIGN_ROOT)/src
HDL            = $(DESIGN_ROOT)/cocotb/hdl
TESTS          = $(DESIGN_ROOT)/cocotb/tests

VERILOG_SOURCES = \
    $(SRC)/top/trouper_top.v             \
    $(SRC)/decimator/sd_decimator_poly.v \
    $(SRC)/frontend/dc_removal.v         \
    $(SRC)/frontend/sc_detector.v        \
    $(SRC)/combiner/training_acc.v       \
    $(SRC)/combiner/mrc_combiner.v       \
    $(SRC)/control/packet_ctrl_fsm.v     \
    $(SRC)/control/psram_buf_ctrl.v      \
    $(SRC)/control/spi_slave.v           \
    $(SRC)/control/reg_bank.v            \
    $(SRC)/remod/sd_remod.v              \
    $(HDL)/psram_model.v                 \
    $(HDL)/tb_trouper_cocotb.v

# Verilator needs --timing for the SPI helpers' Timer()-based bit-bang, plus
# access to dut.u_dut.u_sc.* hierarchical signals the test reads on failure.
EXTRA_ARGS += --timing -Wno-fatal --trace --public-flat-rw
COMPILE_ARGS += -GPSRAM_ADDR_BITS=$(PSRAM_ADDR_BITS)

# cocotb finds the Python test + iq_capture helper via PYTHONPATH
PYTHONPATH    := $(DESIGN_ROOT):$(TESTS)

# Pass capture configuration through to the test (export so cocotb sees them)
export CAPTURE_NPY
export CAPTURE_SF
export CAPTURE_BW
# CAPTURE_STAGE/CAPTURE_GAINS work when passed as `make VAR=...` (GNU make
# exports command-line variables to recipe shells) but NOT when set as plain
# shell env, which is a silent-skip trap: an unexported CAPTURE_GAINS leaves
# gains flat and test_capture_playback quietly skips its ZDIAG rank assertion.
# List them explicitly so both invocation styles behave the same.
export CAPTURE_STAGE
export CAPTURE_GAINS
export CAPTURE_START
export CAPTURE_NSAMP
export CAPTURE_SNRDB
export CAPTURE_SEED
export CAPTURE_CHAN
export CAPTURE_NTAPS
export CAPTURE_DSPREAD
export CAPTURE_PHASES

COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
