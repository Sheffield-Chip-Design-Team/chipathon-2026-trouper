"""Training Accumulator model — non-FFT preamble channel estimation.

Corresponds to planning/blocks/Training Accumulator.md.

Legacy helper path — cross-correlation against nominated reference branch:

    Z_j = Σ_n  raw_j[n] · conj(raw_ref[n])

where raw_ref = raw_j[ref_sel] and the sum runs from sc_lock_sample to
acc_end (= timing_ref + preamble_len·M − 1 in baseline live mode, or
packet_end_estimate − tacc_guard in PSRAM replay mode).

Z_j / n_acc  ≈  h_j · conj(h_ref)

The common CFO exp(j·ω·n) cancels exactly in the cross-product because
|s[n]|² = 1 for a constant-amplitude LoRa upchirp. This holds at all CFO
values — no Dirichlet attenuation, no integer-bin nulls.

Current RTL uses the all-pairs accumulator implemented by
`training_accumulate_allpairs()`. The legacy single-reference helper remains
available for comparison studies and older notebooks.
"""

import numpy as np
from .weight_generation import (
    WeightGenerator,
    shift_normalise,
    apply_calibration as _apply_calibration,
    compute_weights_hw,
)


def chirp_reference(M: int) -> np.ndarray:
    """
    Complex upchirp reference LUT, length M.

    chirp_ref[n] = exp(j·π·n²/M)   for n = 0, …, M−1

    Retained for diagnostic use and the alternative chirp-ref path.
    Not used in the primary cross-correlation accumulation path.
    """
    n = np.arange(M)
    return np.exp(1j * np.pi * n ** 2 / M)


def training_accumulate(
    raw_j: np.ndarray,
    sc_lock_sample: int,
    timing_ref: int,
    M: int,
    ref_sel: int = 0,
    preamble_len: int = 8,
    psram_en: bool = False,
    packet_end_estimate: int | None = None,
    tacc_guard: int = 0,
) -> tuple[np.ndarray, int, float]:
    """
    Cross-correlate preamble samples against reference branch to estimate
    per-branch relative channel coefficients.

    Parameters
    ----------
    raw_j : (NR, N_samples) complex array
        Full-precision decimator output samples. Must NOT be 8-bit saturated
        (see Frontend Buffer Controller spec).
    sc_lock_sample : int
        Sample index at which sc_lock asserted. Accumulation starts here.
    timing_ref : int
        Preamble-start sample index back-calculated by the SC detector.
        Defines acc_end in baseline live mode.
    M : int
        Samples per symbol (2^SF).
    ref_sel : int
        Reference branch index (0–3). Controlled by TACC_REF_SEL register.
        Default 0. The best-known antenna for the deployment should be used.
    preamble_len : int
        Number of preamble upchirp symbols (TACC_PREAMBLE_LEN register).
        Baseline live mode: acc_end = timing_ref + preamble_len·M − 1.
        Default 8.
    psram_en : bool
        False (default) = baseline live path; acc_end bounded by preamble.
        True = PSRAM replay path; acc_end extended to packet_end_estimate − tacc_guard,
        allowing accumulation beyond the preamble.
    packet_end_estimate : int, optional
        Latest sample index of the current packet. Required when psram_en=True.
        Ignored when psram_en=False.
    tacc_guard : int
        Guard margin subtracted from packet_end_estimate in PSRAM mode to allow
        time for final latch, weight-gen latency, and replay-control switching.
        Default 0 (no guard). Controlled by TACC_GUARD register.

    Returns
    -------
    Z_j : (NR,) complex
        Cross-correlation output. Z_j / n_acc ≈ h_j · conj(h_ref).
        For j == ref_sel: Z_j is real (auto-correlation = branch energy).
    n_acc : int
        Number of samples accumulated.
    E_ref : float
        Reference branch energy: Σ_n |rx_ref[n]|² over the accumulation window.
        Retained for software/exact-MRC comparisons. The hardened hardware
        WeightGenerator ignores E_ref and uses shift-based normalization.

    Notes
    -----
    Baseline live path (psram_en=False):
        With SC_HITS_REQ=2 and SF6 (M=64), sc_lock fires ~3·M samples into the
        preamble, so ~5 of 8 symbols are accumulated (n_acc ≈ 320). This gives
        a ~2 dB SNR penalty vs ideal; see Training Accumulator spec.

    PSRAM replay path (psram_en=True):
        SX1302 sees zeros during BUFFERING, so there is no live-payload deadline.
        Accumulation may extend beyond the preamble up to packet_end_estimate −
        tacc_guard. The branch-reference cross-correlation property holds over any
        packet region where the channel is approximately constant.
    """
    if psram_en and packet_end_estimate is None:
        raise ValueError("packet_end_estimate must be provided when psram_en=True")

    NR, N_samples = raw_j.shape

    acc_start = sc_lock_sample
    if psram_en:
        acc_end = min(packet_end_estimate - tacc_guard, N_samples - 1)
    else:
        acc_end = min(timing_ref + preamble_len * M - 1, N_samples - 1)

    if acc_start > acc_end:
        return np.zeros(NR, dtype=complex), 0, 0.0

    window     = raw_j[:, acc_start:acc_end + 1]   # (NR, n_acc)
    ref_window = raw_j[ref_sel, acc_start:acc_end + 1]  # (n_acc,)

    # Z_j = Σ_n raw_j[n] · conj(raw_ref[n])
    Z_j = window @ np.conj(ref_window)              # (NR,)

    n_acc = acc_end - acc_start + 1
    E_ref = float(np.sum(np.abs(ref_window) ** 2))
    return Z_j, n_acc, E_ref


def apply_calibration(
    Z_j: np.ndarray,
    cal_j: np.ndarray | None,
) -> np.ndarray:
    """Thin wrapper — canonical implementation is weight_generation.apply_calibration."""
    return _apply_calibration(Z_j, cal_j)


def compute_weights(
    Z_j: np.ndarray,
    mode: str = "mrc",
    sf: int = 7,
    antenna_en: int = 0xF,
    cal_j: np.ndarray | None = None,
    E_ref: float | None = None,
) -> np.ndarray:
    """
    Compute combining weights from training accumulator output.

    Delegates to WeightGenerator which models the full hardware FSM:
    SHIFT (Z>>>sf → 18-bit H) → CALIBRATE → COMPUTE → SCALE (Q1.15).

    Parameters
    ----------
    Z_j       : (NR,) complex cross-correlation estimates from training_accumulate()
    mode      : 'mrc' | 'egc' | 'sc' | 'bypass'
    sf        : spreading factor (6–12). Passed to the SHIFT state. Default 7.
    antenna_en: bitmask of enabled antennas (bit 0 = antenna 0)
    cal_j     : (NR,) complex Q1.15 calibration coefficients, or None
    E_ref     : retained for API compatibility and exact-MRC comparisons;
                ignored by the hardened hardware WeightGenerator

    Returns
    -------
    w : (NR,) complex Q1.15 weights
    """
    wgen = WeightGenerator(mode=mode, antenna_en=antenna_en, cal_j=cal_j)
    w, _ = wgen.process(Z_j, sf=sf, E_ref=E_ref)
    return w


def training_accumulate_allpairs(
    raw_j: np.ndarray,
    sc_lock_sample: int,
    timing_ref: int,
    M: int,
    preamble_len: int = 8,
    packet_end: int | None = None,
    tacc_guard: int = 0,
) -> tuple[np.ndarray, np.ndarray, int]:
    """
    All-pairs cross-correlator matching training_acc.v.

    Computes the full NR×NR Hermitian correlation matrix:
        Z_kl = Σ_n raw_k[n] · conj(raw_l[n])

    Diagonal: Z_kk = Σ|raw_k[n]|² (signal + noise power) → maps to Zdiag_k registers.
    Off-diagonal: Z_kl ≈ h_k · conj(h_l) · n_acc  (channel cross-term) → Zpair_kl registers.

    trouper_top does not instantiate weight_gen.v — weights are computed by the
    PicoRV32 firmware (eigenvector path via compute_eigvec_fw) reading Zpair_kl
    and Zdiag_k from the register bank.  W_k = Σ_{l≠k} Z_kl (row sum excluding
    diagonal) is no longer a hardware output; derive it locally for comparison
    studies via ``np.sum(Z, axis=1) - np.diag(Z)``.

    In noise mode (no signal): Z_kl ≈ 0 for k≠l (uncorrelated noise),
    Z_kk ≈ σ²_k · n_acc (diagonal carries noise power directly).

    Parameters
    ----------
    raw_j         : (NR, N_samples) complex int8 samples
    sc_lock_sample: accumulation start index (sc_lock fires here)
    timing_ref    : preamble-start estimate from SC detector
    M             : samples per symbol (2^SF)
    preamble_len  : number of preamble symbols; sets acc_end in live mode
    packet_end    : if given, enables PSRAM mode — acc_end extends to
                    packet_end - tacc_guard instead of the preamble boundary
    tacc_guard    : guard margin subtracted from packet_end in PSRAM mode

    Returns
    -------
    Z_matrix : (NR, NR) complex — full Hermitian cross-correlation matrix
    Zdiag    : (NR,) real — diagonal autocorrelations (Σ|raw_k|²)
    n_acc    : int — number of samples accumulated
    """
    NR, N_samples = raw_j.shape
    acc_start = sc_lock_sample
    if packet_end is not None:
        acc_end = min(packet_end - tacc_guard, N_samples - 1)
    else:
        acc_end = min(timing_ref + preamble_len * M - 1, N_samples - 1)
    if acc_start > acc_end:
        return np.zeros((NR, NR), dtype=complex), np.zeros(NR), 0

    win = raw_j[:, acc_start:acc_end + 1]   # (NR, n_acc)
    n_acc = acc_end - acc_start + 1

    Z = win @ np.conj(win.T)  # (NR, NR) Hermitian
    Zdiag = np.real(np.diag(Z))   # always real (Σ|raw_k|²)
    return Z, Zdiag, n_acc


def compute_eigvec_weights(
    Z_matrix: np.ndarray,
    antenna_en: int = 0xF,
    cal_j: np.ndarray | None = None,
) -> np.ndarray:
    """
    Firmware eigenvector MRC: principal eigenvector of the full Z matrix.

    Z ≈ h · h^H · n_acc + σ² · I
    The principal eigenvector of Z is the ML channel estimator.

    This is the float-reference firmware path (matches trouper_top architecture).
    The bit-accurate RV32IM fixed-point version is compute_eigvec_fw() in
    eigvec_fw.py; use that for chip-accurate simulation.

    Parameters
    ----------
    Z_matrix  : (NR, NR) complex Hermitian matrix from training_accumulate_allpairs()
    antenna_en: enabled antenna bitmask (bit j = antenna j)
    cal_j     : (NR,) complex Q1.15 calibration coefficients, or None

    Returns
    -------
    w : (NR,) complex Q1.15 weights (conj of principal eigenvector, normalised)
    """
    from .weight_generation import apply_calibration
    from .fixed import quantize_q1_15

    NR = Z_matrix.shape[0]
    mask = np.array([(antenna_en >> j) & 1 for j in range(NR)], dtype=bool)

    # Restrict to enabled branches
    Z = Z_matrix.copy()
    Z[~mask, :] = 0.0
    Z[:, ~mask] = 0.0

    eigvals, eigvecs = np.linalg.eigh(Z)
    v = eigvecs[:, -1]                   # largest eigenvalue → best channel estimate

    if cal_j is not None:
        v = apply_calibration(v, cal_j)

    v[~mask] = 0.0

    max_abs = float(np.max(np.abs(v)))
    if max_abs == 0.0:
        return np.zeros(NR, dtype=complex)
    w = np.conj(v) / max_abs            # w = conj(h_hat), normalised

    return quantize_q1_15(w.real) + 1j * quantize_q1_15(w.imag)


def whiten_z_diagonal(
    Z_matrix: np.ndarray,
    sigma2: np.ndarray,
    n_acc: int,
) -> np.ndarray:
    """
    Remove the per-branch noise pedestal from a Z matrix's diagonal.

        Z_kk' = max(Z_kk - sigma2_k * n_acc, 0)

    Z_kk carries (|h_k|^2 + sigma2_k) * n_acc. With MATCHED branch noise the
    pedestal is a multiple of I: it shifts every eigenvalue equally and leaves
    the eigenvectors untouched, so whitening is a no-op in direction. With
    UNEQUAL branch noise it is not a multiple of I and biases the principal
    eigenvector toward the noisiest branch — the inverse of what MRC should do.
    That asymmetric case is the one this corrects.

    Clamped at zero per branch: a negative diagonal would let the fixed-point
    power iteration (which tracks largest |lambda|, not largest lambda) lock
    onto a negative eigenvalue.

    Parameters
    ----------
    Z_matrix : (NR, NR) complex Hermitian matrix.
    sigma2   : (NR,) per-branch noise power per sample, in the SAME units as
               Z_matrix's entries.
    n_acc    : accumulation sample count.

    Returns
    -------
    Z_w : (NR, NR) complex, whitened copy (input is not modified).
    """
    NR = Z_matrix.shape[0]
    s2 = np.asarray(sigma2, dtype=float)
    Z_w = Z_matrix.copy()
    for k in range(NR):
        Z_w[k, k] = complex(max(Z_matrix[k, k].real - s2[k] * n_acc, 0.0), 0.0)
    return Z_w


def sigma2_is_usable(sigma2: np.ndarray) -> bool:
    """
    True if a per-branch noise estimate is safe to whiten with.

    Rejects a PARTIALLY underflowed estimate — some branches zero, others not.
    That case is worse than not whitening at all: subtracting a pedestal from
    only some branches fabricates an imbalance that was never measured, biasing
    the eigenvector away from the branches that happened to resolve.

    An all-zero estimate is accepted: whitening is then exactly a no-op, which
    is the correct degenerate behaviour.

    Seen for real on silicon-model RTL: an 8-symbol noise window on a live
    capture produced sigma2 = [0.004, 0, 0, 0] because the sigma-delta full
    scale is set by the packet peak, putting the noise floor below one ZDIAG
    LSB on three of four branches (SGE job 3593).
    """
    s2 = np.asarray(sigma2, dtype=float)
    nz = np.count_nonzero(s2)
    return nz == 0 or nz == s2.size


def compute_eigvec_nw_weights(
    Z_matrix: np.ndarray,
    sigma2: np.ndarray,
    n_acc: int,
    antenna_en: int = 0xF,
    cal_j: np.ndarray | None = None,
) -> np.ndarray:
    """
    Float-reference NOISE-WHITENED eigenvector MRC weights.

    Principal eigenvector of `whiten_z_diagonal(Z, sigma2, n_acc)`, falling back
    to the unwhitened matrix if whitening drives the top eigenvalue non-positive
    (over-subtraction at very low SNR).

    This is the float counterpart of `eigvec_fw.compute_eigvec_nw_fw`. Unlike the
    older scalar `sims/compare_mrc_methods.py::_eigvec_nw`, the pedestal is
    PER BRANCH — a scalar sigma2*I cannot rotate an eigenvector at all, so the
    scalar form is structurally unable to correct branch-noise imbalance.

    Callers should gate on `sigma2_is_usable(sigma2)`; this function does not
    enforce it, so that studies can deliberately explore degenerate estimates.

    Parameters
    ----------
    Z_matrix  : (NR, NR) complex Hermitian matrix.
    sigma2    : (NR,) per-branch noise power per sample, same units as Z_matrix.
    n_acc     : accumulation sample count.
    antenna_en: enabled antenna bitmask.
    cal_j     : (NR,) complex Q1.15 calibration coefficients, or None.

    Returns
    -------
    w : (NR,) complex Q1.15 weights.
    """
    Z_w = whiten_z_diagonal(Z_matrix, sigma2, n_acc)
    eigvals = np.linalg.eigvalsh(Z_w)
    if eigvals[-1] <= 0:
        Z_w = Z_matrix
    return compute_eigvec_weights(Z_w, antenna_en=antenna_en, cal_j=cal_j)


def compute_eigvec_snr_weights(
    Z_matrix: np.ndarray,
    sigma2: np.ndarray,
    n_acc: int,
    antenna_en: int = 0xF,
    cal_j: np.ndarray | None = None,
) -> np.ndarray:
    """
    Full noise-whitened (SNR-weighted) eigenvector MRC weights — float reference.

    Distinct from `compute_eigvec_nw_weights`, and the difference matters:

      * `compute_eigvec_nw_weights` subtracts the noise pedestal from the
        diagonal. That recovers Z' ~ n_acc * h*h^H, whose principal eigenvector
        is h, so it returns conj(h) — the EQUAL-noise optimum. It removes the
        bias that pulls the raw eigenvector onto the noisiest branch, but it
        never applies a 1/sigma2_k factor.
      * this function additionally applies the similarity transform
        D^-1/2 Z' D^-1/2 (D = diag(sigma2)), takes the principal eigenvector
        v~ of the transformed matrix, then maps back with D^-1/2. Since
        v~ ∝ D^-1/2 h, the result is D^-1 h — the true UNEQUAL-noise optimum
        w ∝ conj(h_k)/sigma2_k.

    Worked example (h identical on all branches, ant0 10x noisier), weights
    normalised to max 1:

        raw eigenvector          [1.000, 0.023, 0.023, 0.023]   broken
        pedestal subtraction     [1.000, 1.000, 1.000, 1.000]   de-biased
        this function            [0.100, 1.000, 1.000, 1.000]   optimal
        theory D^-1 h            [0.100, 1.000, 1.000, 1.000]

    Degenerate sigma2 (any non-positive entry) cannot be transformed, so the
    function falls back to `compute_eigvec_nw_weights`. Callers should still
    gate on `sigma2_is_usable`.

    Parameters
    ----------
    Z_matrix  : (NR, NR) complex Hermitian matrix.
    sigma2    : (NR,) per-branch noise power per sample, same units as Z_matrix.
    n_acc     : accumulation sample count.
    antenna_en: enabled antenna bitmask.
    cal_j     : (NR,) complex Q1.15 calibration coefficients, or None.

    Returns
    -------
    w : (NR,) complex Q1.15 weights.
    """
    from .fixed import quantize_q1_15
    from .weight_generation import apply_calibration

    NR = Z_matrix.shape[0]
    s2 = np.asarray(sigma2, dtype=float)
    mask = np.array([(antenna_en >> j) & 1 for j in range(NR)], dtype=bool)

    if np.any(s2[mask] <= 0):
        # No usable per-branch scale — de-bias only.
        return compute_eigvec_nw_weights(Z_matrix, sigma2, n_acc,
                                         antenna_en=antenna_en, cal_j=cal_j)

    Z_w = whiten_z_diagonal(Z_matrix, s2, n_acc)
    if np.linalg.eigvalsh(Z_w)[-1] <= 0:
        Z_w = Z_matrix

    inv_sqrt = np.where(mask, 1.0 / np.sqrt(np.where(s2 > 0, s2, 1.0)), 0.0)
    D_inv = np.diag(inv_sqrt)

    Z_t = D_inv @ Z_w @ D_inv
    Z_t[~mask, :] = 0.0
    Z_t[:, ~mask] = 0.0

    v_t = np.linalg.eigh(Z_t)[1][:, -1]
    v = inv_sqrt * v_t                  # map back: D^-1/2 v~  ∝  D^-1 h

    if cal_j is not None:
        v = apply_calibration(v, cal_j)
    v[~mask] = 0.0

    max_abs = float(np.max(np.abs(v)))
    if max_abs == 0.0:
        return np.zeros(NR, dtype=complex)
    w = np.conj(v) / max_abs
    return quantize_q1_15(w.real) + 1j * quantize_q1_15(w.imag)


def noise_est_rtl(
    raw_j: np.ndarray,
    sc_lock_sample: int,
    sample_rate: float = 125e3,
) -> np.ndarray:
    """
    Legacy bit-accurate model of the removed standalone noise_est.v block.

    Active Trouper RTL uses firmware-triggered training_acc noise windows and
    Zdiag readback instead; keep this helper only for old notebooks/comparisons.

    Accumulates Manhattan norm Σ(|I_k|+|Q_k|) per branch for all samples
    before sc_lock, using a 24-bit unsigned accumulator. Returns the 8-bit
    snapshot (acc[23:16]) taken at sc_lock.

    Parameters
    ----------
    raw_j         : (NR, N) complex int8 samples from DC removal output
    sc_lock_sample: index at which sc_lock fires (accumulation stops here)
    sample_rate   : unused, kept for API clarity

    Returns
    -------
    noise_snap : (NR,) uint8 array — acc[23:16] per branch
    """
    NR = raw_j.shape[0]
    acc = np.zeros(NR, dtype=np.uint32)

    for n in range(sc_lock_sample):
        raw_i = np.clip(np.round(raw_j[:, n].real), -128, 127).astype(np.int32)
        raw_q = np.clip(np.round(raw_j[:, n].imag), -128, 127).astype(np.int32)
        # |x| ≈ bitwise flip for negative (off by 1 LSB — irrelevant for ratios)
        abs_i = np.where(raw_i < 0, ~raw_i & 0xFF, raw_i).astype(np.uint32)
        abs_q = np.where(raw_q < 0, ~raw_q & 0xFF, raw_q).astype(np.uint32)
        man = abs_i + abs_q  # Manhattan norm, max 254, 9-bit
        acc = (acc + man) & 0xFFFFFF  # 24-bit unsigned wrap

    return ((acc >> 16) & 0xFF).astype(np.uint8)


def cfo_diagnostic(Z_j: np.ndarray) -> float:
    """
    Pooled CFO diagnostic from training accumulator output.

    Not used in the weight computation path — diagnostic readback only.
    Note: with the cross-correlation scheme, Z_j = h_j·conj(h_ref) so
    angle(C_pool) reflects the spread of h_j phases, not CFO directly.
    This function is retained for compatibility but its interpretation
    changes with the cross-correlation scheme.
    """
    C_pool = np.sum(Z_j)
    return -float(np.angle(C_pool))
