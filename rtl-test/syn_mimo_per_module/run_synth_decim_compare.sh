#!/bin/bash
# Decimator area comparison: 3 NR=4 variants, FD cells, R=256 (125 kHz).
#
# Variant A: sd_decim_4ch_cic_only   — 4 × CIC-only (no FIR)
# Variant B: sd_decimator_cic_tdm8  — boxcar-4 + 4-slot TDM CIC(R=64), 1 shared adder
# Variant C: sd_decim_4ch_shiftadd  — 4 × CIC + shift-add FIR
#
# All synthesised against gf180mcu_fd_sc_mcu7t5v0 (FD, 5V cells — same as die-area baseline).
set -euo pipefail

RTL=/foss/designs/lora-mimo
RT=$RTL/rtl-test
OUT=$RT/syn_mimo_per_module/out_decim_compare
CORE_LIB=/foss/pdks/gf180mcuD/libs.ref/gf180mcu_fd_sc_mcu7t5v0/lib/gf180mcu_fd_sc_mcu7t5v0__tt_025C_3v30.lib

mkdir -p "$OUT"
LOG=$OUT/run.log
echo "=== decimator compare $(date --iso-8601=seconds) on $(hostname) ===" | tee "$LOG"

synth_variant() {
    local NAME=$1; shift
    local TOP=$1;  shift
    local SRCS=("$@")
    local STAT=$OUT/stat_${NAME}.txt
    local YS=$OUT/synth_${NAME}.ys

    {
        for S in "${SRCS[@]}"; do echo "read_verilog $S"; done
        echo "hierarchy -top ${TOP}"
        echo "synth -top ${TOP}"
        echo "dfflibmap -liberty ${CORE_LIB}"
        echo "abc -liberty ${CORE_LIB}"
        echo "setundef -zero"
        echo "opt_clean -purge"
        echo "tee -o ${STAT} stat -liberty ${CORE_LIB} -top ${TOP}"
    } > "$YS"

    echo "--- synth ${NAME} ---" | tee -a "$LOG"
    yosys -s "$YS" 2>&1 | tee -a "$LOG" | grep -E "Chip area|ERROR" | head -5
}

# Variant A: 4 × CIC-only
synth_variant cic_only sd_decim_4ch_cic_only \
    "$RT/sd_decimator_cic_only.v" \
    "$RT/sd_decim_4ch_cic_only.v"

# Variant B: TDM CIC (1 shared adder, boxcar-4 pre-stage)
synth_variant cic_tdm8 sd_decimator_cic_tdm8 \
    "$RT/sd_decimator_cic_tdm8.v"

# Variant C: 4 × CIC + shift-add FIR
synth_variant shiftadd sd_decim_4ch_shiftadd \
    "$RT/sd_decimator_shiftadd.v" \
    "$RT/sd_decim_4ch_shiftadd.v"

# --- NR=2 variants ---

# Variant D: 2 × CIC-only
synth_variant cic_only_2ch sd_decim_2ch_cic_only \
    "$RT/sd_decimator_cic_only.v" \
    "$RT/sd_decim_2ch_cic_only.v"

# Variant E: TDM CIC NR=2 (2-slot, boxcar-2, CIC R=128)
synth_variant cic_tdm2ch sd_decimator_cic_tdm2ch \
    "$RT/sd_decimator_cic_tdm2ch.v"

# Variant F: 2 × CIC + shift-add FIR
synth_variant shiftadd_2ch sd_decim_2ch_shiftadd \
    "$RT/sd_decimator_shiftadd.v" \
    "$RT/sd_decim_2ch_shiftadd.v"

echo "" | tee -a "$LOG"
echo "=== Summary (FD cells, R=256) ===" | tee -a "$LOG"

python3 - <<'PYEOF' 2>/dev/null | tee -a "$LOG"
import re, os

OUT = "/foss/designs/lora-mimo/rtl-test/syn_mimo_per_module/out_decim_compare"

def get_top_area(stat_path):
    try:
        txt = open(stat_path).read()
        # Prefer "top module" line; fall back to largest area in file
        m = re.search(r'Chip area for top module[^:]*:\s*([\d.]+)', txt)
        if m:
            return float(m.group(1))
        vals = [float(x) for x in re.findall(r'Chip area for \S+ module[^:]*:\s*([\d.]+)', txt)]
        return max(vals) if vals else None
    except FileNotFoundError:
        return None

nr4 = [
    ("cic_only",  "NR=4  4× CIC-only            "),
    ("cic_tdm8",  "NR=4  1× TDM CIC (bx4+R64)   "),
    ("shiftadd",  "NR=4  4× CIC+FIR shiftadd    "),
]
nr2 = [
    ("cic_only_2ch", "NR=2  2× CIC-only            "),
    ("cic_tdm2ch",   "NR=2  1× TDM CIC (bx2+R128)  "),
    ("shiftadd_2ch", "NR=2  2× CIC+FIR shiftadd    "),
]

all_variants = nr4 + nr2
areas = {k: get_top_area(f"{OUT}/stat_{k}.txt") for k, _ in all_variants}

sa4 = areas.get("shiftadd"); sa2 = areas.get("shiftadd_2ch")

print(f"\n{'Variant':<42} {'Area (µm²)':>12}  {'vs same-NR FIR':>14}")
print("-" * 72)
for key, label in nr4:
    a = areas[key]
    ref = sa4
    delta = f"{(a-ref)/ref*100:+.1f}%" if (a and ref) else "—"
    print(f"  {label}  {a:>12,.0f}  {delta:>14}" if a else f"  {label}  {'(missing)':>12}")

print("")
for key, label in nr2:
    a = areas[key]
    ref = sa2
    delta = f"{(a-ref)/ref*100:+.1f}%" if (a and ref) else "—"
    print(f"  {label}  {a:>12,.0f}  {delta:>14}" if a else f"  {label}  {'(missing)':>12}")

print("\n--- Key deltas ---")
c4 = areas.get("cic_only");    t4 = areas.get("cic_tdm8")
c2 = areas.get("cic_only_2ch"); t2 = areas.get("cic_tdm2ch")
if c4 and t4: print(f"NR=4 TDM vs CIC-only:   {t4-c4:+,.0f} µm²  ({(t4-c4)/c4*100:+.1f}%)")
if c2 and t2: print(f"NR=2 TDM vs CIC-only:   {t2-c2:+,.0f} µm²  ({(t2-c2)/c2*100:+.1f}%)")
if c4 and c2: print(f"NR=2 vs NR=4 CIC-only:  {c2-c4:,.0f} µm²  ({(c2/c4)*100:.1f}% of NR=4)")
if t4 and t2: print(f"NR=2 vs NR=4 TDM:       {t2-t4:,.0f} µm²  ({(t2/t4)*100:.1f}% of NR=4)")
PYEOF

echo "=== DONE ===" | tee -a "$LOG"
