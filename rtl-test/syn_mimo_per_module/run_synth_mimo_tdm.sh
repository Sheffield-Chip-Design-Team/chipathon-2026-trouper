#!/bin/bash
# Hierarchical synthesis of trouper_top with sd_decimator_top (TDM).
# Reports per-module area and compares total vs monolithic baseline.
# Baseline: run from out_combchain/yosys.log (uses sd_decimator_combchain x 4).
set -euo pipefail
RTL=/foss/designs/lora-mimo
OUT=$RTL/rtl-test/syn_mimo_per_module/out_mimo_tdm
CORE_LIB=$RTL/ip/gf180mcu_as_sc_mcu7t3v3/pdk/libs.ref/gf180mcu_as_sc_mcu7t3v3/lib/gf180mcu_as_sc_mcu7t3v3__tt_025C_3v30.lib
mkdir -p "$OUT"
LOG=$OUT/run.log
echo "=== trouper_top TDM synth $(date --iso-8601=seconds) on $(hostname) ===" | tee "$LOG"

RT=$RTL/rtl-test
YS=$OUT/synth.ys
cat > "$YS" <<'YEOF'
read_verilog $RTL/ip/picorv32/picorv32.v
read_verilog $RT/sd_decimator_top.v
read_verilog $RT/sd_cic_chan.v
read_verilog $RT/sd_fir_state.v
read_verilog $RT/sd_fir_mac.v
read_verilog $RT/ahb_lite_bus.v
read_verilog $RT/dc_removal.v
read_verilog $RT/energy_meas_coarse.v
read_verilog $RT/frontend_buf_ctrl.v
read_verilog $RT/irq_ctrl.v
read_verilog $RT/trouper_top.v
read_verilog $RT/mrc_combiner.v
read_verilog $RT/packet_ctrl_fsm.v
read_verilog $RT/picorv32_wrap.v
read_verilog $RT/reg_bank.v
read_verilog $RT/sc_detector.v
read_verilog $RT/sd_remod.v
read_verilog $RT/spi_master.v
read_verilog $RT/spi_slave.v
read_verilog $RT/sram512x8_bb.v
read_verilog $RT/sram1024x8_bb.v
read_verilog $RT/training_acc.v
read_verilog $RT/weight_gen.v
hierarchy -top trouper_top
synth -top trouper_top
dfflibmap -liberty $CORE_LIB
abc -liberty $CORE_LIB
setundef -zero
opt_clean -purge
tee -o $OUT/stat.txt stat -liberty $CORE_LIB -top trouper_top
YEOF

echo "--- running yosys (hierarchical) ---" | tee -a "$LOG"
yosys -s "$YS" 2>&1 | tee -a "$LOG" | grep -E "Chip area|ERROR|Warning.*wire" | head -30

echo "" | tee -a "$LOG"
echo "=== Per-module area ===" | tee -a "$LOG"
grep "Chip area for" "$OUT/stat.txt" | sort -t: -k2 -rn | head -20 | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "=== Chip total ===" | tee -a "$LOG"
grep "Chip area for top module" "$OUT/stat.txt" | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "=== vs monolithic baseline ===" | tee -a "$LOG"
BASELINE_STAT=$RTL/rtl-test/syn_mimo_per_module/out/stat_hier.txt
if [ -f "$BASELINE_STAT" ]; then
    echo "  monolithic (sd_decimator x 4):" | tee -a "$LOG"
    grep "Chip area for top module" "$BASELINE_STAT" | tee -a "$LOG"
    echo "  TDM (sd_decimator_top x 1):" | tee -a "$LOG"
    grep "Chip area for top module" "$OUT/stat.txt" | tee -a "$LOG"
    python3 -c "
import re
def get_area(path):
    with open(path) as f: txt = f.read()
    m = re.search(r'Chip area for top module.*?: ([\d.]+)', txt)
    return float(m.group(1)) if m else None
base = get_area('$BASELINE_STAT')
tdm  = get_area('$OUT/stat.txt')
if base and tdm:
    print(f'  saving: {base-tdm:.0f} um2  ({(base-tdm)/base*100:.1f}% of chip)')
    print(f'  chip area TDM: {tdm/1e6:.3f} mm2')
" 2>/dev/null | tee -a "$LOG"
else
    echo "  (baseline stat not found at $BASELINE_STAT)" | tee -a "$LOG"
fi

echo "=== DONE ===" | tee -a "$LOG"
