#!/bin/bash
# Verify sd_fir_mac (step 3): 1-channel wrapper bit-exact vs combchain.
set -euo pipefail
RTL=/foss/designs/lora-mimo
OUT=$RTL/rtl-test/syn_mimo_per_module/out_fir_mac
TB_DATA=$RTL/sim/tb_data
mkdir -p "$OUT" "$TB_DATA"
LOG=$OUT/run.log
echo "=== sd_fir_mac 1-ch SQNR $(date --iso-8601=seconds) on $(hostname) ===" | tee "$LOG"

cd "$RTL"
python3 -m sim.sims.run_sqnr_tb --gen-only 2>&1 | tee -a "$LOG" | tail -3

SWAP_CC=$OUT/sd_decimator_combchain_swap.v
sed 's/sd_decimator_combchain/sd_decimator/g' \
    "$RTL/rtl-test/sd_decimator_combchain.v" > "$SWAP_CC"

for VARIANT in combchain fir_mac_1ch; do
    if [ "$VARIANT" = "combchain" ]; then
        SRCS="$SWAP_CC"
    else
        SRCS="$RTL/rtl-test/tb_fir_mac_1ch_wrap.v \
              $RTL/rtl-test/sd_cic_chan.v \
              $RTL/rtl-test/sd_fir_state.v \
              $RTL/rtl-test/sd_fir_mac.v"
    fi
    VVP=$OUT/tb_sqnr_${VARIANT}.vvp
    RTL_OUT=$TB_DATA/rtl_out.txt

    echo "--- compile + run $VARIANT ---" | tee -a "$LOG"
    iverilog -g2001 -Wall -o "$VVP" \
        "$RTL/rtl-test/tb_sqnr.v" $SRCS 2>&1 | tee -a "$LOG" | grep -vE "@\* is sensitive" | tail -5 || true
    vvp "$VVP" 2>&1 | tee -a "$LOG" | tail -3
    cp "$RTL_OUT" "$OUT/rtl_out_${VARIANT}.txt"
    wc -l "$OUT/rtl_out_${VARIANT}.txt" | tee -a "$LOG"
done

echo "--- analysis ---" | tee -a "$LOG"
python3 <<'PYEOF' 2>&1 | tee -a "$LOG"
import numpy as np, os
OUT = "/foss/designs/lora-mimo/rtl-test/syn_mimo_per_module/out_fir_mac"
R = 64; FS_ADC = 32e6; FS_OUT = FS_ADC / R; F_TONE = FS_OUT / 16; SKIP = 20

def sqnr(path):
    d = np.loadtxt(path, dtype=np.int8).reshape(-1, 2)[SKIP:]
    t = np.arange(len(d)) / FS_OUT
    A = np.column_stack([np.cos(2*np.pi*F_TONE*t), np.sin(2*np.pi*F_TONE*t)])
    out = {}
    for i, ch in enumerate(["I", "Q"]):
        x = d[:, i].astype(float)
        c, *_ = np.linalg.lstsq(A, x, rcond=None)
        sig = np.mean((A@c)**2); noise = np.mean((x - A@c)**2)
        out[ch] = (10*np.log10(sig/noise) if noise > 1e-12 else 99.0, np.hypot(*c), len(d))
    return out

for v in ["combchain", "fir_mac_1ch"]:
    r = sqnr(os.path.join(OUT, f"rtl_out_{v}.txt"))
    for ch, (db, amp, n) in r.items():
        print(f"  [{v:12s}] {ch}: SQNR {db:5.2f} dB  amp {amp:6.1f}  n={n}  [{'PASS' if db>=28 else 'FAIL'}]")

print()
cc = np.loadtxt(os.path.join(OUT, "rtl_out_combchain.txt"),  dtype=np.int8).reshape(-1,2)[SKIP:]
mm = np.loadtxt(os.path.join(OUT, "rtl_out_fir_mac_1ch.txt"), dtype=np.int8).reshape(-1,2)[SKIP:]
n  = min(len(cc), len(mm))
d  = np.abs(cc[:n].astype(int) - mm[:n].astype(int))
mis = (d > 0).any(axis=1).sum()
print(f"  combchain vs fir_mac_1ch: {n} samples, max_diff={d.max()}, mismatches={mis}")
if mis == 0:
    print("  RESULT: BIT-EXACT — sd_fir_mac pipeline correct (1-channel)")
else:
    print("  RESULT: MISMATCH — check FSM / pipeline timing")
    bad = np.where((d > 0).any(axis=1))[0][:8]
    for i in bad:
        print(f"    [{i}]  cc={cc[i]}  mac={mm[i]}  diff={cc[i].astype(int)-mm[i].astype(int)}")
PYEOF

echo "=== DONE ===" | tee -a "$LOG"
