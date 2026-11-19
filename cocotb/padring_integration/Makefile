# cocotb/padring_integration/Makefile
# Drives trouper_top THROUGH the real A40 padring (A40_ACV_padring.v) and the
# foundry gf180mcu_fd_io cell models, at the physical pad nets.  Smoke bring-up
# + one full end-to-end packet (test_padring_integration.py).
#
# icarus only: the gf180 IO primitives do not elaborate under Verilator.  The
# IO model is supplied by the pinned chipathon26 PDK and is intentionally not
# copied into this repo (same path as cocotb/io_cell_controls, cocotb/psram_ops).
#
# Usage (inside the chipathon26 container):
#   make                       # all testcases
#   make TESTCASE=test_padring_reset_and_id
#   make clean

SIM            = icarus
TOPLEVEL_LANG  = verilog
TOPLEVEL            = tb_trouper_padring
COCOTB_TEST_MODULES = test_padring_integration

DESIGN_ROOT   ?= /foss/designs/lora-mimo
SRC            = $(DESIGN_ROOT)/src
HDL            = $(DESIGN_ROOT)/cocotb/hdl
TESTS          = $(DESIGN_ROOT)/cocotb/tests
A40            = $(DESIGN_ROOT)/rtl-test/ol_trouper_top/a40_integrator
IO_MODEL      ?= /foss/pdks/ciel/gf180mcu/versions/7b70722e33c03fcb5dabcf4d479fb0822d9251c9/gf180mcuD/libs.ref/gf180mcu_fd_io/verilog/gf180mcu_fd_io.v

# A40_ACV_padring.v names every pad-cell instance identically to its slot net,
# which yosys accepts but iverilog rejects.  Rewrite it (instance names only)
# into the writable build dir -- /foss/designs is read-only under SGE.
SIM_BUILD    ?= sim_build
PADRING_SIM   = $(SIM_BUILD)/A40_ACV_padring_sim.v

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
    $(IO_MODEL)                          \
    $(PADRING_SIM)                       \
    $(HDL)/tb_trouper_padring.v

COMPILE_ARGS += -g2012

PYTHONPATH := $(TESTS)
COCOTB_RESULTS_FILE = results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim

# After the include so it does not become the default goal.  Listed in
# VERILOG_SOURCES above, so the cocotb compile target depends on it.
$(PADRING_SIM): $(A40)/A40_ACV_padring.v $(HDL)/mk_padring_sim.py
	@mkdir -p $(dir $@)
	python3 $(HDL)/mk_padring_sim.py $< $@
