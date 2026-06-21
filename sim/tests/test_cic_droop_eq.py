"""
test_cic_droop_eq.py — verify 2-tap CIC-3 droop equalizer in SigmaDeltaDecimator.

Tests amplitude ratio (output/input) at mid-band and near-edge frequencies:
  31.25 kHz: CIC-3 R=128 droop -0.67 dB; with EQ expect +0.27 dB
  50.00 kHz: CIC-3 R=128 droop -1.73 dB; with EQ expect +0.22 dB
  62.50 kHz: CIC-3 R=128 droop -2.73 dB; with EQ expect -0.13 dB

PASS: EQ amplitude ratio > 0.97 at all test frequencies.
FAIL: without EQ, 50 kHz → 0.82 and 62.5 kHz → 0.73.
"""

import numpy as np
import pytest
from sim.models.decimator import SigmaDeltaDecimator, FS_ADC

FS   = FS_ADC        # 32 MHz
R    = 128           # decimation ratio → 250 kHz output
AMP  = 64 / 127     # -6 dBFS in normalised ±1 units


def make_sd_bitstream(freq_hz: float, amp: float, n: int, fs: float = FS) -> np.ndarray:
    """1st-order ΣΔ encode a real sine at freq_hz to a ±1 bitstream."""
    t = np.arange(n) / fs
    signal = amp * np.sin(2 * np.pi * freq_hz * t)
    out = np.empty(n)
    err = 0.0
    for i in range(n):
        q = 1.0 if (signal[i] + err) >= 0 else -1.0
        err += signal[i] - q
        out[i] = q
    return out


def measure_amplitude(output: np.ndarray, freq_hz: float, fs_out: float,
                      burn_in: int = 50) -> float:
    """Measure the complex DFT amplitude of freq_hz in a real output sequence."""
    x = output[burn_in:].real
    n = len(x)
    t = np.arange(n) / fs_out
    # one-sided DFT at the exact frequency
    return 2 * abs(np.sum(x * np.exp(-2j * np.pi * freq_hz * t))) / n


def run_tone(freq_hz: float, droop_eq: bool, n_out: int = 600) -> float:
    """Return amplitude ratio (output/input) for a tone at freq_hz."""
    n_bits = R * n_out
    bits   = make_sd_bitstream(freq_hz, AMP, n_bits) + 1j * np.zeros(n_bits)
    dec    = SigmaDeltaDecimator(ratio=R, droop_eq=droop_eq)
    out    = dec.process(bits)
    amp    = measure_amplitude(out, freq_hz, FS / R, burn_in=50)
    return float(amp / AMP)   # normalised to input amplitude


FREQS = [31.25e3, 50e3, 62.5e3]
EXPECTED_NO_EQ_DB  = [-0.67, -1.73, -2.73]   # CIC-3 droop
EXPECTED_WITH_EQ_DB = [+0.27, +0.22, -0.13]  # after 2-tap correction


def test_without_eq_shows_droop():
    """CIC-3 droop is measurable without equalizer."""
    for freq, expected_db in zip(FREQS, EXPECTED_NO_EQ_DB):
        ratio = run_tone(freq, droop_eq=False)
        ratio_db = 20 * np.log10(ratio)
        print(f"  no-EQ  {freq/1e3:5.2f} kHz: {ratio_db:+.2f} dB  (expected {expected_db:+.2f} dB)")
        # Droop should be worse than -0.3 dB for all test frequencies
        assert ratio_db < -0.3, (
            f"Expected CIC-3 droop at {freq/1e3:.2f} kHz, got {ratio_db:.2f} dB")


def test_with_eq_near_flat():
    """2-tap equalizer recovers band-edge amplitude to within ±0.5 dB of flat."""
    for freq, expected_db in zip(FREQS, EXPECTED_WITH_EQ_DB):
        ratio = run_tone(freq, droop_eq=True)
        ratio_db = 20 * np.log10(ratio)
        print(f"  eq-on  {freq/1e3:5.2f} kHz: {ratio_db:+.2f} dB  (expected {expected_db:+.2f} dB)")
        assert ratio > 0.97, (
            f"EQ amplitude ratio {ratio:.4f} at {freq/1e3:.2f} kHz should be > 0.97 "
            f"({ratio_db:.2f} dB)")


def test_dc_unchanged():
    """DC gain must remain 1.0 with equalizer enabled (diff=0 for constant input)."""
    bits = np.ones(R * 200, dtype=complex)
    dec  = SigmaDeltaDecimator(ratio=R, droop_eq=True, output_bits=16)
    out  = dec.process(bits)
    assert np.allclose(out[10:].real, 1.0, atol=0.01), (
        f"DC response with EQ: mean={out[10:].real.mean():.4f}")


def test_eq_improvement_over_no_eq():
    """EQ must improve amplitude at all test frequencies."""
    for freq in FREQS:
        r_plain = run_tone(freq, droop_eq=False)
        r_eq    = run_tone(freq, droop_eq=True)
        assert r_eq > r_plain, (
            f"EQ should improve amplitude at {freq/1e3:.2f} kHz: "
            f"plain={r_plain:.4f} eq={r_eq:.4f}")


if __name__ == "__main__":
    print("=== CIC-3 droop equalizer verification ===\n")
    print("Without equalizer:")
    test_without_eq_shows_droop()
    print("\nWith equalizer:")
    test_with_eq_near_flat()
    print("\nDC response:")
    test_dc_unchanged()
    print("  DC response OK")
    print("\nImprovement check:")
    test_eq_improvement_over_no_eq()
    print("  Improvement confirmed at all frequencies")
    print("\nAll tests PASSED")
