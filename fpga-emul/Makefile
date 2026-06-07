# fpga-emul/Makefile
# Simulation (Verilator via SGE) and Vivado build targets for the DSP chain FPGA emulation.
#
# SGE targets (primary): submit Verilator jobs to the homelab SGE cluster.
#   make sge_sim_inject      — INJECT mode: preamble → sc_lock + weights
#   make sge_sim_decim_eth   — DECIM_ETH mode: 1-bit bitstream → decimated output
#   make sge_sim_all         — both sims
#
# Local Verilator targets (for use inside the chipathon26 container directly):
#   make sim_inject / sim_decim_eth / sim_all
#
# After submitting an SGE job, poll completion with:
#   curl -s http://nas.home:4783/api/jobs/<ID>
# Read output from:
#   /srv/eda/logs/timothyn/job-<ID>.o

HLAB_SGE_URL  = http://nas.home:4783
NFS_DESIGN    = /srv/eda/designs/timothyjabez/lora-mimo

VERILATOR   = verilator
VFLAGS      = --binary --timing -Wall --Wno-UNUSED --Wno-DECLFILENAME \
              --Wno-WIDTHTRUNC --Wno-WIDTHEXPAND --Wno-BLKSEQ \
              --Wno-SYNCASYNCNET --Wno-PINCONNECTEMPTY \
              --Wno-UNOPTFLAT -sv

RTL         = rtl
ASIC_RTL    = ../rtl-test/rtl

# All ASIC RTL modules needed by fpga_dsp_wrap
ASIC_SRCS   = $(ASIC_RTL)/sd_decimator.v       \
              $(ASIC_RTL)/dc_removal.v          \
              $(ASIC_RTL)/frontend_buf_ctrl.v   \
              $(ASIC_RTL)/noise_est.v           \
              $(ASIC_RTL)/sc_detector.v         \
              $(ASIC_RTL)/training_acc.v        \
              $(ASIC_RTL)/weight_gen.v          \
              $(ASIC_RTL)/packet_ctrl_fsm.v     \
              $(ASIC_RTL)/mrc_combiner.v        \
              $(ASIC_RTL)/sd_remod.v

FPGA_SRCS   = $(RTL)/fpga_sram512x8.v \
              $(RTL)/sync_fifo.v      \
              $(RTL)/fpga_dsp_wrap.v

# ============================================================================
# SGE simulation targets (submit to homelab cluster)
# Scripts in sge/ run inside the chipathon26 container on the NFS-mounted tree.
# ============================================================================

.PHONY: sge_sim_inject sge_sim_decim_eth sge_sim_all \
        sim_inject sim_decim_eth sim_all clean vivado_project vivado_synth

sge_sim_inject:
	HLAB_SGE_URL=$(HLAB_SGE_URL) hqsub \
	    --name fpga-sim-inject \
	    --cpus 4 \
	    --mem 8G \
	    $(NFS_DESIGN)/fpga-emul/sge/sim_inject.sh

sge_sim_decim_eth:
	HLAB_SGE_URL=$(HLAB_SGE_URL) hqsub \
	    --name fpga-sim-decim-eth \
	    --cpus 4 \
	    --mem 8G \
	    $(NFS_DESIGN)/fpga-emul/sge/sim_decim_eth.sh

sge_sim_all: sge_sim_inject sge_sim_decim_eth

# ============================================================================
# Local Verilator targets (run inside chipathon26 container)
# ============================================================================

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
