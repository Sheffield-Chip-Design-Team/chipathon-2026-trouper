#!/bin/bash
# Top-level hierarchical synthesis — current RTL state (2026-06-03).
#
# Changes vs run_synth_hier.sh:
#   - sd_decimator_cic_only.v  (was sd_decimator.v — old FIR version)
#   - psram_buf_ctrl.v         (was missing)
#   - noise_floor_est removed  (already removed from mimo_rx_top.v)
#   - energy_meas_coarse.v     (already correct)
#   - mrc_combiner.v           (now serialised I/Q — same module name, drop-in)
#
# Cell library: AS cells (gf180mcu_as_sc_mcu7t3v3) — same as prior baselines.
set -euo pipefail

RTL=/foss/designs/lora-mimo
RT=$RTL/rtl-test
OUT=$RT/syn_mimo_per_module/out_top_current
CORE_LIB=$RTL/ip/gf180mcu_as_sc_mcu7t3v3/pdk/libs.ref/gf180mcu_as_sc_mcu7t3v3/lib/gf180mcu_as_sc_mcu7t3v3__tt_025C_3v30.lib
SRAM_LIB=$RTL/ip/gf180mcu_ocd_ip_sram/timing/gf180mcu_fd_ip_sram__sram512x8m8wm1_tt_025C_3v30.lib

mkdir -p "$OUT"
LOG=$OUT/run.log
echo "=== mimo_rx_top current synth $(date --iso-8601=seconds) on $(hostname) ===" | tee "$LOG"

YS=$OUT/synth.ys
cat > "$YS" <<YEOF
read_verilog $RTL/ip/picorv32/picorv32.v
read_verilog $RT/ahb_lite_bus.v
read_verilog $RT/dc_removal.v
read_verilog $RT/energy_meas_coarse.v
read_verilog $RT/frontend_buf_ctrl.v
read_verilog $RT/irq_ctrl.v
read_verilog $RT/mimo_rx_top.v
read_verilog $RT/mrc_combiner.v
read_verilog $RT/packet_ctrl_fsm.v
read_verilog $RT/picorv32_wrap.v
read_verilog $RT/psram_buf_ctrl.v
read_verilog $RT/reg_bank.v
read_verilog $RT/sc_detector.v
read_verilog $RT/sd_decimator_cic_only.v
read_verilog $RT/sd_remod.v
read_verilog $RT/spi_master.v
read_verilog $RT/spi_slave.v
read_verilog $RT/sram512x8_bb.v
read_verilog $RT/sram1024x8_bb.v
read_verilog $RT/training_acc.v
read_verilog $RT/weight_gen.v
hierarchy -top mimo_rx_top
synth -top mimo_rx_top
dfflibmap -liberty $CORE_LIB
abc -liberty $CORE_LIB
setundef -zero
opt_clean -purge
tee -o $OUT/stat_hier.txt stat -liberty $CORE_LIB -top mimo_rx_top
YEOF

echo "--- running yosys ---" | tee -a "$LOG"
yosys -s "$YS" 2>&1 | tee -a "$LOG" | grep -E "Chip area|ERROR|Warning.*wire" | head -20

echo "" | tee -a "$LOG"
echo "=== Per-module area (top 20) ===" | tee -a "$LOG"
grep "Chip area for module" "$OUT/stat_hier.txt" | sort -t: -k2 -rn | head -20 | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "=== Top module total ===" | tee -a "$LOG"
grep "Chip area for top module" "$OUT/stat_hier.txt" | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "=== vs prior baseline (out/stat_hier.txt) ===" | tee -a "$LOG"
python3 - <<'PYEOF' 2>/dev/null | tee -a "$LOG"
import re

def top_area(path):
    try:
        txt = open(path).read()
        m = re.search(r'Chip area for top module[^:]*:\s*([\d.]+)', txt)
        return float(m.group(1)) if m else None
    except FileNotFoundError:
        return None

prev = top_area("/foss/designs/lora-mimo/rtl-test/syn_mimo_per_module/out/stat_hier.txt")
curr = top_area("/foss/designs/lora-mimo/rtl-test/syn_mimo_per_module/out_top_current/stat_hier.txt")
if prev and curr:
    print(f"  Previous baseline:  {prev:>12,.0f} µm²")
    print(f"  Current:            {curr:>12,.0f} µm²")
    print(f"  Delta:              {curr-prev:>+12,.0f} µm²  ({(curr-prev)/prev*100:+.1f}%)")
elif curr:
    print(f"  Current:            {curr:>12,.0f} µm²")
    print(f"  (no previous baseline found)")
PYEOF

echo "=== DONE ===" | tee -a "$LOG"
