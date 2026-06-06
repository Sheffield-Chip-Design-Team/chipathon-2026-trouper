#!/bin/bash
# A/B/C SQNR regression: baseline (sd_decimator) vs combchain vs shiftadd.
# All three are compiled from the same tb_sqnr.v (instantiates sd_decimator);
# combchain and shiftadd are renamed via sed before compilation.
# Pass threshold 28 dB; baseline reference ~34 dB at OSR=64.
set -euo pipefail
RTL=/foss/designs/lora-mimo
OUT=$RTL/rtl-test/syn_mimo_per_module/out_sqnr_shiftadd
TB_DATA=$RTL/sim/tb_data
mkdir -p "$OUT" "$TB_DATA"
LOG=$OUT/run.log
echo "=== sd_decimator SQNR A/B/C $(date --iso-8601=seconds) on $(hostname) ===" | tee "$LOG"

cd "$RTL"

echo "--- gen stimulus ---" | tee -a "$LOG"
python3 -m sim.sims.run_sqnr_tb --gen-only 2>&1 | tee -a "$LOG" | tail -5

SWAP_CC=$OUT/sd_decimator_combchain_swap.v
SWAP_SA=$OUT/sd_decimator_shiftadd_swap.v
sed 's/sd_decimator_combchain/sd_decimator/g' \
    "$RTL/rtl-test/sd_decimator_combchain.v" > "$SWAP_CC"
sed 's/sd_decimator_shiftadd/sd_decimator/g' \
    "$RTL/rtl-test/sd_decimator_shiftadd.v" > "$SWAP_SA"

for VARIANT in baseline combchain shiftadd; do
    case "$VARIANT" in
        baseline)  DEC=$RTL/rtl-test/sd_decimator.v ;;
        combchain) DEC=$SWAP_CC ;;
        shiftadd)  DEC=$SWAP_SA ;;
    esac
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
import numpy as np, os
OUT = "/foss/designs/lora-mimo/rtl-test/syn_mimo_per_module/out_sqnr_shiftadd"
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
for v in ["baseline", "combchain", "shiftadd"]:
    p = os.path.join(OUT, f"rtl_out_{v}.txt")
    results[v] = sqnr(p)
    for ch, (db, amp, n) in results[v].items():
        flag = "PASS" if db >= 28.0 else "FAIL"
        print(f"  [{v:9s}] {ch}: SQNR {db:5.2f} dB  amp {amp:6.1f}  n={n}  [{flag}]")

print()
# Sample-by-sample diff: combchain vs shiftadd (should be identical)
cc = np.loadtxt(os.path.join(OUT, "rtl_out_combchain.txt"), dtype=np.int8).reshape(-1, 2)[SKIP:]
sa = np.loadtxt(os.path.join(OUT, "rtl_out_shiftadd.txt"),  dtype=np.int8).reshape(-1, 2)[SKIP:]
n = min(len(cc), len(sa))
diffs = np.abs(cc[:n].astype(int) - sa[:n].astype(int))
max_diff = diffs.max()
n_mismatch = (diffs > 0).any(axis=1).sum()
print(f"  combchain vs shiftadd: {n} samples, max_diff={max_diff}, mismatches={n_mismatch}")
if n_mismatch == 0:
    print("  RESULT: BIT-EXACT vs combchain baseline")
else:
    print("  RESULT: NOT bit-exact vs combchain (check for latency offset)")
    print("  First 10 mismatching rows:")
    bad = np.where((diffs > 0).any(axis=1))[0][:10]
    for i in bad:
        print(f"    [{i}] cc={cc[i]} sa={sa[i]} diff={cc[i].astype(int)-sa[i].astype(int)}")
PYEOF

echo "=== DONE ===" | tee -a "$LOG"
