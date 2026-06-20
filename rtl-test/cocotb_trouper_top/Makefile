# cocotb_trouper_top/Makefile
# Runs all SF7-SF12 × BW250/125 integration tests via cocotb + Icarus Verilog.
#
# Usage:
#   make                        # run all 12 tests
#   make TESTCASE=test_sf7_bw250,test_sf7_bw125   # subset
#   make clean                  # remove build artefacts
#
# Inside the chipathon26 Docker container the design root is mounted at
# /foss/designs/lora-mimo. The DESIGN_ROOT variable is set accordingly.

SIM           ?= icarus
TOPLEVEL_LANG  = verilog
TOPLEVEL            = tb_trouper_cocotb
COCOTB_TEST_MODULES = test_trouper_top

DESIGN_ROOT   ?= /foss/designs/lora-mimo
RTL            = $(DESIGN_ROOT)/rtl-test/rtl
FPGA           = $(DESIGN_ROOT)/fpga-emul/rtl
TB             = $(DESIGN_ROOT)/rtl-test/tb

VERILOG_SOURCES = \
    $(RTL)/trouper_top.v          \
    $(RTL)/sd_decimator_cic_tdm8.v \
    $(RTL)/dc_removal.v           \
    $(RTL)/sc_detector.v          \
    $(RTL)/training_acc.v         \
    $(RTL)/packet_ctrl_fsm.v      \
    $(RTL)/psram_buf_ctrl.v       \
    $(RTL)/mrc_combiner.v         \
    $(RTL)/sd_remod.v             \
    $(RTL)/spi_slave.v            \
    $(RTL)/reg_bank.v             \
    $(FPGA)/psram_model.v         \
    $(TB)/tb_trouper_cocotb.v

# cocotb finds the Python test module via PYTHONPATH
PYTHONPATH    := $(TB)

COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
