#!/bin/bash
# Standalone synth of sd_decimator vs sd_decimator_combchain on as_sc 3.3V.
# Goal: measure area delta from collapsing the 3-stage registered CIC comb
# pipeline into a combinational chain (saves 6x 26-bit register banks per
# instance; combs fire only on cic_strobe so the slow path has slack).
set -euo pipefail
RTL=/foss/designs/lora-mimo
OUT=/foss/designs/lora-mimo/rtl-test/syn_mimo_per_module/out_combchain
CORE_LIB=${RTL}/ip/gf180mcu_as_sc_mcu7t3v3/pdk/libs.ref/gf180mcu_as_sc_mcu7t3v3/lib/gf180mcu_as_sc_mcu7t3v3__tt_025C_3v30.lib
mkdir -p "$OUT"
LOG=$OUT/yosys.log
echo "=== sd_decimator A/B (baseline vs comb-chain) $(date --iso-8601=seconds) on $(hostname) ===" | tee "$LOG"

for VARIANT in baseline combchain; do
    if [ "$VARIANT" = "baseline" ]; then
        SRC=${RTL}/rtl-test/sd_decimator.v
        TOP=sd_decimator
    else
        SRC=${RTL}/rtl-test/sd_decimator_combchain.v
        TOP=sd_decimator_combchain
    fi
    YS=$OUT/synth_${VARIANT}.ys
    STAT=$OUT/stat_${VARIANT}.txt
    cat > "$YS" <<EOF
read_verilog ${SRC}
hierarchy -top ${TOP}
synth -top ${TOP}
dfflibmap -liberty ${CORE_LIB}
abc -liberty ${CORE_LIB}
setundef -zero
opt_clean -purge
tee -o ${STAT} stat -liberty ${CORE_LIB} -top ${TOP}
EOF
    echo "--- synth ${VARIANT} ---" | tee -a "$LOG"
    yosys -s "$YS" 2>&1 | tee -a "$LOG" | tail -3
done

echo "=== summary ===" | tee -a "$LOG"
grep "Chip area for module" "$OUT"/stat_*.txt | tee -a "$LOG"
echo "=== DONE ===" | tee -a "$LOG"
