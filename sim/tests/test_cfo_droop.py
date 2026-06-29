"""
CFO sensitivity regression for the current fixed R=64 half-band decimator.

The previous version compared removed CIC-only R=256/R=128 operating points. The
active RTL always outputs 500 kS/s and uses BW_CFG only to select sample_shift.
These tests make sure the current half-band path preserves LoRa dechirp peak
amplitude under moderate CFO for both supported bandwidths.
"""

import numpy as np

from sim.models.decimator import DECIMATION_RATIO, FS_ADC, SigmaDeltaDecimator

SF = 7
AMP = 0.4


def sigma_delta_adc(x: np.ndarray) -> np.ndarray:
    out = np.empty(x.size, dtype=np.complex128)
    er = ei = 0.0
    for n, sample in enumerate(x):
        ur = sample.real + er
        qr = 1.0 if ur >= 0.0 else -1.0
        er = ur - qr
        ui = sample.imag + ei
        qi = 1.0 if ui >= 0.0 else -1.0
        ei = ui - qi
        out[n] = qr + 1j * qi
    return out


def apply_cfo(signal: np.ndarray, cfo_hz: float) -> np.ndarray:
    n = np.arange(signal.size)
    return signal * np.exp(1j * 2 * np.pi * cfo_hz * n / FS_ADC)


def chirp_symbol(symbol: int, m: int) -> np.ndarray:
    n = np.arange(m)
    return np.exp(1j * np.pi * (2 * symbol * n + n**2) / m)


def dechirp_peak(rx: np.ndarray, m: int) -> float:
    n = np.arange(m)
    dechirped = rx[:m] * np.exp(-1j * np.pi * n**2 / m)
    return float(np.max(np.abs(np.fft.fft(dechirped)))) / m


def run_symbol_peak(bw_hz: float, cfo_hz: float, symbol: int = 17) -> float:
    dec = SigmaDeltaDecimator(bw_hz=bw_hz)
    m = dec.samples_per_symbol(SF)
    base = AMP * chirp_symbol(symbol % m, m)
    adc = np.repeat(base, DECIMATION_RATIO)
    bits = sigma_delta_adc(apply_cfo(adc, cfo_hz))
    out = dec.process(bits) * (1.0 / AMP)
    return dechirp_peak(out, m)


def test_cfo_quarter_bw_keeps_peak_for_bw250():
    peak0 = run_symbol_peak(250e3, 0.0)
    peak = run_symbol_peak(250e3, 0.25 * 250e3)
    assert peak / peak0 > 0.72


def test_cfo_quarter_bw_keeps_peak_for_bw125():
    peak0 = run_symbol_peak(125e3, 0.0)
    peak = run_symbol_peak(125e3, 0.25 * 125e3)
    assert peak / peak0 > 0.78


def test_sample_shift_changes_symbol_length_not_decimation_ratio():
    d250 = SigmaDeltaDecimator(bw_hz=250e3)
    d125 = SigmaDeltaDecimator(bw_hz=125e3)
    assert d250.ratio == d125.ratio == 64
    assert d250.samples_per_symbol(SF) == 256
    assert d125.samples_per_symbol(SF) == 512


if __name__ == "__main__":
    test_cfo_quarter_bw_keeps_peak_for_bw250()
    test_cfo_quarter_bw_keeps_peak_for_bw125()
    test_sample_shift_changes_symbol_length_not_decimation_ratio()
    print("Current CFO/half-band decimator tests passed")
