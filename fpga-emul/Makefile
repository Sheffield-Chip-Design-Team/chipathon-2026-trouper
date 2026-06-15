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
ASIC_SRCS   = $(ASIC_RTL)/sd_decimator_cic_tdm8.v \
              $(ASIC_RTL)/dc_removal.v          \
              $(ASIC_RTL)/frontend_buf_ctrl.v   \
              $(ASIC_RTL)/sc_detector.v         \
              $(ASIC_RTL)/training_acc.v        \
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
        sim_inject sim_decim_eth sim_all clean vivado_project vivado_synth \
        test_fw run_test_fw eth_fw run_eth_fw

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
VIVADO = /home/timothyjabez/tools/Xilinx/2025.2/Vivado/bin/vivado

vivado_project:
	$(VIVADO) -mode batch -source vivado/create_project.tcl 2>&1 | tee vivado_create.log

vivado_synth:
	$(VIVADO) -mode batch -source vivado/run_synth.tcl 2>&1 | tee vivado_synth.log

# ============================================================================
# Bare-metal MicroBlaze test firmware (sw/test_fw.c)
# Built with mb-gcc + crt0.S + lscript.ld — no Vitis BSP / -lxil dependency.
# Produces a known-good ELF for `xsdb vivado/run_test_fw.tcl`.
# ============================================================================
MB_BIN   = /home/timothyjabez/tools/Xilinx/2025.2/Vitis/gnu/microblaze/lin/bin
MB_GCC   = $(MB_BIN)/mb-gcc
XSDB     = /home/timothyjabez/tools/Xilinx/2025.2/Vivado/bin/xsdb
MB_FLAGS = -mlittle-endian -O2 -G0 -nostdlib -nostartfiles -ffreestanding
SW       = sw

test_fw: $(SW)/test_fw.elf

$(SW)/test_fw.elf: $(SW)/crt0.S $(SW)/test_fw.c $(SW)/lscript.ld
	$(MB_GCC) $(MB_FLAGS) -Wl,-T,$(SW)/lscript.ld -Wl,-Map,$(SW)/test_fw.map \
	    -o $@ $(SW)/crt0.S $(SW)/test_fw.c \
	    `$(MB_GCC) -mlittle-endian -print-libgcc-file-name`

# Program bitstream + download/run the bare-metal firmware over JTAG (xsdb)
run_test_fw: $(SW)/test_fw.elf
	$(XSDB) vivado/run_test_fw.tcl

# ============================================================================
# Full Ethernet/SPI firmware (sw/main.c) — Vitis BSP build from the XSA.
# Vitis 2025.2 xsct needs an X display, so the BSP generation runs under Xvfb.
# We then link main.c directly against libxil to avoid the Vitis app-build's
# missing -L for the BSP lib dir.
# ============================================================================
XSCT     = /home/timothyjabez/tools/Xilinx/2025.2/Vitis/bin/xsct
BSP_DIR  = $(SW)/vitis_ws/arty_dsp_emul/export/arty_dsp_emul/sw/arty_dsp_emul/standalone_domain
ETH_LD   = $(SW)/vitis_ws/lora_mimo_fw/src/lscript.ld
ETH_FLAGS = -Wall -O2 -g -mlittle-endian -mcpu=v11.0 -mxl-soft-mul -Wl,--no-relax \
            -ffunction-sections -fdata-sections

eth_fw: $(SW)/lora_mimo_fw.elf

# BSP (libxil.a + headers) generated from the XSA by xsct under Xvfb.
$(BSP_DIR)/bsplib/lib/libxil.a: $(SW)/arty_dsp_emul.xsa $(SW)/build_fw.tcl
	cd $(SW) && xvfb-run -a $(XSCT) build_fw.tcl

$(SW)/lora_mimo_fw.elf: $(SW)/main.c $(BSP_DIR)/bsplib/lib/libxil.a
	$(MB_GCC) $(ETH_FLAGS) -I$(BSP_DIR)/bspinclude/include \
	    -Wl,-T -Wl,$(ETH_LD) -Wl,--gc-sections -L$(BSP_DIR)/bsplib/lib \
	    -o $@ $(SW)/main.c -Wl,--start-group,-lxil,-lgcc,-lc,--end-group

# Program bitstream + download/run the full Ethernet firmware over JTAG (xsdb)
run_eth_fw: $(SW)/lora_mimo_fw.elf
	$(XSDB) vivado/run_eth_fw.tcl

# ============================================================================
# Clean
# ============================================================================
clean:
	rm -rf obj_dir_inject obj_dir_decim_eth *.vcd
	rm -f $(SW)/test_fw.elf $(SW)/test_fw.map
	rm -f $(SW)/lora_mimo_fw.elf
