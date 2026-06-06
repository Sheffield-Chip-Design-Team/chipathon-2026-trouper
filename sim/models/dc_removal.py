"""
DC Removal model — per-branch IIR running-mean subtraction.

Stage 3 in the DSP Flow. Corresponds to dc_removal.v.

Two implementations:

DCRemoval (floating-point, configurable alpha_shift)
    Legacy model used by existing notebooks. Floating-point arithmetic,
    alpha_shift is a free parameter. Note: alpha_shift=8 on 8-bit inputs is
    BROKEN in the old RTL — >>> 8 on a max 9-bit difference always yields 0 for
    positive errors, so the filter never tracked positive DC offsets.

DCRemovalRTL (bit-accurate, matches dc_removal.v)
    Mirrors the simplified RTL: 12-bit Q8.4 accumulator, fixed α = 2^{-4}.
    Input clamped to int8 [-128, 127], output is int8.
    The output uses the DC estimate from the PREVIOUS cycle (pre-update acc).
"""

import numpy as np


class DCRemoval:
    """
    Floating-point per-branch IIR DC removal.

    Parameters
    ----------
    nr          : number of receive branches (default 4)
    alpha_shift : time constant = 2^alpha_shift samples. Default 8.
                  NOTE: alpha_shift=8 is BROKEN for 8-bit integer inputs
                  (>>> 8 on a 9-bit difference = 0 for positive errors).
                  Use DCRemovalRTL for the current bit-accurate model.
    """

    def __init__(self, nr: int = 4, alpha_shift: int = 8):
        self.nr = nr
        self.alpha_shift = alpha_shift
        self._dc_est = np.zeros(nr, dtype=np.complex128)

    def reset(self) -> None:
        self._dc_est[:] = 0.0

    def process(self, samples: np.ndarray) -> np.ndarray:
        """
        Process one block of samples, updating the running DC estimate.

        Parameters
        ----------
        samples : (NR, N) complex array at decimator output rate

        Returns
        -------
        out : (NR, N) complex, DC removed
        """
        NR, N = samples.shape
        assert NR == self.nr, f"Expected {self.nr} branches, got {NR}"
        out = np.empty_like(samples)
        alpha = float(2 ** self.alpha_shift)

        for n in range(N):
            self._dc_est += (samples[:, n] - self._dc_est) / alpha
            out[:, n] = samples[:, n] - self._dc_est

        return out


class DCRemovalRTL:
    """
    Bit-accurate model of dc_removal.v (simplified RTL, committed b8c8f0d).

    12-bit Q8.4 accumulators, fixed α = 2^{-4}, int8 I/O.

    Algorithm (per branch, per component):
        diff    = clip(raw, -128, 127) - acc[11:4]   (9-bit signed)
        err     = diff sign-extended to 12-bit         (full diff, no /16)
        acc_new = clip(acc + err, -2048, 2047)         (12-bit)
        out     = clip(raw - acc[11:4], -128, 127)     (uses PRE-update acc)

    The update is acc += diff (not diff>>4). This eliminates the +ve DC deadband:
        Old diff>>4: floor(diff/16) = 0 for 0 < diff < 16 → stalls
        New diff:    always non-zero for diff ≠ 0 → symmetric convergence
    Time constant is unchanged: τ = 16 samples = 128 µs at 125 kHz.

    Time constant τ = 16 samples = 128 µs at 125 kHz (CIC R=128).

    Parameters
    ----------
    nr : number of receive branches (default 4)
    """

    def __init__(self, nr: int = 4):
        self.nr = nr
        # acc is 12-bit signed integer (Q8.4); stored as int32 for arithmetic
        self._acc_i = np.zeros(nr, dtype=np.int32)
        self._acc_q = np.zeros(nr, dtype=np.int32)

    def reset(self) -> None:
        self._acc_i[:] = 0
        self._acc_q[:] = 0

    @staticmethod
    def _step(raw: np.ndarray, acc: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        """Single sample update. raw: int8 array, acc: int32 (12-bit range)."""
        raw_i8 = np.clip(np.round(raw), -128, 127).astype(np.int32)
        dc_est = (acc >> 4).astype(np.int32)          # acc[11:4]
        diff   = raw_i8 - dc_est                       # 9-bit signed, full value
        # err = diff sign-extended to 12-bit (no /16) — eliminates +ve deadband
        err    = np.clip(diff, -256, 255).astype(np.int32)
        acc_new = np.clip(acc + err, -2048, 2047).astype(np.int32)
        out = np.clip(raw_i8 - dc_est, -128, 127).astype(np.int8)
        return out, acc_new

    def process(self, samples: np.ndarray) -> np.ndarray:
        """
        Process one block of complex samples.

        Parameters
        ----------
        samples : (NR, N) complex array. Values treated as int8 (clamped to [-128,127]).

        Returns
        -------
        out : (NR, N) complex int8 array (values in [-128, 127])
        """
        NR, N = samples.shape
        assert NR == self.nr
        out_r = np.empty((NR, N), dtype=np.float64)
        out_i = np.empty((NR, N), dtype=np.float64)

        for n in range(N):
            o_r, self._acc_i = self._step(samples[:, n].real, self._acc_i)
            o_q, self._acc_q = self._step(samples[:, n].imag, self._acc_q)
            out_r[:, n] = o_r.astype(float)
            out_i[:, n] = o_q.astype(float)

        return out_r + 1j * out_i
