#!/bin/bash
# Synthesise sd_decimator_shiftadd standalone on gf180mcu_as_sc_mcu7t3v3.
# Reports area and cell counts; compare against combchain baseline.
set -euo pipefail
RTL=/foss/designs/lora-mimo
OUT=$RTL/rtl-test/syn_mimo_per_module/out_synth_shiftadd
mkdir -p "$OUT"
LOG=$OUT/run.log
YS=$OUT/run.ys
LIB=$RTL/ip/gf180mcu_as_sc_mcu7t3v3/pdk/libs.ref/gf180mcu_as_sc_mcu7t3v3/lib/gf180mcu_as_sc_mcu7t3v3__tt_025C_3v30.lib
echo "=== sd_decimator_shiftadd synth $(date --iso-8601=seconds) on $(hostname) ===" | tee "$LOG"

cat > "$YS" <<YEOF
read_verilog $RTL/rtl-test/sd_decimator_shiftadd.v
synth -top sd_decimator_shiftadd
dfflibmap -liberty $LIB
abc -liberty $LIB
setundef -zero
opt_clean -purge
tee -o $OUT/stat_shiftadd.txt stat -liberty $LIB -top sd_decimator_shiftadd
write_verilog $OUT/sd_decimator_shiftadd_synth.v
YEOF

yosys -s "$YS" 2>&1 | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "=== Area summary ===" | tee -a "$LOG"
grep -E "Chip area|Number of cells|abc" "$LOG" | tail -20 | tee -a "$LOG"

# Compare against combchain baseline if it exists
BASELINE_STAT=$RTL/rtl-test/syn_mimo_per_module/out_combchain/stat_combchain.txt
echo "" | tee -a "$LOG"
echo "=== Area comparison ===" | tee -a "$LOG"
if [ -f "$BASELINE_STAT" ]; then
    echo "  combchain:" | tee -a "$LOG"
    grep "Chip area for module" "$BASELINE_STAT" | tee -a "$LOG"
fi
echo "  shiftadd:" | tee -a "$LOG"
grep "Chip area for module" "$OUT/stat_shiftadd.txt" | tee -a "$LOG"

echo "=== DONE ===" | tee -a "$LOG"
