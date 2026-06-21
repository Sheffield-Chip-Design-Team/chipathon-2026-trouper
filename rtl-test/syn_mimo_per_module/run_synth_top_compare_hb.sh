#!/bin/bash
# run_synth_top_compare_hb.sh
# Yosys synthesis comparison: trouper_top (CIC-only R=128) vs trouper_top_hb (HB R=64).
# Both use gf180mcu_fd_sc_mcu7t5v0 FD cells at TT/25°C/3.3V.
set -euo pipefail

export PDK_ROOT=/foss/pdks
export PDK=gf180mcuD
export STD_CELL_LIBRARY=gf180mcu_fd_sc_mcu7t5v0
ROOT=/foss/designs/lora-mimo
RT=$ROOT/rtl-test
EXP=$RT/rtl/experiment_hb
LIB=$PDK_ROOT/$PDK/libs.ref/$STD_CELL_LIBRARY/lib/${STD_CELL_LIBRARY}__tt_025C_3v30.lib
OUT=$RT/syn_mimo_per_module/out_top_compare_hb
mkdir -p "$OUT"

echo "=== trouper_top vs trouper_top_hb FD synth comparison ==="
echo "    $(date --iso-8601=seconds) on $(hostname)"
echo "    LIB: $LIB"
echo ""

# ---------------------------------------------------------------------------
# 1. trouper_top (production — CIC-only R=128, 250 kS/s)
# ---------------------------------------------------------------------------
echo "--- [1/2] trouper_top (CIC-only R=128) ---"
cat > "$OUT/synth_orig.ys" <<YEOF
read_verilog $RT/rtl/trouper_top.v
read_verilog $RT/rtl/sd_decimator_cic_tdm8.v
read_verilog $RT/rtl/dc_removal.v
read_verilog $RT/rtl/sc_detector.v
read_verilog $RT/rtl/training_acc.v
read_verilog $RT/rtl/packet_ctrl_fsm.v
read_verilog $RT/rtl/psram_buf_ctrl.v
read_verilog $RT/rtl/mrc_combiner.v
read_verilog $RT/rtl/sd_remod.v
read_verilog $RT/rtl/spi_slave.v
read_verilog $RT/rtl/reg_bank.v
hierarchy -check -top trouper_top
synth -top trouper_top
dfflibmap -liberty $LIB
abc -liberty $LIB
setundef -zero
opt_clean -purge
check
tee -o $OUT/stat_orig.txt stat -liberty $LIB -top trouper_top
write_verilog -noattr $OUT/trouper_top_synth.v
YEOF
yosys -s "$OUT/synth_orig.ys" > "$OUT/yosys_orig.log" 2>&1
echo "  Done. Log: $OUT/yosys_orig.log"

# ---------------------------------------------------------------------------
# 2. trouper_top_hb (HB decimator — CIC-3/R=16 + HB1 + HB2, 500 kS/s)
# ---------------------------------------------------------------------------
echo "--- [2/2] trouper_top_hb (HB R=64) ---"
cat > "$OUT/synth_hb.ys" <<YEOF
read_verilog $EXP/trouper_top_hb.v
read_verilog $RT/rtl/sd_decimator_hb_tdm.v
read_verilog $EXP/dc_removal_hb.v
read_verilog $EXP/sc_detector_hb.v
read_verilog $EXP/training_acc_hb.v
read_verilog $EXP/packet_ctrl_fsm_hb.v
read_verilog $EXP/psram_buf_ctrl_hb.v
read_verilog $RT/rtl/mrc_combiner.v
read_verilog $EXP/sd_remod_hb.v
read_verilog $RT/rtl/spi_slave.v
read_verilog $EXP/reg_bank_hb.v
hierarchy -check -top trouper_top_hb
synth -top trouper_top_hb
dfflibmap -liberty $LIB
abc -liberty $LIB
setundef -zero
opt_clean -purge
check
tee -o $OUT/stat_hb.txt stat -liberty $LIB -top trouper_top_hb
write_verilog -noattr $OUT/trouper_top_hb_synth.v
YEOF
yosys -s "$OUT/synth_hb.ys" > "$OUT/yosys_hb.log" 2>&1
echo "  Done. Log: $OUT/yosys_hb.log"

# ---------------------------------------------------------------------------
# 3. Comparison summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Per-module area breakdown (trouper_top) ==="
grep "Chip area for module" "$OUT/stat_orig.txt" | sort -t: -k2 -rn | head -20

echo ""
echo "=== Per-module area breakdown (trouper_top_hb) ==="
grep "Chip area for module" "$OUT/stat_hb.txt" | sort -t: -k2 -rn | head -20

echo ""
echo "=== Side-by-side comparison ==="
python3 - <<'PYEOF'
import re, sys

def parse_stat(path):
    try:
        txt = open(path).read()
    except FileNotFoundError:
        return None, {}
    top_m = re.search(r'Chip area for top module[^:]*:\s*([\d.]+)', txt)
    top_area = float(top_m.group(1)) if top_m else None
    mods = {}
    for m in re.finditer(r"Chip area for module '([^']+)':\s*([\d.]+)", txt):
        mods[m.group(1)] = float(m.group(2))
    # also grab Number of cells and FFs
    cells_m = re.search(r'Number of cells:\s*(\d+)', txt)
    ff_m    = re.search(r'flop\S*\s+(\d+)', txt)
    return top_area, mods

orig_top, orig_mods = parse_stat('/foss/designs/lora-mimo/rtl-test/syn_mimo_per_module/out_top_compare_hb/stat_orig.txt')
hb_top,   hb_mods   = parse_stat('/foss/designs/lora-mimo/rtl-test/syn_mimo_per_module/out_top_compare_hb/stat_hb.txt')

print(f"{'Module':<35} {'CIC-orig (µm²)':>16} {'HB (µm²)':>16} {'Delta':>10}")
print("-" * 80)

# Pair up modules by base name (strip _hb suffix for comparison)
all_mods = sorted(set(list(orig_mods.keys()) + [k.replace('_hb','') for k in hb_mods.keys()]))
for mod in all_mods:
    o = orig_mods.get(mod, None)
    h = hb_mods.get(mod + '_hb', hb_mods.get(mod, None))
    if o is None and h is None:
        continue
    o_str = f"{o:>16,.1f}" if o is not None else f"{'—':>16}"
    h_str = f"{h:>16,.1f}" if h is not None else f"{'—':>16}"
    if o and h:
        delta = f"{h-o:>+10,.1f}"
    else:
        delta = f"{'':>10}"
    print(f"{mod:<35} {o_str} {h_str} {delta}")

print("-" * 80)
o_str = f"{orig_top:>16,.1f}" if orig_top is not None else f"{'—':>16}"
h_str = f"{hb_top:>16,.1f}"   if hb_top is not None   else f"{'—':>16}"
if orig_top and hb_top:
    pct = (hb_top - orig_top) / orig_top * 100
    delta = f"{hb_top-orig_top:>+10,.1f} ({pct:+.1f}%)"
else:
    delta = ""
print(f"{'TOTAL (top module)':<35} {o_str} {h_str} {delta}")
PYEOF

echo ""
echo "=== DONE $(date --iso-8601=seconds) ==="
