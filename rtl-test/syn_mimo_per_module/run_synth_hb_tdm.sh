#!/bin/bash
set -euo pipefail
export PDK_ROOT=/foss/pdks
export PDK=gf180mcuD
export STD_CELL_LIBRARY=gf180mcu_fd_sc_mcu7t5v0
ROOT=/foss/designs/lora-mimo
OUT=$ROOT/rtl-test/syn_mimo_per_module/out_synth_hb_tdm
LIB=$PDK_ROOT/$PDK/libs.ref/$STD_CELL_LIBRARY/lib/${STD_CELL_LIBRARY}__tt_025C_3v30.lib
mkdir -p "$OUT"
cat > "$OUT/run.ys" <<YEOF
read_verilog -sv $ROOT/rtl-test/rtl/sd_decimator_hb_tdm.v
hierarchy -check -top sd_decimator_hb_tdm
synth -top sd_decimator_hb_tdm
dfflibmap -liberty $LIB
abc -liberty $LIB
setundef -zero
opt_clean -purge
check
tee -o $OUT/stat_hb_tdm.txt stat -liberty $LIB -top sd_decimator_hb_tdm
write_verilog -noattr $OUT/sd_decimator_hb_tdm_synth.v
YEOF
echo "=== sd_decimator_hb_tdm FD synth $(date --iso-8601=seconds) on $(hostname) ===" | tee "$OUT/run.log"
yosys -s "$OUT/run.ys" 2>&1 | tee -a "$OUT/run.log"
echo "=== Area summary ===" | tee -a "$OUT/run.log"
grep -E "Number of cells|Chip area" "$OUT/stat_hb_tdm.txt" | tee -a "$OUT/run.log"
echo "=== DONE ===" | tee -a "$OUT/run.log"
