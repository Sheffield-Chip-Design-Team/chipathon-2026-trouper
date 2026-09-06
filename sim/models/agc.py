"""External-board-controller AGC model for the four SX1257 receive chains.

This is intentionally outside the Trouper RTL model: Trouper has neither a
CPU nor an SX1257 SPI master.  The model defines the packet-boundary policy
that board-controller firmware must implement and exposes the quantised
frontend sample presented to Trouper.
"""

from dataclasses import dataclass

import numpy as np


# Gain reduction relative to SX1257 LNA G1.  The SX1257 LNA settings are not
# uniformly spaced: G1->G2->G3 are 6 dB steps and G3->G6 are 12 dB steps.
_LNA_REDUCTION_DB = (0, 6, 12, 24, 36, 48)


@dataclass
class SX1257Gain:
    """One SX1257 gain setting; LNA codes follow RegRxAnaGain [7:5]."""

    lna: int = 3
    bb: int = 7

    def __post_init__(self) -> None:
        if not 1 <= self.lna <= 6:
            raise ValueError("lna must be in SX1257 range 1..6")
        if not 0 <= self.bb <= 15:
            raise ValueError("bb must be in SX1257 range 0..15")

    @property
    def reduction_db(self) -> int:
        """Total attenuation relative to LNA G1 + BB gain 15."""
        return _LNA_REDUCTION_DB[self.lna - 1] + 2 * (15 - self.bb)

    @property
    def relative_scale(self) -> float:
        return float(10.0 ** (-self.reduction_db / 20.0))


@dataclass
class PacketAgc:
    """Per-antenna, packet-boundary AGC policy from planning/blocks/AGC.md."""

    gain: SX1257Gain
    target_lo_power: float = 20.0**2
    target_hi_power: float = 80.0**2
    saturation_component: int = 115
    bb_mid: int = 7

    def frontend_samples(self, samples_at_max_gain: np.ndarray) -> np.ndarray:
        """Apply analogue gain then the signed-int8 decimator boundary."""
        x = np.asarray(samples_at_max_gain, dtype=np.complex128) * self.gain.relative_scale
        return np.clip(np.rint(x.real), -128, 127) + 1j * np.clip(np.rint(x.imag), -128, 127)

    @staticmethod
    def power(samples: np.ndarray) -> float:
        x = np.asarray(samples, dtype=np.complex128)
        return float(np.mean(x.real**2 + x.imag**2)) if x.size else 0.0

    @staticmethod
    def component_peak(samples: np.ndarray) -> int:
        x = np.asarray(samples, dtype=np.complex128)
        if not x.size:
            return 0
        return int(max(np.max(np.abs(x.real)), np.max(np.abs(x.imag))))

    def update_after_packet(self, samples: np.ndarray, *, packet_active: bool) -> bool:
        """Change gain only after the observed packet is complete.

        A clipped packet cannot reveal its true excess power, so the saturation
        guard makes the largest safe documented correction: one LNA step down
        and BB reset no higher than mid-scale.  The following packet is then
        safe for the re-modulator, even though it may be temporarily cold.
        """
        if packet_active:
            raise ValueError("SX1257 gain updates are forbidden while packet_active")

        old = SX1257Gain(self.gain.lna, self.gain.bb)
        peak = self.component_peak(samples)
        pwr = self.power(samples)

        if peak >= self.saturation_component:
            self.gain.lna = min(6, self.gain.lna + 1)
            self.gain.bb = min(self.gain.bb, self.bb_mid)
        elif pwr > self.target_hi_power:
            if self.gain.bb > 0:
                self.gain.bb -= 1
            elif self.gain.lna < 6:
                self.gain.lna += 1
                self.gain.bb = self.bb_mid
        elif pwr < self.target_lo_power:
            if self.gain.bb < 15:
                self.gain.bb += 1
            elif self.gain.lna > 1:
                self.gain.lna -= 1
                self.gain.bb = self.bb_mid

        return self.gain != old


def remod_ingress(samples: np.ndarray, *, use_mrc: bool, backoff_shift: int = 1) -> np.ndarray:
    """Model Trouper's current remod ingress selection at trouper_top.v.

    The shift is deliberately MRC-only in RTL.  Keeping that distinction here
    makes the deep-fade return test report the real bypass exposure instead of
    accidentally giving the bypass path MRC's protection.
    """
    x = np.asarray(samples, dtype=np.complex128)
    if not use_mrc:
        return x
    return (np.floor(x.real / (1 << backoff_shift)) +
            1j * np.floor(x.imag / (1 << backoff_shift)))
