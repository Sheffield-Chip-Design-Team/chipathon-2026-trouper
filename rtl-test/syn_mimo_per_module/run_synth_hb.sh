#!/bin/bash
# Standalone area synthesis for the CIC-3 R=16 + two-half-band prototype.
# Uses the current tapeout-plan FD cells for comparison with decimator baselines.
set -euo pipefail

export PDK_ROOT=/foss/pdks
export PDK=gf180mcuD
export STD_CELL_LIBRARY=gf180mcu_fd_sc_mcu7t5v0

RTL=/foss/designs/lora-mimo
RT=$RTL/rtl-test
OUT=$RT/syn_mimo_per_module/out_synth_hb
LIB=$PDK_ROOT/$PDK/libs.ref/$STD_CELL_LIBRARY/lib/${STD_CELL_LIBRARY}__tt_025C_3v30.lib
LOG=$OUT/run.log
YS=$OUT/run.ys

mkdir -p "$OUT"
echo "=== sd_decimator_hb FD synth $(date --iso-8601=seconds) on $(hostname) ===" | tee "$LOG"

cat > "$YS" <<YEOF
read_verilog -sv $RT/rtl/sd_decimator_hb.v
hierarchy -check -top sd_decimator_hb
synth -top sd_decimator_hb
dfflibmap -liberty $LIB
abc -liberty $LIB
setundef -zero
opt_clean -purge
check
tee -o $OUT/stat_hb.txt stat -liberty $LIB -top sd_decimator_hb
write_verilog -noattr $OUT/sd_decimator_hb_synth.v
YEOF

yosys -s "$YS" 2>&1 | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "=== Area summary ===" | tee -a "$LOG"
grep -E "Number of cells|Chip area" "$OUT/stat_hb.txt" | tee -a "$LOG"

for BASE in \
    "$RT/syn_mimo_per_module/out_decim_compare/stat_cic_tdm8.txt" \
    "$RT/syn_mimo_per_module/out_decim_compare/stat_cic_only.txt"; do
    if [ -f "$BASE" ]; then
        echo "--- $(basename "$BASE") ---" | tee -a "$LOG"
        grep -E "Number of cells|Chip area" "$BASE" | tee -a "$LOG"
    fi
done

echo "=== DONE ===" | tee -a "$LOG"
