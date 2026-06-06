import numpy as np


class ADCModel:
    """Stage 1 — ΣΔ ADC (Simplified)."""

    def __init__(self, bits: int = 1):
        self.bits = bits

    def process(self, signal: np.ndarray) -> np.ndarray:
        return np.sign(signal.real) + 1j * np.sign(signal.imag)


class SigmaDeltaRemodulator:
    """
    Stage 8 — MASH 1-1-1 ΣΔ re-modulator.

    Three cascaded 1st-order stages; unconditionally stable for any bounded input.
    NTF = (1 − z⁻¹)³ — quantisation noise is 3rd-order high-pass shaped.

    Each stage k:
        u_k[n] = e_{k-1}[n]  +  s_k[n-1]     (e₀ = input x)
        q_k[n] = sign(u_k[n])
        s_k[n] = u_k[n] − q_k[n]              (integrator state = quantisation error)

    process() / process_block() return q₁ (1-bit output of stage 1).
    The full 3rd-order combined output Y = q₁ + Δq₂ + Δ²q₃ (multi-level)
    is available via mash_combine() after a process_block() call.

    Input must be normalised to |x| < 0.9 for stable operation.
    """

    def __init__(self, order: int = 3):
        self.order = order
        self._states = [0j] * order   # integrator state per stage (= error from prev sample)
        self._q_arr: list[np.ndarray] = []   # filled by process_block for mash_combine

    def reset(self):
        self._states = [0j] * self.order
        self._q_arr = []

    def process(self, sample: complex) -> complex:
        """Process one complex sample. Returns q₁ (1-bit)."""
        x = sample
        q1 = None
        for k in range(self.order):
            u = x + self._states[k]
            q = np.sign(u.real) + 1j * np.sign(u.imag)
            self._states[k] = u - q   # state becomes current error
            if k == 0:
                q1 = q
            x = self._states[k]       # next stage input is current stage error
        return q1

    def process_block(self, samples: np.ndarray) -> np.ndarray:
        """
        Process a block of complex samples. Returns q₁ array (1-bit).
        Also stores per-stage outputs internally for mash_combine().
        """
        n = len(samples)
        qs = [np.zeros(n, dtype=complex) for _ in range(self.order)]
        x_in = samples.copy()

        for k in range(self.order):
            x_out = np.zeros(n, dtype=complex)
            s = self._states[k]
            for i in range(n):
                u = x_in[i] + s
                q = np.sign(u.real) + 1j * np.sign(u.imag)
                s = u - q
                qs[k][i] = q
                x_out[i] = s     # next stage input = current error
            self._states[k] = s
            x_in = x_out         # error feeds next stage

        self._q_arr = qs
        return qs[0]             # 1-bit output from stage 1

    def mash_combine(self) -> np.ndarray:
        """
        Return the full MASH combined output after process_block():
            Y = q₁ + Δq₂ + Δ²q₃
        This multi-level signal has NTF = (1−z⁻¹)³ and is used for
        SQNR analysis. Normalise by 3 before LPF for unit-scale.
        """
        if not self._q_arr:
            raise RuntimeError("Call process_block() before mash_combine()")
        q1 = self._q_arr[0].real
        if self.order >= 2:
            dq2 = np.diff(self._q_arr[1].real, prepend=0)
        else:
            dq2 = np.zeros_like(q1)
        if self.order >= 3:
            ddq3 = np.diff(np.diff(self._q_arr[2].real, prepend=0), prepend=0)
        else:
            ddq3 = np.zeros_like(q1)
        return q1 + dq2 + ddq3
