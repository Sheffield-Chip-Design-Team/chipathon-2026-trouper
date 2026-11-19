"""
Representative SX1257-style receive ΣΔ stream — the reference that the SX1302
was designed to accept on RADIO_A_IQ (I/Q 1-bit, 32 MS/s).

SX1257 DS Rev 1.2 §3.7.2: each of I and Q is a 5th-order continuous-time ΣΔ
ADC, one bit per channel at 32 MS/s, "13 bits of resolution after decimation
and filtering ... within a 500 kHz maximum bandwidth". The real NTF is not
published, so this is a discrete-time stand-in with the same order, rate and
band: python-deltasigma synthesizeNTF(order=5, OSR=32, opt=1, H_inf=1.5)
(OSR 32 = 32 MS/s over a ±500 kHz complex / 500 kHz real band), realised as
a CIFB loop, simulated in float with an ideal ±1
quantizer. It is a *reference shape* for the noise the SX1302's decimators
expect — not a model of the SX1257's analog front end.

Use: `Sx1257AdcRef().modulate(x)` with x complex at 32 MS/s, |x| relative to
the ±1 output full scale. Stable to ~0.6 FS per rail (5th-order 1-bit MSA);
a float loop driven past that diverges and does not recover.

The designed ABCD is frozen below so the model has no runtime dependency on
python-deltasigma (unmaintained, needs local patches to import — see
planning/sd-remod-4th-order-fix-2026-09-04.md §7). `_design()` regenerates it.
"""
from __future__ import annotations

import warnings

import numpy as np

FS = 32e6
ORDER = 5
OSR = 32
H_INF = 1.5


# _design() output, frozen 2026-10-03. Rows: x1..x5 update, then quantizer
# input; columns: x1..x5, u, v.
ABCD = np.array([
    [1.0, 0.0, 0.0, 0.0, 0.0, 0.0006755598059134787, -0.0006755598059134787],
    [1.0, 1.0, -0.002792010846255452, 0.0, 0.0, 0.0, -0.009545995627554787],
    [0.0, 1.0, 1.0, 0.0, 0.0, 0.0, -0.0730810689163975],
    [0.0, 0.0, 1.0, 1.0, -0.007893734761635431, 0.0, -0.3099546586870676],
    [0.0, 0.0, 0.0, 1.0, 1.0, 0.0, -0.8129770352659391],
    [0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0],
])
NTF_ZEROS = np.array([1.0, 0.9986030187986338 + 0.05283948188859777j,
                      0.9986030187986338 - 0.05283948188859777j,
                      0.996045312843931 + 0.08884669246311554j,
                      0.996045312843931 - 0.08884669246311554j])
NTF_POLES = np.array([0.806556961971758 - 0.11982270863624665j,
                      0.806556961971758 + 0.11982270863624665j,
                      0.8980709825087387 - 0.21981938660789452j,
                      0.8980709825087387 + 0.21981938660789452j,
                      0.7777670757730486])


def _design():
    """Regenerate (ntf, ABCD) with python-deltasigma."""
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        import deltasigma as ds
        ntf = ds.synthesizeNTF(ORDER, OSR, 1, H_INF)
        a, g, b, c = ds.realizeNTF(ntf, "CIFB")
        b = np.r_[b[0], np.zeros(len(b) - 1)]       # input only into stage 1
        abcd = ds.stuffABCD(a, g, b, c, "CIFB")
    # No dynamic-range scaling: in a float simulation it does not change the
    # output bits (and ds.scaleABCD is broken under modern numpy).
    return ntf, np.asarray(abcd, dtype=float)


class Sx1257AdcRef:
    """Float 5th-order CIFB 1-bit modulator, one instance per I/Q rail pair."""

    def __init__(self):
        self.ntf, abcd = (NTF_ZEROS, NTF_POLES, 1.0), ABCD
        n = ORDER
        self.A = abcd[:n, :n]
        self.B = abcd[:n, n:n + 2]          # [u, v] columns
        self.C = abcd[n:n + 1, :n]
        self.D1 = float(abcd[n, n])         # direct u -> quantizer (0 for CIFB)

    def _rail(self, u: np.ndarray) -> np.ndarray:
        A, B, C, D1 = self.A, self.B, self.C[0], self.D1
        Bu, Bv = B[:, 0], B[:, 1]
        # Unroll into python floats: ~3x faster than per-sample numpy matmul.
        A = A.tolist(); Bu = Bu.tolist(); Bv = Bv.tolist(); C = C.tolist()
        n = ORDER
        x = [0.0] * n
        out = np.empty(len(u), dtype=np.int8)
        for k, uk in enumerate(u.tolist()):
            y = D1 * uk
            for i in range(n):
                y += C[i] * x[i]
            v = 1.0 if y >= 0 else -1.0
            x = [sum(A[r][j] * x[j] for j in range(n)) + Bu[r] * uk + Bv[r] * v
                 for r in range(n)]
            out[k] = 1 if v > 0 else -1
        return out

    def modulate(self, x: np.ndarray) -> np.ndarray:
        """x: complex 32 MS/s, full scale ±1. Returns complex ±1±1j."""
        x = np.asarray(x)
        return self._rail(x.real).astype(float) + 1j * self._rail(x.imag).astype(float)
