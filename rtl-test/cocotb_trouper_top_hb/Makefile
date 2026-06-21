# cocotb_trouper_top_hb/Makefile
# Runs SF7-SF12 × BW250/125 integration tests for trouper_top_hb (HB decimator).
#
# Usage:
#   make                                          # run all 12 tests
#   make TESTCASE=test_sf7_bw250,test_sf7_bw125  # subset
#   make clean                                    # remove build artefacts
#
# Run inside the chipathon26 Docker container where the design root is
# mounted at /foss/designs/lora-mimo.

SIM           ?= icarus
TOPLEVEL_LANG  = verilog
TOPLEVEL            = tb_trouper_hb_cocotb
COCOTB_TEST_MODULES = test_trouper_top_hb

DESIGN_ROOT   ?= /foss/designs/lora-mimo
RTL            = $(DESIGN_ROOT)/rtl-test/rtl
EXP            = $(DESIGN_ROOT)/rtl-test/rtl/experiment_hb
FPGA           = $(DESIGN_ROOT)/fpga-emul/rtl
TB             = $(DESIGN_ROOT)/rtl-test/tb

VERILOG_SOURCES = \
    $(EXP)/trouper_top_hb.v           \
    $(RTL)/sd_decimator_hb_tdm.v      \
    $(EXP)/dc_removal_hb.v            \
    $(EXP)/sc_detector_hb.v           \
    $(EXP)/training_acc_hb.v          \
    $(EXP)/packet_ctrl_fsm_hb.v       \
    $(EXP)/psram_buf_ctrl_hb.v        \
    $(RTL)/mrc_combiner.v             \
    $(EXP)/sd_remod_hb.v              \
    $(RTL)/spi_slave.v                \
    $(EXP)/reg_bank_hb.v              \
    $(FPGA)/psram_model.v             \
    $(TB)/tb_trouper_hb_cocotb.v

PYTHONPATH    := $(TB)

COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
