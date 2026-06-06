#!/bin/bash
# A/B SQNR regression: original sd_decimator vs sd_decimator_combchain.
# Drives both with the same sigma-delta tone stimulus, captures int8 IQ
# output, measures SQNR via least-squares fit. Pass threshold 28 dB (same
# as run_sqnr_tb.py); baseline reference at OSR=64 is ~34 dB.
set -euo pipefail
RTL=/foss/designs/lora-mimo
OUT=$RTL/rtl-test/syn_mimo_per_module/out_sqnr
TB_DATA=$RTL/sim/tb_data
mkdir -p "$OUT" "$TB_DATA"
LOG=$OUT/run.log
echo "=== sd_decimator SQNR A/B $(date --iso-8601=seconds) on $(hostname) ===" | tee "$LOG"

cd "$RTL"

echo "--- gen stimulus ---" | tee -a "$LOG"
python3 -m sim.sims.run_sqnr_tb --gen-only 2>&1 | tee -a "$LOG" | tail -5

# Make a copy of the combchain RTL with the module renamed to sd_decimator
# so tb_sqnr.v (which instantiates sd_decimator) can pick it up unchanged.
SWAP=$OUT/sd_decimator_swap.v
sed 's/sd_decimator_combchain/sd_decimator/g' \
    "$RTL/rtl-test/sd_decimator_combchain.v" > "$SWAP"

for VARIANT in baseline combchain; do
    if [ "$VARIANT" = "baseline" ]; then
        DEC=$RTL/rtl-test/sd_decimator.v
    else
        DEC=$SWAP
    fi
    VVP=$OUT/tb_sqnr_${VARIANT}.vvp
    RTL_OUT=$TB_DATA/rtl_out.txt

    echo "--- compile + run $VARIANT ($DEC) ---" | tee -a "$LOG"
    iverilog -g2001 -Wall -o "$VVP" \
        "$RTL/rtl-test/tb_sqnr.v" "$DEC" 2>&1 | tee -a "$LOG"
    vvp "$VVP" 2>&1 | tee -a "$LOG" | tail -3

    cp "$RTL_OUT" "$OUT/rtl_out_${VARIANT}.txt"
    wc -l "$OUT/rtl_out_${VARIANT}.txt" | tee -a "$LOG"
done

echo "--- SQNR analysis (Python) ---" | tee -a "$LOG"
python3 <<'PYEOF' 2>&1 | tee -a "$LOG"
import numpy as np
import os
OUT = "/foss/designs/lora-mimo/rtl-test/syn_mimo_per_module/out_sqnr"
R = 64; FS_ADC = 32e6; FS_OUT = FS_ADC / R
F_TONE = FS_OUT / 16
SKIP = 20

def sqnr(path):
    d = np.loadtxt(path, dtype=np.int8).reshape(-1, 2)[SKIP:]
    n = len(d)
    t = np.arange(n) / FS_OUT
    A = np.column_stack([np.cos(2*np.pi*F_TONE*t), np.sin(2*np.pi*F_TONE*t)])
    out = {}
    for i, ch in enumerate(["I", "Q"]):
        x = d[:, i].astype(float)
        coef, *_ = np.linalg.lstsq(A, x, rcond=None)
        fit = A @ coef
        sig = np.mean(fit**2)
        noise = np.mean((x - fit)**2)
        db = 10*np.log10(sig/noise) if noise > 1e-12 else 99.0
        out[ch] = (db, np.hypot(*coef), n)
    return out

results = {}
for v in ["baseline", "combchain"]:
    p = os.path.join(OUT, f"rtl_out_{v}.txt")
    results[v] = sqnr(p)
    for ch, (db, amp, n) in results[v].items():
        print(f"  [{v:9s}] {ch}: SQNR {db:5.2f} dB  amp {amp:6.1f}  n={n}")

print()
print("  Latency-aligned sample diff (first 40 outputs after SKIP, common length):")
b = np.loadtxt(os.path.join(OUT, "rtl_out_baseline.txt"), dtype=np.int8).reshape(-1, 2)[SKIP:]
c = np.loadtxt(os.path.join(OUT, "rtl_out_combchain.txt"), dtype=np.int8).reshape(-1, 2)[SKIP:]
n = min(len(b), len(c), 40)
print(f"  idx  base_I base_Q  comb_I comb_Q   dI  dQ")
mismatches = 0
total = 0
for i in range(n):
    dI = int(c[i, 0]) - int(b[i, 0])
    dQ = int(c[i, 1]) - int(b[i, 1])
    flag = "  *" if (abs(dI) > 1 or abs(dQ) > 1) else ""
    if abs(dI) > 1 or abs(dQ) > 1: mismatches += 1
    total += 1
    print(f"  {i:3d}  {b[i,0]:6d} {b[i,1]:6d}  {c[i,0]:6d} {c[i,1]:6d}  {dI:3d} {dQ:3d}{flag}")
print()
print(f"  Within-1-LSB match: {total-mismatches}/{total}")
PYEOF

echo "=== DONE ===" | tee -a "$LOG"
