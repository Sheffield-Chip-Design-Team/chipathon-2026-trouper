"""
Float eigenvector weight computation via power iteration.

This is the float reference for the firmware path — identical algorithm
structure to the fixed-point implementation in eigvec_fw.py but using
float64 throughout.  Use this to validate method correctness and iteration
count before introducing fixed-point constraints.
"""

import numpy as np


def eigvec_power_iter(
    Z: np.ndarray,
    iters: int = 8,
    v0: np.ndarray | None = None,
) -> np.ndarray:
    """
    Principal eigenvector of a Hermitian matrix via power iteration.

    Equivalent to np.linalg.eigh(Z)[1][:, -1] but with a controllable
    iteration count, matching the firmware algorithm structure.

    Parameters
    ----------
    Z     : (NR, NR) complex Hermitian matrix.
    iters : number of power-iteration steps.
    v0    : starting vector; defaults to e_0 = [1, 0, ..., 0].

    Returns
    -------
    v : (NR,) complex, unit-inf-norm principal eigenvector.
    """
    NR = Z.shape[0]
    v = np.array([1.0] + [0.0] * (NR - 1), dtype=complex) if v0 is None else v0.copy()

    for _ in range(iters):
        w = Z @ v
        mx = np.max(np.abs(w))
        if mx == 0.0:
            return np.zeros(NR, dtype=complex)
        v = w / mx

    return v


def compute_eigvec_weights_float(
    Z: np.ndarray,
    iters: int = 8,
    v0: np.ndarray | None = None,
) -> np.ndarray:
    """
    MRC weights from the principal eigenvector of Z, float precision.

    w = conj(v) / max|v|  — ready to write to the Q1.15 weight bank.

    Parameters
    ----------
    Z     : (NR, NR) complex Hermitian matrix from the training accumulator.
    iters : power-iteration steps (default 8, matches firmware).
    v0    : optional warm-start vector.

    Returns
    -------
    w : (NR,) complex float weights, max component magnitude = 1.
    """
    v = eigvec_power_iter(Z, iters=iters, v0=v0)
    mx = np.max(np.abs(v))
    if mx == 0.0:
        return np.zeros(Z.shape[0], dtype=complex)
    return np.conj(v) / mx
