import numpy as np


class ADCModel:
    """Stage 1 — ΣΔ ADC (Simplified)."""

    def __init__(self, bits: int = 1):
        self.bits = bits

    def process(self, signal: np.ndarray) -> np.ndarray:
        return np.sign(signal.real) + 1j * np.sign(signal.imag)


class SigmaDeltaRemodulator:
    """
    Stage 8 — CIFF ΣΔ re-modulator. `order=3` (default) matches sd_remod.v exactly.

    Architecture: Cascade of Integrators, Feed-Forward (CIFF).
      N saturating integrators; Q8 weighted feed-forward summer; sign quantizer.
      Coefficients from synthesizeNTF(order, OSR=64, H_inf=1.5) via python-deltasigma.
      order=3 matches SX1257 datasheet §6.2.3 Figure 6-3 / deployed RTL.
      order=2 is the B3 area-cut candidate (planning/area-reduction-roadmap.md §7) —
      NOT deployed in RTL; coefficients derived the same way for a fair comparison.

    Normalised convention: input |x| <= 1.0, feedback = ±1.0.
    Integrators saturate at ±CLIP (= 32767/127, matching int16/int8 ratio in RTL).
    Input must be < −3 dBFS (|x| < 0.708) for 3rd-order stability (RTL header).
    """

    # Q8 feed-forward coefficients, round(synthesizeNTF(order, OSR=64, H_inf=1.5) * 256) / 256.
    # order=3 verified to reproduce the deployed RTL constants (sd_remod.v A1/A2/A3 = 205/74/11).
    _COEFFS = {
        2: (198 / 256, 55 / 256),          # 0.7734, 0.2148 — B3 candidate, not in RTL
        3: (205 / 256, 74 / 256, 11 / 256),  # 0.800, 0.289, 0.043 — matches sd_remod.v
    }
    CLIP = 32767 / 127  # integrator saturation limit in normalised units (~258)

    def __init__(self, order: int = 3):
        if order not in self._COEFFS:
            raise ValueError(f"order must be one of {sorted(self._COEFFS)}")
        self.order = order
        self._a = self._COEFFS[order]
        self._s = [0j] * order
        self._prev_fb = 0j

    # Back-compat accessors for the 3rd-order-only call sites (notebook 14, debug scripts)
    @property
    def A1(self): return self._a[0]
    @property
    def A2(self): return self._a[1]
    @property
    def A3(self): return self._a[2] if self.order >= 3 else 0.0
    @property
    def _s1(self): return self._s[0]
    @property
    def _s2(self): return self._s[1]
    @property
    def _s3(self): return self._s[2] if self.order >= 3 else 0j

    def reset(self):
        self._s = [0j] * self.order
        self._prev_fb = 0j

    def _sat(self, v: complex) -> complex:
        c = self.CLIP
        return complex(max(-c, min(c, v.real)), max(-c, min(c, v.imag)))

    def process(self, sample: complex) -> complex:
        """Process one complex sample. Returns ±1+j·±1 (1-bit per I/Q)."""
        e = sample - self._prev_fb
        v = e
        prev = e
        for k in range(self.order):
            prev = self._sat(self._s[k] + prev)
            self._s[k] = prev
            v = v + self._a[k] * prev
        q = (1.0 if v.real >= 0 else -1.0) + 1j * (1.0 if v.imag >= 0 else -1.0)
        self._prev_fb = q
        return q

    def process_block(self, samples: np.ndarray) -> np.ndarray:
        """Process a block of complex samples. Returns ±1+j·±1 array."""
        out = np.empty(len(samples), dtype=complex)
        for i, s in enumerate(samples):
            out[i] = self.process(s)
        return out
