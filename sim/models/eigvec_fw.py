"""
Firmware-accurate fixed-point eigenvector weight computation.

Models the power-iteration path in firmware/picorv32/main.c::compute_eigvec_weights_fw().

All arithmetic mirrors the RV32IM int32 constraints:
  - int12 normalisation shift to prevent accumulator overflow
  - int32 matrix-vector products (no wider intermediates needed)
  - power-of-2 renormalisation between iterations (no division in the loop)
  - final Q1.15 output via int32 truncating division

The model also reproduces the ZDIAG hardware register truncation: the diagonal
of Z is stored as bits [31:8] of the 32-bit accumulator (widened from the
original [31:16] — see `planning/blocks/Training Accumulator.md`), so the
lower 8 bits are discarded before the normalisation step. This matches the
scale of the off-diagonal Zpair registers exactly, so no separate
scale-alignment shift between diagonal and off-diagonal is needed.

Reference spec: planning/blocks/Eigenvector Weight Computation.md
Float reference: sim/models/training_accumulator.py::compute_eigvec_weights()
"""

import math
import numpy as np

from .training_accumulator import sigma2_is_usable

_SCALE_BITS = 12        # normalise matrix entries to ±(2^12 - 1) = 4095
_ITERS      = 8         # power-iteration count
_INIT_SCALE = 1 << _SCALE_BITS   # 4096 — starting eigenvector magnitude
_G_BITS     = 15        # Q bits for the per-branch D^-1/2 scale (SNR weighting)


def _norm_shift(max_val: int, scale_bits: int) -> int:
    """Smallest sh >= 0 such that max_val >> sh <= 2**scale_bits - 1."""
    thresh = (1 << scale_bits) - 1
    sh, mv = 0, max_val
    while mv > thresh:
        mv >>= 1
        sh += 1
    return sh


def _trunc_div(a: int, b: int) -> int:
    """Integer division truncating toward zero — matches C `int / int`."""
    if a >= 0:
        return a // b
    return -((-a) // b)


def _isqrt32(v: int) -> int:
    """Integer square root, bit-by-bit — matches the firmware `isqrt32()`.

    No multiply, no float. Used for the per-branch D^-1/2 scale so the model
    stays bit-accurate to RV32IM firmware (a float sqrt here would diverge).
    """
    if v <= 0:
        return 0
    rem, root, bit = 0, 0, 1 << 30
    while bit > v:
        bit >>= 2
    x = v
    while bit:
        if x >= root + bit:
            x -= root + bit
            root = (root >> 1) + bit
        else:
            root >>= 1
        bit >>= 2
    return root


def _asr(value: int, sh: int) -> int:
    """Arithmetic right-shift of a Python int, matching C `int32_t >>` on signed values."""
    if sh <= 0:
        return value
    # Python's signed >> is an arithmetic (sign-extending) shift, matching the
    # deployed PicoRV32/GCC behaviour.  Do not emulate C division here:
    # division truncates negative values toward zero, whereas an ASR rounds
    # toward negative infinity (e.g. -9 >> 1 == -5).
    return value >> sh


def compute_eigvec_fw(
    Z_matrix: np.ndarray,
    n_acc: int,
    iters: int = _ITERS,
    scale_bits: int = _SCALE_BITS,
    sigma2_zdiag: np.ndarray | None = None,
    strict: bool = True,
    snr_weight: bool = False,
    register_units: bool = False,
) -> np.ndarray:
    """
    Firmware-accurate fixed-point eigenvector weight computation.

    Finds the principal eigenvector of the 4×4 Hermitian channel correlation
    matrix Z via fixed-point power iteration, then returns conj(v) as Q1.15
    MRC combining weights — bit-accurate to the RV32IM firmware implementation.

    The diagonal of Z_matrix is truncated to its upper 24 bits before processing
    to match the ZDIAG hardware register representation (bits [31:8] of the
    32-bit energy accumulator — the same scale as the off-diagonal Zpair
    registers).

    Parameters
    ----------
    Z_matrix   : (4, 4) complex Hermitian matrix from the training accumulator.
                 Off-diagonal values should be in int32 range; diagonal must be
                 non-negative real (Σ|raw_k|²).
    n_acc      : accumulation sample count. Returns zero weights if 0.
    iters      : power-iteration step count (default 8, matches firmware).
    scale_bits : normalisation target bits (default 12, matches firmware).
    sigma2_zdiag : optional (4,) per-branch noise power per sample, in the
                 SAME units as Z_matrix's own entries. When Z is read from the
                 register bank (both Z_kl and ZDIAG are bits [31:8]) that is
                 ZDIAG units, so `NoiseFloorEstimator.estimate` can be passed
                 directly; when Z is a full-scale float matrix, pass σ² at full
                 scale. σ²_k·n_acc is subtracted from each diagonal entry
                 before iteration. See `compute_eigvec_nw_fw`.
    snr_weight : when True, additionally apply the D^-1/2 similarity transform
                 so the result is the UNEQUAL-noise optimum conj(D^-1 h) rather
                 than the equal-noise optimum conj(h). See
                 `compute_eigvec_snrw_fw`.
    register_units : when True, `Z_matrix` is already the 24-bit SPI readback
                 representation (Z_kl/ZDIAG bits [31:8]), as consumed by
                 firmware. This is the mode for bit-for-bit firmware tests.

    Returns
    -------
    w : (4,) complex ndarray, Q1.15 weights. Conjugate of the principal
        eigenvector, max-component normalised. Returns zeros if n_acc == 0
        or the matrix is identically zero after truncation.
    """
    NR = Z_matrix.shape[0]

    if n_acc == 0:
        return np.zeros(NR, dtype=complex)

    init_scale = 1 << scale_bits

    # ------------------------------------------------------------------
    # Step 0 — Reproduce ZDIAG register truncation.
    # The diagonal is stored as bits [31:8] of the 32-bit accumulator —
    # the same scale as the off-diagonal Zpair registers.
    # ------------------------------------------------------------------
    diag_full = np.array([int(round(Z_matrix[k, k].real)) for k in range(NR)])

    # ------------------------------------------------------------------
    # Step 0b — Optional noise whitening. Z_kk carries (|h_k|² + σ²_k)·n_acc;
    # subtracting σ²_k·n_acc removes the noise pedestal that otherwise tilts
    # the principal eigenvector toward the noisiest branch.
    #
    # Applied to `diag_full`, i.e. at the SAME scale as the caller's Z_matrix
    # entries, BEFORE the >>8 below — sigma2_zdiag is specified in those units.
    # Subtracting after the shift would be 256x too large.
    #
    # Clamped at 0: an over-subtraction must not flip a diagonal negative,
    # which would let power iteration lock onto a negative eigenvalue
    # (it converges on largest |λ|, not largest λ).
    # ------------------------------------------------------------------
    if sigma2_zdiag is not None:
        s2 = np.asarray(sigma2_zdiag, dtype=np.float64)
        if strict and not sigma2_is_usable(s2):
            raise ValueError(
                f"partially underflowed sigma2 {list(s2)}: some branches are zero "
                f"and some are not. Whitening this fabricates a branch imbalance "
                f"that was never measured. Gate on NoiseFloorEstimator.valid and "
                f"skip whitening, lengthen the noise window, or pass strict=False "
                f"to override deliberately.")
        pedestal = np.array([int(s2[k] * n_acc) for k in range(NR)], dtype=np.int64)
        whitened = np.maximum(diag_full - pedestal, 0)
        # Full-cancellation guard: if whitening flattens every diagonal to
        # zero the matrix carries no usable scale, so keep the raw diagonal.
        if np.any(whitened > 0):
            diag_full = whitened

    zdiag_reg = (diag_full if register_units else
                 np.array([v >> 8 for v in diag_full], dtype=np.int64))

    # ------------------------------------------------------------------
    # Step 1 — Find common normalisation shift.
    # Compare off-diagonal int32 components with diagonal at full scale.
    # ------------------------------------------------------------------
    max_abs = 1
    for k in range(NR):
        for l in range(k + 1, NR):
            max_abs = max(max_abs,
                          abs(int(round(Z_matrix[k, l].real))),
                          abs(int(round(Z_matrix[k, l].imag))))
    for k in range(NR):
        max_abs = max(max_abs, int(zdiag_reg[k] if register_units else zdiag_reg[k] << 8))

    sh = _norm_shift(max_abs, scale_bits)

    # Build normalised int32 upper-triangle off-diagonal entries.
    # M[k,l] = Z_kl >> sh for k < l; M[l,k] = conj(M[k,l]).
    m_re = [[0]*NR for _ in range(NR)]
    m_im = [[0]*NR for _ in range(NR)]
    for k in range(NR):
        for l in range(k + 1, NR):
            ri = _asr(int(round(Z_matrix[k, l].real)), sh)
            ii = _asr(int(round(Z_matrix[k, l].imag)), sh)
            m_re[k][l] =  ri;  m_re[l][k] =  ri
            m_im[k][l] =  ii;  m_im[l][k] = -ii   # Hermitian conjugate

    # Full-accumulator callers need to undo ZDIAG's [31:8] truncation before
    # the common shift. Firmware/register callers already have matched-scale
    # 24-bit ZDIAG and off-diagonal entries, so use the shift directly.
    net = sh if register_units else sh - 8
    diag = []
    for k in range(NR):
        zd = int(zdiag_reg[k])
        diag.append(_asr(zd, net) if net >= 0 else zd << (-net))

    if all(d == 0 for d in diag) and all(m_re[k][l] == 0 and m_im[k][l] == 0
                                          for k in range(NR) for l in range(NR) if k != l):
        return np.zeros(NR, dtype=complex)

    # ------------------------------------------------------------------
    # Step 1b — Per-branch D^-1/2 scale for full SNR weighting (optional).
    #
    # De-biasing the diagonal alone returns conj(h), the EQUAL-noise optimum.
    # The UNEQUAL-noise optimum is conj(D^-1 h), reached by iterating on the
    # similarity transform  Z~ = D^-1/2 Z' D^-1/2  and mapping the result back
    # through D^-1/2 (see training_accumulator.compute_eigvec_snr_weights).
    #
    # Z~ is built ONCE, here, from the ALREADY-NORMALISED matrix. That ordering
    # is what keeps this cheap on picorv32:
    #
    #   * scaling the raw matrix would need Z' (<=2^24) x gg (<=2^15) = 2^39,
    #     i.e. a 32x32->64 product. That is available on RV32IM as MUL+MULH,
    #     but picorv32 with ENABLE_FAST_MUL=0 costs 40 cycles for MUL and
    #     *72* for MULH (ip/picorv32/README.md) -- 112 cycles per entry.
    #   * scaling AFTER the >>sh normalisation, entries are <=2^12, so
    #     2^12 x 2^15 = 2^27 fits in int32: one 40-cycle MUL, no MULH at all.
    #
    # Cost: 10 pairwise gg products + 16 entry scalings = 26 MUL, ~1040 cycles,
    # once. The power-iteration loop below is then completely untouched, so its
    # existing int32 overflow bound still applies verbatim. (Folding G into the
    # loop instead would be 136 MUL / ~5440 cycles for the same 8 iterations.)
    #
    # gg for the quietest branch pair is ~2^15, so the largest entries keep
    # their full 12-bit scale and no renormalisation pass is needed.
    # ------------------------------------------------------------------
    g = None
    if snr_weight and sigma2_zdiag is not None:
        s2 = np.asarray(sigma2_zdiag, dtype=np.float64)
        if np.all(s2 > 0):
            # Integer path, bit-identical to firmware: g_k ~ 1/sqrt(sigma2_k),
            # normalised so the quietest branch gets full scale. Working from
            # integer sqrts makes this g_k = GMAX * s_min / s_k with s = isqrt,
            # which needs only isqrt + one divu per branch -- no float, no
            # reciprocal-sqrt table.
            gmax = (1 << _G_BITS) - 1
            # sigma2 may be fractional here (ZDIAG units); scale into an integer
            # domain first, exactly as firmware does with its Q16 EMA state.
            s2_q = [max(1, int(x * (1 << 16))) for x in s2]
            sq = [max(1, _isqrt32(x)) for x in s2_q]
            s_min = min(sq)
            g = [max(1, min(gmax, (gmax * s_min) // sq[k])) for k in range(NR)]
        # else: no usable per-branch scale -> de-bias only (g stays None)

    if g is not None:
        for k in range(NR):
            gg_kk = (g[k] * g[k]) >> _G_BITS
            diag[k] = _asr(diag[k] * gg_kk, _G_BITS)
        # Firmware stores/scales only the upper triangle and reconstructs the
        # reverse entry by conjugation in the MAC equations.  Scaling both
        # sides independently can round a tiny imaginary component differently
        # (e.g. +1 -> 0 while -1 -> -1), breaking Hermitian symmetry.
        for k in range(NR):
            for l in range(k + 1, NR):
                gg = (g[k] * g[l]) >> _G_BITS
                m_re[k][l] = _asr(m_re[k][l] * gg, _G_BITS)
                m_im[k][l] = _asr(m_im[k][l] * gg, _G_BITS)
                m_re[l][k] = m_re[k][l]
                m_im[l][k] = -m_im[k][l]

    # ------------------------------------------------------------------
    # Step 2 — Power iteration.
    # Starting vector v = [init_scale, 0, 0, 0]^T (real).
    # ------------------------------------------------------------------
    vr = [init_scale, 0, 0, 0]
    vi = [0,          0, 0, 0]

    for _ in range(iters):
        wr = [0] * NR
        wi = [0] * NR

        # w = Z_norm * v, exploiting Z[l,k] = conj(Z[k,l])
        for k in range(NR):
            acc_r = diag[k] * vr[k]
            acc_i = diag[k] * vi[k]
            for l in range(NR):
                if l == k:
                    continue
                acc_r += m_re[k][l] * vr[l] - m_im[k][l] * vi[l]
                acc_i += m_re[k][l] * vi[l] + m_im[k][l] * vr[l]
            # Clamp to int32 range (should never fire given scale_bits=12 proof,
            # but makes the model safe for unusual inputs)
            wr[k] = max(-2**31, min(2**31 - 1, acc_r))
            wi[k] = max(-2**31, min(2**31 - 1, acc_i))

        # Renormalise to ±init_scale via power-of-2 right-shift.
        wmx = max(1, max(abs(x) for x in wr + wi))
        sh2 = 0
        tmp = wmx
        while tmp > init_scale:
            tmp >>= 1
            sh2 += 1

        vr = [_asr(x, sh2) for x in wr]
        vi = [_asr(x, sh2) for x in wi]

    # Map the converged eigenvector of Z~ back through D^-1/2: w = G v~.
    # One scaling, 8 MUL. Operand is <= init_scale so this also stays 32-bit.
    if g is not None:
        vr = [_asr(vr[k] * g[k], _G_BITS) for k in range(NR)]
        vi = [_asr(vi[k] * g[k], _G_BITS) for k in range(NR)]

    # ------------------------------------------------------------------
    # Step 3 — Convert to Q1.15.
    # w_k = conj(v_k) / max_component, scaled to 32767.
    # Conjugate = negate imaginary part.
    # ------------------------------------------------------------------
    vmx = max(1, max(abs(x) for x in vr + vi))
    w_re = [_trunc_div( x * 32767, vmx) for x in vr]
    w_im = [_trunc_div(-x * 32767, vmx) for x in vi]   # conjugate

    return np.array(w_re, dtype=np.int16) / 32768.0 + \
           1j * np.array(w_im, dtype=np.int16) / 32768.0


def compute_eigvec_nw_fw(
    Z_matrix: np.ndarray,
    n_acc: int,
    sigma2_zdiag: np.ndarray,
    iters: int = _ITERS,
    scale_bits: int = _SCALE_BITS,
    strict: bool = True,
) -> np.ndarray:
    """
    Noise-whitened fixed-point eigenvector weights — firmware-accurate.

    Identical to `compute_eigvec_fw` except that the per-branch noise pedestal
    is removed from the diagonal before power iteration:

        Z_kk' = max(ZDIAG_k − σ²_k · n_acc, 0)

    Why it matters: the training accumulator's diagonal holds
    (|h_k|² + σ²_k)·n_acc. With matched branch noise the pedestal is a common
    σ²·I term, which shifts every eigenvalue equally and leaves the eigenvectors
    untouched — whitening is then a no-op in direction and only costs estimator
    noise. With *unequal* branch noise the pedestal is no longer a multiple of
    I: it biases the principal eigenvector toward the noisiest branch, exactly
    inverting what MRC should do. That is the failure this corrects.

    Firmware cost is 4 multiplies and 4 subtractions on top of the power
    iteration already required for the plain eigenvector path.

    Parameters
    ----------
    Z_matrix     : (4, 4) complex Hermitian matrix from the training accumulator.
    n_acc        : accumulation sample count from N_ACC (0x21-0x23).
    sigma2_zdiag : (4,) per-branch noise power per sample, in the SAME units as
                   Z_matrix's entries. Reading Z over SPI gives ZDIAG units for
                   both diagonal and off-diagonal (all bits [31:8]), so
                   `NoiseFloorEstimator.estimate` can be passed straight in with
                   no scale alignment. For a full-scale float Z, pass full-scale σ².
    iters        : power-iteration step count (default 8, matches firmware).
    scale_bits   : normalisation target bits (default 12, matches firmware).

    Returns
    -------
    w : (4,) complex ndarray, Q1.15 weights.

    Caveats
    -------
    - Whitening is clamped at zero per branch, so it cannot drive a diagonal
      negative. It does not guarantee the whitened matrix is PSD; at very low
      SNR a residual negative eigenvalue could in principle exceed the signal
      eigenvalue in magnitude, and power iteration tracks largest |λ|. The
      clamp bounds this but does not eliminate it — see the low-SNR test in
      `sim/tests/test_eigvec_nw_fw.py`.
    - With matched branch noise this is slightly *worse* than the unwhitened
      path because σ̂² carries estimator error while the true correction is a
      no-op in direction. Gate on measured branch imbalance rather than
      applying unconditionally.
    - `strict=True` (default) rejects a partially underflowed σ² — some branches
      zero, some not — because whitening that fabricates an imbalance that was
      never measured. Gate callers on `NoiseFloorEstimator.valid`. Real capture
      data hits this: see that property's docstring.
    """
    return compute_eigvec_fw(
        Z_matrix, n_acc, iters=iters, scale_bits=scale_bits,
        sigma2_zdiag=sigma2_zdiag, strict=strict,
    )


def compute_eigvec_snrw_fw(
    Z_matrix: np.ndarray,
    n_acc: int,
    sigma2_zdiag: np.ndarray,
    iters: int = _ITERS,
    scale_bits: int = _SCALE_BITS,
    strict: bool = True,
    register_units: bool = False,
) -> np.ndarray:
    """
    Full noise-whitened (SNR-weighted) fixed-point eigenvector weights.

    Fixed-point counterpart of
    `training_accumulator.compute_eigvec_snr_weights`, and one step beyond
    `compute_eigvec_nw_fw`:

        compute_eigvec_fw       -> conj(h_hat) from raw Z. Biased toward the
                                   noisiest branch when sigma2 is unequal,
                                   because Z_kk carries (|h_k|^2 + sigma2_k)*n_acc.
        compute_eigvec_nw_fw    -> subtracts the pedestal. Recovers conj(h),
                                   the EQUAL-noise optimum. Bias removed, but no
                                   1/sigma2_k weighting.
        compute_eigvec_snrw_fw  -> also applies D^-1/2 on both sides and maps
                                   back, giving conj(D^-1 h), the UNEQUAL-noise
                                   optimum.

    Implementation note: Z~ is never materialised. The per-branch scale
    G = diag(g), g_k ~ 1/sqrt(sigma2_k) in Q15, is folded into the power
    iteration as G (Z' (G v)) -- 16 extra RV32IM multiplies per iteration and
    no divides in the loop. A single reciprocal-sqrt per branch is computed
    once up front.

    Falls back to de-biasing only (`compute_eigvec_nw_fw` behaviour) if any
    sigma2 entry is non-positive, since D^-1/2 is undefined there.

    Parameters
    ----------
    Z_matrix     : (4, 4) complex Hermitian matrix.
    n_acc        : accumulation sample count.
    sigma2_zdiag : (4,) per-branch noise power per sample, in the SAME units as
                   Z_matrix's entries (see `compute_eigvec_fw`).
    iters        : power-iteration step count.
    scale_bits   : normalisation target bits.
    strict       : reject a partially underflowed sigma2 (see
                   `compute_eigvec_nw_fw`).

    Returns
    -------
    w : (4,) complex ndarray, Q1.15 weights.
    """
    return compute_eigvec_fw(
        Z_matrix, n_acc, iters=iters, scale_bits=scale_bits,
        sigma2_zdiag=sigma2_zdiag, strict=strict, snr_weight=True,
        register_units=register_units,
    )
