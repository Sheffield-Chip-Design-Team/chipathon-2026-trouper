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
# shift_normalise — SF-based arithmetic right-shift (RTL commit 034f2f6)
# ---------------------------------------------------------------------------

def test_shift_normalise_sf7():
    # SF7: shift by 7. Verify floor division per component.
    Z_j = np.array([1000 + 2000j, -300 + 400j, 0j, 12000 + 0j])
    H_j, K = shift_normalise(Z_j, sf=7)
    assert K == 7
    assert H_j[0] == complex(np.floor(1000/128), np.floor(2000/128))
    assert H_j[1] == complex(np.floor(-300/128), np.floor(400/128))
    assert H_j[2] == 0j
    assert H_j[3] == complex(np.floor(12000/128), 0)
    print(f"PASS  shift_normalise sf=7: H_j={H_j}, K={K}")


def test_shift_normalise_realistic_sf12():
    # SF12: max |Z_i| = 8×4096×127² ≈ 528M. After >> 12: ≈ 129k < 2^17.
    n_acc = 8 * 4096
    val = int(127 ** 2 * n_acc)  # 528,416,768
    Z_j = np.array([val + 0j, -val + 0j, 0j, 0j])
    H_j, K = shift_normalise(Z_j, sf=12)
    assert K == 12
    assert H_j[0] == np.floor(val / 4096)
    assert H_j[1] == np.floor(-val / 4096)
    expected_max = 127 ** 2 * 8  # = 129032 < 2^17 = 131072
    assert abs(float(H_j[0].real)) <= expected_max + 1
    print(f"PASS  shift_normalise sf=12: H[0]={H_j[0].real:.0f} (max {expected_max}), K={K}")


def test_shift_normalise_zero():
    Z_j = np.zeros(4, dtype=complex)
    H_j, K = shift_normalise(Z_j, sf=7)
    assert K == 7
    assert np.all(H_j == 0)
    print("PASS  shift_normalise: zero input → H_j=0, K=sf")


def test_shift_normalise_preserves_phase():
    # Phase preservation: for large values, floor(x/2^sf) doesn't change angle.
    Z_j = np.array([3e35 + 4e35j, -1e35 + 2e35j, 0j, 0j])
    H_j, K = shift_normalise(Z_j, sf=7)
    for j in range(4):
        if abs(Z_j[j]) > 0:
            assert abs(np.angle(H_j[j]) - np.angle(Z_j[j])) < 1e-9, \
                f"Phase changed for branch {j}"
    print("PASS  shift_normalise: phases preserved for large-amplitude input")


def test_shift_normalise_negative():
    # Arithmetic right-shift: floor(-5/2) = -3 (not -2)
    Z_j = np.array([-5 + 0j, 0j, 0j, 0j])
    H_j, K = shift_normalise(Z_j, sf=1)
    assert H_j[0].real == -3.0, f"Expected -3, got {H_j[0].real}"
    assert K == 1
    print(f"PASS  shift_normalise: arithmetic right-shift floor(-5/2)={H_j[0].real}")


# ---------------------------------------------------------------------------
# WeightGenerator — hardware FSM path (uses realistic Z scales)
# ---------------------------------------------------------------------------

def _realistic_Z(h: np.ndarray, sf: int = 7) -> np.ndarray:
    """Scale Z to realistic hardware range: n_acc × 127² × h × conj(h[0])."""
    n_acc = 8 * (1 << sf)
    return h * np.conj(h[0]) * float(n_acc) * float(127 ** 2)


def test_mrc_noiseless():
    h = np.array([0.8 + 0.6j, 0.5 - 0.3j, 0.1 + 0.9j, 0.7 + 0.2j])
    sf = 7
    Z_j = _realistic_Z(h, sf=sf)
    wgen = WeightGenerator(mode="mrc")
    w, K = wgen.process(Z_j, sf=sf)
    assert K == sf
    # Phase should be within 0.05 rad after SF-normalization with large H values
    for j in range(4):
        expected_phase = -np.angle(Z_j[j])
        actual_phase = np.angle(w[j])
        assert abs(actual_phase - expected_phase) < 5e-2, \
            f"MRC phase wrong on branch {j}: expected {expected_phase:.4f}, got {actual_phase:.4f}"
    # Branch ratios preserved to within integer-shift quantization (~5%)
    ratios_hw = np.abs(w) / np.abs(w[0])
    ratios_ref = np.abs(Z_j) / np.abs(Z_j[0])
    assert np.allclose(ratios_hw, ratios_ref, atol=5e-2), \
        f"Shift-MRC should preserve branch ratios: got {ratios_hw}, expected {ratios_ref}"
    print("PASS  WeightGenerator MRC: SF-normalised shift preserves conjugate phase and branch ratios")


def test_egc_unit_magnitude():
    h = np.array([0.6 + 0.8j, -0.3 + 0.4j, 0.9 + 0.1j, 0.5 - 0.5j])
    Z_j = h * 5e6  # large scale to minimise integer-shift quantisation
    wgen = WeightGenerator(mode="egc")
    w, _ = wgen.process(Z_j, sf=7)
    mags = np.abs(w)
    assert np.allclose(mags, 1.0, atol=2e-4), f"EGC weights not unit magnitude: {mags}"
    print("PASS  WeightGenerator EGC: all weights have unit magnitude")


def test_egc_conjugate_phase():
    # EGC is a software-only path; use large Z to keep sf-shift quantisation small.
    h = np.array([0.6 + 0.8j, -0.3 + 0.4j, 0.9 + 0.1j, 0.5 - 0.5j])
    Z_j = h * 5e6
    wgen = WeightGenerator(mode="egc")
    w, _ = wgen.process(Z_j, sf=7)
    for j in range(4):
        expected_phase = -np.angle(Z_j[j])
        actual_phase = np.angle(w[j])
        assert abs(actual_phase - expected_phase) < 1e-3, \
            f"EGC phase wrong on branch {j}: expected {expected_phase:.4f}, got {actual_phase:.4f}"
    print("PASS  WeightGenerator EGC: weight phases = −angle(Z_j)")


def test_sc_selects_strongest():
    # Scale above 2^7=128 so sf=7 right-shift leaves nonzero values
    Z_j = np.array([1e4 + 0j, 5e4 + 0j, 5e3 + 0j, 2e4 + 0j])
    wgen = WeightGenerator(mode="sc")
    w, _ = wgen.process(Z_j, sf=7)
    assert w[1] == 1.0, f"SC should select branch 1 (strongest), got w={w}"
    assert np.sum(np.abs(w)) == 1.0
    print("PASS  WeightGenerator SC: selects strongest branch")


def test_bypass_selects_lowest_enabled():
    Z_j = np.array([1e4 + 0j, 2e4 + 0j, 3e4 + 0j, 4e4 + 0j])
    wgen = WeightGenerator(mode="bypass", antenna_en=0b1100)  # branches 2 and 3
    w, _ = wgen.process(Z_j, sf=7)
    assert w[2] == 1.0, f"Bypass should select lowest enabled (branch 2), got w={w}"
    assert w[0] == 0 and w[1] == 0 and w[3] == 0
    print("PASS  WeightGenerator bypass: selects lowest enabled antenna")


def test_disabled_antennas_zeroed():
    # Scale above 2^7 so H values are nonzero for all branches
    Z_j = np.array([1e4 + 0j, 5e4 + 0j, 1e4 + 0j, 1e4 + 0j])
    wgen = WeightGenerator(mode="mrc", antenna_en=0b1101)
    w, _ = wgen.process(Z_j, sf=7)
    assert abs(w[1]) < 1e-9, f"Disabled branch 1 should have zero weight, got {w[1]}"
    print("PASS  WeightGenerator: disabled branches have zero weight")


def test_equal_branches_mrc():
    # Use realistic scale (SF7 with typical SNR)
    Z_j = np.ones(4, dtype=complex) * float(8 * 128 * 127**2)
    wgen = WeightGenerator(mode="mrc")
    w, _ = wgen.process(Z_j, sf=7)
    assert np.all(np.abs(w) > 0), "Equal branches should have non-zero weights"
    assert np.allclose(np.abs(w), np.abs(w[0]), atol=2e-4), \
        "Equal branches should give equal-magnitude MRC weights"
    print("PASS  WeightGenerator MRC: equal branches → equal-magnitude weights")


def test_mrc_sf_normalisation_equal_branches():
    """Equal channels: weight magnitude follows SF-normalised H after MRC shift."""
    NR = 4
    sf = 6
    n_acc = 8 * (1 << sf)           # 8 symbols × M = 512
    Z_j = np.ones(NR, dtype=complex) * float(n_acc)
    wgen = WeightGenerator(mode="mrc")
    w, K = wgen.process(Z_j, sf=sf)
    assert K == sf, f"Expected K={sf}, got K={K}"
    # H = floor(n_acc / 2^sf) = floor(512/64) = 8
    H_val = int(np.floor(n_acc / (1 << sf)))
    # mrc_norm_shift: H_val=8 < 65536 → 0; branch_hdr=2 for 4 branches → mrc_shift=2
    # W = _round_ashr(8, 2) = (8+2)>>2 = 2
    # |w_j| = 2 / 2^15
    expected = 2.0 / 2**15
    assert np.allclose(np.abs(w), expected, atol=1 / 2**15), \
        f"SF-norm equal branches: expected |w_j|={expected:.6f}, got {np.abs(w)}"
    print(f"PASS  WeightGenerator MRC SF-norm: equal branches |w_j|={np.abs(w[0]):.6f} (expected {expected:.6f})")


def test_mrc_eref_ignored_by_hardware():
    """Hardware shift-MRC does not use E_ref; exact/oracle MRC is separate."""
    NR = 4
    n_acc = 512
    Z_j = np.ones(NR, dtype=complex) * n_acc
    E_ref = float(n_acc)
    sf = 7

    wgen = WeightGenerator(mode="mrc")
    w_with, _ = wgen.process(Z_j, sf=sf, E_ref=E_ref)
    w_without, _ = wgen.process(Z_j, sf=sf, E_ref=None)
    w_exact = compute_exact_mrc_weights(Z_j, sf=sf, E_ref=E_ref)

    assert np.allclose(w_with, w_without), "Hardware MRC should ignore E_ref"
    assert np.abs(w_exact[0]) > np.abs(w_with[0]) * 10, \
        "Exact/oracle MRC should remain distinguishable from shift-MRC"
    print(f"PASS  MRC E_ref: hardware ignores E_ref (|w|={np.abs(w_with[0]):.6f}); exact helper gives {np.abs(w_exact[0]):.4f}")


def test_sf_normalisation_improves_high_sf():
    """SF12 weights should have comparable quality to SF7 weights (old code was broken for SF10+)."""
    h = np.array([0.8 + 0.6j, 0.5 - 0.3j, 0.1 + 0.9j, 0.7 + 0.2j])

    for sf in (7, 10, 12):
        Z_j = _realistic_Z(h, sf=sf)
        wgen = WeightGenerator(mode="mrc")
        w, K = wgen.process(Z_j, sf=sf)
        assert K == sf
        # Phases should be within 0.05 rad for all SFs after correct normalisation
        for j in range(4):
            expected_phase = -np.angle(Z_j[j])
            actual_phase = np.angle(w[j])
            assert abs(actual_phase - expected_phase) < 5e-2, \
                f"SF{sf} branch {j}: phase error {abs(actual_phase - expected_phase):.4f} > 0.05"
    print("PASS  WeightGenerator MRC: SF normalisation correct for SF7/SF10/SF12")


# ---------------------------------------------------------------------------
# DCRemoval
# ---------------------------------------------------------------------------

def test_dc_removal_removes_dc():
    # Legacy float helper; bit-accurate current model is DCRemovalRTL.
    dcr = DCRemoval(nr=4, alpha_shift=8)
    N = 2000
    samples = np.ones((4, N), dtype=complex) * 10.0
    out = dcr.process(samples)
    assert np.allclose(out[:, N // 2:].real, 0.0, atol=0.5), \
        "DC not removed after convergence"
    print("PASS  DCRemoval: DC offset removed after convergence")


def test_dc_removal_passes_ac():
    # Legacy float helper; bit-accurate current model is DCRemovalRTL.
    dcr = DCRemoval(nr=1, alpha_shift=8)
    N = 1000
    t = np.arange(N)
    fs = 125e3
    freq = 10e3
    sig = np.cos(2 * np.pi * freq / fs * t).reshape(1, N) + 0j
    out = dcr.process(sig)
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
    test_shift_normalise_sf7()
    test_shift_normalise_realistic_sf12()
    test_shift_normalise_zero()
    test_shift_normalise_preserves_phase()
    test_shift_normalise_negative()
    test_mrc_noiseless()
    test_egc_unit_magnitude()
    test_egc_conjugate_phase()
    test_sc_selects_strongest()
    test_bypass_selects_lowest_enabled()
    test_disabled_antennas_zeroed()
    test_equal_branches_mrc()
    test_mrc_sf_normalisation_equal_branches()
    test_mrc_eref_ignored_by_hardware()
    test_sf_normalisation_improves_high_sf()
    test_dc_removal_removes_dc()
    test_dc_removal_passes_ac()
    test_dc_removal_reset()
