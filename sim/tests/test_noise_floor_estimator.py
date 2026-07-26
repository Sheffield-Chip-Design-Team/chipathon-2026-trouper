"""
Tests for sim/models/weight_generation.py::NoiseFloorEstimator — the
firmware-side per-branch noise floor EMA fed from ZDIAG.

Covers:
  1. Source contract — ZDIAG register units, N_ACC division
  2. Integer EMA behaviour — cold start, convergence, no deadband stall
  3. Near-far guard
  4. Scale contract with the Z_kl pairs (both are bits [31:8])
"""

import numpy as np
import pytest

from sim.models.weight_generation import (
    NoiseFloorEstimator,
    zdiag_from_energy,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _zdiag_for(sigma2_full: np.ndarray, n_acc: int) -> np.ndarray:
    """ZDIAG register value for a given per-sample noise power (full scale)."""
    energy = np.asarray(sigma2_full, dtype=float) * n_acc
    return zdiag_from_energy(energy)


# ---------------------------------------------------------------------------
# 1. Source contract
# ---------------------------------------------------------------------------

def test_zdiag_from_energy_is_upper_24_bits():
    # ZDIAG_k = bits [31:8] of the accumulator (Register Map 0x64-0x6F)
    assert zdiag_from_energy(np.array([1 << 8])) [0] == 1
    assert zdiag_from_energy(np.array([(1 << 8) - 1]))[0] == 0
    assert zdiag_from_energy(np.array([0x12345678]))[0] == 0x123456


def test_estimate_is_zdiag_units_per_sample():
    n_acc = 4096
    zdiag = np.array([1000, 2000, 3000, 4000], dtype=np.int64) * n_acc
    nfe = NoiseFloorEstimator(NR=4)
    assert nfe.update(zdiag, n_acc)
    np.testing.assert_allclose(nfe.estimate, [1000, 2000, 3000, 4000], rtol=1e-6)


def test_full_scale_view_is_256x():
    n_acc = 1024
    nfe = NoiseFloorEstimator(NR=4)
    nfe.update(np.array([512, 512, 512, 512]) * n_acc, n_acc)
    np.testing.assert_allclose(nfe.estimate_full_scale, nfe.estimate * 256.0)


def test_zero_n_acc_is_rejected_not_divided():
    nfe = NoiseFloorEstimator(NR=4)
    assert nfe.update(np.array([1, 2, 3, 4]), 0) is False
    assert nfe.n_updates == 0
    assert nfe.n_rejected == 1


# ---------------------------------------------------------------------------
# 2. Integer EMA behaviour
# ---------------------------------------------------------------------------

def test_cold_start_seeds_rather_than_decays_up():
    """First window must land on the measured value, not alpha * value."""
    n_acc = 2048
    zdiag = np.array([800, 800, 800, 800], dtype=np.int64) * n_acc
    nfe = NoiseFloorEstimator(NR=4, alpha_shift=4)
    nfe.update(zdiag, n_acc)
    np.testing.assert_allclose(nfe.estimate, 800, rtol=1e-6)


def test_ema_converges_to_constant_input():
    n_acc = 2048
    target = 600
    zdiag = np.array([target] * 4, dtype=np.int64) * n_acc
    nfe = NoiseFloorEstimator(NR=4, alpha_shift=4)
    for _ in range(64):
        nfe.update(zdiag, n_acc)
    np.testing.assert_allclose(nfe.estimate, target, rtol=1e-3)


def test_ema_tracks_a_step_without_deadband_stall():
    """
    Integer EMA s += (x-s)>>shift stalls if (x-s) < 2^shift. The Q8 fractional
    state must push that deadband far below one ZDIAG LSB, so a small step is
    still tracked to convergence.
    """
    n_acc = 4096
    nfe = NoiseFloorEstimator(NR=4, alpha_shift=4)
    nfe.update(np.array([500] * 4, dtype=np.int64) * n_acc, n_acc)

    # Step up by 3 ZDIAG units — far smaller than 2^alpha_shift in raw units
    stepped = np.array([503] * 4, dtype=np.int64) * n_acc
    for _ in range(200):
        nfe.update(stepped, n_acc)
    np.testing.assert_allclose(nfe.estimate, 503, rtol=2e-3)


def test_larger_alpha_shift_is_slower():
    n_acc = 4096
    lo = NoiseFloorEstimator(NR=4, alpha_shift=2)
    hi = NoiseFloorEstimator(NR=4, alpha_shift=6)
    seed = np.array([100] * 4, dtype=np.int64) * n_acc
    lo.update(seed, n_acc); hi.update(seed, n_acc)

    stepped = np.array([900] * 4, dtype=np.int64) * n_acc
    for _ in range(5):
        lo.update(stepped, n_acc); hi.update(stepped, n_acc)
    assert lo.estimate[0] > hi.estimate[0]


def test_per_branch_independence():
    n_acc = 4096
    zdiag = np.array([100, 400, 900, 1600], dtype=np.int64) * n_acc
    nfe = NoiseFloorEstimator(NR=4)
    for _ in range(40):
        nfe.update(zdiag, n_acc)
    np.testing.assert_allclose(nfe.estimate, [100, 400, 900, 1600], rtol=1e-3)


def test_state_is_integer():
    """The firmware-visible state must be exactly integer, no float creep."""
    n_acc = 1024
    nfe = NoiseFloorEstimator(NR=4)
    nfe.update(np.array([333] * 4, dtype=np.int64) * n_acc, n_acc)
    assert nfe.estimate_q.dtype == np.int64


# ---------------------------------------------------------------------------
# 3. Near-far guard
# ---------------------------------------------------------------------------

def test_guard_rejects_hot_window_and_leaves_state_untouched():
    n_acc = 4096
    nfe = NoiseFloorEstimator(NR=4, noise_thresh=1000)
    nfe.update(np.array([500] * 4, dtype=np.int64) * n_acc, n_acc)
    before = nfe.estimate.copy()

    hot = np.array([500, 500, 50_000, 500], dtype=np.int64) * n_acc
    assert nfe.update(hot, n_acc) is False
    np.testing.assert_array_equal(nfe.estimate, before)
    assert nfe.n_rejected == 1
    assert nfe.n_updates == 1


def test_guard_disabled_by_default():
    n_acc = 4096
    nfe = NoiseFloorEstimator(NR=4)
    assert nfe.update(np.array([10**6] * 4, dtype=np.int64) * n_acc, n_acc) is True


# ---------------------------------------------------------------------------
# 4. Scale contract with the Z_kl pairs
# ---------------------------------------------------------------------------

def test_estimate_times_nacc_matches_zdiag_scale():
    """
    sigma2 * n_acc must be directly subtractable from a ZDIAG-scale diagonal —
    this is the contract compute_eigvec_nw_fw relies on.
    """
    n_acc = 8192
    sigma2_full = np.array([40.0, 55.0, 61.0, 48.0])
    zdiag = _zdiag_for(sigma2_full, n_acc)

    nfe = NoiseFloorEstimator(NR=4)
    nfe.update(zdiag, n_acc)

    reconstructed = nfe.estimate * n_acc
    np.testing.assert_allclose(reconstructed, zdiag.astype(float), rtol=1e-3)


# ---------------------------------------------------------------------------
# 5. Underflow detection (the sigma2-quantises-to-zero failure, SGE job 3593)
# ---------------------------------------------------------------------------

def test_real_capture_case_resolves_at_q16_but_not_q8():
    """
    The measured job-3593 window: ZDIAG=[11,7,5,4] at n_acc=2048.
    At Q8 three branches floor to zero (partial underflow, unusable);
    the Q16 default resolves all four.
    """
    n_acc = 2048
    zdiag = np.array([11, 7, 5, 4], dtype=np.int64)

    q8 = NoiseFloorEstimator(NR=4, frac_bits=8)
    q8.update(zdiag, n_acc)
    np.testing.assert_array_equal(q8.underflow_mask, [False, True, True, True])
    assert q8.valid is False       # partial underflow -> must not whiten

    q16 = NoiseFloorEstimator(NR=4)          # default frac_bits = 16
    q16.update(zdiag, n_acc)
    assert not np.any(q16.underflow_mask)
    assert q16.valid is True


def test_partial_underflow_is_not_valid():
    """The dangerous case: some branches resolve, others floor to zero."""
    nfe = NoiseFloorEstimator(NR=4, frac_bits=8)
    nfe.update(np.array([11, 7, 5, 4], dtype=np.int64), 2048)
    assert nfe.valid is False


def test_all_branches_resolved_is_valid():
    nfe = NoiseFloorEstimator(NR=4)
    nfe.update(np.array([4000, 3000, 2500, 2000], dtype=np.int64), 2048)
    assert nfe.valid is True


def test_all_branches_underflowed_is_valid():
    """All-zero is a no-op for whitening, so it is not the dangerous case."""
    nfe = NoiseFloorEstimator(NR=4, frac_bits=8)
    nfe.update(np.array([1, 1, 1, 1], dtype=np.int64), 100000)
    assert np.all(nfe.underflow_mask)
    assert nfe.valid is True


def test_not_valid_before_any_update():
    assert NoiseFloorEstimator(NR=4).valid is False


def test_longer_window_alone_does_NOT_fix_underflow():
    """
    Guards a tempting-but-wrong remedy. sigma2 is the ratio ZDIAG_k / n_acc, so
    a longer noise window scales numerator and denominator together and leaves
    the fixed-point resolution untouched. Only more frac_bits helps.
    """
    zd = np.array([11, 7, 5, 4], dtype=np.int64)
    short = NoiseFloorEstimator(NR=4, frac_bits=8)
    short.update(zd, 2048)

    long = NoiseFloorEstimator(NR=4, frac_bits=8)
    long.update(zd * 16, 2048 * 16)          # 16x window, same noise floor

    np.testing.assert_array_equal(short.underflow_mask, long.underflow_mask)
    assert long.valid is False
