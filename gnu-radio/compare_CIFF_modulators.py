"""
compare_CIFF_modulators.py

Compares 1st, 2nd, and 3rd order CIFF (Cascade of Integrators, Feedforward)
delta-sigma modulators. Shows that higher order yields increasingly aggressive
in-band noise shaping at the cost of a narrower stable input range.

Converted from compare_CIFF_modulators.m (MATLAB Delta Sigma Toolbox).
"""

import numpy as np
import matplotlib.pyplot as plt
from deltasigma import (
    synthesizeNTF, realizeNTF, stuffABCD,
    evalTF, dbv, figureMagic, plotPZ,
    predictSNR, simulateSNR, peakSNR,
)

osr    = 64
nlev   = 2      # binary (1-bit) quantizer
Hinf   = 1.5    # maximum NTF gain (out-of-band peaking)
orders = [1, 2, 3]
colors = [(0, 0.45, 0.74), (0.85, 0.33, 0.10), (0.47, 0.67, 0.19)]
labels = ['1st-order CIFF', '2nd-order CIFF', '3rd-order CIFF']
ord_suffix = ['st', 'nd', 'rd']

# --- Synthesize NTFs and compute CIFF ABCD matrices --------------------------
ntfs = []
ABCDs = []
for k, order in enumerate(orders):
    ntf = synthesizeNTF(order, osr, opt=0, H_inf=Hinf, f0=0)
    a, g, b, c = realizeNTF(ntf, 'CIFF')
    b = np.concatenate(([b[0]], np.zeros(len(b) - 1)))  # single input feed-in
    print(f"k={k+1}  a={a}  g={g}  b={b}  c={c}")
    ABCD = stuffABCD(a, g, b, c, 'CIFF')
    ntfs.append(ntf)
    ABCDs.append(ABCD)

f   = np.linspace(0, 0.5, 2000)
z   = np.exp(2j * np.pi * f)
fBW = 0.5 / osr

# --- Figure 1: NTF magnitude -------------------------------------------------
plt.figure(1, figsize=(8, 4.5))
plt.clf()
plt.gcf().canvas.manager.set_window_title('NTF Magnitude — CIFF Order Comparison')

ylo = -120
for k in range(3):
    H = evalTF(ntfs[k], z)
    plt.plot(f, dbv(abs(H)), color=colors[k], linewidth=2, label=labels[k])

plt.plot([0, fBW], [-3, -3], 'k:', linewidth=1)
plt.plot([fBW, fBW], [ylo, 5], 'k--', linewidth=1)
plt.text(fBW * 1.04, -100, f'$f_{{BW}}$\n(OSR={osr})', fontsize=9)

figureMagic([0, 0.5], 0.05, None, [ylo, 5], 20, None, [8, 4.5],
            'NTF Magnitude — CIFF Modulator Comparison')
plt.xlabel('Normalized frequency  $f / f_s$')
plt.ylabel('|NTF(f)|  (dB)')
plt.title('Noise Transfer Function Magnitude — CIFF Modulator Order Comparison')
plt.legend(loc='upper left')

# --- Figure 2: NTF poles and zeros -------------------------------------------
plt.figure(2, figsize=(12, 4))
plt.clf()
plt.gcf().canvas.manager.set_window_title('NTF Poles & Zeros — CIFF')

for k in range(3):
    plt.subplot(1, 3, k + 1)
    plotPZ(ntfs[k])
    plt.title(f'{orders[k]}{ord_suffix[k]}-order CIFF')

plt.tight_layout()

# --- Figure 3: SQNR vs input amplitude ---------------------------------------
plt.figure(3, figsize=(8, 5))
plt.clf()
plt.gcf().canvas.manager.set_window_title('SQNR vs. Input Level — CIFF Order Comparison')

pred_handles = []
peak_snrs = np.zeros(3)
peak_amps = np.zeros(3)

for k in range(3):
    snr_pred, amp_pred, _, _, _ = predictSNR(ntfs[k], osr)
    h, = plt.plot(amp_pred, snr_pred, color=colors[k], linewidth=2)
    pred_handles.append(h)

    snr_sim, amp_sim = simulateSNR(ABCDs[k], osr, amp=None, f0=0, nlev=nlev)
    plt.plot(amp_sim, snr_sim, 'o', color=colors[k], markersize=5)

    pk, pa = peakSNR(snr_sim, amp_sim)
    pk, pa = float(np.squeeze(pk)), float(np.squeeze(pa))
    if np.isnan(pk):  # fallback when curve fitting fails (e.g. 1st order noisy data)
        idx = int(np.nanargmax(snr_sim))
        pk, pa = snr_sim[idx], amp_sim[idx]
    peak_snrs[k], peak_amps[k] = pk, pa
    plt.text(peak_amps[k] - 2, peak_snrs[k] + 3, f'{peak_snrs[k]:.0f} dB',
             color=colors[k], fontsize=9, ha='right')

figureMagic([-100, 0], 10, None, [0, 110], 10, None, [8, 5], 'SQNR vs Input Level')
plt.xlabel('Input Level  (dBFS)')
plt.ylabel('SQNR  (dB)')
plt.title(f'SQNR vs. Input Level — CIFF Modulators, OSR={osr}')
plt.legend(pred_handles, labels, loc='upper left')
plt.text(-98, 105, 'Lines = predicted,  circles = simulated', fontsize=8)

# --- Console summary ---------------------------------------------------------
print(f'\n=== CIFF Modulator Comparison  (OSR={osr}, 1-bit quantizer, H_inf={Hinf:.1f}) ===\n')
print(f'  {"Modulator":<18}  {"Peak SQNR (simulated)":<22}  Peak input (dBFS)')
print(f'  {"-"*18}  {"-"*22}  {"-"*17}')
for k in range(3):
    print(f'  {labels[k]:<18}  {peak_snrs[k]:<22.1f}  {peak_amps[k]:.1f}')

theoretical_gain = 20 * np.log10(osr) - 10 * np.log10(np.pi**2)
print(f'\n  Theoretical SQNR gain per order ≈ +{theoretical_gain:.0f} dB for OSR={osr} (each order adds')
print(f'  ~20*log10(OSR) - 10*log10(pi^2) dB of in-band noise rejection).\n')

plt.show()
