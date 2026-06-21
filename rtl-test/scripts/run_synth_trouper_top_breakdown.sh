#!/bin/bash
# Hierarchical synthesis-only area breakdown for the current trouper_top RTL.
# Runs inside the chipathon26 container or an equivalent environment with yosys
# and the GF180 FD liberty available.
set -euo pipefail

RTL_ROOT=${RTL_ROOT:-/foss/designs/lora-mimo}
RT=$RTL_ROOT/rtl-test
OUT=${OUT:-$RT/syn_mimo_per_module/out_trouper_top_current_fd}
CORE_LIB=${CORE_LIB:-/foss/pdks/gf180mcuD/libs.ref/gf180mcu_fd_sc_mcu7t5v0/lib/gf180mcu_fd_sc_mcu7t5v0__tt_025C_3v30.lib}
TOP=${TOP:-trouper_top}

mkdir -p "$OUT"
LOG=$OUT/run.log
STAT=$OUT/stat_hier.txt
YS=$OUT/synth.ys

exec > >(tee "$LOG") 2>&1
echo "=== ${TOP} hierarchical synth $(date --iso-8601=seconds) on $(hostname) ==="
echo "RTL_ROOT=$RTL_ROOT"
echo "OUT=$OUT"
echo "CORE_LIB=$CORE_LIB"

cat > "$YS" <<EOF
read_verilog $RT/rtl/dc_removal.v
read_verilog $RT/rtl/trouper_top.v
read_verilog $RT/rtl/mrc_combiner.v
read_verilog $RT/rtl/packet_ctrl_fsm.v
read_verilog $RT/rtl/psram_buf_ctrl.v
read_verilog $RT/rtl/reg_bank.v
read_verilog $RT/rtl/sc_detector.v
read_verilog $RT/rtl/sd_decimator_cic_tdm8.v
read_verilog $RT/rtl/sd_remod.v
read_verilog $RT/rtl/spi_slave.v
read_verilog $RT/rtl/training_acc.v
hierarchy -top $TOP
synth -top $TOP
dfflibmap -liberty $CORE_LIB
abc -liberty $CORE_LIB -D 31250
setundef -zero
opt_clean -purge
tee -o $STAT stat -liberty $CORE_LIB -top $TOP
EOF

echo "--- running yosys ---"
yosys -s "$YS"

echo
echo "=== top chip-area lines ==="
grep "Chip area for module" "$STAT" | sort -t: -k2 -rn | head -20 || true

echo
echo "=== done ==="
