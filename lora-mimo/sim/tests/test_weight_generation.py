import numpy as np
from sim.models.weight_generation import (
    WeightGenerator,
    shift_normalise,
    apply_calibration,
    compute_weights_hw,
    compute_exact_mrc_weights,
)
from sim.models.dc_removal import DCRemoval


# ---------------------------------------------------------------------------
# shift_normalise
# ---------------------------------------------------------------------------

def test_shift_normalise_in_range():
    Z_j = np.array([1000 + 2000j, -300 + 400j, 0j, 12000 + 0j])
    H_j, K = shift_normalise(Z_j)
    assert K == 0
    assert np.allclose(H_j, Z_j)
    print("PASS  shift_normalise: no shift when already in Q1.15-friendly range")


def test_shift_normalise_int64_input():
    # Simulate a max-scale int64 accumulation: 4 branches × int8(127)² × 8×4096 samples
    n_acc = 8 * 4096
    val = 127 * 127 * n_acc  # ~5.4e8 — still fits int32 actually
    # Force an out-of-range value
    val_large = float(2**34)
    Z_j = np.array([val_large + 0j, 0j, 0j, 0j])
    H_j, K = shift_normalise(Z_j)
    assert K >= 20, f"Expected K>=20 for 2^34 input, got K={K}"
    assert np.max(np.abs(H_j.real)) <= 2**15, "H_j out of Q1.15-friendly range after shift"
    print(f"PASS  shift_normalise: 2^34 input → K={K}, max component = {np.max(np.abs(H_j.real)):.1e}")


def test_shift_normalise_zero():
    Z_j = np.zeros(4, dtype=complex)
    H_j, K = shift_normalise(Z_j)
    assert K == 0
    assert np.all(H_j == 0)
    print("PASS  shift_normalise: zero input → K=0, H_j=0")


def test_shift_normalise_preserves_phase():
    Z_j = np.array([3e35 + 4e35j, -1e35 + 2e35j, 0j, 0j])
    H_j, K = shift_normalise(Z_j)
    for j in range(4):
        if abs(Z_j[j]) > 0:
            assert abs(np.angle(H_j[j]) - np.angle(Z_j[j])) < 1e-9, \
                f"Phase changed for branch {j}"
    print("PASS  shift_normalise: phases preserved after large shift")


# ---------------------------------------------------------------------------
# WeightGenerator — hardware FSM path
# ---------------------------------------------------------------------------

def test_mrc_noiseless():
    h = np.array([0.8 + 0.6j, 0.5 - 0.3j, 0.1 + 0.9j, 0.7 + 0.2j])
    Z_j = h * np.conj(h[0]) * 1000  # simulate n_acc=1000, ref=branch 0
    wgen = WeightGenerator(mode="mrc")
    w, _ = wgen.process(Z_j)
    for j in range(4):
        expected_phase = -np.angle(Z_j[j])
        actual_phase = np.angle(w[j])
        assert abs(actual_phase - expected_phase) < 5e-3,             f"MRC phase wrong on branch {j}: expected {expected_phase:.4f}, got {actual_phase:.4f}"
    ratios_hw = np.abs(w) / np.abs(w[0])
    ratios_ref = np.abs(Z_j) / np.abs(Z_j[0])
    assert np.allclose(ratios_hw, ratios_ref, atol=4e-2),         f"Shift-MRC should preserve branch ratios: got {ratios_hw}, expected {ratios_ref}"
    print("PASS  WeightGenerator MRC: shift-MRC preserves conjugate phase and branch ratios")


def test_egc_unit_magnitude():
    h = np.array([0.6 + 0.8j, -0.3 + 0.4j, 0.9 + 0.1j, 0.5 - 0.5j])
    Z_j = h * 5000.0
    wgen = WeightGenerator(mode="egc")
    w, _ = wgen.process(Z_j)
    mags = np.abs(w)
    assert np.allclose(mags, 1.0, atol=2e-4), f"EGC weights not unit magnitude: {mags}"
    print("PASS  WeightGenerator EGC: all weights have unit magnitude")


def test_egc_conjugate_phase():
    h = np.array([0.6 + 0.8j, -0.3 + 0.4j, 0.9 + 0.1j, 0.5 - 0.5j])
    Z_j = h * 5000.0
    wgen = WeightGenerator(mode="egc")
    w, _ = wgen.process(Z_j)
    for j in range(4):
        expected_phase = -np.angle(Z_j[j])
        actual_phase = np.angle(w[j])
        assert abs(actual_phase - expected_phase) < 1e-3, \
            f"EGC phase wrong on branch {j}: expected {expected_phase:.4f}, got {actual_phase:.4f}"
    print("PASS  WeightGenerator EGC: weight phases = −angle(Z_j)")


def test_sc_selects_strongest():
    Z_j = np.array([1.0 + 0j, 5.0 + 0j, 0.5 + 0j, 2.0 + 0j])
    wgen = WeightGenerator(mode="sc")
    w, _ = wgen.process(Z_j)
    assert w[1] == 1.0, f"SC should select branch 1 (strongest), got w={w}"
    assert np.sum(np.abs(w)) == 1.0
    print("PASS  WeightGenerator SC: selects strongest branch")


def test_bypass_selects_lowest_enabled():
    Z_j = np.array([1.0 + 0j, 2.0 + 0j, 3.0 + 0j, 4.0 + 0j])
    wgen = WeightGenerator(mode="bypass", antenna_en=0b1100)  # branches 2 and 3
    w, _ = wgen.process(Z_j)
    assert w[2] == 1.0, f"Bypass should select lowest enabled (branch 2), got w={w}"
    assert w[0] == 0 and w[1] == 0 and w[3] == 0
    print("PASS  WeightGenerator bypass: selects lowest enabled antenna")


def test_disabled_antennas_zeroed():
    Z_j = np.array([1.0 + 0j, 5.0 + 0j, 1.0 + 0j, 1.0 + 0j])
    # Disable branch 1 (strongest) — MRC should not use it
    wgen = WeightGenerator(mode="mrc", antenna_en=0b1101)
    w, _ = wgen.process(Z_j)
    assert abs(w[1]) < 1e-9, f"Disabled branch 1 should have zero weight, got {w[1]}"
    print("PASS  WeightGenerator: disabled branches have zero weight")


def test_equal_branches_mrc():
    Z_j = np.array([1.0 + 0j, 1.0 + 0j, 1.0 + 0j, 1.0 + 0j])
    wgen = WeightGenerator(mode="mrc")
    w, _ = wgen.process(Z_j)
    assert np.allclose(np.abs(w), np.abs(w[0]), atol=2e-4), \
        "Equal branches should give equal-magnitude MRC weights"
    print("PASS  WeightGenerator MRC: equal branches → equal-magnitude weights")


def test_mrc_conservative_shift_equal_branches():
    """Equal channels stay equal and receive 4-branch coherent-add headroom."""
    NR = 4
    n_acc = 8 * 64
    Z_j = np.ones(NR, dtype=complex) * n_acc
    wgen = WeightGenerator(mode="mrc")
    w, _ = wgen.process(Z_j, E_ref=float(n_acc))
    expected = (n_acc >> 2) / 2**15  # branch_headroom=2 for four enabled branches
    assert np.allclose(np.abs(w), expected, atol=1 / 2**15),         f"Shift-MRC equal branches: expected |w_j|={expected:.6f}, got {np.abs(w)}"
    print(f"PASS  WeightGenerator shift-MRC: equal branches -> |w_j|={np.abs(w[0]):.6f} with 4-branch headroom")


def test_mrc_eref_ignored_by_hardware():
    """Hardware shift-MRC does not use E_ref; exact/oracle MRC is separate."""
    NR = 4
    n_acc = 512
    Z_j = np.ones(NR, dtype=complex) * n_acc
    E_ref = float(n_acc)

    wgen = WeightGenerator(mode="mrc")
    w_with, _ = wgen.process(Z_j, E_ref=E_ref)
    w_without, _ = wgen.process(Z_j, E_ref=None)
    w_exact = compute_exact_mrc_weights(Z_j, E_ref=E_ref)

    assert np.allclose(w_with, w_without), "Hardware MRC should ignore E_ref"
    assert np.abs(w_exact[0]) > np.abs(w_with[0]) * 10,         "Exact/oracle MRC should remain distinguishable from shift-MRC"
    print(f"PASS  MRC E_ref: hardware ignores E_ref (|w|={np.abs(w_with[0]):.6f}); exact helper gives {np.abs(w_exact[0]):.4f}")

def test_int64_scale_shift_applied():
    # Verify shift_normalise fires for int64-range inputs (would overflow int32 without it)
    h = np.array([0.8 + 0.6j, 0.5 - 0.3j, 0.1 + 0.9j, 0.7 + 0.2j])
    Z_j_large = h * np.conj(h[0]) * float(2**38)
    wgen = WeightGenerator(mode="mrc")
    w, K = wgen.process(Z_j_large)
    assert K > 0, f"Expected K>0 for 2^38-scale input, got K={K}"
    # After shifting, phases should still match the channel estimate directions
    # (MRC weight direction = -angle(Z_j), magnitude is scaled by Q1.15 saturation)
    for j in range(4):
        if abs(w[j]) > 1e-9:
            expected_phase = -np.angle(h[j] * np.conj(h[0]))
            actual_phase = np.angle(w[j])
            assert abs(actual_phase - expected_phase) < 1e-3, \
                f"Phase wrong on branch {j} after large-scale shift"
    print(f"PASS  WeightGenerator MRC: shift applied (K={K}) for 2^38-scale input; phases correct")


# ---------------------------------------------------------------------------
# DCRemoval
# ---------------------------------------------------------------------------

def test_dc_removal_removes_dc():
    dcr = DCRemoval(nr=4, alpha_shift=8)
    # DC offset of 10.0 on all branches
    N = 2000
    samples = np.ones((4, N), dtype=complex) * 10.0
    out = dcr.process(samples)
    # After convergence (last half) the DC should be largely removed
    assert np.allclose(out[:, N // 2:].real, 0.0, atol=0.5), \
        "DC not removed after convergence"
    print("PASS  DCRemoval: DC offset removed after convergence")


def test_dc_removal_passes_ac():
    dcr = DCRemoval(nr=1, alpha_shift=8)
    N = 1000
    t = np.arange(N)
    # 10 Hz sinusoid at 125 kHz (well above DC)
    fs = 125e3
    freq = 10e3
    sig = np.cos(2 * np.pi * freq / fs * t).reshape(1, N) + 0j
    out = dcr.process(sig)
    # AC power should be mostly preserved (allow 3 dB loss)
    power_in = float(np.mean(np.abs(sig[:, 100:]) ** 2))
    power_out = float(np.mean(np.abs(out[:, 100:]) ** 2))
    assert power_out > 0.5 * power_in, \
        f"AC signal attenuated too much: in={power_in:.3f}, out={power_out:.3f}"
    print("PASS  DCRemoval: AC signal passes with < 3 dB attenuation")


def test_dc_removal_reset():
    dcr = DCRemoval(nr=2, alpha_shift=4)
    samples = (np.ones((2, 500)) * 5.0).astype(complex)
    dcr.process(samples)
    dcr.reset()
    assert np.all(dcr._dc_est == 0), "DC estimate not reset to zero"
    print("PASS  DCRemoval: reset() clears DC estimate")


if __name__ == "__main__":
    test_shift_normalise_in_range()
    test_shift_normalise_int64_input()
    test_shift_normalise_zero()
    test_shift_normalise_preserves_phase()
    test_mrc_noiseless()
    test_egc_unit_magnitude()
    test_egc_conjugate_phase()
    test_sc_selects_strongest()
    test_bypass_selects_lowest_enabled()
    test_disabled_antennas_zeroed()
    test_equal_branches_mrc()
    test_mrc_conservative_shift_equal_branches()
    test_mrc_eref_ignored_by_hardware()
    test_int64_scale_shift_applied()
    test_dc_removal_removes_dc()
    test_dc_removal_passes_ac()
    test_dc_removal_reset()
