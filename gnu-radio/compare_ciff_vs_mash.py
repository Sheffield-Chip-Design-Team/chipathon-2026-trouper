#!/usr/bin/env python3
"""
compare_ciff_vs_mash.py

SQNR comparison of CIFF (tuned) vs MASH 1-1-1 at the actual system parameters:
  FS     = 32 MS/s  (actual ASIC modulator clock)
  OSR=128 → 125 kHz BW
  OSR=64  → 250 kHz BW

Input scaled to int8 range (±127 FS). Feedback = ±127.

MASH SQNR is measured two ways:
  (a) Full multi-level Y = q1 + Δq2 + Δ²q3, then box-filter decimate → true 3rd-order
  (b) sign(Y) as 1-bit output then decimate → shows what a hard sign quantiser costs
"""

import numpy as np
import matplotlib.pyplot as plt

FS       = 32_000_000   # 32 MS/s — actual system clock
SIG_FREQ =    10_000    # 10 kHz test tone (well within 125 kHz band)
N        = 1 << 18      # 262144 samples (~8 ms at 32 MS/s)
AMP_DBFS = -6.0         # input level
AMP      = 10 ** (AMP_DBFS / 20) * 127   # scale to int8 FS (±127)

FB_POS =  127.0
FB_NEG = -127.0

# CIFF Q8 coefficients (from synthesizeNTF(order=3, OSR=64))
A1 = 205 / 256   # 0.800
A2 =  74 / 256   # 0.289
A3 =  11 / 256   # 0.043


def simulate_ciff(x_in):
    """CIFF 3rd-order — matches sd_remod_ciff.v exactly."""
    N = len(x_in)
    out = np.empty(N)
    s1 = s2 = s3 = 0.0
    prev_fb = FB_NEG
    for n in range(N):
        e  = x_in[n] - prev_fb
        s1 = np.clip(s1 + e,  -32768, 32767)
        s2 = np.clip(s2 + s1, -32768, 32767)
        s3 = np.clip(s3 + s2, -32768, 32767)
        v  = e + A1*s1 + A2*s2 + A3*s3
        q  = FB_POS if v >= 0 else FB_NEG
        out[n]  = q
        prev_fb = q
    return out


def simulate_mash(x_in):
    """
    MASH 1-1-1 — returns (q1_bits, Y_multilevel, mash_1bit).
    q1_bits  : 1-bit from stage 1 only        (1st-order NS)
    Y_out    : q1 + Δq2 + Δ²q3               (3rd-order NS, multi-level)
    mash_1bit: 1st-order requantizer on Y     (3rd+1st order NS, 1-bit)
    """
    N = len(x_in)
    q1_bits   = np.empty(N)
    Y_out     = np.empty(N)
    mash_1bit = np.empty(N)

    s1 = s2 = s3 = 0.0
    q2_prev = q3_prev1 = q3_prev2 = 0.0
    req_state = 0.0   # requantizer integrator state

    for n in range(N):
        x = x_in[n]

        u1 = x + s1
        q1 = FB_POS if u1 >= 0 else FB_NEG
        s1 = u1 - q1

        u2 = s1 + s2
        q2 = FB_POS if u2 >= 0 else FB_NEG
        s2 = u2 - q2

        u3 = s2 + s3
        q3 = FB_POS if u3 >= 0 else FB_NEG
        s3 = u3 - q3

        dq2  = q2 - q2_prev
        d2q3 = q3 - 2*q3_prev1 + q3_prev2
        Y    = q1 + dq2 + d2q3

        # 1st-order error-feedback requantizer: converts multi-level Y → 1-bit
        u_req     = Y + req_state
        q_req     = FB_POS if u_req >= 0 else FB_NEG
        req_state = u_req - q_req

        q1_bits[n]   = q1
        Y_out[n]     = Y
        mash_1bit[n] = q_req

        q2_prev  = q2
        q3_prev2 = q3_prev1
        q3_prev1 = q3

    return q1_bits, Y_out, mash_1bit


def sqnr_inband(bits, sig_freq, fs, osr):
    """
    In-band SQNR measured directly on the full bitstream via FFT.
    Signal band = [0, fs/(2*osr)].  No decimation filter — avoids alias folding.
    """
    N = len(bits)
    window = np.hanning(N)
    X = np.fft.rfft(bits * window)
    freqs = np.fft.rfftfreq(N, 1.0 / fs)

    sig_bin = int(round(sig_freq / fs * N))
    guard = 3
    band_mask = freqs <= fs / (2 * osr)
    sig_mask  = np.zeros(len(freqs), dtype=bool)
    sig_mask[max(0, sig_bin - guard):sig_bin + guard + 1] = True

    noise_mask  = band_mask & ~sig_mask
    sig_power   = np.sum(np.abs(X[sig_mask])   ** 2)
    noise_power = np.sum(np.abs(X[noise_mask]) ** 2)
    return 10 * np.log10(sig_power / (noise_power + 1e-30))


# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
t = np.arange(N) / FS
x = AMP * np.sin(2 * np.pi * SIG_FREQ * t)

print(f"FS={FS/1e6:.0f} MS/s,  signal={SIG_FREQ/1e3:.0f} kHz,  "
      f"A={AMP:.1f} counts ({AMP_DBFS:.0f} dBFS),  N={N}\n")

ciff_bits                    = simulate_ciff(x)
mash_q1, mash_Y, mash_1bit  = simulate_mash(x)

header = f"{'Variant':<46}  {'OSR=128 (125kHz)':>18}  {'OSR=64 (250kHz)':>17}"
print(header)
print("-" * len(header))

results = {}
for osr in [128, 64]:
    results[osr] = {
        "ciff":      sqnr_inband(ciff_bits,  SIG_FREQ, FS, osr),
        "mash_q1":   sqnr_inband(mash_q1,   SIG_FREQ, FS, osr),
        "mash_Y":    sqnr_inband(mash_Y,     SIG_FREQ, FS, osr),
        "mash_1bit": sqnr_inband(mash_1bit,  SIG_FREQ, FS, osr),
    }

rows = [
    ("CIFF tuned        (3rd order, 1-bit)",          "ciff"),
    ("MASH q1 only      (1st order, 1-bit)",          "mash_q1"),
    ("MASH full Y       (3rd order, multi-level)",    "mash_Y"),
    ("MASH + requantizer(3rd+1st order, 1-bit) ★",   "mash_1bit"),
]
for label, key in rows:
    r128 = results[128][key]
    r64  = results[64][key]
    print(f"  {label:<48}  {r128:>14.1f} dB  {r64:>14.1f} dB")

print("-" * len(header))
sc   = results[128]["ciff"];   smY  = results[128]["mash_Y"]
sm1b = results[128]["mash_1bit"]
sc2  = results[64]["ciff"];    smY2 = results[64]["mash_Y"]
sm1b2= results[64]["mash_1bit"]
print(f"\n  MASH+req vs CIFF (OSR=128):  {sm1b  - sc:+.1f} dB")
print(f"  MASH+req vs CIFF (OSR= 64):  {sm1b2 - sc2:+.1f} dB")

# ---------------------------------------------------------------------------
# Spectrum plot (OSR=128)
# ---------------------------------------------------------------------------
osr_plot = 128
fs_dec   = FS / osr_plot

fig, ax = plt.subplots(figsize=(10, 5))

for sig, label, color, lw in [
    (ciff_bits,  "CIFF tuned (3rd order, 1-bit)",             "steelblue", 1.5),
    (mash_q1,    "MASH q1 only (1st order, 1-bit)",           "orange",    0.9),
    (mash_Y,     "MASH full Y (3rd order, multi-level)",      "tomato",    1.0),
    (mash_1bit,  "MASH + requantizer (3rd+1st order, 1-bit)", "green",     1.2),
]:
    M = len(sig)
    X = np.fft.rfft(sig * np.hanning(M))
    f = np.fft.rfftfreq(M, 1.0 / FS)
    psd = 20 * np.log10(np.abs(X) / M + 1e-12)
    ax.plot(f / 1e6, psd, label=label, color=color, linewidth=lw, alpha=0.9)

bw_khz = FS / (2 * osr_plot) / 1e3
ax.axvline(bw_khz / 1e3, linestyle="--", linewidth=0.8, color="gray",
           label=f"BW = {bw_khz:.0f} kHz (OSR={osr_plot})")
ax.axvline(SIG_FREQ / 1e6, linestyle=":", color="black", linewidth=0.8,
           label=f"Signal {SIG_FREQ//1000} kHz")
ax.set_xlim(0, FS / 2e6)
ax.set_ylim(-120, 10)
ax.set_xlabel("Frequency (MHz)")
ax.set_ylabel("Power (dB)")
ax.set_title(f"Decimated spectra — OSR={osr_plot}  (125 kHz BW)  |  {AMP_DBFS} dBFS input")
ax.legend(fontsize=9)
ax.grid(True, alpha=0.3)
plt.tight_layout()
plt.savefig("ciff_vs_mash_spectrum.png", dpi=150)
print("\nSpectrum saved to gnu-radio/ciff_vs_mash_spectrum.png")
plt.show()
