# fpga-emul/Makefile
# Simulation (Verilator) and Vivado build targets for the DSP chain FPGA emulation.
#
# Simulation validates the RTL before committing to FPGA synthesis.
# The Verilator targets compile a co-simulation that exercises:
#   - INJECT mode: synthetic LoRa preamble → sc_lock, weights, combined output
#   - DECIM_ETH mode: random 1-bit bitstream → decimated I/Q output check

VERILATOR   = verilator
VFLAGS      = --binary --timing -Wall --Wno-UNUSED --Wno-DECLFILENAME \
              --Wno-WIDTHTRUNC --Wno-WIDTHEXPAND --Wno-BLKSEQ \
              --Wno-SYNCASYNCNET --Wno-PINCONNECTEMPTY \
              --Wno-UNOPTFLAT -sv

RTL         = rtl
ASIC_RTL    = ../rtl-test

# All ASIC RTL modules needed by fpga_dsp_wrap
ASIC_SRCS   = $(ASIC_RTL)/sd_decimator.v       \
              $(ASIC_RTL)/dc_removal.v          \
              $(ASIC_RTL)/frontend_buf_ctrl.v   \
              $(ASIC_RTL)/energy_meas.v         \
              $(ASIC_RTL)/sc_detector.v         \
              $(ASIC_RTL)/training_acc.v        \
              $(ASIC_RTL)/weight_gen.v          \
              $(ASIC_RTL)/packet_ctrl_fsm.v     \
              $(ASIC_RTL)/mrc_combiner.v        \
              $(ASIC_RTL)/sd_remod.v            \
              $(ASIC_RTL)/noise_floor_est.v

FPGA_SRCS   = $(RTL)/fpga_sram512x8.v \
              $(RTL)/sync_fifo.v      \
              $(RTL)/fpga_dsp_wrap.v

# ============================================================================
# Simulation targets
# ============================================================================

.PHONY: sim_inject sim_decim_eth sim_all clean vivado_project

# INJECT mode simulation: synthetic preamble → verify sc_lock + weights
sim_inject: obj_dir_inject/Vtb_fpga_inject
	$<

obj_dir_inject/Vtb_fpga_inject: tb/tb_fpga_inject.v $(FPGA_SRCS) $(ASIC_SRCS)
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir_inject \
	    --top-module tb_fpga_inject $^

# DECIM_ETH mode simulation: 1-bit random stream → decimated output
sim_decim_eth: obj_dir_decim_eth/Vtb_fpga_decim_eth
	$<

obj_dir_decim_eth/Vtb_fpga_decim_eth: tb/tb_fpga_decim_eth.v $(FPGA_SRCS) $(ASIC_SRCS)
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir_decim_eth \
	    --top-module tb_fpga_decim_eth $^

sim_all: sim_inject sim_decim_eth

# ============================================================================
# Vivado project
# ============================================================================
vivado_project:
	vivado -mode batch -source vivado/create_project.tcl

vivado_synth:
	cd vivado_proj && vivado -mode batch -source run_synth.tcl

# ============================================================================
# Clean
# ============================================================================
clean:
	rm -rf obj_dir_inject obj_dir_decim_eth *.vcd
