# rtl-test/Makefile — simulation targets (Verilator primary, iverilog fallback)

VERILATOR = verilator
VFLAGS    = --binary --timing -Wall --Wno-UNUSED --Wno-DECLFILENAME \
            --Wno-WIDTHTRUNC --Wno-WIDTHEXPAND --Wno-BLKSEQ \
            --Wno-SYNCASYNCNET --Wno-PINCONNECTEMPTY -sv

IVERILOG  = iverilog
VVP       = vvp
IFLAGS    = -g2012

# Source files for the DSP chain (no PicoRV32)
# energy_meas_coarse replaces energy_meas; noise_floor_est removed from design.
# sd_decimator_cic_only replaces sd_decimator (old FIR version).
DSP_SRCS  = dc_removal.v frontend_buf_ctrl.v energy_meas_coarse.v \
            sc_detector.v training_acc.v weight_gen.v mrc_combiner.v sd_remod.v
DSP_SRCS_SD = $(DSP_SRCS) sd_decimator_cic_only.v

# -----------------------------------------------------------------------
# DSP chain end-to-end testbench (Verilator)
# -----------------------------------------------------------------------
.PHONY: sim_dsp_chain sim_dsp_chain_iverilog clean

sim_dsp_chain: obj_dir_dsp_chain/Vtb_dsp_chain
	$<

obj_dir_dsp_chain/Vtb_dsp_chain: tb_dsp_chain.v $(DSP_SRCS)
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir_dsp_chain --top-module tb_dsp_chain $^

# iverilog fallback
sim_dsp_chain_iverilog: tb_dsp_chain.vvp
	$(VVP) $<

tb_dsp_chain.vvp: tb_dsp_chain.v $(DSP_SRCS)
	$(IVERILOG) $(IFLAGS) -o $@ $^

# -----------------------------------------------------------------------
# Real-capture DSP chain testbench (Verilator)
# -----------------------------------------------------------------------
.PHONY: sim_dsp_chain_real sim_dsp_chain_loopback_probe \
	sim_dsp_chain_real_probe sim_dsp_chain_real_probe_osr256 \
	sim_remod_decim_const

sim_dsp_chain_real: obj_dir_dsp_chain_real/Vtb_dsp_chain_real
	$<

obj_dir_dsp_chain_real/Vtb_dsp_chain_real: tb_dsp_chain_real.v $(DSP_SRCS)
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir_dsp_chain_real \
	    --top-module tb_dsp_chain_real $^

sim_dsp_chain_loopback_probe: obj_dir_loopback_probe/Vtb_dsp_chain_real
	$<

obj_dir_loopback_probe/Vtb_dsp_chain_real: tb_dsp_chain_loopback_probe.v $(DSP_SRCS_SD)
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir_loopback_probe \
	    --top-module tb_dsp_chain_real $^

sim_dsp_chain_real_probe: obj_dir_dsp_chain_real_probe/Vtb_dsp_chain_real
	$<

obj_dir_dsp_chain_real_probe/Vtb_dsp_chain_real: tb_dsp_chain_real_probe.v $(DSP_SRCS_SD)
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir_dsp_chain_real_probe \
	    --top-module tb_dsp_chain_real $^

sim_dsp_chain_real_probe_osr256: obj_dir_dsp_chain_real_probe_osr256/Vtb_dsp_chain_real
	$<

obj_dir_dsp_chain_real_probe_osr256/Vtb_dsp_chain_real: tb_dsp_chain_real_probe_osr256.v $(DSP_SRCS_SD)
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir_dsp_chain_real_probe_osr256 \
	    --top-module tb_dsp_chain_real $^

sim_remod_decim_const: obj_dir_const/Vtb_remod_decim_const
	$<

obj_dir_const/Vtb_remod_decim_const: tb_remod_decim_const.v sd_remod.v sd_decimator_cic_only.v
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir_const \
	    --top-module tb_remod_decim_const $^

# -----------------------------------------------------------------------
# Energy / noise-floor testbench (existing)
# -----------------------------------------------------------------------
DSP_SRCS2 = energy_meas_coarse.v

.PHONY: sim_dsp

sim_dsp: tb_dsp.vvp
	$(VVP) $<

tb_dsp.vvp: tb_dsp.v $(DSP_SRCS2)
	$(IVERILOG) $(IFLAGS) -o $@ $^

# -----------------------------------------------------------------------
# SQNR testbench (existing)
# -----------------------------------------------------------------------
.PHONY: sim_sqnr

sim_sqnr: tb_sqnr.vvp
	$(VVP) $<

tb_sqnr.vvp: tb_sqnr.v sd_decimator_cic_only.v
	$(IVERILOG) $(IFLAGS) -o $@ $^

# -----------------------------------------------------------------------

clean:
	rm -rf obj_dir_dsp_chain obj_dir_dsp_chain_real obj_dir_loopback_probe \
		obj_dir_dsp_chain_real_probe obj_dir_dsp_chain_real_probe_osr256 \
		obj_dir_const *.vvp *.vcd
