# cocotb/capture_two_packet/Makefile
# sc_lock re-arm proven on a REAL two-packet capture (Open Risks #2/#3,
# TRPR-SCD-014, TRPR-IRQ-002/006). Three checks: PK1-1 first lock, ARM-1
# de-assert / re-arm, PK2-1 second lock.
#
# The synthetic tb_trouper_two_packet.v (job 3203) builds its own stimulus;
# this is the only real-signal evidence that the receiver is not one-shot.
#
# LONG RUN (~50 min): the window spans two bursts ~4.07 M capture samples
# apart. That gap is the point, not overhead -- dc_removal settles across it,
# psram_buf_ctrl's pointers advance and wrap, and sc_detector's counters
# accumulate. Splicing it out would cut ~34x of runtime and most of the
# state-accumulation coverage with it. Run at milestones / on changes touching
# the packet FSM, PSRAM or the SC counters, not on every commit.
#
# Migrated out of rtl-test/tb (scratch, no runner) 2026-08-16.

SIM           ?= verilator
TOPLEVEL_LANG  = verilog
TOPLEVEL            = tb_trouper_cocotb
COCOTB_TEST_MODULES = test_capture_two_packet

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

EXTRA_ARGS += --timing -Wno-fatal --public-flat-rw

# No --trace: a ~4.15 M-sample run would produce an unusably large VCD.

PYTHONPATH    := $(DESIGN_ROOT):$(TESTS)

export CAPTURE_NPY
export CAPTURE_SF
export CAPTURE_BW
export CAPTURE_START
export CAPTURE_NSAMP
export CAPTURE_SNRDB
export CAPTURE_SEED
export CAPTURE_CHAN
export SHARED_DIR

COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
