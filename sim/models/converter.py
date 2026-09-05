import numpy as np


class ADCModel:
    """Stage 1 — ΣΔ ADC (Simplified)."""

    def __init__(self, bits: int = 1):
        self.bits = bits

    def process(self, signal: np.ndarray) -> np.ndarray:
        return np.sign(signal.real) + 1j * np.sign(signal.imag)


class SigmaDeltaRemodulator:
    """
    Stage 8 — CIFF ΣΔ re-modulator reference. STALE as of 2026-09-04: this class's
    cascade propagates each integrator stage's just-updated value within the same
    sample (zero extra loop delay) -- not physically realizable in a real clocked
    circuit, where the quantizer decision must be registered (see sd_remod.v
    header for the full "excess loop delay" derivation). Deployed RTL is now a
    4th-order loop with real coefficients A1..A4 = 377/106/-8/-8 (Q8), re-derived
    specifically for that mandatory extra delay -- NOT expressible as a
    same-sample-cascade order-4 entry here without reproducing the same
    structural mismatch this class already had at order=3. Treat order=3 below
    as an idealized reference only, not a model of deployed RTL; see
    planning/ss-timing-closure-exploration-2026-09-04.md for the real derivation
    and cross-check numbers (bit-exact RTL vs this model).

    Architecture: Cascade of Integrators, Feed-Forward (CIFF).
      N saturating integrators; Q8 weighted feed-forward summer; sign quantizer.
      Coefficients from synthesizeNTF(order, OSR=64, H_inf=1.5) via python-deltasigma.
      order=2 is the B3 area-cut candidate (planning/area-reduction-roadmap.md §7) —
      NOT deployed in RTL; coefficients derived the same way for a fair comparison.

    Normalised convention: input |x| <= 1.0, feedback = ±1.0.
    Integrators saturate at ±CLIP (= 32767/127, matching int16/int8 ratio in RTL).
    Input must be < −3 dBFS (|x| < 0.708) for stability (RTL header).
    """

    # Q8 feed-forward coefficients, round(synthesizeNTF(order, OSR=64, H_inf=1.5) * 256) / 256.
    # NOTE: no longer matches deployed RTL at any order -- see class docstring.
    _COEFFS = {
        2: (198 / 256, 55 / 256),          # 0.7734, 0.2148 — B3 candidate, not in RTL
        3: (205 / 256, 74 / 256, 11 / 256),  # 0.800, 0.289, 0.043 — idealized reference only
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
