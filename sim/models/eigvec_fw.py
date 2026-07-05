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

_SCALE_BITS = 12        # normalise matrix entries to ±(2^12 - 1) = 4095
_ITERS      = 8         # power-iteration count
_INIT_SCALE = 1 << _SCALE_BITS   # 4096 — starting eigenvector magnitude


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


def _asr(value: int, sh: int) -> int:
    """Arithmetic right-shift of a Python int, matching C `int32_t >>` on signed values."""
    if sh <= 0:
        return value
    if value >= 0:
        return value >> sh
    return -((-value) >> sh)


def compute_eigvec_fw(
    Z_matrix: np.ndarray,
    n_acc: int,
    iters: int = _ITERS,
    scale_bits: int = _SCALE_BITS,
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
    zdiag_reg = np.array([v >> 8 for v in diag_full], dtype=np.int64)   # upper 24 bits only

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
        max_abs = max(max_abs, int(zdiag_reg[k] << 8))   # compare at int32 scale

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

    # Diagonal: (zdiag_reg[k] << 8) >> sh -- same scale as off-diagonal, so no
    # separate scale-alignment case is needed (net is always >= 0 in practice
    # since sh grows with matrix magnitude, but keep the >=0 guard for safety).
    net = sh - 8
    diag = []
    for k in range(NR):
        zd = int(zdiag_reg[k])
        diag.append(_asr(zd, net) if net >= 0 else zd << (-net))

    if all(d == 0 for d in diag) and all(m_re[k][l] == 0 and m_im[k][l] == 0
                                          for k in range(NR) for l in range(NR) if k != l):
        return np.zeros(NR, dtype=complex)

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
