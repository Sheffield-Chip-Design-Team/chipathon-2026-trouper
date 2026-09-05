# cocotb/w_valid_split/Makefile
# Open Risk #62 -- an IDLE W_COMMIT splits the packet_ctrl_fsm internal W_valid
# from the top-level W_valid reconstruction.
#
# packet_ctrl_fsm.v accepts a commit in any state and keeps its own sticky
# internal W_valid, cleared only at the ST_PAYLOAD_ACTIVE packet timeout
# (line 122-184, 292). trouper_top.v separately rebuilds W_valid from the
# one-cycle W_valid_set pulse and clears that copy whenever packet_active==0
# (line 756-760). A commit consumed in IDLE therefore leaves the FSM copy high
# and the top copy low: on the next packet the FSM believes weights are valid
# (suppresses W_MISSED_PACKET, ST_W_PENDING `if (!W_valid)` is false) while the
# combiner sees W_valid==0 and stays in bypass, and reg_bank's live-weight
# write-lock (w_valid_rb == the top copy) is also open.
#
# Top-level bench, TOPLEVEL = tb_trouper_cocotb. EXPECTED TO FAIL until #62 is
# fixed (one authoritative W_valid).
#
# Usage (inside the chipathon26 container):
#   make
#   make clean

SIM           ?= verilator
TOPLEVEL_LANG  = verilog
TOPLEVEL            = tb_trouper_cocotb
COCOTB_TEST_MODULES = test_w_valid_split

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
    $(SRC)/debug/bringup_src.v           \
    $(SRC)/control/packet_ctrl_fsm.v     \
    $(SRC)/control/psram_buf_ctrl.v      \
    $(SRC)/control/spi_slave.v           \
    $(SRC)/control/reg_bank.v            \
    $(SRC)/remod/sd_remod.v              \
    $(SRC)/remod/sd_remod_multiplierless.v \
    $(HDL)/psram_model.v                 \
    $(HDL)/tb_trouper_cocotb.v

EXTRA_ARGS += --timing -Wno-fatal --public-flat-rw

PYTHONPATH    := $(TESTS)

COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
