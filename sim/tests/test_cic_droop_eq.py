"""
Current half-band decimator response tests.

The old contents of this file tested the removed CIC-only 2-tap droop equalizer.
The active RTL is fixed R=64: CIC-3 R=16 followed by two integer half-band
filters, so these tests now pin the current passband behavior instead.
"""

import numpy as np

from sim.models.decimator import DECIMATION_RATIO, FS_ADC, FS_OUT, SigmaDeltaDecimator

AMP = 0.4


def make_sd_bitstream(freq_hz: float, amp: float, n: int) -> np.ndarray:
    t = np.arange(n) / FS_ADC
    signal = amp * np.sin(2 * np.pi * freq_hz * t)
    out = np.empty(n)
    err = 0.0
    for i in range(n):
        q = 1.0 if (signal[i] + err) >= 0 else -1.0
        err += signal[i] - q
        out[i] = q
    return out + 0j


def measure_amplitude(output: np.ndarray, freq_hz: float, burn_in: int = 40) -> float:
    x = output[burn_in:].real
    n = len(x)
    t = np.arange(n) / FS_OUT
    return 2 * abs(np.sum(x * np.exp(-2j * np.pi * freq_hz * t))) / n


def run_tone(freq_hz: float, n_out: int = 1200) -> float:
    bits = make_sd_bitstream(freq_hz, AMP, DECIMATION_RATIO * n_out)
    out = SigmaDeltaDecimator().process(bits)
    return float(measure_amplitude(out, freq_hz) / AMP)


def test_halfband_passband_flat_to_250k_nyquist_half():
    for freq in [10e3, 31.25e3, 62.5e3, 100e3, 125e3]:
        ratio = run_tone(freq)
        ratio_db = 20 * np.log10(max(ratio, 1e-12))
        assert -0.8 < ratio_db < 0.5, f"{freq/1e3:.1f} kHz response {ratio_db:.2f} dB"


def test_current_model_has_no_removed_droop_eq_option():
    try:
        SigmaDeltaDecimator(droop_eq=True)
    except TypeError:
        return
    raise AssertionError("removed CIC droop_eq option should not be accepted")


if __name__ == "__main__":
    test_halfband_passband_flat_to_250k_nyquist_half()
    test_current_model_has_no_removed_droop_eq_option()
    print("Current half-band decimator response tests passed")
