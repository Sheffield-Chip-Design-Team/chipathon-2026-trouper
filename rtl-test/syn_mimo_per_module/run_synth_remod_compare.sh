#!/bin/bash
# run_synth_remod_compare.sh — area comparison: sd_remod variants
#
# Variant A: sd_remod         — CIFF, unity feedforward weights (current, BROKEN)
# Variant B: sd_remod_ciff    — CIFF, synthesised CIFF coefficients (Q8 multipliers)
# Variant C: sd_remod_mash    — MASH 1-1-1, no multipliers (q1 output only)
#
# GF180MCU FD cells, TT 25C 3v30.
set -euo pipefail

RTL=/foss/designs/lora-mimo/rtl-test/rtl
OUT=/foss/designs/lora-mimo/rtl-test/syn_mimo_per_module/out_remod_compare
CORE_LIB=/foss/pdks/gf180mcuD/libs.ref/gf180mcu_fd_sc_mcu7t5v0/lib/gf180mcu_fd_sc_mcu7t5v0__tt_025C_3v30.lib

mkdir -p "$OUT"
LOG=$OUT/run.log
echo "=== remod compare $(date --iso-8601=seconds) on $(hostname) ===" | tee "$LOG"

synth_variant() {
    local NAME=$1
    local TOP=$2
    local SRC=$3
    local STAT=$OUT/stat_${NAME}.txt
    local YS=$OUT/synth_${NAME}.ys

    {
        echo "read_verilog ${SRC}"
        echo "hierarchy -top ${TOP}"
        echo "synth -top ${TOP}"
        echo "dfflibmap -liberty ${CORE_LIB}"
        echo "abc -liberty ${CORE_LIB}"
        echo "setundef -zero"
        echo "opt_clean -purge"
        echo "tee -o ${STAT} stat -liberty ${CORE_LIB} -top ${TOP}"
    } > "$YS"

    echo "--- synth ${NAME} ---" | tee -a "$LOG"
    yosys -s "$YS" 2>&1 | tee -a "$LOG" | grep -E "Chip area|Number of|ERROR" | head -10
}

synth_variant unity_ciff  sd_remod      "$RTL/sd_remod.v"
synth_variant tuned_ciff  sd_remod_ciff "$RTL/sd_remod_ciff.v"
synth_variant mash        sd_remod_mash "$RTL/sd_remod_mash.v"

python3 - <<'PYEOF' 2>/dev/null | tee -a "$LOG"
import re

OUT = "/foss/designs/lora-mimo/rtl-test/syn_mimo_per_module/out_remod_compare"

def parse_stat(path):
    try:
        txt = open(path).read()
        area = re.search(r'Chip area for top module[^:]*:\s*([\d.]+)', txt)
        cells = re.search(r'Number of cells:\s*(\d+)', txt)
        return (float(area.group(1)) if area else None,
                int(cells.group(1)) if cells else None)
    except FileNotFoundError:
        return None, None

variants = [
    ("unity_ciff", "CIFF unity weights (BROKEN)   "),
    ("tuned_ciff", "CIFF tuned Q8 coefficients    "),
    ("mash",       "MASH 1-1-1 q1 output (no mux)"),
]

print(f"\n{'Variant':<38}  {'Area (µm²)':>12}  {'Cells':>7}  {'vs CIFF-tuned':>14}")
print("-" * 78)

areas = {}
for key, label in variants:
    a, c = parse_stat(f"{OUT}/stat_{key}.txt")
    areas[key] = a
    ref = None
    delta = ""
    if a and areas.get("tuned_ciff"):
        ref = areas["tuned_ciff"]
        delta = f"{(a-ref)/ref*100:+.1f}%"
    astr = f"{a:>12,.0f}" if a else f"{'(missing)':>12}"
    cstr = f"{c:>7}" if c else f"{'—':>7}"
    print(f"  {label}  {astr}  {cstr}  {delta:>14}")

print()
tc = areas.get("tuned_ciff"); ma = areas.get("mash")
if tc and ma:
    print(f"  MASH saving vs tuned CIFF: {tc-ma:+,.0f} µm²  ({(ma/tc)*100:.1f}% of CIFF area)")
PYEOF

echo "=== DONE ===" | tee -a "$LOG"
