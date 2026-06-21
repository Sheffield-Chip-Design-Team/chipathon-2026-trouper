#!/bin/bash
# HB area-reduction candidate #3 (14-bit CIC): prove bit-exact vs the 16-bit
# sd_decimator_hb_tdm reference, then FD area-synth and compare.
set -euo pipefail
export PDK_ROOT=/foss/pdks
export PDK=gf180mcuD
export STD_CELL_LIBRARY=gf180mcu_fd_sc_mcu7t5v0
ROOT=/foss/designs/lora-mimo
RT=$ROOT/rtl-test
OUT=$RT/syn_mimo_per_module/out_synth_hb_poly
LIB=$PDK_ROOT/$PDK/libs.ref/$STD_CELL_LIBRARY/lib/${STD_CELL_LIBRARY}__tt_025C_3v30.lib
mkdir -p "$OUT"
LOG=$OUT/run.log
echo "=== hb_poly verify+synth $(date --iso-8601=seconds) on $(hostname) ===" | tee "$LOG"

# 1) Bit-exact equivalence simulation (icarus)
echo "--- equivalence sim ---" | tee -a "$LOG"
iverilog -g2012 -o "$OUT/equiv.vvp" \
    "$RT/tb/tb_hb_poly_equiv.v" \
    "$RT/rtl/sd_decimator_hb_tdm.v" \
    "$RT/rtl/sd_decimator_hb_poly.v" 2>&1 | tee -a "$LOG"
vvp "$OUT/equiv.vvp" 2>&1 | tee -a "$LOG"
if ! grep -q "tb_hb_poly_equiv: PASS" "$LOG"; then
    echo "EQUIVALENCE FAILED — aborting synth" | tee -a "$LOG"; exit 2
fi

# 2) FD area synthesis of the trimmed variant
echo "--- yosys area synth ---" | tee -a "$LOG"
cat > "$OUT/run.ys" <<YEOF
read_verilog -sv $RT/rtl/sd_decimator_hb_poly.v
hierarchy -check -top sd_decimator_hb_poly
synth -top sd_decimator_hb_poly
dfflibmap -liberty $LIB
abc -liberty $LIB
setundef -zero
opt_clean -purge
check
tee -o $OUT/stat_hb_poly.txt stat -liberty $LIB -top sd_decimator_hb_poly
YEOF
yosys -s "$OUT/run.ys" 2>&1 | tee -a "$LOG"

echo "=== Area summary ===" | tee -a "$LOG"
echo "[poly variant]" | tee -a "$LOG"
grep -E "Number of cells|Chip area" "$OUT/stat_hb_poly.txt" | tee -a "$LOG"
BASE="$RT/syn_mimo_per_module/out_synth_hb_tdm/stat_hb_tdm.txt"
if [ -f "$BASE" ]; then
    echo "[hb_tdm baseline (SGE 2082)]" | tee -a "$LOG"
    grep -E "Number of cells|Chip area" "$BASE" | tee -a "$LOG"
fi
echo "=== DONE ===" | tee -a "$LOG"
