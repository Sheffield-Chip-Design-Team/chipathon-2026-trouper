#!/bin/bash
# Step 4 verification: sd_decimator_top 4-channel TDM.
# Runs tb_sqnr_4ch.v and compares vs sd_decimator_combchain (ch 0).
# Also runs standalone yosys synthesis to measure area saving.
set -euo pipefail
RTL=/foss/designs/lora-mimo
OUT=$RTL/rtl-test/syn_mimo_per_module/out_dec_top
TB_DATA=$RTL/sim/tb_data
CORE_LIB=$RTL/ip/gf180mcu_as_sc_mcu7t3v3/pdk/libs.ref/gf180mcu_as_sc_mcu7t3v3/lib/gf180mcu_as_sc_mcu7t3v3__tt_025C_3v30.lib
mkdir -p "$OUT" "$TB_DATA"
LOG=$OUT/run.log
echo "=== sd_decimator_top step4 $(date --iso-8601=seconds) on $(hostname) ===" | tee "$LOG"

cd "$RTL"

echo "--- gen stimulus ---" | tee -a "$LOG"
python3 -m sim.sims.run_sqnr_tb --gen-only 2>&1 | tee -a "$LOG" | tail -3

SWAP_CC=$OUT/sd_decimator_combchain_swap.v
sed 's/sd_decimator_combchain/sd_decimator/g' \
    "$RTL/rtl-test/sd_decimator_combchain.v" > "$SWAP_CC"

DEC_TOP_SRCS="$RTL/rtl-test/sd_decimator_top.v \
              $RTL/rtl-test/sd_cic_chan.v \
              $RTL/rtl-test/sd_fir_state.v \
              $RTL/rtl-test/sd_fir_mac.v"

# --- Simulation: combchain 1-ch reference ---
echo "--- sim: combchain (1-ch reference) ---" | tee -a "$LOG"
VVP_CC=$OUT/tb_sqnr_combchain.vvp
iverilog -g2001 -Wall -o "$VVP_CC" \
    "$RTL/rtl-test/tb_sqnr.v" "$SWAP_CC" 2>&1 | tee -a "$LOG" | grep -vE "@\* is sensitive" | tail -3 || true
vvp "$VVP_CC" 2>&1 | tee -a "$LOG" | tail -2
cp "$TB_DATA/rtl_out.txt" "$OUT/rtl_out_combchain.txt"

# --- Simulation: sd_decimator_top 4-ch TDM ---
echo "--- sim: sd_decimator_top (4-ch TDM) ---" | tee -a "$LOG"
VVP_TOP=$OUT/tb_sqnr_4ch.vvp
iverilog -g2001 -Wall -o "$VVP_TOP" \
    "$RTL/rtl-test/tb_sqnr_4ch.v" $DEC_TOP_SRCS 2>&1 | tee -a "$LOG" | grep -vE "@\* is sensitive" | tail -5 || true
vvp "$VVP_TOP" 2>&1 | tee -a "$LOG" | tail -2
cp "$TB_DATA/rtl_out.txt"     "$OUT/rtl_out_top_ch0.txt"
cp "$TB_DATA/rtl_out_4ch.txt" "$OUT/rtl_out_top_4ch.txt"

# --- Analysis ---
echo "--- analysis ---" | tee -a "$LOG"
python3 <<'PYEOF' 2>&1 | tee -a "$LOG"
import numpy as np, os
OUT = "/foss/designs/lora-mimo/rtl-test/syn_mimo_per_module/out_dec_top"
R = 64; FS_OUT = 32e6 / R; F_TONE = FS_OUT / 16; SKIP = 20

def sqnr_ch(samples_i, samples_q):
    n = len(samples_i)
    t = np.arange(n) / FS_OUT
    A = np.column_stack([np.cos(2*np.pi*F_TONE*t), np.sin(2*np.pi*F_TONE*t)])
    out = {}
    for name, x in [("I", samples_i.astype(float)), ("Q", samples_q.astype(float))]:
        c, *_ = np.linalg.lstsq(A, x, rcond=None)
        sig = np.mean((A@c)**2); noise = np.mean((x-A@c)**2)
        out[name] = 10*np.log10(sig/noise) if noise > 1e-12 else 99.0
    return out

# combchain ch0 reference
cc = np.loadtxt(os.path.join(OUT,"rtl_out_combchain.txt"), dtype=np.int8).reshape(-1,2)[SKIP:]
r = sqnr_ch(cc[:,0], cc[:,1])
print(f"  [combchain   ch0] I:{r['I']:5.2f} dB  Q:{r['Q']:5.2f} dB  [{'PASS' if min(r.values())>=28 else 'FAIL'}]")

# TDM ch0 vs combchain — cap at min(len) to exclude tail drain samples
ch0 = np.loadtxt(os.path.join(OUT,"rtl_out_top_ch0.txt"), dtype=np.int8).reshape(-1,2)[SKIP:]
n = min(len(cc), len(ch0))
ch0c = ch0[:n]
r0 = sqnr_ch(ch0c[:,0], ch0c[:,1])
print(f"  [dec_top     ch0] I:{r0['I']:5.2f} dB  Q:{r0['Q']:5.2f} dB  [{'PASS' if min(r0.values())>=28 else 'FAIL'}]")
d = np.abs(cc[:n].astype(int) - ch0c.astype(int))
print(f"  combchain vs top ch0: {n} samples, max_diff={d.max()}, mismatches={(d>0).any(axis=1).sum()}")

# All 4 channels from 4ch file — cap at min(cc, d4) to exclude tail drain
d4_raw = np.loadtxt(os.path.join(OUT,"rtl_out_top_4ch.txt"), dtype=np.int8)[SKIP:]
ncap = min(len(cc), len(d4_raw))
d4 = d4_raw[:ncap]
print()
all_pass = True
for ch in range(4):
    r = sqnr_ch(d4[:,ch*2], d4[:,ch*2+1])
    ok = min(r.values()) >= 28
    if not ok: all_pass = False
    print(f"  [dec_top     ch{ch}] I:{r['I']:5.2f} dB  Q:{r['Q']:5.2f} dB  [{'PASS' if ok else 'FAIL'}]")

# Check all channels identical (same input)
for ch in range(1, 4):
    mi = np.abs(d4[:,0].astype(int) - d4[:,ch*2].astype(int)).max()
    mq = np.abs(d4[:,1].astype(int) - d4[:,ch*2+1].astype(int)).max()
    print(f"  ch0 vs ch{ch}: max_diff I={mi} Q={mq}  [{'OK' if mi==0 and mq==0 else 'DIFF'}]")

print()
if all_pass:
    note = "bit-exact" if d.max() == 0 else f"max_diff={d.max()} LSB (≤2 expected from pipeline rounding)"
    print(f"  RESULT: PASS — all 4 channels SQNR ≥28 dB; ch0 vs combchain {note}")
else:
    print("  RESULT: FAIL")
PYEOF

# --- Synthesis: area measurement ---
echo "--- synthesis: sd_decimator_top area ---" | tee -a "$LOG"
YS=$OUT/synth_top.ys
cat > "$YS" <<YEOF
read_verilog $RTL/rtl-test/sd_decimator_top.v
read_verilog $RTL/rtl-test/sd_cic_chan.v
read_verilog $RTL/rtl-test/sd_fir_state.v
read_verilog $RTL/rtl-test/sd_fir_mac.v
synth -top sd_decimator_top
dfflibmap -liberty $CORE_LIB
abc -liberty $CORE_LIB
setundef -zero
opt_clean -purge
tee -o $OUT/stat_top.txt stat -liberty $CORE_LIB -top sd_decimator_top
YEOF
yosys -s "$YS" 2>&1 | tee -a "$LOG" | tail -5

echo "" | tee -a "$LOG"
echo "=== Area comparison ===" | tee -a "$LOG"
echo "  4× combchain (baseline): $(python3 -c 'print(f\"{4*189665:.0f} um2  ({4*189665/1e6:.3f} mm2)\")')" | tee -a "$LOG"
echo "  sd_decimator_top (TDM):" | tee -a "$LOG"
grep "Chip area for module" "$OUT/stat_top.txt" | tee -a "$LOG"
SAVING=$(python3 -c "
import re
with open('$OUT/stat_top.txt') as f: txt = f.read()
m = re.search(r'Chip area.*?: ([\d.]+)', txt)
if m:
    tdm = float(m.group(1))
    base = 4 * 189665.28
    print(f'  saving: {base-tdm:.0f} um2  ({(base-tdm)/base*100:.1f}% of 4x baseline)  ({(base-tdm)/2562000*100:.1f}% of 2.56 mm2 chip)')
" 2>/dev/null || echo "  (parse failed)")
echo "$SAVING" | tee -a "$LOG"

echo "=== DONE ===" | tee -a "$LOG"
