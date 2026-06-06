#!/bin/bash
# SQNR A/B: sd_decimator_combchain vs sd_decimator_cic_only.
# Tests all four decim_ratio settings (R = 256 / 128 / 64 / 32).
# Pass threshold: 28 dB on both channels for every ratio.
set -euo pipefail
RTL=/foss/designs/lora-mimo
OUT=$RTL/rtl-test/syn_mimo_per_module/out_sqnr_cic_only
TB_DATA=$RTL/sim/tb_data
mkdir -p "$OUT" "$TB_DATA"
LOG=$OUT/run.log
echo "=== sd_decimator_cic_only SQNR A/B $(date --iso-8601=seconds) on $(hostname) ===" | tee "$LOG"

cd "$RTL"

# Rename combchain module to "sd_decimator" for tb_sqnr.v
SWAP_COMB=$OUT/sd_decimator_comb_swap.v
SWAP_CIC=$OUT/sd_decimator_cic_swap.v
sed 's/sd_decimator_combchain/sd_decimator/g' \
    "$RTL/rtl-test/sd_decimator_combchain.v" > "$SWAP_COMB"
sed 's/sd_decimator_cic_only/sd_decimator/g' \
    "$RTL/rtl-test/sd_decimator_cic_only.v" > "$SWAP_CIC"

# tb_sqnr.v uses DECIM and N_STIM parameters via +define or parameter override.
# We override DECIM and N_STIM at compile time for each ratio.
# N_STIM = N_OUT * R;  N_OUT = 600 (generous for startup transient skip).
declare -A RATIO_MAP
RATIO_MAP[0]=256   # 125 kHz BW
RATIO_MAP[1]=128   # 250 kHz BW
RATIO_MAP[2]=64    # 500 kHz BW
RATIO_MAP[3]=32    # 1 MS/s

N_OUT=600

for DECIM_VAL in 0 1 2 3; do
    R=${RATIO_MAP[$DECIM_VAL]}
    N_STIM=$(( N_OUT * R ))

    echo "" | tee -a "$LOG"
    echo "--- decim_ratio=$DECIM_VAL  R=$R  N_STIM=$N_STIM ---" | tee -a "$LOG"

    # Generate stimulus for this R
    python3 -c "
import numpy as np, os, sys
sys.path.insert(0, '.')
np.random.seed(42)
R = $R; N_OUT = $N_OUT; FS_ADC = 32e6
FS_OUT = FS_ADC / R
F_TONE = FS_OUT * 0.4   # near band edge (worst-case droop)
N_STIM = N_OUT * R
AMPLITUDE = 0.35
t = np.arange(N_STIM) / FS_ADC
sig = AMPLITUDE * np.exp(2j * np.pi * F_TONE * t)
e_re, e_im = 0.0, 0.0
bits_i = []; bits_q = []
for x in sig:
    u = x.real + e_re; q = 1.0 if u >= 0 else -1.0; e_re = u - q; bits_i.append(int(q > 0))
    u = x.imag + e_im; q = 1.0 if u >= 0 else -1.0; e_im = u - q; bits_q.append(int(q > 0))
os.makedirs('sim/tb_data', exist_ok=True)
np.savetxt('sim/tb_data/stim_i.txt', bits_i, fmt='%d')
np.savetxt('sim/tb_data/stim_q.txt', bits_q, fmt='%d')
print(f'[gen] R={R}  F_tone={F_TONE/1e3:.1f} kHz  N_STIM={N_STIM}')
" 2>&1 | tee -a "$LOG"

    for VARIANT in combchain cic_only; do
        if [ "$VARIANT" = "combchain" ]; then
            DEC=$SWAP_COMB
        else
            DEC=$SWAP_CIC
        fi
        VVP=$OUT/tb_sqnr_${VARIANT}_r${R}.vvp
        RTL_OUT=$TB_DATA/rtl_out.txt

        echo "  compile + run $VARIANT R=$R" | tee -a "$LOG"
        iverilog -g2001 -Wall \
            -P "tb_sqnr.N_STIM=$N_STIM" -P "tb_sqnr.DECIM=$DECIM_VAL" \
            -o "$VVP" \
            "$RTL/rtl-test/tb_sqnr.v" "$DEC" 2>&1 | tee -a "$LOG"
        vvp "$VVP" 2>&1 | grep -v "^$" | tee -a "$LOG" | tail -2

        cp "$RTL_OUT" "$OUT/rtl_out_${VARIANT}_r${R}.txt"
    done
done

echo "" | tee -a "$LOG"
echo "--- SQNR analysis ---" | tee -a "$LOG"
python3 <<'PYEOF' 2>&1 | tee -a "$LOG"
import numpy as np, os

OUT  = "/foss/designs/lora-mimo/rtl-test/syn_mimo_per_module/out_sqnr_cic_only"
FS_ADC = 32e6
SKIP = 30
MIN_SQNR = 28.0

RATIOS = [256, 128, 64, 32]

def sqnr(path, R):
    fs_out = FS_ADC / R
    f_tone = fs_out * 0.4
    d = np.loadtxt(path, dtype=np.int8).reshape(-1, 2)[SKIP:]
    n = len(d)
    t = np.arange(n) / fs_out
    A = np.column_stack([np.cos(2*np.pi*f_tone*t), np.sin(2*np.pi*f_tone*t)])
    out = {}
    for i, ch in enumerate(["I", "Q"]):
        x = d[:, i].astype(float)
        coef, *_ = np.linalg.lstsq(A, x, rcond=None)
        fit = A @ coef
        sig_pwr   = np.mean(fit**2)
        noise_pwr = np.mean((x - fit)**2)
        db = 10*np.log10(sig_pwr/noise_pwr) if noise_pwr > 1e-12 else 99.0
        out[ch] = (db, np.hypot(*coef))
    return out

print(f"  {'R':>5}  {'BW kHz':>7}  {'Variant':>12}  {'I SQNR':>8}  {'Q SQNR':>8}  {'Pass?':>6}")
print("  " + "-"*60)

all_pass = True
for R in RATIOS:
    bw = int(FS_ADC / R / 1e3)
    for variant in ["combchain", "cic_only"]:
        p = os.path.join(OUT, f"rtl_out_{variant}_r{R}.txt")
        if not os.path.exists(p):
            print(f"  {R:>5}  {bw:>7}  {variant:>12}  MISSING")
            continue
        res = sqnr(p, R)
        idb = res["I"][0]; qdb = res["Q"][0]
        ok  = idb >= MIN_SQNR and qdb >= MIN_SQNR
        if not ok: all_pass = False
        flag = "PASS" if ok else "FAIL"
        print(f"  {R:>5}  {bw:>7}  {variant:>12}  {idb:>8.1f}  {qdb:>8.1f}  {flag:>6}")
    print()

print()
if all_pass:
    print("  OVERALL: PASS — cic_only ≥ 28 dB on all R / channel combinations.")
else:
    print("  OVERALL: FAIL — one or more cases below 28 dB threshold.")
PYEOF

echo "=== DONE ===" | tee -a "$LOG"
