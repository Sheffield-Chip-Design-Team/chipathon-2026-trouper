#!/bin/bash
# Hierarchical synthesis-only area breakdown for the current trouper_top RTL.
# Runs inside the chipathon26 container or an equivalent environment with yosys
# and the GF180 FD liberty available.
set -euo pipefail

RTL_ROOT=${RTL_ROOT:-/foss/designs/lora-mimo}
# Project-scoped SGE snapshots mount the project directly at /foss/designs;
# local Docker usage mounts it at /foss/designs/lora-mimo.
if [ ! -d "$RTL_ROOT/src" ] && [ -d /foss/designs/src ]; then RTL_ROOT=/foss/designs; fi
RT=$RTL_ROOT/rtl-test
SRC=$RTL_ROOT/src
# Local runs are retained beside the project.  On SGE, RUN_DIR is the unique,
# writable per-job mount at /foss/runs and is persisted by the scheduler.
DEFAULT_OUT=$RT/syn_mimo_per_module/out_trouper_top_current_fd
if [ -n "${JOB_ID:-}" ]; then DEFAULT_OUT=${RUN_DIR:-/foss/runs}; fi
OUT=${OUT:-$DEFAULT_OUT}
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
read_verilog $SRC/frontend/dc_removal.v
read_verilog $SRC/top/trouper_top.v
read_verilog $SRC/combiner/mrc_combiner.v
read_verilog $SRC/control/packet_ctrl_fsm.v
read_verilog $SRC/control/psram_buf_ctrl.v
read_verilog $SRC/control/reg_bank.v
read_verilog $SRC/frontend/sc_detector.v
read_verilog $SRC/decimator/sd_decimator_poly.v
read_verilog $SRC/remod/sd_remod.v
read_verilog $SRC/control/spi_slave.v
read_verilog $SRC/combiner/training_acc.v
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
