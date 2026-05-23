"""
Weight Generation model — hardware FSM path.

Corresponds to planning/blocks/Weight Generation.md.

Hardware FSM state sequence:
    IDLE → SHIFT → CALIBRATE → COMPUTE → SCALE → WRITE → IDLE

The SHIFT state applies the same common right shift used by the RTL: the
largest I/Q component is brought into the signed Q1.15-friendly range before
calibration. Hardware MRC then preserves branch ratios with a conservative
power-of-two scale rather than an exact reciprocal/divide.
"""

import numpy as np
from .fixed import quantize_q1_15


# ---------------------------------------------------------------------------
# Noise floor estimator — firmware policy model
# ---------------------------------------------------------------------------

class NoiseFloorEstimator:
    """
    Firmware-side per-branch noise floor estimator.

    Models the idle-state noise sampling policy from Weight Generation.md:
    when packet_phase == IDLE, sc_lock is inactive, and all per-branch
    energy_j < noise_thresh, firmware reads ENERGY[0..3] and updates
    a per-branch EMA of the noise power.

    Parameters
    ----------
    NR          : number of receive branches
    alpha_shift : EMA decay exponent; alpha = 2^(-alpha_shift). Default 4 → α=0.0625.
    noise_thresh: per-branch per-sample energy threshold above which the near-far
                  guard rejects the symbol window. None disables the guard.
    """

    def __init__(
        self,
        NR: int,
        alpha_shift: int = 4,
        noise_thresh: float | None = None,
    ):
        self.NR = NR
        self.alpha = 2.0 ** (-alpha_shift)
        self.noise_thresh = noise_thresh
        self._sigma2_j = np.zeros(NR)
        self._n_updates = 0
        self._n_rejected = 0

    def update(self, energy_sum_j: np.ndarray, n_window: int) -> bool:
        """
        Attempt a noise floor update from one symbol window.

        Parameters
        ----------
        energy_sum_j : (NR,) per-branch Σ|x|² over the symbol window (ENERGY registers)
        n_window     : samples in the window (M = 2^SF)

        Returns
        -------
        accepted : True if the near-far guard passed and the EMA was updated
        """
        energy_per_sample = energy_sum_j / n_window

        # Near-far guard: reject if any branch exceeds threshold
        if self.noise_thresh is not None and np.any(energy_per_sample > self.noise_thresh):
            self._n_rejected += 1
            return False

        if self._n_updates == 0:
            self._sigma2_j = energy_per_sample.copy()   # cold-start: seed the EMA
        else:
            self._sigma2_j = (
                (1.0 - self.alpha) * self._sigma2_j + self.alpha * energy_per_sample
            )
        self._n_updates += 1
        return True

    @property
    def estimate(self) -> np.ndarray:
        """Current per-branch noise power estimate σ²_j (per sample)."""
        return self._sigma2_j.copy()

    @property
    def n_updates(self) -> int:
        return self._n_updates

    @property
    def n_rejected(self) -> int:
        return self._n_rejected


def _norm_shift_from_peak(peak: float) -> int:
    """RTL-compatible shift: keep the peak signed component below 2^15."""
    peak_i = int(abs(round(float(peak))))
    if peak_i <= 0x7FFF:
        return 0
    return max(0, int(np.floor(np.log2(float(peak_i)))) - 14)


def _branch_headroom(mask: np.ndarray) -> int:
    """Conservative coherent-add headroom used by hardware MRC."""
    count = int(np.count_nonzero(mask))
    if count <= 1:
        return 0
    if count == 2:
        return 1
    return 2


def _round_ashr(v: float, sh: int) -> int:
    """Match RTL round_ashr32(): add/subtract half-LSB before arithmetic shift."""
    vi = int(round(float(v)))
    if sh <= 0:
        return vi
    bias = 1 << (sh - 1)
    if vi < 0:
        return (vi - bias) >> sh
    return (vi + bias) >> sh


def shift_normalise(Z_j: np.ndarray) -> tuple[np.ndarray, int]:
    """
    SHIFT state: reduce Z_j to the signed Q1.15-friendly range via common K.

    K is selected from the largest absolute I/Q component across all branches.
    The same shift is applied to every branch, preserving relative magnitudes
    and phases before calibration.

    Returns
    -------
    H_j : (NR,) complex, shifted channel estimates
    K   : int, bits shifted (0 if already in range)
    """
    max_component = float(max(
        np.max(np.abs(Z_j.real)),
        np.max(np.abs(Z_j.imag)),
    ))
    if max_component == 0.0:
        return np.zeros_like(Z_j, dtype=complex), 0
    K = _norm_shift_from_peak(max_component)
    return (Z_j / (2 ** K)).astype(complex), K


def apply_calibration(H_j: np.ndarray, cal_j: np.ndarray | None) -> np.ndarray:
    """
    CALIBRATE state: H_j_cal = H_j * conj(cal_j).

    cal_j : (NR,) complex Q1.15 calibration coefficients.
            None = unity (no correction, default).
    """
    if cal_j is None:
        return H_j.copy()
    return H_j * np.conj(cal_j)


def compute_weights_hw(
    H_j_cal: np.ndarray,
    mode: str = "mrc",
    antenna_en: int = 0xF,
    E_ref_H: float | None = None,
) -> np.ndarray:
    """
    COMPUTE + SCALE states: produce Q1.15 combining weights.

    The hardware MRC path is intentionally approximate: it emits
    conj(H_j_cal) shifted by a shared power-of-two scale. This preserves the
    MRC branch ratios without a divider/reciprocal. E_ref_H is accepted for API
    compatibility with older simulations but is not used by the hardware path.

    Parameters
    ----------
    H_j_cal   : (NR,) complex calibrated channel estimates after SHIFT
    mode      : 'mrc' | 'egc' | 'sc' | 'bypass'
    antenna_en: bitmask of enabled antennas (bit j = antenna j)
    E_ref_H   : ignored by hardware MRC; exact/oracle MRC uses a separate helper

    Returns
    -------
    w : (NR,) complex Q1.15 weights
    """
    NR = len(H_j_cal)
    mask = np.array([(antenna_en >> j) & 1 for j in range(NR)], dtype=bool)
    H = H_j_cal.copy()
    H[~mask] = 0.0

    if mode == "bypass":
        w = np.zeros(NR, dtype=complex)
        enabled = np.flatnonzero(mask)
        if len(enabled):
            w[enabled[0]] = 1.0 + 0j
        return w

    if mode == "sc":
        mag_sq = np.abs(H) ** 2
        mag_sq[~mask] = -1.0
        j_best = int(np.argmax(mag_sq))
        w = np.zeros(NR, dtype=complex)
        if mask[j_best]:
            w[j_best] = 1.0 + 0j
        return w

    if mode == "egc":
        mag = np.abs(H)
        safe_mag = np.where(mag > 0, mag, 1.0)
        w = np.where(mag > 0, np.conj(H) / safe_mag, 0j)
        w[~mask] = 0.0
        return quantize_q1_15(w.real) + 1j * quantize_q1_15(w.imag)

    if mode == "mrc":
        peak = float(max(np.max(np.abs(H.real)), np.max(np.abs(H.imag))))
        if peak == 0.0:
            return np.zeros(NR, dtype=complex)
        mrc_shift = _norm_shift_from_peak(peak) + _branch_headroom(mask)
        w_re = np.array([_round_ashr(h.real, mrc_shift) if en else 0
                         for h, en in zip(H, mask)], dtype=float)
        w_im = np.array([_round_ashr(-h.imag, mrc_shift) if en else 0
                         for h, en in zip(H, mask)], dtype=float)
        w_re = np.clip(w_re, -32768, 32767)
        w_im = np.clip(w_im, -32768, 32767)
        return (w_re / 2**15) + 1j * (w_im / 2**15)

    raise ValueError(f"Unknown mode {mode!r}. Use 'mrc', 'egc', 'sc', or 'bypass'.")


class WeightGenerator:
    """
    Hardware weight generation FSM model.

    Models the full SHIFT → CALIBRATE → COMPUTE → SCALE → WRITE path.
    Input is Z_j (int64-range complex from the training accumulator);
    output is W (Q1.15 complex) ready to write to W_HW registers.

    Parameters
    ----------
    mode      : combining mode ('mrc', 'egc', 'sc', 'bypass')
    antenna_en: enabled antenna bitmask (default 0xF = all four)
    cal_j     : (NR,) complex Q1.15 calibration coefficients, or None

    Usage
    -----
    wgen = WeightGenerator(mode='mrc')
    w, K = wgen.process(Z_j)
    """

    def __init__(
        self,
        mode: str = "mrc",
        antenna_en: int = 0xF,
        cal_j: np.ndarray | None = None,
    ):
        self.mode = mode
        self.antenna_en = antenna_en
        self.cal_j = cal_j

    def process(self, Z_j: np.ndarray, E_ref: float | None = None) -> tuple[np.ndarray, int]:
        """
        Run the full FSM from Z_j to Q1.15 weights.

        Parameters
        ----------
        Z_j   : (NR,) complex channel estimates from training_accumulate()
        E_ref : retained for API compatibility. Hardware MRC ignores it because
                normalization is a conservative shared shift, not an exact divide.

        Returns
        -------
        w : (NR,) complex Q1.15 weights
        K : common shift applied in the SHIFT state (diagnostic)
        """
        H_j, K = shift_normalise(Z_j)
        H_j_cal = apply_calibration(H_j, self.cal_j)
        w = compute_weights_hw(H_j_cal, mode=self.mode, antenna_en=self.antenna_en,
                               E_ref_H=None)
        return w, K


def compute_exact_mrc_weights(
    Z_j: np.ndarray,
    antenna_en: int = 0xF,
    cal_j: np.ndarray | None = None,
    E_ref: float | None = None,
) -> np.ndarray:
    """
    Exact/oracle normalized MRC retained for algorithm sweeps and comparison.

    This is not the hardened hardware path. It represents firmware/offline MRC
    that can afford division: w_j = conj(H_j) * E_ref_H / Σ|H_k|² when E_ref is
    provided, otherwise w_j = conj(H_j) / Σ|H_k|².
    """
    H_j, K = shift_normalise(Z_j)
    H = apply_calibration(H_j, cal_j)
    NR = len(H)
    mask = np.array([(antenna_en >> j) & 1 for j in range(NR)], dtype=bool)
    H = H.copy()
    H[~mask] = 0.0
    S = float(np.sum(np.abs(H) ** 2))
    if S == 0.0:
        return np.zeros(NR, dtype=complex)
    E_ref_H = E_ref / (2 ** K) if (E_ref is not None and K >= 0) else None
    if E_ref_H is not None and E_ref_H > 0.0:
        w = np.conj(H) * E_ref_H / S
    else:
        w = np.conj(H) / S
    return quantize_q1_15(w.real) + 1j * quantize_q1_15(w.imag)


# ---------------------------------------------------------------------------
# SW-path noise-weighted MRC — firmware computes via W_SHADOW
# ---------------------------------------------------------------------------

def compute_nw_mrc_weights(
    Z_j: np.ndarray,
    sigma2_j: np.ndarray,
    n_acc: int,
    antenna_en: int = 0xF,
) -> np.ndarray:
    """
    SW-path noise-weighted MRC.

    w_j = conj(Z_j) / σ²_j

    This is the optimal MRC combiner with per-branch noise weighting.
    With equal σ²_j it is exactly proportional to plain MRC (same branch
    ratios, different overall scale which cancels in demodulation).
    With unequal σ²_j, high-noise branches are downweighted relative to
    low-noise branches, recovering diversity gain that plain MRC loses when
    branch noise floors differ.

    Contrast with the per-branch MMSE form conj(Z_j)/(|Z_j|²+σ²_j·n_acc),
    which has a signal-dependent denominator per branch and does NOT reduce
    to plain MRC even when noise is equal.

    σ²_j is obtained from NoiseFloorEstimator.estimate after sufficient idle
    symbol windows have been accumulated.

    Parameters
    ----------
    Z_j      : (NR,) complex cross-correlation from training_accumulate()
    sigma2_j : (NR,) per-branch noise power estimate (per sample) from NoiseFloorEstimator
    n_acc    : accumulation sample count (unused in weight formula; retained for API symmetry)
    antenna_en : enabled antenna bitmask (bit j = antenna j)

    Returns
    -------
    w : (NR,) complex Q1.15 weights
    """
    NR = len(Z_j)
    mask = np.array([(antenna_en >> j) & 1 for j in range(NR)], dtype=bool)

    Z = Z_j.copy().astype(complex)
    Z[~mask] = 0.0

    s2 = sigma2_j.copy().astype(float)
    s2[~mask] = np.inf   # disabled branches → zero weight

    safe_s2 = np.where(s2 > 0, s2, 1.0)
    w_raw = np.where(mask, np.conj(Z) / safe_s2, 0.0 + 0.0j)

    # Normalise to fill Q1.15: scale so max |w_j| = 1
    max_abs = np.max(np.abs(w_raw))
    if max_abs > 0:
        w_raw = w_raw / max_abs

    return quantize_q1_15(w_raw.real) + 1j * quantize_q1_15(w_raw.imag)
