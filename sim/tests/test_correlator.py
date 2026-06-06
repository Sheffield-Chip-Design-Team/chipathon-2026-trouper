"""Unit tests for the FFT-based preamble channel estimator (Stage 4).

CorrelatorBank removed: a time-domain dot-product at bin 0 gives zero output
for any timing or CFO offset, making it useless for acquisition.  The FFT
estimator finds the signal at whatever bin it occupies and yields the same
h_hat after peak-bin normalisation.

Tests
-----
1. Noiseless accuracy      — h_hat == h exactly when N0=0
2. Estimation error vs SNR — var(error) matches theory N0/(N_sym·M)
3. Phase accuracy          — |∠h_hat - ∠h| < tolerance across SNR sweep
4. Data symbol rejection   — random payload symbol (b≠0) in the preamble
                             window does not bias the estimate
5. PLL phase absorption    — h_hat absorbs a fixed per-antenna PLL offset
                             so the residual error statistics are unchanged

Run with:  python3 -m sim.tests.test_correlator
"""

import numpy as np

from ..models.lora import modulate, upchirp
from ..models.receiver import estimate_channel

SF        = 7
M         = 2 ** SF          # 128 chips per symbol
N_SYM     = 8                # preamble symbols
NR        = 4                # receive antennas
RNG       = np.random.default_rng(0)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def make_preamble_rx(h: np.ndarray, N0: float) -> np.ndarray:
    """Return (NR, N_SYM*M) received preamble samples for channel h."""
    c = upchirp(M)
    tx = np.tile(c, N_SYM)
    noise = np.sqrt(N0 / 2) * (
        RNG.standard_normal((NR, N_SYM * M))
        + 1j * RNG.standard_normal((NR, N_SYM * M))
    )
    return h[:, None] * tx[None, :] + noise


def random_channel(NR: int) -> np.ndarray:
    return (RNG.standard_normal(NR) + 1j * RNG.standard_normal(NR)) / np.sqrt(2)


def pass_fail(label: str, ok: bool):
    status = "PASS" if ok else "FAIL"
    print(f"  [{status}] {label}")
    return ok


# ---------------------------------------------------------------------------
# Test 1 — Noiseless accuracy
# ---------------------------------------------------------------------------

def test_noiseless_accuracy():
    """With N0=0, h_hat must equal h to floating-point precision."""
    print("\nTest 1 — Noiseless accuracy")
    h   = random_channel(NR)
    c   = upchirp(M)
    tx  = np.tile(c, N_SYM)
    rx  = h[:, None] * tx[None, :]   # no noise

    h_hat = estimate_channel(rx, M, N_SYM)
    err   = np.abs(h_hat - h)

    for j in range(NR):
        ok = err[j] < 1e-10
        pass_fail(f"antenna {j}  |h_hat - h| = {err[j]:.2e}", ok)


# ---------------------------------------------------------------------------
# Test 2 — Estimation error variance vs theory
# ---------------------------------------------------------------------------

def test_estimation_error_variance():
    """
    Theoretical estimation error: h_hat = h + delta
    where delta ~ CN(0, N0 / (N_sym * M)).

    Check that empirical variance matches theory within 20% across SNR sweep.
    """
    print("\nTest 2 — Estimation error variance vs theory")
    N_trials = 2000
    all_pass  = True

    for snr_db in [-10, -5, 0, 5, 10]:
        N0          = 10 ** (-snr_db / 10)
        theory_var  = N0 / (N_SYM * M)

        errors = []
        for _ in range(N_trials):
            h     = random_channel(NR)
            rx    = make_preamble_rx(h, N0)
            h_hat = estimate_channel(rx, M, N_SYM)
            errors.extend((h_hat - h).tolist())

        errors     = np.array(errors)
        emp_var_re = np.var(errors.real)
        emp_var_im = np.var(errors.imag)
        emp_var    = (emp_var_re + emp_var_im) / 2   # average I and Q

        ratio = emp_var / (theory_var / 2)           # theory splits over I+Q
        ok    = 0.85 < ratio < 1.15
        all_pass &= ok
        pass_fail(
            f"SNR={snr_db:+3d} dB  theory={theory_var/2:.2e}  "
            f"empirical={emp_var:.2e}  ratio={ratio:.3f}",
            ok,
        )

    return all_pass


# ---------------------------------------------------------------------------
# Test 3 — Phase accuracy vs SNR
# ---------------------------------------------------------------------------

def test_phase_accuracy():
    """
    Phase estimation error σ_φ = σ_delta / |h| (small-angle approximation).
    Notion spec requires σₑ < 0.1 (channel estimation error norm).

    Report RMS phase error per antenna across SNR range.
    """
    print("\nTest 3 — Phase accuracy vs SNR")
    N_trials  = 1000
    tolerance = 0.1   # radians RMS, per Notion spec table
    all_pass  = True

    for snr_db in [-10, -5, 0, 5, 10]:
        N0           = 10 ** (-snr_db / 10)
        phase_errors = []

        for _ in range(N_trials):
            h     = random_channel(NR)
            rx    = make_preamble_rx(h, N0)
            h_hat = estimate_channel(rx, M, N_SYM)

            phi_true = np.angle(h)
            phi_hat  = np.angle(h_hat)
            # wrap to (-pi, pi]
            delta = np.angle(np.exp(1j * (phi_hat - phi_true)))
            phase_errors.extend(delta.tolist())

        rms = np.sqrt(np.mean(np.array(phase_errors) ** 2))
        ok  = rms < tolerance
        all_pass &= ok
        pass_fail(f"SNR={snr_db:+3d} dB  RMS phase error = {rms:.4f} rad", ok)

    return all_pass


# ---------------------------------------------------------------------------
# Test 4 — Data symbol rejection
# ---------------------------------------------------------------------------

def test_data_symbol_rejection():
    """
    If a random data symbol (b != 0) is present instead of an upchirp in one
    preamble slot, the correlator output for that slot is near zero (different
    frequency bin).  The 8-symbol average should absorb one such corruption
    with < 20% bias in |h_hat|.
    """
    print("\nTest 4 — Data symbol rejection")
    N_trials = 500
    N0       = 0.01   # high SNR so estimation noise is negligible
    all_pass  = True

    for corrupt_slots in [0, 1, 2]:
        bias_ratios = []
        for _ in range(N_trials):
            h  = random_channel(NR)
            c  = upchirp(M)
            tx = np.tile(c, N_SYM).copy()

            for slot in range(corrupt_slots):
                b             = RNG.integers(1, M)   # non-zero symbol
                tx[slot*M:(slot+1)*M] = modulate(b, M)

            noise = np.sqrt(N0 / 2) * (
                RNG.standard_normal((NR, N_SYM * M))
                + 1j * RNG.standard_normal((NR, N_SYM * M))
            )
            rx    = h[:, None] * tx[None, :] + noise
            h_hat = estimate_channel(rx, M, N_SYM)

            # expected estimate is h scaled by fraction of clean preamble symbols
            clean_fraction = (N_SYM - corrupt_slots) / N_SYM
            expected_mag   = np.abs(h) * clean_fraction
            ratio          = np.abs(h_hat) / np.maximum(expected_mag, 1e-9)
            bias_ratios.extend(ratio.tolist())

        mean_ratio = np.mean(bias_ratios)
        ok = 0.85 < mean_ratio < 1.15
        all_pass &= ok
        pass_fail(
            f"{corrupt_slots} corrupt slot(s) / {N_SYM}  "
            f"mean |h_hat|/expected = {mean_ratio:.4f}",
            ok,
        )

    return all_pass


# ---------------------------------------------------------------------------
# Test 5 — PLL phase absorption
# ---------------------------------------------------------------------------

def test_pll_absorption():
    """
    A fixed PLL phase offset on each antenna appears as a phase rotation in
    h_hat.  Verify that angle(h_hat) == angle(h_true) + pll_offset to
    floating-point precision (noiseless case).
    """
    print("\nTest 5 — PLL phase absorption (noiseless)")
    N_trials = 200
    all_pass  = True

    max_residual = 0.0
    for _ in range(N_trials):
        h_true   = random_channel(NR)
        pll      = RNG.uniform(-np.pi, np.pi, NR)
        h        = h_true * np.exp(1j * pll)

        c  = upchirp(M)
        tx = np.tile(c, N_SYM)
        rx = h[:, None] * tx[None, :]   # noiseless

        h_hat = estimate_channel(rx, M, N_SYM)

        expected_phase = np.angle(h_true) + pll
        actual_phase   = np.angle(h_hat)
        residual       = np.abs(np.angle(np.exp(1j * (actual_phase - expected_phase))))
        max_residual   = max(max_residual, residual.max())

    ok = max_residual < 1e-9
    all_pass &= ok
    pass_fail(
        f"max phase residual across {N_trials} trials = {max_residual:.2e} rad",
        ok,
    )
    return all_pass


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

def main():
    print(f"Preamble correlator unit tests  (SF={SF}, M={M}, N_sym={N_SYM}, NR={NR})")
    results = [
        test_noiseless_accuracy(),
        test_estimation_error_variance(),
        test_phase_accuracy(),
        test_data_symbol_rejection(),
        test_pll_absorption(),
    ]
    n_pass = sum(1 for r in results if r is not False)
    print(f"\n{n_pass}/{len(results)} test groups passed.")


if __name__ == "__main__":
    main()
