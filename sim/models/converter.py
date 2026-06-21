import numpy as np


class ADCModel:
    """Stage 1 — ΣΔ ADC (Simplified)."""

    def __init__(self, bits: int = 1):
        self.bits = bits

    def process(self, signal: np.ndarray) -> np.ndarray:
        return np.sign(signal.real) + 1j * np.sign(signal.imag)


class SigmaDeltaRemodulator:
    """
    Stage 8 — 3rd-order CIFF ΣΔ re-modulator. Matches sd_remod.v exactly.

    Architecture: Cascade of Integrators, Feed-Forward (CIFF).
      Three saturating integrators; Q8 weighted feed-forward summer; sign quantizer.
      Coefficients from synthesizeNTF(order=3, OSR=64) via python-deltasigma.
      Matches SX1257 datasheet §6.2.3 Figure 6-3.

    Normalised convention: input |x| <= 1.0, feedback = ±1.0.
    Integrators saturate at ±CLIP (= 32767/127, matching int16/int8 ratio in RTL).
    Input must be < −3 dBFS (|x| < 0.708) for stability.
    """

    A1   = 205 / 256   # 0.800 — Q8 coefficient matching RTL
    A2   =  74 / 256   # 0.289
    A3   =  11 / 256   # 0.043
    CLIP = 32767 / 127  # integrator saturation limit in normalised units (~258)

    def __init__(self, order: int = 3):
        # `order` kept for API compatibility; always 3rd-order CIFF
        self.order = order
        self._s1 = self._s2 = self._s3 = 0j
        self._prev_fb = 0j

    def reset(self):
        self._s1 = self._s2 = self._s3 = 0j
        self._prev_fb = 0j

    def _sat(self, v: complex) -> complex:
        c = self.CLIP
        return complex(max(-c, min(c, v.real)), max(-c, min(c, v.imag)))

    def process(self, sample: complex) -> complex:
        """Process one complex sample. Returns ±1+j·±1 (1-bit per I/Q)."""
        e = sample - self._prev_fb
        self._s1 = self._sat(self._s1 + e)
        self._s2 = self._sat(self._s2 + self._s1)
        self._s3 = self._sat(self._s3 + self._s2)
        v = e + self.A1 * self._s1 + self.A2 * self._s2 + self.A3 * self._s3
        q = (1.0 if v.real >= 0 else -1.0) + 1j * (1.0 if v.imag >= 0 else -1.0)
        self._prev_fb = q
        return q

    def process_block(self, samples: np.ndarray) -> np.ndarray:
        """Process a block of complex samples. Returns ±1+j·±1 array."""
        out = np.empty(len(samples), dtype=complex)
        for i, s in enumerate(samples):
            out[i] = self.process(s)
        return out
