"""
Tests for sim/models/eigvec_fw.py::compute_eigvec_nw_fw — noise-whitened
fixed-point eigenvector weights.

Covers:
  1. Degenerate / guard behaviour
  2. Matched-noise case — whitening must be near-neutral in direction
  3. Unequal-noise case — whitening must beat the unwhitened path
  4. Agreement with the float reference
  5. Interop with NoiseFloorEstimator (the ZDIAG unit contract)
"""

import numpy as np
import pytest

from sim.models.eigvec_fw import compute_eigvec_fw, compute_eigvec_nw_fw
from sim.models.training_accumulator import compute_eigvec_weights
from sim.models.weight_generation import NoiseFloorEstimator, zdiag_from_energy


NR = 4
SIGNAL_AMP = 64.0


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_Z(h, n_acc, sigma2_per_branch):
    """Hermitian Z for channel h with per-branch noise, at int8-ish scale."""
    h = np.asarray(h, dtype=complex)
    h = h / np.linalg.norm(h) * SIGNAL_AMP
    s2 = np.asarray(sigma2_per_branch, dtype=float)
    return n_acc * (np.outer(h, np.conj(h)) + np.diag(s2))


def _sigma2_for(sigma2_full):
    """sigma2 at the same scale as the Z built by _make_Z (full accumulator
    scale), matching compute_eigvec_nw_fw's 'same units as Z_matrix' contract."""
    return np.asarray(sigma2_full, dtype=float)


def _angle_deg(a, b):
    a = a / np.linalg.norm(a)
    b = b / np.linalg.norm(b)
    return float(np.degrees(np.arccos(np.clip(abs(np.dot(np.conj(a), b)), 0.0, 1.0))))


def _align_err(w, h):
    """Angle between computed weights and the ideal conj(h) direction."""
    return _angle_deg(w, np.conj(np.asarray(h, dtype=complex)))


# ---------------------------------------------------------------------------
# 1. Degenerate / guard behaviour
# ---------------------------------------------------------------------------

def test_zero_n_acc_returns_zeros():
    Z = _make_Z([1, 1, 1, 1], 1024, [10] * NR)
    w = compute_eigvec_nw_fw(Z, 0, _sigma2_for([10] * NR))
    assert np.allclose(w, 0)


def test_zero_sigma_matches_unwhitened_exactly():
    n_acc = 4096
    Z = _make_Z([1, 0.6, 0.3, 0.9], n_acc, [0.0] * NR)
    a = compute_eigvec_fw(Z, n_acc)
    b = compute_eigvec_nw_fw(Z, n_acc, np.zeros(NR))
    np.testing.assert_array_equal(a, b)


def test_over_subtraction_is_clamped_not_negative():
    """A wildly oversized sigma2 must not produce garbage or negative diagonals."""
    n_acc = 4096
    Z = _make_Z([1, 0.8, 0.5, 0.2], n_acc, [5.0] * NR)
    huge = _sigma2_for([10_000.0] * NR)
    w = compute_eigvec_nw_fw(Z, n_acc, huge)
    assert np.all(np.isfinite(w.real)) and np.all(np.isfinite(w.imag))
    assert np.max(np.abs(w)) > 0        # falls back rather than collapsing to zero


def test_full_cancellation_falls_back_to_raw_diagonal():
    """If whitening zeroes every diagonal, keep the raw one."""
    n_acc = 2048
    Z = _make_Z([1, 1, 1, 1], n_acc, [4.0] * NR)
    over = np.array([Z[k, k].real for k in range(NR)]) / n_acc * 10
    w = compute_eigvec_nw_fw(Z, n_acc, over)
    assert np.max(np.abs(w)) > 0


# ---------------------------------------------------------------------------
# 2. Matched noise — whitening is near-neutral in direction
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("seed", [0, 1, 2, 3, 4])
def test_matched_noise_whitening_is_near_neutral(seed):
    """
    With equal sigma2 the pedestal is a multiple of I, which does not move the
    eigenvector. Whitened and unwhitened directions must stay close.
    """
    rng = np.random.default_rng(seed)
    n_acc = 8192
    h = rng.normal(size=NR) + 1j * rng.normal(size=NR)
    s2 = 8.0
    Z = _make_Z(h, n_acc, [s2] * NR)

    w_plain = compute_eigvec_fw(Z, n_acc)
    w_nw = compute_eigvec_nw_fw(Z, n_acc, _sigma2_for([s2] * NR))
    assert _angle_deg(w_plain, w_nw) < 5.0


# ---------------------------------------------------------------------------
# 3. Unequal noise — the case whitening exists for
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("seed", [0, 1, 2, 3, 4, 5, 6, 7])
def test_unequal_noise_whitening_improves_alignment(seed):
    """
    Branch 0 is 10 dB noisier. The raw-Z eigenvector tilts toward it; the
    whitened one should align better with conj(h).
    """
    rng = np.random.default_rng(100 + seed)
    n_acc = 8192
    h = rng.normal(size=NR) + 1j * rng.normal(size=NR)
    base = 12.0
    s2 = np.array([base * 10, base, base, base])
    Z = _make_Z(h, n_acc, s2)

    h_scaled = np.asarray(h, dtype=complex)
    h_scaled = h_scaled / np.linalg.norm(h_scaled) * SIGNAL_AMP

    err_plain = _align_err(compute_eigvec_fw(Z, n_acc), h_scaled)
    err_nw = _align_err(compute_eigvec_nw_fw(Z, n_acc, _sigma2_for(s2)), h_scaled)
    assert err_nw <= err_plain + 1e-9


@pytest.mark.parametrize("base,min_ratio", [
    (12.0,   2.0),    # high effective SNR — both errors sub-degree
    (400.0,  2.0),    # low effective SNR — errors are degrees, the case that matters
])
def test_unequal_noise_mean_improvement_is_material(base, min_ratio):
    """
    Aggregate over many channels: whitening should be a clear net win.

    Asserted as a ratio, not an absolute angle — at high effective SNR both
    paths are already sub-degree, so an absolute threshold would say nothing.
    """
    rng = np.random.default_rng(7)
    n_acc = 8192
    s2 = np.array([base * 10, base, base, base])

    errs_plain, errs_nw = [], []
    for _ in range(200):
        h = rng.normal(size=NR) + 1j * rng.normal(size=NR)
        Z = _make_Z(h, n_acc, s2)
        h_scaled = h / np.linalg.norm(h) * SIGNAL_AMP
        errs_plain.append(_align_err(compute_eigvec_fw(Z, n_acc), h_scaled))
        errs_nw.append(_align_err(
            compute_eigvec_nw_fw(Z, n_acc, _sigma2_for(s2)), h_scaled))

    m_plain, m_nw = np.mean(errs_plain), np.mean(errs_nw)
    assert m_nw * min_ratio < m_plain, (
        f"base={base}: plain={m_plain:.3f}deg nw={m_nw:.3f}deg "
        f"(ratio {m_plain/max(m_nw,1e-9):.1f}x)")


# ---------------------------------------------------------------------------
# 4. Agreement with the float reference
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("seed", [0, 1, 2, 3, 4])
def test_matches_float_whitened_reference(seed):
    """Fixed-point whitened path should track eigh(Z - diag(sigma2*n_acc))."""
    rng = np.random.default_rng(200 + seed)
    n_acc = 8192
    base = 12.0
    s2 = np.array([base * 10, base, base, base])
    h = rng.normal(size=NR) + 1j * rng.normal(size=NR)
    Z = _make_Z(h, n_acc, s2)

    w_fw = compute_eigvec_nw_fw(Z, n_acc, _sigma2_for(s2))

    Z_w = Z - np.diag(s2 * n_acc)
    w_float = compute_eigvec_weights(Z_w)

    assert _angle_deg(w_fw, w_float) < 10.0


# ---------------------------------------------------------------------------
# 5. Interop with NoiseFloorEstimator
# ---------------------------------------------------------------------------

def test_estimator_output_feeds_whitening_directly():
    """
    NoiseFloorEstimator.estimate must be consumable by compute_eigvec_nw_fw
    with no scale conversion — both live in ZDIAG register units.
    """
    n_acc = 8192
    base = 12.0
    s2_full = np.array([base * 10, base, base, base])

    # A noise-only window: ZDIAG_k = sigma2_k * n_acc, register-truncated.
    nfe = NoiseFloorEstimator(NR=NR)
    nfe.update(zdiag_from_energy(s2_full * n_acc), n_acc)

    rng = np.random.default_rng(11)
    h = rng.normal(size=NR) + 1j * rng.normal(size=NR)
    Z_full = _make_Z(h, n_acc, s2_full)
    h_scaled = h / np.linalg.norm(h) * SIGNAL_AMP

    # Mirror the RTL read path: BOTH Z_kl and ZDIAG come back as bits [31:8],
    # so the whole matrix is in register units -- the same units as
    # NoiseFloorEstimator.estimate. No scale alignment anywhere.
    Z_reg = np.zeros((NR, NR), dtype=complex)
    for k in range(NR):
        for l in range(NR):
            Z_reg[k, l] = complex(int(Z_full[k, l].real) >> 8,
                                  int(Z_full[k, l].imag) >> 8)
        Z_reg[k, k] = complex(int(Z_full[k, k].real) >> 8, 0.0)

    err_plain = _align_err(compute_eigvec_fw(Z_reg, n_acc), h_scaled)
    err_nw = _align_err(compute_eigvec_nw_fw(Z_reg, n_acc, nfe.estimate), h_scaled)
    assert err_nw < err_plain


# ---------------------------------------------------------------------------
# 6. strict mode — partially underflowed sigma2 must be refused
# ---------------------------------------------------------------------------

def test_partial_underflow_raises_by_default():
    n_acc = 8192
    Z = _make_Z([1, 0.7, 0.5, 0.35], n_acc, [10.0] * NR)
    with pytest.raises(ValueError, match="partially underflowed"):
        compute_eigvec_nw_fw(Z, n_acc, np.array([5.0, 0.0, 0.0, 0.0]))


def test_partial_underflow_can_be_overridden():
    n_acc = 8192
    Z = _make_Z([1, 0.7, 0.5, 0.35], n_acc, [10.0] * NR)
    w = compute_eigvec_nw_fw(Z, n_acc, np.array([5.0, 0.0, 0.0, 0.0]), strict=False)
    assert np.max(np.abs(w)) > 0


def test_all_zero_sigma_is_not_rejected():
    n_acc = 8192
    Z = _make_Z([1, 0.7, 0.5, 0.35], n_acc, [10.0] * NR)
    np.testing.assert_array_equal(
        compute_eigvec_nw_fw(Z, n_acc, np.zeros(NR)), compute_eigvec_fw(Z, n_acc))


def test_estimator_valid_gates_a_partially_underflowed_estimate():
    """The gating contract: an estimator reporting invalid must not be fed to
    the whitened path. Forced with frac_bits=8, which is what made the real
    job-3593 window (ZDIAG=[11,7,5,4] @ n_acc=2048) partially underflow; the
    Q16 default now resolves that particular case."""
    n_acc_noise, n_acc = 2048, 1791
    nfe = NoiseFloorEstimator(NR=NR, frac_bits=8)
    nfe.update(np.array([11, 7, 5, 4], dtype=np.int64), n_acc_noise)
    assert nfe.valid is False

    Z = _make_Z([1, 0.7, 0.5, 0.35], n_acc, [0.5] * NR)
    with pytest.raises(ValueError):
        compute_eigvec_nw_fw(Z, n_acc, nfe.estimate)
    # Gated path: fall back cleanly.
    w = compute_eigvec_fw(Z, n_acc) if not nfe.valid else None
    assert w is not None and np.max(np.abs(w)) > 0


# ---------------------------------------------------------------------------
# 7. float reference parity
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("seed", [0, 1, 2, 3])
def test_fixed_point_tracks_new_float_nw_reference(seed):
    from sim.models.training_accumulator import compute_eigvec_nw_weights
    rng = np.random.default_rng(300 + seed)
    n_acc = 8192
    base = 12.0
    s2 = np.array([base * 10, base, base, base])
    h = rng.normal(size=NR) + 1j * rng.normal(size=NR)
    Z = _make_Z(h, n_acc, s2)
    w_fw = compute_eigvec_nw_fw(Z, n_acc, _sigma2_for(s2))
    w_float = compute_eigvec_nw_weights(Z, s2, n_acc)
    assert _angle_deg(w_fw, w_float) < 10.0


# ---------------------------------------------------------------------------
# 8. Full SNR weighting (compute_eigvec_snr_weights) vs de-biasing only
# ---------------------------------------------------------------------------

def _rel(w):
    return np.abs(w) / np.abs(w).max()


def test_snr_weighting_hits_the_unequal_noise_optimum():
    """
    Identical channel, ant0 10x noisier. Optimum is D^-1 h = [0.1, 1, 1, 1].
    Pedestal subtraction alone returns the EQUAL-noise answer [1,1,1,1]; the
    full D^-1/2 transform must reach the true optimum.
    """
    from sim.models.training_accumulator import (
        compute_eigvec_nw_weights, compute_eigvec_snr_weights)
    n_acc = 1000
    h = np.array([1.0, 1.0, 1.0, 1.0], dtype=complex)
    s2 = np.array([50.0, 5.0, 5.0, 5.0])
    Z = n_acc * (np.outer(h, np.conj(h)) + np.diag(s2))

    w_debias = compute_eigvec_nw_weights(Z, s2, n_acc)
    w_snr = compute_eigvec_snr_weights(Z, s2, n_acc)
    w_opt = np.linalg.inv(np.diag(s2)) @ h

    np.testing.assert_allclose(_rel(w_debias), [1, 1, 1, 1], atol=0.02)
    np.testing.assert_allclose(_rel(w_snr), _rel(w_opt), atol=0.02)


@pytest.mark.parametrize("seed", [0, 1, 2, 3, 4])
def test_snr_weighting_matches_optimum_for_random_channels(seed):
    from sim.models.training_accumulator import compute_eigvec_snr_weights
    rng = np.random.default_rng(400 + seed)
    n_acc = 4096
    h = rng.normal(size=NR) + 1j * rng.normal(size=NR)
    s2 = np.array([40.0, 8.0, 15.0, 5.0])
    Z = n_acc * (np.outer(h, np.conj(h)) + np.diag(s2))

    w = compute_eigvec_snr_weights(Z, s2, n_acc)
    w_opt = np.conj(np.linalg.inv(np.diag(s2)) @ h)
    assert _angle_deg(w, w_opt) < 3.0


def test_snr_weighting_equals_debias_when_noise_is_matched():
    """With equal sigma2, D^-1/2 is a scalar -> both paths agree in direction."""
    from sim.models.training_accumulator import (
        compute_eigvec_nw_weights, compute_eigvec_snr_weights)
    rng = np.random.default_rng(9)
    n_acc = 4096
    h = rng.normal(size=NR) + 1j * rng.normal(size=NR)
    s2 = np.full(NR, 12.0)
    Z = n_acc * (np.outer(h, np.conj(h)) + np.diag(s2))
    assert _angle_deg(compute_eigvec_nw_weights(Z, s2, n_acc),
                      compute_eigvec_snr_weights(Z, s2, n_acc)) < 2.0


def test_snr_weighting_falls_back_on_degenerate_sigma():
    """A zero sigma2 entry cannot be transformed; must not divide by zero."""
    from sim.models.training_accumulator import compute_eigvec_snr_weights
    n_acc = 4096
    Z = _make_Z([1, 0.7, 0.5, 0.35], n_acc, [10.0] * NR)
    w = compute_eigvec_snr_weights(Z, np.array([0.0, 0.0, 0.0, 0.0]), n_acc)
    assert np.all(np.isfinite(w.real)) and np.max(np.abs(w)) > 0


# ---------------------------------------------------------------------------
# 9. Fixed-point full SNR weighting (compute_eigvec_snrw_fw)
# ---------------------------------------------------------------------------

def test_fp_snr_weighting_reaches_the_optimum():
    from sim.models.eigvec_fw import compute_eigvec_snrw_fw
    n_acc = 1000
    h = np.array([1.0, 1.0, 1.0, 1.0], dtype=complex)
    s2 = np.array([50.0, 5.0, 5.0, 5.0])
    Z = n_acc * (np.outer(h, np.conj(h)) + np.diag(s2))
    w = compute_eigvec_snrw_fw(Z, n_acc, s2)
    w_opt = np.linalg.inv(np.diag(s2)) @ h
    np.testing.assert_allclose(_rel(w), _rel(w_opt), atol=0.03)


@pytest.mark.parametrize("seed", [0, 1, 2, 3, 4, 5])
def test_fp_snr_weighting_tracks_the_float_reference(seed):
    from sim.models.eigvec_fw import compute_eigvec_snrw_fw
    from sim.models.training_accumulator import compute_eigvec_snr_weights
    rng = np.random.default_rng(500 + seed)
    n_acc = 4096
    h = rng.normal(size=NR) + 1j * rng.normal(size=NR)
    s2 = np.array([40.0, 8.0, 15.0, 5.0])
    Z = n_acc * (np.outer(h, np.conj(h)) + np.diag(s2))
    assert _angle_deg(compute_eigvec_snrw_fw(Z, n_acc, s2),
                      compute_eigvec_snr_weights(Z, s2, n_acc)) < 5.0


def test_fp_snr_weighting_beats_debias_under_imbalance():
    """The whole point: SNR weighting should align better than de-biasing."""
    from sim.models.eigvec_fw import compute_eigvec_snrw_fw
    rng = np.random.default_rng(31)
    n_acc = 4096
    s2 = np.array([120.0, 12.0, 12.0, 12.0])
    errs_deb, errs_snr = [], []
    for _ in range(100):
        h = rng.normal(size=NR) + 1j * rng.normal(size=NR)
        Z = n_acc * (np.outer(h, np.conj(h)) + np.diag(s2))
        w_opt = np.conj(np.linalg.inv(np.diag(s2)) @ h)
        errs_deb.append(_angle_deg(compute_eigvec_nw_fw(Z, n_acc, s2), w_opt))
        errs_snr.append(_angle_deg(compute_eigvec_snrw_fw(Z, n_acc, s2), w_opt))
    assert np.mean(errs_snr) < np.mean(errs_deb) / 2


def test_fp_snr_weighting_equals_debias_when_noise_matched():
    from sim.models.eigvec_fw import compute_eigvec_snrw_fw
    rng = np.random.default_rng(17)
    n_acc = 4096
    s2 = np.full(NR, 10.0)
    h = rng.normal(size=NR) + 1j * rng.normal(size=NR)
    Z = n_acc * (np.outer(h, np.conj(h)) + np.diag(s2))
    assert _angle_deg(compute_eigvec_snrw_fw(Z, n_acc, s2),
                      compute_eigvec_nw_fw(Z, n_acc, s2)) < 3.0


def test_fp_snr_weighting_falls_back_on_zero_sigma():
    """D^-1/2 undefined -> must degrade to de-biasing, not divide by zero."""
    from sim.models.eigvec_fw import compute_eigvec_snrw_fw
    n_acc = 4096
    Z = _make_Z([1, 0.7, 0.5, 0.35], n_acc, [10.0] * NR)
    w = compute_eigvec_snrw_fw(Z, n_acc, np.zeros(NR))
    np.testing.assert_array_equal(w, compute_eigvec_fw(Z, n_acc))


def test_fp_snr_weighting_stays_in_int32():
    """G is applied to renormalised operands; g*v must not exceed int32."""
    from sim.models.eigvec_fw import compute_eigvec_snrw_fw, _G_BITS, _SCALE_BITS
    assert (1 << _SCALE_BITS) * ((1 << _G_BITS) - 1) < 2**31
    n_acc = 131072
    Z = _make_Z([1, 0.9, 0.8, 0.7], n_acc, [1e4, 1e3, 1e3, 1e3])
    w = compute_eigvec_snrw_fw(Z, n_acc, np.array([1e4, 1e3, 1e3, 1e3]))
    assert np.all(np.isfinite(w.real)) and np.max(np.abs(w)) > 0


def test_fp_snr_weighting_needs_no_mulh():
    """
    A' ordering contract: G is applied to the ALREADY-NORMALISED matrix, so
    every product fits in int32 and only MUL (40 cyc on picorv32) is needed --
    never MULH (72 cyc). Pinning this stops a refactor from silently moving the
    scaling back before the >>sh normalisation, which would need a 32x32->64
    product and cost ~2.7x more cycles on the target core.
    """
    from sim.models.eigvec_fw import _G_BITS, _SCALE_BITS
    max_entry = (1 << _SCALE_BITS)          # normalised matrix bound
    max_g = (1 << _G_BITS) - 1
    assert max_entry * max_g < 2**31, "entry * g must fit int32 (single MUL)"
    assert max_g * max_g < 2**31, "g * g must fit int32 (single MUL)"


def test_snrw_register_units_matches_picorv32_trace_job_3612():
    """Pin the 24-bit register-interface arithmetic against real PicoRV32.

    This vector uses a completed unequal-noise window (N_ACC=1024) followed by
    a signal window (N_ACC=512). Job 3612 ran the matching C firmware on the
    project's rv32emc PicoRV32 and returned the expected Q1.15 pairs.
    """
    from sim.models.eigvec_fw import compute_eigvec_snrw_fw

    od = [0x31A240, -0x0022C1, 0x28FF10, 0x15AB00, -0x001D33, 0x0F4208,
          0x26B000, 0x19C420, 0x12AA00, -0x000E71, 0x21D500, 0x113340]
    diag = [0x5A2180, 0x4C9340, 0x611008, 0x3F0477]
    pairs = [(0, 1), (0, 2), (0, 3), (1, 2), (1, 3), (2, 3)]
    z = np.zeros((NR, NR), dtype=complex)
    for i, (k, l) in enumerate(pairs):
        z[k, l] = complex(od[2*i], od[2*i + 1])
        z[l, k] = np.conj(z[k, l])
    for k in range(NR):
        z[k, k] = diag[k]

    # ZDIAG noise samples [4096, 1024, 256, 64] over 1024 samples.
    w = compute_eigvec_snrw_fw(
        z, n_acc=512, sigma2_zdiag=np.array([4.0, 1.0, 0.25, 0.0625]),
        register_units=True,
    )
    got = [(int(x.real * 32768), int(x.imag * 32768)) for x in w]
    assert got == [(169, 12), (448, 653), (4649, 5279), (9069, 32767)]
