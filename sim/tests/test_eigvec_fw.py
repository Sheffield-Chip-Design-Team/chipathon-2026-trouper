"""
Tests for sim/models/eigvec_fw.py — firmware-accurate fixed-point eigenvector
weight computation.

Tests are organised in three tiers:

  1. Unit tests — boundary inputs (zero, identity, rank-1)
  2. Numerical accuracy — compare against the float reference
     (compute_eigvec_weights) on synthetic channel matrices
  3. Fixed-point fidelity — verify int32 overflow bounds hold and that
     ZDIAG truncation is applied correctly
"""

import numpy as np
import pytest

from sim.models.eigvec_fw import compute_eigvec_fw, _norm_shift, _trunc_div
from sim.models.training_accumulator import compute_eigvec_weights


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_rank1_Z(
    h: np.ndarray,
    n_acc: int,
    sigma2: float = 0.0,
    signal_amp: float = 64.0,
) -> np.ndarray:
    """Build the Hermitian Z matrix for a known channel vector h.

    signal_amp scales h to simulate int8-range inputs.  The default 64.0
    gives Z_kk ~ n_acc * 64² * |h_k|² ≈ n_acc * 4096, which places the
    diagonal well above 2^8 for any n_acc >= 1, ensuring the ZDIAG
    hardware register truncation (upper 24 bits) retains meaningful values.
    """
    h = np.asarray(h, dtype=complex)
    h = h / np.linalg.norm(h) * signal_amp   # normalise then scale
    Z = n_acc * (np.outer(h, np.conj(h)) + sigma2 * np.eye(len(h)))
    return Z


def _angle_between(a: np.ndarray, b: np.ndarray) -> float:
    """Angle in degrees between two complex vectors (modulo global phase)."""
    a = a / np.linalg.norm(a)
    b = b / np.linalg.norm(b)
    cos_sim = abs(np.dot(np.conj(a), b))
    return float(np.degrees(np.arccos(np.clip(cos_sim, 0.0, 1.0))))


# ---------------------------------------------------------------------------
# Unit tests — _norm_shift helper
# ---------------------------------------------------------------------------

def test_norm_shift_exact_power_of_two():
    # 4096 = 2^12 > 4095 → needs 1 shift
    assert _norm_shift(4096, 12) == 1

def test_norm_shift_at_threshold():
    # 4095 fits in 12 bits — zero shift needed
    assert _norm_shift(4095, 12) == 0

def test_norm_shift_large():
    # INT32_MAX ≈ 2^31: needs 31 - 12 = 19 shifts
    assert _norm_shift(2**31 - 1, 12) == 19

def test_norm_shift_one():
    assert _norm_shift(1, 12) == 0


# ---------------------------------------------------------------------------
# Unit tests — _trunc_div (C-style truncation toward zero)
# ---------------------------------------------------------------------------

def test_trunc_div_positive():
    assert _trunc_div(7, 2) == 3

def test_trunc_div_negative_numerator():
    # C: -7 / 2 = -3 (truncation), Python floor: -7 // 2 = -4
    assert _trunc_div(-7, 2) == -3

def test_trunc_div_exact():
    assert _trunc_div(32767 * 4096, 4096) == 32767


# ---------------------------------------------------------------------------
# Unit tests — zero and trivial inputs
# ---------------------------------------------------------------------------

def test_zero_n_acc_returns_zeros():
    Z = _make_rank1_Z([1, 1, 1, 1], n_acc=128)
    w = compute_eigvec_fw(Z, n_acc=0)
    assert np.all(w == 0), "n_acc=0 must produce zero weights"
    print("PASS  n_acc=0 → zero weights")


def test_zero_matrix_returns_zeros():
    Z = np.zeros((4, 4), dtype=complex)
    w = compute_eigvec_fw(Z, n_acc=128)
    assert np.all(w == 0), "all-zero Z must produce zero weights"
    print("PASS  zero Z matrix → zero weights")


def test_identity_matrix():
    # Z = I: all eigenvalues equal, eigenvector arbitrary.
    # The algorithm should return a unit-length result without crashing.
    Z = np.eye(4, dtype=complex) * (1 << 20)  # scale to be register-realistic
    w = compute_eigvec_fw(Z, n_acc=128)
    assert w.shape == (4,)
    assert np.linalg.norm(w) > 0, "identity Z should produce non-zero weights"
    print(f"PASS  identity Z → w={w}")


# ---------------------------------------------------------------------------
# Unit tests — output format
# ---------------------------------------------------------------------------

def test_output_shape():
    Z = _make_rank1_Z([1, 0.5j, -0.3, 0.8 + 0.2j], n_acc=256)
    w = compute_eigvec_fw(Z, n_acc=256)
    assert w.shape == (4,)


def test_output_q1_15_range():
    # All components must lie in [-1, 1) — the Q1.15 representable range.
    Z = _make_rank1_Z([1, 0.5j, -0.3, 0.8 + 0.2j], n_acc=256)
    w = compute_eigvec_fw(Z, n_acc=256)
    assert np.all(np.abs(w.real) <= 1.0), "Q1.15 real parts must be in [-1, 1)"
    assert np.all(np.abs(w.imag) <= 1.0), "Q1.15 imag parts must be in [-1, 1)"
    print(f"PASS  Q1.15 range: w={w}")


def test_max_component_is_one():
    # The normalisation step should produce max|w_k| ≈ 1.0 (within Q1.15 LSB).
    rng = np.random.default_rng(42)
    h = rng.standard_normal(4) + 1j * rng.standard_normal(4)
    Z = _make_rank1_Z(h, n_acc=512, sigma2=0.1)
    w = compute_eigvec_fw(Z, n_acc=512)
    max_comp = max(np.max(np.abs(w.real)), np.max(np.abs(w.imag)))
    assert max_comp > 0.9, f"max component {max_comp:.3f} should be close to 1"
    print(f"PASS  max component = {max_comp:.4f}")


# ---------------------------------------------------------------------------
# Numerical accuracy — compare against float reference
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("seed", [0, 1, 7, 42, 99])
def test_weight_direction_vs_float_reference(seed):
    """
    The firmware eigenvector direction should agree with the float reference
    (numpy eigh) to within 5 degrees for a realistic SNR channel matrix.

    The tolerance accounts for:
      - 8 power iterations (not exact eigh)
      - int12 matrix normalisation quantisation
      - ZDIAG upper-24-bit truncation
    """
    rng = np.random.default_rng(seed)
    h = rng.standard_normal(4) + 1j * rng.standard_normal(4)
    sigma2 = 0.1
    n_acc = 512
    Z = _make_rank1_Z(h, n_acc=n_acc, sigma2=sigma2)

    w_fw    = compute_eigvec_fw(Z, n_acc=n_acc)
    w_float = compute_eigvec_weights(Z)

    angle = _angle_between(w_fw, w_float)
    assert angle < 5.0, (
        f"seed={seed}: direction error {angle:.2f}° exceeds 5° tolerance\n"
        f"  w_fw    = {w_fw}\n"
        f"  w_float = {w_float}"
    )
    print(f"PASS  seed={seed}: direction error = {angle:.3f}°")


def test_weight_direction_low_snr():
    """At low SNR the matrix is near-spherical; 8 iterations may converge slowly.
    Still expect < 15° error."""
    rng = np.random.default_rng(123)
    h = rng.standard_normal(4) + 1j * rng.standard_normal(4)
    sigma2 = 10.0   # high noise relative to signal
    n_acc = 128
    Z = _make_rank1_Z(h, n_acc=n_acc, sigma2=sigma2)

    w_fw    = compute_eigvec_fw(Z, n_acc=n_acc)
    w_float = compute_eigvec_weights(Z)

    angle = _angle_between(w_fw, w_float)
    assert angle < 15.0, f"low-SNR direction error {angle:.2f}° exceeds 15°"
    print(f"PASS  low-SNR direction error = {angle:.3f}°")


def test_weight_direction_single_strong_antenna():
    """With one dominant branch the eigenvector should point almost entirely
    along that branch on both implementations."""
    h = np.array([10.0 + 0j, 0.1, 0.1, 0.1])
    n_acc = 256
    Z = _make_rank1_Z(h, n_acc=n_acc, sigma2=0.01)

    w_fw    = compute_eigvec_fw(Z, n_acc=n_acc)
    w_float = compute_eigvec_weights(Z)

    angle = _angle_between(w_fw, w_float)
    # Both should be near [1,0,0,0]; check w_fw branch-0 dominates
    assert abs(w_fw[0]) > 0.9, f"branch-0 weight {abs(w_fw[0]):.3f} should dominate"
    assert angle < 5.0, f"direction error {angle:.2f}° for single-antenna case"
    print(f"PASS  single strong antenna: w_fw[0]={w_fw[0]:.3f}, angle={angle:.3f}°")


# ---------------------------------------------------------------------------
# Fixed-point fidelity tests
# ---------------------------------------------------------------------------

def test_zdiag_truncation_applied():
    """
    The model must truncate the diagonal to upper 24 bits.

    Z and Z_floored differ only in the lower 8 bits of their diagonals
    (Z_floored has those bits zeroed), so both produce the same ZDIAG register
    value and must produce identical weights.
    """
    rng = np.random.default_rng(7)
    h = rng.standard_normal(4) + 1j * rng.standard_normal(4)
    n_acc = 512
    Z = _make_rank1_Z(h, n_acc=n_acc, sigma2=0.1)

    # Floor each diagonal entry to the nearest multiple of 2^8.
    # This zeroes the lower 8 bits, leaving the ZDIAG register value unchanged.
    Z_floored = Z.copy()
    for k in range(4):
        d = int(round(Z[k, k].real))
        Z_floored[k, k] = float(d & ~0xFF)   # clear lower 8 bits

    w1 = compute_eigvec_fw(Z, n_acc=n_acc)
    w2 = compute_eigvec_fw(Z_floored, n_acc=n_acc)
    assert np.allclose(w1, w2), (
        "Matrices differing only in the lower 8 bits of the diagonal must "
        "produce identical weights after ZDIAG truncation"
    )
    print("PASS  ZDIAG truncation: lower-8-bit diagonal difference invisible")


def test_int32_accumulator_does_not_overflow():
    """
    Verify the overflow proof from the spec: with int12 matrix entries and a
    ±4096 vector, each row accumulation is at most 7×2×4095²≈235M < 2^31.
    Use a worst-case all-equal matrix (max entries = 4095).
    """
    # Construct a matrix where all off-diagonal real parts are near max after
    # normalisation.  Use a large uniform channel so the normalisation shift
    # brings entries close to 4095.
    h = np.ones(4, dtype=complex) * (1 << 20)
    n_acc = 64
    Z = _make_rank1_Z(h, n_acc=n_acc, sigma2=0.0)

    # Should complete without any int32 overflow (clamp guard never fires)
    w = compute_eigvec_fw(Z, n_acc=n_acc)
    assert w.shape == (4,)
    assert not np.any(np.isnan(w))
    print(f"PASS  worst-case uniform channel: w={w}")


def test_more_iterations_improve_accuracy():
    """More iterations should match the float reference at least as well."""
    rng = np.random.default_rng(55)
    h = rng.standard_normal(4) + 1j * rng.standard_normal(4)
    Z = _make_rank1_Z(h, n_acc=256, sigma2=1.0)
    w_float = compute_eigvec_weights(Z)

    angle_8  = _angle_between(compute_eigvec_fw(Z, n_acc=256, iters=8),  w_float)
    angle_16 = _angle_between(compute_eigvec_fw(Z, n_acc=256, iters=16), w_float)

    assert angle_16 <= angle_8 + 0.5, (
        f"16-iter angle {angle_16:.2f}° should be no worse than 8-iter {angle_8:.2f}°"
    )
    print(f"PASS  iterations: 8-iter={angle_8:.3f}°, 16-iter={angle_16:.3f}°")
