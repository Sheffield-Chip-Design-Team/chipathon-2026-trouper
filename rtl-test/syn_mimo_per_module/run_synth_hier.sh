#!/bin/bash
# Hierarchical (no-flatten) yosys synth of mimo_rx_top -> per-module gate area.
# Goal: rank the largest submodules to pick time-multiplex targets.
# Uses 3.3V cells (as_sc_mcu7t3v3) so numbers match the 3.3V target flow.
set -euo pipefail
RTL=/foss/designs/lora-mimo
OUT=/foss/designs/lora-mimo/rtl-test/syn_mimo_per_module/out
CORE_LIB=${RTL}/ip/gf180mcu_as_sc_mcu7t3v3/pdk/libs.ref/gf180mcu_as_sc_mcu7t3v3/lib/gf180mcu_as_sc_mcu7t3v3__tt_025C_3v30.lib
mkdir -p "$OUT"
LOG=$OUT/yosys.log
exec > >(tee "$LOG") 2>&1
echo "=== mimo_rx_top per-module synth $(date --iso-8601=seconds) on $(hostname) ==="

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
read_verilog ${RTL}/rtl-test/noise_est.v
read_verilog ${RTL}/rtl-test/packet_ctrl_fsm.v
read_verilog ${RTL}/rtl-test/picorv32_wrap.v
read_verilog ${RTL}/rtl-test/psram_buf_ctrl.v
read_verilog ${RTL}/rtl-test/reg_bank.v
read_verilog ${RTL}/rtl-test/sc_detector.v
read_verilog ${RTL}/rtl-test/sd_decimator_cic_only.v
read_verilog ${RTL}/rtl-test/sd_remod.v
read_verilog ${RTL}/rtl-test/spi_master.v
read_verilog ${RTL}/rtl-test/spi_slave.v
read_verilog ${RTL}/rtl-test/sram512x8_bb.v
read_verilog ${RTL}/rtl-test/sram1024x8_bb.v
read_verilog ${RTL}/rtl-test/training_acc.v
hierarchy -top mimo_rx_top
# synth without -flatten preserves module hierarchy through tech mapping so
# stat -liberty reports area per submodule. SRAM macros are blackboxes (0 gate area).
synth -top mimo_rx_top
dfflibmap -liberty ${CORE_LIB}
abc -liberty ${CORE_LIB}
setundef -zero
opt_clean -purge
tee -o ${OUT}/stat_hier.txt stat -liberty ${CORE_LIB} -top mimo_rx_top
EOF

yosys -q -s "$YS"
echo "=== DONE ==="
