#!/bin/bash
set -euo pipefail
RTL=/foss/designs/lora-mimo
OUT=$RTL/rtl-test/syn_mimo_per_module/out_synth_sc_wgen
CORE_LIB=${RTL}/ip/gf180mcu_as_sc_mcu7t3v3/pdk/libs.ref/gf180mcu_as_sc_mcu7t3v3/lib/gf180mcu_as_sc_mcu7t3v3__tt_025C_3v30.lib
mkdir -p "$OUT"
LOG=$OUT/yosys.log
echo "=== sc_detector + weight_gen area $(date --iso-8601=seconds) ===" | tee "$LOG"

for VARIANT in sc_detector weight_gen; do
    YS=$OUT/synth_${VARIANT}.ys
    STAT=$OUT/stat_${VARIANT}.txt
    cat > "$YS" << YSEOF
read_verilog ${RTL}/rtl-test/${VARIANT}.v
hierarchy -top ${VARIANT}
synth -top ${VARIANT}
dfflibmap -liberty ${CORE_LIB}
abc -liberty ${CORE_LIB}
setundef -zero
opt_clean -purge
tee -o ${STAT} stat -liberty ${CORE_LIB} -top ${VARIANT}
YSEOF
    echo "--- synth $VARIANT ---" | tee -a "$LOG"
    yosys -s "$YS" 2>&1 | tee -a "$LOG" | tail -3
done

echo "=== summary ===" | tee -a "$LOG"
grep "Chip area for module" "$OUT"/stat_*.txt | tee -a "$LOG"

python3 << 'PYEOF' 2>&1 | tee -a "$LOG"
import re, glob
OUT = "/foss/designs/lora-mimo/rtl-test/syn_mimo_per_module/out_synth_sc_wgen"
old = {"sc_detector": 304755, "weight_gen": 183846}
for f in sorted(glob.glob(f"{OUT}/stat_*.txt")):
    name = f.split("stat_")[1].replace(".txt","")
    for line in open(f):
        m = re.search(r"Chip area.*?:\s+([\d.]+)", line)
        if m:
            new = float(m.group(1))
            delta = new - old[name]
            print(f"  {name:<15}: {old[name]:>8,.0f} → {new:>8,.0f}  ({delta:+,.0f} µm²)")
PYEOF
echo "=== DONE ===" | tee -a "$LOG"
