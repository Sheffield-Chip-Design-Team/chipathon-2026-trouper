"""Stress tests for the all-pairs training accumulator.

The active RTL estimates branch-to-branch channel products with
    Z_kl = sum raw_k[n] * conj(raw_l[n])
so the LoRa symbol content cancels whenever all branches observe the same
constant-envelope waveform.  These tests separate that intended invariance from
cases that violate the common-waveform/static-channel assumptions.
"""

import numpy as np

from sim.models.lora import modulate, upchirp
from sim.models.training_accumulator import training_accumulate_allpairs


M = 128
NR = 4
H = np.array([1.0 + 0.0j, 0.72 + 0.31j, -0.24 + 0.88j, 0.43 - 0.52j])


def _packet(symbols: list[int]) -> np.ndarray:
    return np.concatenate([modulate(int(b % M), M) for b in symbols])


def _downchirp() -> np.ndarray:
    return np.conj(upchirp(M))


def _rx_static(h: np.ndarray, s: np.ndarray) -> np.ndarray:
    return h[:, None] * s[None, :]


def _znorm(rx: np.ndarray, n_sym: int | None = None, packet_end: int | None = None) -> tuple[np.ndarray, int]:
    if packet_end is None:
        Z, _, n = training_accumulate_allpairs(
            rx, sc_lock_sample=0, timing_ref=0, M=M, preamble_len=n_sym
        )
    else:
        Z, _, n = training_accumulate_allpairs(
            rx, sc_lock_sample=0, timing_ref=0, M=M, packet_end=packet_end
        )
    return Z / max(n, 1), n


def _offdiag_rms_err(Zn: np.ndarray, expected: np.ndarray) -> float:
    mask = ~np.eye(expected.shape[0], dtype=bool)
    denom = np.maximum(np.abs(expected[mask]), 1e-12)
    return float(np.sqrt(np.mean(np.abs((Zn[mask] - expected[mask]) / denom) ** 2)))


def test_allpairs_is_unbiased_across_arbitrary_lora_symbols_and_downchirps():
    symbols = [0, 17, 63, 5, 91, 2, 127, 44, 8, 73, 11, 39]
    s = np.concatenate([_packet(symbols[:6]), _downchirp(), _downchirp(), _packet(symbols[6:])])
    rx = _rx_static(H, s)

    Zn, n = _znorm(rx, n_sym=len(s) // M)
    expected = np.outer(H, np.conj(H))

    assert n == len(s)
    np.testing.assert_allclose(Zn, expected, atol=1e-12, rtol=1e-12)


def test_common_phase_drift_cancels_but_branch_phase_drift_degrades_estimate():
    s = _packet([3, 22, 80, 4, 19, 71, 12, 45, 101, 6, 38, 90])
    n = np.arange(len(s))
    expected = np.outer(H, np.conj(H))

    common_phase = np.exp(1j * 1.2 * n / len(s))
    rx_common = _rx_static(H, s * common_phase)
    Zn_common, _ = _znorm(rx_common, n_sym=len(s) // M)
    assert _offdiag_rms_err(Zn_common, expected) < 1e-12

    drift_rates = np.array([0.0, 0.6, -0.35, 0.25])
    branch_phase = np.exp(1j * drift_rates[:, None] * n[None, :] / len(s))
    rx_branch = _rx_static(H, s) * branch_phase
    Zn_branch, _ = _znorm(rx_branch, n_sym=len(s) // M)

    assert _offdiag_rms_err(Zn_branch, expected) > 0.05


def test_branch_gain_step_biases_correlation_toward_time_average_channel():
    s = _packet([9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20])
    rx = _rx_static(H, s)
    half = rx.shape[1] // 2
    rx[2, half:] *= 0.45

    Zn, _ = _znorm(rx, n_sym=len(s) // M)
    expected_static = np.outer(H, np.conj(H))

    assert abs(Zn[2, 2] / expected_static[2, 2] - 0.5 * (1.0 + 0.45**2)) < 1e-12
    assert _offdiag_rms_err(Zn, expected_static) > 0.15


def test_branch_local_interferer_inflates_diagonal_power():
    rng = np.random.default_rng(7)
    s = _packet([1, 5, 9, 13, 17, 21, 25, 29, 33, 37, 41, 45])
    rx = _rx_static(H, s)
    expected = np.outer(H, np.conj(H))
    clean, _ = _znorm(rx, n_sym=len(s) // M)

    # A branch-local random-phase interferer averages out of cross-products with
    # other branches, but it still pollutes Z_kk.  That matters because the
    # firmware eigvec path sees the diagonal too unless noise whitening removes it.
    interferer = 0.9 * np.exp(1j * rng.uniform(0, 2 * np.pi, rx.shape[1]))
    rx_bad = rx.copy()
    rx_bad[1] += interferer
    bad, _ = _znorm(rx_bad, n_sym=len(s) // M)

    assert _offdiag_rms_err(clean, expected) < 1e-12
    assert _offdiag_rms_err(bad, expected) < 0.05
    assert bad[1, 1].real > clean[1, 1].real + 0.65


def test_branch_clipping_biases_estimate():
    s = _packet([2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24])
    rx = 80.0 * _rx_static(H, s)
    clean, _ = _znorm(rx, n_sym=len(s) // M)

    clipped = rx.copy()
    clipped[3] = np.clip(clipped[3].real, -30, 30) + 1j * np.clip(clipped[3].imag, -30, 30)
    bad, _ = _znorm(clipped, n_sym=len(s) // M)

    expected_clean = np.outer(80.0 * H, np.conj(80.0 * H))
    assert _offdiag_rms_err(clean, expected_clean) < 1e-12
    assert abs(bad[3, 3]) < 0.5 * abs(clean[3, 3])
    assert _offdiag_rms_err(bad, expected_clean) > 0.20


def test_window_overrun_into_noise_dilutes_offdiagonal_correlation():
    rng = np.random.default_rng(11)
    packet = _packet([0, 3, 6, 9, 12, 15, 18, 21])
    rx_packet = _rx_static(H, packet)
    noise_only = 0.8 * (rng.standard_normal((NR, 4 * M)) + 1j * rng.standard_normal((NR, 4 * M)))
    rx = np.concatenate([rx_packet, noise_only], axis=1)

    expected = np.outer(H, np.conj(H))
    clean, n_clean = _znorm(rx, n_sym=len(packet) // M)
    overrun, n_overrun = _znorm(rx, packet_end=rx.shape[1] - 1)

    dilution = n_clean / n_overrun
    mask = ~np.eye(NR, dtype=bool)
    measured_ratio = np.mean(np.abs(overrun[mask])) / np.mean(np.abs(clean[mask]))

    assert _offdiag_rms_err(clean, expected) < 1e-12
    assert n_clean == 8 * M
    assert n_overrun == 12 * M
    assert abs(measured_ratio - dilution) < 0.08
