#!/usr/bin/env python3
"""
compare_unity_vs_ciff.py

SQNR comparison: 3rd-order CIFF SD modulator with unity feedforward weights
vs the synthesized CIFF coefficients from the dsp guy.

OSR=64  →  250 kHz BW (32 MS/s / (2 * 250 kHz))
OSR=128 →  125 kHz BW (32 MS/s / (2 * 125 kHz))
"""

import numpy as np
import matplotlib.pyplot as plt

# ---------------------------------------------------------------------------
# SD3 modulator — matches SD_comparison_v2_epy_block_2.py exactly
# b1=1 (single feed-in), b2=b3=b4=0, c1=c2=c3=1 (unity inter-stage)
# Only a1/a2/a3 (feedforward summer weights) differ between variants
# ---------------------------------------------------------------------------
def simulate_sd3(x_in, a1, a2, a3):
    N = len(x_in)
    out = np.empty(N)
    i1 = i2 = i3 = 0.0
    prev_out = 0.0
    for n in range(N):
        x = x_in[n - 1] if n > 0 else 0.0
        i1 += x - prev_out       # b1=1, c1=1
        i2 += i1                  # b2=0, c2=1
        i3 += i2                  # b3=0, c3=1
        sigma = a1 * i1 + a2 * i2 + a3 * i3
        prev_out = 1.0 if sigma > 0 else -1.0
        out[n] = prev_out
    return out


def sqnr_fft(bits, signal_freq, fs, osr):
    """In-band SQNR via FFT. Signal band = [0, fs/(2*osr)]."""
    N = len(bits)
    window = np.hanning(N)
    X = np.fft.rfft(bits * window)
    freqs = np.fft.rfftfreq(N, 1.0 / fs)

    # Bin closest to the signal tone
    sig_bin = int(round(signal_freq / fs * N))
    guard = 3  # bins either side treated as signal

    band_mask = freqs <= fs / (2 * osr)
    sig_mask = np.zeros(len(freqs), dtype=bool)
    sig_mask[max(0, sig_bin - guard):sig_bin + guard + 1] = True

    noise_mask = band_mask & ~sig_mask
    sig_power = np.sum(np.abs(X[sig_mask]) ** 2)
    noise_power = np.sum(np.abs(X[noise_mask]) ** 2)
    return 10 * np.log10(sig_power / noise_power)


# ---------------------------------------------------------------------------
# Simulation parameters  (match the GRC flowgraph: samp_rate=256 kHz)
# ---------------------------------------------------------------------------
FS = 256_000          # SD modulator clock rate
SIG_FREQ = 1_000      # 1 kHz test tone  (same as GRC flowgraph)
AMP = 0.5             # amplitude (~-6 dBFS)
N = 1 << 18           # 262144 samples — good FFT resolution

t = np.arange(N) / FS
x = AMP * np.sin(2 * np.pi * SIG_FREQ * t)

VARIANTS = {
    "Unity (a=[1, 1, 1])":              (1.0,    1.0,    1.0),
    "CIFF OSR=64  (a=[0.800, 0.288, 0.044])": (0.79973886, 0.2881357, 0.04398262),
}

OSR_LIST = [64, 128]

print(f"Signal: {SIG_FREQ} Hz,  A={AMP} ({20*np.log10(AMP):.1f} dBFS),  N={N},  FS={FS/1e3:.0f} kHz\n")
print(f"{'Variant':<44}  {'OSR=64 SQNR':>12}  {'OSR=128 SQNR':>13}")
print("-" * 74)

results = {}
for label, (a1, a2, a3) in VARIANTS.items():
    bits = simulate_sd3(x, a1, a2, a3)
    row = {}
    for osr in OSR_LIST:
        snr = sqnr_fft(bits, SIG_FREQ, FS, osr)
        row[osr] = snr
    results[label] = row
    print(f"{label:<44}  {row[64]:>11.1f} dB  {row[128]:>12.1f} dB")

unity = results["Unity (a=[1, 1, 1])"]
ciff  = results["CIFF OSR=64  (a=[0.800, 0.288, 0.044])"]
print("-" * 74)
print(f"{'CIFF gain over unity':<44}  {ciff[64]-unity[64]:>+11.1f} dB  {ciff[128]-unity[128]:>+12.1f} dB")

# ---------------------------------------------------------------------------
# Spectrum plot
# ---------------------------------------------------------------------------
fig, ax = plt.subplots(figsize=(10, 5))
colors = {"Unity (a=[1, 1, 1])": "steelblue",
          "CIFF OSR=64  (a=[0.800, 0.288, 0.044])": "tomato"}

for label, (a1, a2, a3) in VARIANTS.items():
    bits = simulate_sd3(x, a1, a2, a3)
    N2 = len(bits)
    window = np.hanning(N2)
    X = np.fft.rfft(bits * window)
    freqs = np.fft.rfftfreq(N2, 1.0 / FS)
    psd = 20 * np.log10(np.abs(X) / N2 + 1e-12)
    ax.plot(freqs / 1e3, psd, label=label, color=colors[label], linewidth=0.8, alpha=0.85)

# signal band boundaries
for osr in OSR_LIST:
    bw = FS / (2 * osr)
    ax.axvline(bw / 1e3, linestyle="--", linewidth=0.8, color="gray",
               label=f"OSR={osr} BW ({bw/1e3:.0f} kHz)")

ax.set_xlim(0, FS / 2e3)
ax.set_ylim(-160, 0)
ax.set_xlabel("Frequency (kHz)")
ax.set_ylabel("Power (dB, relative)")
ax.set_title("SD3 output spectrum: Unity vs CIFF coefficients")
ax.legend(fontsize=8)
ax.grid(True, alpha=0.3)
plt.tight_layout()
plt.savefig("unity_vs_ciff_spectrum.png", dpi=150)
print("\nSpectrum saved to gnu-radio/unity_vs_ciff_spectrum.png")
plt.show()
