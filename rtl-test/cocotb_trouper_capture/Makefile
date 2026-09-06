# cocotb_trouper_capture/Makefile
# Drive trouper_top with a MEASURED IQ capture (test_capture_playback.py).
# Runs on Verilator (not Icarus) — millions of 32 MS/s clocks bit-by-bit are
# impractical under Icarus. Clip the capture with CAPTURE_START/CAPTURE_NSAMP.
#
# Usage (inside the chipathon26 container):
#   make CAPTURE_NPY=/foss/designs/lora-mimo/lora-capture/captures/<file>.npy \
#        CAPTURE_SF=7 CAPTURE_BW=250 CAPTURE_NSAMP=60000
#   make clean

SIM           ?= verilator
TOPLEVEL_LANG  = verilog
TOPLEVEL            = tb_trouper_cocotb
COCOTB_TEST_MODULES = test_capture_playback

DESIGN_ROOT   ?= /foss/designs/lora-mimo
RTL            = $(DESIGN_ROOT)/rtl-test/rtl
FPGA           = $(DESIGN_ROOT)/fpga-emul/rtl
TB             = $(DESIGN_ROOT)/rtl-test/tb

VERILOG_SOURCES = \
    $(RTL)/trouper_top.v          \
    $(RTL)/sd_decimator_poly.v    \
    $(RTL)/dc_removal.v           \
    $(RTL)/sc_detector.v          \
    $(RTL)/training_acc.v         \
    $(RTL)/packet_ctrl_fsm.v      \
    $(RTL)/psram_buf_ctrl.v       \
    $(RTL)/mrc_combiner.v         \
    $(RTL)/sd_remod.v             \
    $(RTL)/sd_remod_multiplierless.v \
    $(RTL)/spi_slave.v            \
    $(RTL)/reg_bank.v             \
    $(FPGA)/psram_model.v         \
    $(TB)/tb_trouper_cocotb.v

# Verilator needs --timing for the SPI helpers' Timer()-based bit-bang, plus
# access to dut.u_dut.u_sc.* hierarchical signals the test reads on failure.
EXTRA_ARGS += --timing -Wno-fatal --trace --public-flat-rw

# cocotb finds the Python test + iq_capture helper via PYTHONPATH
PYTHONPATH    := $(TB)

# Pass capture configuration through to the test (export so cocotb sees them)
export CAPTURE_NPY
export CAPTURE_SF
export CAPTURE_BW
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
