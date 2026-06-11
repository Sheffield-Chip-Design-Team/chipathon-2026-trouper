"""Unit tests for branch IQ-imbalance modelling."""

import numpy as np

from sim.models.channel import apply_iq_imbalance, iq_imbalance_coefficients


def test_zero_imbalance_is_identity():
    x = np.array([1 + 2j, -3 + 0.5j, 0.25 - 0.75j], dtype=np.complex128)
    y = apply_iq_imbalance(x, gain_db=0.0, phase_deg=0.0)
    assert np.allclose(y, x)
    print("PASS  IQ imbalance identity: zero mismatch leaves signal unchanged")


def test_image_term_appears_for_nonzero_mismatch():
    mu, nu = iq_imbalance_coefficients(gain_db=1.0, phase_deg=5.0)
    assert abs(nu) > 0.0, "Non-zero mismatch should create a non-zero image term"
    x = np.exp(1j * 2 * np.pi * np.arange(32) / 32)
    y = apply_iq_imbalance(x, gain_db=1.0, phase_deg=5.0)
    y_ref = mu * x + nu * np.conj(x)
    assert np.allclose(y, y_ref)
    print(f"PASS  IQ imbalance image term: |nu|={abs(nu):.6f}")


if __name__ == "__main__":
    test_zero_imbalance_is_identity()
    test_image_term_appears_for_nonzero_mismatch()
