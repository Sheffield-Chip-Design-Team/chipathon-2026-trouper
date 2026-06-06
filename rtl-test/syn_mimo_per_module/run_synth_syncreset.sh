#!/bin/bash
# Variant of run_synth_hier.sh that converts async-reset flops to sync-reset
# via yosys's `async2sync` pass, then re-runs the per-module area report.
# Same library, same RTL — only the reset flop choice changes. Goal: quantify
# the saving from replacing dffrnq/dfsrtp_2 (async reset, larger) with the
# sync-reset variant on the heavy DSP banks (sd_decimator x4 and friends).
set -euo pipefail
RTL=/foss/designs/lora-mimo
OUT=/foss/designs/lora-mimo/rtl-test/syn_mimo_per_module/out_syncreset
CORE_LIB=${RTL}/ip/gf180mcu_as_sc_mcu7t3v3/pdk/libs.ref/gf180mcu_as_sc_mcu7t3v3/lib/gf180mcu_as_sc_mcu7t3v3__tt_025C_3v30.lib
mkdir -p "$OUT"
LOG=$OUT/yosys.log
echo "=== mimo_rx_top per-module synth [SYNC-RESET] $(date --iso-8601=seconds) on $(hostname) ===" | tee "$LOG"

YS=$OUT/synth.ys
cat > "$YS" <<EOF
read_verilog ${RTL}/ip/picorv32/picorv32.v
read_verilog ${RTL}/rtl-test/ahb_lite_bus.v
read_verilog ${RTL}/rtl-test/dc_removal.v
read_verilog ${RTL}/rtl-test/energy_meas_coarse.v
read_verilog ${RTL}/rtl-test/frontend_buf_ctrl.v
read_verilog ${RTL}/rtl-test/irq_ctrl.v
read_verilog ${RTL}/rtl-test/mimo_rx_top.v
read_verilog ${RTL}/rtl-test/mrc_combiner.v
read_verilog ${RTL}/rtl-test/packet_ctrl_fsm.v
read_verilog ${RTL}/rtl-test/picorv32_wrap.v
read_verilog ${RTL}/rtl-test/reg_bank.v
read_verilog ${RTL}/rtl-test/sc_detector.v
read_verilog ${RTL}/rtl-test/sd_decimator.v
read_verilog ${RTL}/rtl-test/sd_remod.v
read_verilog ${RTL}/rtl-test/spi_master.v
read_verilog ${RTL}/rtl-test/spi_slave.v
read_verilog ${RTL}/rtl-test/sram512x8_bb.v
read_verilog ${RTL}/rtl-test/sram1024x8_bb.v
read_verilog ${RTL}/rtl-test/training_acc.v
read_verilog ${RTL}/rtl-test/weight_gen.v
hierarchy -top mimo_rx_top
# Full synth (ends with generic-FF + generic-mux/shift techmap), then convert
# async-reset to sync-reset so dfflibmap picks the smaller sync-reset liberty
# cell instead of the async-reset variant.
synth -top mimo_rx_top
async2sync
opt_clean
dfflibmap -liberty ${CORE_LIB}
abc -liberty ${CORE_LIB}
setundef -zero
opt_clean -purge
tee -o ${OUT}/stat_hier.txt stat -liberty ${CORE_LIB} -top mimo_rx_top
EOF

yosys -s "$YS" 2>&1 | tee -a "$LOG"
echo "=== DONE ===" | tee -a "$LOG"
