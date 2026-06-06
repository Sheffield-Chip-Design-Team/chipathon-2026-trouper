"""
Bit-width sweep: compare float, 12-bit, and 8-bit decimator output.

Tests the full non-FFT path with the training accumulator (not perfect
channel knowledge) across a range of SNR values.

Quantization model
------------------
A fixed AGC scale is applied before quantization:
    alpha = TARGET_RMS / sqrt(1 + N0)   -- normalises expected RMS to TARGET_RMS
    adc_in = rx * alpha
    adc_out = round(adc_in * (2^(bits-1)-1)) / (2^(bits-1)-1)   clamped to ±1
    rx_q = adc_out / alpha                                         -- restore scale

Using a fixed scale (not per-block peak) correctly models the fixed relationship
between thermal noise and quantization noise. TARGET_RMS = 0.25 puts signal+noise
at -12 dBFS, leaving headroom for Rayleigh fades above the mean.

SC lock is assumed at 3M samples into the preamble (hits_req=2 ideal timing),
so we generate 8 preamble + 1 payload symbol and accumulate from sample 3M.
This isolates quantization effects on training and combining from SC timing noise.

Run:
    python3 -m sim.tests.test_bitwidth_sweep
"""

import numpy as np
import sys

from sim.models.lora import modulate, demodulate
from sim.models.channel import rayleigh_coefficients
from sim.models.training_accumulator import training_accumulate, compute_weights
from sim.models.receiver import nonfft_combine

SF = 7
M = 2 ** SF          # 128 samples/symbol
NR = 4
N_PREAMBLE = 8       # upchirp preamble symbols
REF_SEL = 0

# SC lock assumed at 3M samples into the preamble (hits_req=2 ideal timing)
SC_LOCK_SAMPLE = 3 * M
TIMING_REF = 0       # preamble starts at sample 0; acc_end = 0 + 8M - 1 = 8M-1

TARGET_RMS = 0.25    # AGC target: signal+noise RMS at -12 dBFS


def make_preamble(M: int, n_sym: int) -> np.ndarray:
    """Generate n_sym upchirp preamble symbols."""
    n = np.arange(M)
    chirp = np.exp(1j * np.pi * n ** 2 / M)
    return np.tile(chirp, n_sym)


def quantize_fixed_agc(rx: np.ndarray, bits: int, N0: float) -> np.ndarray:
    """
    Quantize rx with a fixed AGC scale derived from expected signal+noise RMS.

    Parameters
    ----------
    rx   : (NR, N) complex array — signal after channel + noise (normalized: E[|h|²]=1)
    bits : ADC bit width
    N0   : noise power per complex sample

    Returns
    -------
    rx_q : (NR, N) complex array — quantized then descaled (same units as rx)
    """
    if bits == 0:
        return rx  # float: no quantization

    levels = 2 ** (bits - 1) - 1
    # Fixed AGC: scale so expected RMS of signal+noise = TARGET_RMS
    # E[|rx_j|²] = E[|h_j|²] + N0 = 1 + N0  (per component after channel)
    rms_expected = np.sqrt(1.0 + N0)
    alpha = TARGET_RMS / rms_expected

    scaled = rx * alpha
    re_q = np.clip(np.round(scaled.real * levels), -levels, levels) / levels
    im_q = np.clip(np.round(scaled.imag * levels), -levels, levels) / levels
    return (re_q + 1j * im_q) / alpha  # restore original scale


def simulate_packet(N0: float, bits: int, rng: np.random.Generator):
    """
    Simulate one packet end-to-end through the non-FFT path.

    Returns (b_tx, b_rx) or None if packet is skipped.
    """
    # --- Channel coefficients (Rayleigh, independent per branch) ---
    h = np.array([rayleigh_coefficients(1, pll_phase_random=True)[0] for _ in range(NR)])
    # h shape: (NR,) complex

    # --- Generate preamble + payload samples ---
    preamble = make_preamble(M, N_PREAMBLE)      # (N_PREAMBLE*M,)
    b_tx = rng.integers(0, M)
    payload = modulate(b_tx, M)                   # (M,)
    tx = np.concatenate([preamble, payload])       # (N_PREAMBLE*M + M,)
    N_total = len(tx)

    noise_std = np.sqrt(N0 / 2)
    rx = np.zeros((NR, N_total), dtype=complex)
    for j in range(NR):
        noise = noise_std * (rng.standard_normal((N_total,)) + 1j * rng.standard_normal((N_total,)))
        rx[j] = h[j] * tx + noise

    # --- Quantize (decimator output model) ---
    rx_q = quantize_fixed_agc(rx, bits, N0)

    # --- Training accumulator on quantized preamble ---
    Z_j, n_acc, E_ref = training_accumulate(
        rx_q,
        sc_lock_sample=SC_LOCK_SAMPLE,
        timing_ref=TIMING_REF,
        M=M,
        ref_sel=REF_SEL,
    )

    if n_acc == 0 or E_ref == 0:
        return None

    # --- Compute MRC weights ---
    w = compute_weights(Z_j, mode="mrc", sf=SF, E_ref=E_ref)

    # --- Combine quantized payload ---
    payload_start = N_PREAMBLE * M
    rx_payload = rx_q[:, payload_start:]
    y = nonfft_combine(rx_payload, w)

    # --- Demodulate ---
    b_rx = demodulate(y)
    return b_tx, b_rx


def run_sweep(snr_db_range, bit_widths, n_packets=2000):
    rng = np.random.default_rng(42)

    print(f"\nBit-width sweep: SF={SF}, NR={NR}, {n_packets} packets per point")
    print(f"Quantization model: fixed AGC, TARGET_RMS={TARGET_RMS} (-12 dBFS)")
    print(f"Training: SC lock assumed at {SC_LOCK_SAMPLE} samples, N_acc≈{8*M - SC_LOCK_SAMPLE}")
    print()

    header = f"{'SNR(dB)':>8}" + "".join(f"  {'float':>10}" if b == 0 else f"  {b:>7}b-BER" for b in bit_widths)
    print(header)
    print("-" * len(header))

    for snr_db in snr_db_range:
        N0 = 10 ** (-snr_db / 10)
        row = f"{snr_db:>8.1f}"

        for bits in bit_widths:
            n_err = n_sym = 0
            for _ in range(n_packets):
                result = simulate_packet(N0, bits, rng)
                if result is None:
                    continue
                b_tx, b_rx = result
                n_err += bin(b_tx ^ b_rx).count('1')
                n_sym += SF
            ber = n_err / n_sym if n_sym > 0 else float('nan')
            label = "float" if bits == 0 else f"{bits}b"
            row += f"  {ber:>10.4e}"

        print(row)


if __name__ == "__main__":
    # SNR range: -10 to +10 dB in 2 dB steps
    # At low SNR: all paths show same high BER (thermal-noise limited)
    # At high SNR: degraded paths show floor above float
    snr_range = np.arange(-10, 12, 2, dtype=float)
    bit_widths = [0, 12, 8, 6]   # 0 = float reference

    run_sweep(snr_range, bit_widths, n_packets=2000)
