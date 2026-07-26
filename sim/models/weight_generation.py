"""
Weight Generation model — hardware FSM path.

Corresponds to planning/blocks/Weight Generation.md.

Hardware FSM state sequence:
    IDLE → SHIFT → CALIBRATE → COMPUTE → SCALE → WRITE → IDLE

The SHIFT state applies an SF-normalised right-shift: Z is right-shifted by sf
bits before latching into the 18-bit H register. This is the RTL behaviour
introduced in commit 034f2f6 (weight_gen area opt). K is always 0 in the RTL;
shift_normalise() returns sf as K for diagnostic use by callers.

mrc_norm_shift follows the 3-level RTL logic keyed on bits 17 and 16 of the
18-bit peak_abs value (after calibration).
"""

import numpy as np
from .fixed import quantize_q1_15


# ---------------------------------------------------------------------------
# Noise floor estimator — firmware policy model
# ---------------------------------------------------------------------------

# Fractional bits carried by the integer EMA state. Two separate constraints
# both want fractional bits:
#
#  1. EMA deadband. The increment is (x - s) >> alpha_shift in integer
#     arithmetic, which stalls whenever the difference is under 2^alpha_shift.
#  2. Representable noise floor. sigma2 per sample is ZDIAG_k / n_acc, a RATIO
#     -- so it underflows to zero whenever ZDIAG_k / n_acc < 2^-frac_bits.
#     NOTE this is NOT fixed by a longer noise window: lengthening the window
#     scales ZDIAG_k and n_acc together and leaves the ratio unchanged.
#
# Real capture data forced this from 8 to 16: an 8-symbol window gave
# ZDIAG = [11, 7, 5, 4] at n_acc = 2048, i.e. sigma2 ~ 0.0034 ZDIAG units per
# sample, just under the Q8 floor of 1/256 = 0.0039 -- three of four branches
# floored to zero (SGE job 3593). Q16 resolves them.
#
# Firmware note: (zdiag << 16) with a 24-bit ZDIAG reaches 2^40, so the RV32IM
# implementation needs a 64-bit intermediate (__udivdi3) for this divide. The
# alternative, if that cost is unacceptable, is to skip the per-sample form and
# carry the pedestal directly as ZDIAG_noise * n_acc_sig / n_acc_noise with the
# multiply first -- same precision, one 64/32 divide, no fractional state.
NFE_FRAC_BITS = 16


def zdiag_from_energy(energy_sum: np.ndarray) -> np.ndarray:
    """Convert a full-scale Σ|x|² accumulator to its ZDIAG register value.

    Hardware exposes ZDIAG_k as bits [31:8] of the 32-bit accumulator
    (`Register Map.md` 0x64–0x6F), so the low byte is not readable.
    """
    return (np.asarray(energy_sum).astype(np.int64)) >> 8


class NoiseFloorEstimator:
    """
    Firmware-side per-branch noise floor estimator — ZDIAG source.

    Models the noise-window policy that Trouper actually implements:

        1. firmware waits for PACKET_ACTIVE = 0
        2. firmware writes TACC_NOISE_TRIG (0x1F[0]) to arm a window of
           TACC_WINDOW_SYMS x M samples without sc_lock (TRPR-TAC-007)
        3. on NOISE_READY (IRQ_STATUS[4]) — the hardware SC-contamination
           gate — firmware reads ZDIAG_k (0x64-0x6F) and N_ACC (0x21-0x23)
        4. per-branch EMA update, sigma2_k ~= ZDIAG_k / n_acc

    This replaces the pre-2026-07 policy that polled free-running ENERGY[0..3]
    registers; that block was removed with `noise_est.v` and those registers no
    longer exist. The `noise_thresh` near-far guard is retained as an optional
    firmware-side second line of defence behind the NOISE_READY gate.

    Arithmetic is integer throughout and mirrors what RV32IM firmware runs:
    the state is a fixed-point value with `NFE_FRAC_BITS` fractional bits and
    the EMA is a shift-and-add, so there is no float on the firmware path.

    Parameters
    ----------
    NR          : number of receive branches
    alpha_shift : EMA decay exponent; alpha = 2^(-alpha_shift). Default 4 → α=0.0625.
    noise_thresh: optional per-branch threshold, in ZDIAG-register units per
                  sample, above which the window is rejected. None disables it.
    frac_bits   : fractional bits in the integer EMA state.

    Units
    -----
    `estimate` is returned in **ZDIAG register units per sample** — the same
    scale as the Z_kl off-diagonal readback, since both are bits [31:8]. That
    makes `estimate * n_acc` directly subtractable from a ZDIAG-scale diagonal
    (see `eigvec_fw.compute_eigvec_nw_fw`) with no scale-alignment step.
    Use `estimate_full_scale` for the untruncated int32 accumulator scale.
    """

    def __init__(
        self,
        NR: int,
        alpha_shift: int = 4,
        noise_thresh: float | None = None,
        frac_bits: int = NFE_FRAC_BITS,
    ):
        self.NR = NR
        self.alpha_shift = alpha_shift
        self.alpha = 2.0 ** (-alpha_shift)
        self.noise_thresh = noise_thresh
        self.frac_bits = frac_bits
        self._sigma2_q = np.zeros(NR, dtype=np.int64)   # Q(frac_bits), ZDIAG units
        self._n_updates = 0
        self._n_rejected = 0

    def update(self, zdiag: np.ndarray, n_acc: int) -> bool:
        """
        Attempt a noise floor update from one completed noise window.

        Parameters
        ----------
        zdiag : (NR,) per-branch ZDIAG_k as read from 0x64-0x6F — bits [31:8]
                of the Σ|raw_k|² accumulator. Pass `zdiag_from_energy(E)` if
                starting from a full-scale energy sum.
        n_acc : accumulated sample count from N_ACC (0x21-0x23).

        Returns
        -------
        accepted : True if the guard passed and the EMA was updated.
        """
        if n_acc <= 0:
            self._n_rejected += 1
            return False

        zd = np.asarray(zdiag).astype(np.int64)

        # Per-sample noise power in Q(frac_bits), ZDIAG units. Integer divide
        # matches the RV32IM `divu` firmware would issue.
        x_q = (zd << self.frac_bits) // np.int64(n_acc)

        # Optional near-far guard, behind the hardware NOISE_READY gate.
        if self.noise_thresh is not None:
            thresh_q = np.int64(self.noise_thresh * (1 << self.frac_bits))
            if np.any(x_q > thresh_q):
                self._n_rejected += 1
                return False

        if self._n_updates == 0:
            self._sigma2_q = x_q.copy()          # cold-start: seed, don't decay up
        else:
            # s += (x - s) >> alpha_shift, with arithmetic (floor) shift.
            diff = x_q - self._sigma2_q
            self._sigma2_q = self._sigma2_q + (diff >> self.alpha_shift)
        self._n_updates += 1
        return True

    @property
    def estimate(self) -> np.ndarray:
        """Per-branch σ²_j per sample, in ZDIAG register units (float view)."""
        return self._sigma2_q.astype(float) / (1 << self.frac_bits)

    @property
    def estimate_q(self) -> np.ndarray:
        """Raw integer EMA state, Q(frac_bits) — the bit-exact firmware value."""
        return self._sigma2_q.copy()

    @property
    def estimate_full_scale(self) -> np.ndarray:
        """Per-branch σ²_j per sample at the untruncated int32 accumulator scale."""
        return self.estimate * 256.0

    @property
    def underflow_mask(self) -> np.ndarray:
        """Per-branch True where the EMA state has quantised to exactly zero.

        Happens when ZDIAG_k * 2^frac_bits < n_acc, i.e. the branch's noise
        floor is below the estimator's resolution for that window length.
        """
        return self._sigma2_q == 0

    @property
    def valid(self) -> bool:
        """
        True if `estimate` is safe to whiten with.

        False for a PARTIALLY underflowed estimate — some branches zero, others
        not. Whitening on that fabricates a branch imbalance that was never
        measured, which is worse than not whitening at all. An all-zero estimate
        is 'valid' in the sense that whitening becomes an exact no-op.

        Observed on real capture data: an 8-symbol window gave
        ZDIAG = [11, 7, 5, 4] at n_acc = 2048 -> sigma2 = [0.004, 0, 0, 0],
        three branches underflowed (SGE job 3593). The sigma-delta full scale is
        set by the packet peak, so a quiet noise floor lands below one ZDIAG LSB.
        The remedy is more `frac_bits` (the default is now 16, which resolves
        that case). A longer noise window does NOT help on its own: sigma2 is
        the ratio ZDIAG_k / n_acc and lengthening the window scales both.
        """
        if self._n_updates == 0:
            return False
        nz = int(np.count_nonzero(self._sigma2_q))
        return nz == 0 or nz == self.NR

    def resolution_floor(self, n_acc: int) -> float:
        """Smallest per-sample σ² this estimator can represent for `n_acc`.

        Below this a branch underflows to zero. Useful for sizing the noise
        window: ZDIAG_k must reach about n_acc / 2^frac_bits to resolve at all.
        """
        return 1.0 / (1 << self.frac_bits) if n_acc > 0 else float("inf")

    @property
    def n_updates(self) -> int:
        return self._n_updates

    @property
    def n_rejected(self) -> int:
        return self._n_rejected


def _norm_shift_from_peak(peak: float) -> int:
    """RTL mrc_norm_shift: 3-level keyed on bits 17 and 16 of 18-bit peak_abs.

    Matches weight_gen.v:
        peak_abs[17] ? 2 : peak_abs[16] ? 1 : 0
    """
    peak_i = int(abs(round(float(peak))))
    if peak_i >= (1 << 17):  # bit 17 set (≥ 131072)
        return 2
    if peak_i >= (1 << 16):  # bit 16 set (≥ 65536)
        return 1
    return 0


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


def shift_normalise(Z_j: np.ndarray, sf: int = 7) -> tuple[np.ndarray, int]:
    """
    SHIFT state: SF-normalised right-shift matching weight_gen.v ST_IDLE latch.

    RTL behaviour (commit 034f2f6): H = (Z >>> sf)[17:0].  The shift is the
    spreading-factor value (6–12), not a peak-derived K.  K is always 0 inside
    the RTL but returned here as sf for callers that use it for E_ref scaling.

    The arithmetic right-shift is modelled as floor(component / 2^sf), which
    matches Python's integer >> operator and the Verilog >>> operator for both
    positive and negative values.

    Returns
    -------
    H_j : (NR,) complex, sf-shifted channel estimates (float arithmetic)
    K   : int, sf (bits shifted; always == sf regardless of amplitude)
    """
    scale = float(1 << sf)
    H_re = np.floor(Z_j.real / scale)
    H_im = np.floor(Z_j.imag / scale)
    return (H_re + 1j * H_im).astype(complex), sf


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

    def process(self, Z_j: np.ndarray, sf: int = 7, E_ref: float | None = None) -> tuple[np.ndarray, int]:
        """
        Run the full FSM from Z_j to Q1.15 weights.

        Parameters
        ----------
        Z_j   : (NR,) complex channel estimates from training_accumulate()
        sf    : spreading factor (6–12). Used by the SHIFT state to right-shift
                Z by sf bits before calibration. Matches weight_gen.v sf input.
        E_ref : retained for API compatibility. Hardware MRC ignores it because
                normalization is an SF-based shift, not an exact divide.

        Returns
        -------
        w : (NR,) complex Q1.15 weights
        K : sf (bits shifted in the SHIFT state; diagnostic)
        """
        H_j, K = shift_normalise(Z_j, sf=sf)
        H_j_cal = apply_calibration(H_j, self.cal_j)
        w = compute_weights_hw(H_j_cal, mode=self.mode, antenna_en=self.antenna_en,
                               E_ref_H=None)
        return w, K


def compute_exact_mrc_weights(
    Z_j: np.ndarray,
    sf: int = 7,
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
    H_j, K = shift_normalise(Z_j, sf=sf)
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


def compute_sw_mrc_weights(
    Z_j: np.ndarray,
    antenna_en: int = 0xF,
    cal_j: np.ndarray | None = None,
) -> np.ndarray:
    """
    True SW MRC — no SHIFT, exact conj(Z)/Σ|Z|² on raw accumulator output.

    Legacy comparison path: Z_j is a per-branch vector (e.g. W_k row-sum or
    Z_kl cross-correlation), used to evaluate the float-arithmetic SW MRC limit.
    trouper_top firmware uses the eigenvector path instead (compute_eigvec_fw).

    All three SW improvements over hw_mrc are applied here:
      1. Skip shift_normalise — no truncation of the raw accumulators
      2. Exact division conj(Z)/Σ|Z|² instead of coarse power-of-2 scale
      3. Normalised to max|w|=1 before Q1.15 quantisation to use full range
    """
    NR = len(Z_j)
    mask = np.array([(antenna_en >> j) & 1 for j in range(NR)], dtype=bool)
    Z = apply_calibration(Z_j, cal_j).copy()
    Z[~mask] = 0.0
    S = float(np.sum(np.abs(Z) ** 2))
    if S == 0.0:
        return np.zeros(NR, dtype=complex)
    w = np.conj(Z) / S
    max_abs = float(np.max(np.abs(w)))
    if max_abs > 0:
        w = w / max_abs
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
