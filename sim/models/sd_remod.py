"""
Bit-true, cycle-accurate model of the ΣΔ re-modulator
(src/remod/sd_remod.v + src/remod/sd_remod_multiplierless.v).

Replaces sim/models/converter.py:SigmaDeltaRemodulator as the reference for
deployed RTL — that class is an idealised same-sample 3rd-order cascade with
different coefficients and no interpolator.

Two loop configurations are modelled (see planning/sd-remod-ciff3-redesign-
2026-10-03.md):

  CIFF3 (default, the redesign): 3rd-order CIFF, Q8 taps (334, 89, 10),
      placed for the real RTL loop (registered quantizer + delaying
      integrators + direct 256*e term), H_inf = 1.4, OSR = 64. The
      interpolator keeps FRAC_BITS = 2 extra fractional bits (10-bit loop
      input) so its own re-rounding no longer costs ~1 dB over the int8 floor.
  LEGACY_CIFF4 (the 2026-09-05 core, for A/B comparison only): taps
      (377, 106, -8, -8). A3/A4 have the wrong sign — the linearised loop has
      a real pole at ~+1.2 for every quantizer gain, so s3/s4 run to the
      sat16 rail within ~30 clocks and the loop behaves as a 2nd-order shaper.

Modelled exactly, one call per clk_32m rising edge (F = cfg.frac_bits):

  1. 2x half-band droop-compensating interpolator (sd_remod.v).
     On in_valid the 6-deep int8 history shifts and a serial MAC starts:
     10 shifted add/sub terms per rail, I then Q (one clock per term), with
     a (256 >> F) rounding preload, then sat_{8+F}(acc >>> (9 - F)):
         even = sat(((256>>F) + 19*(x[n]+x[n-5]) - 73*(x[n-1]+x[n-4])
                          + 312*(x[n-2]+x[n-3])) >> (9-F))
     interp_valid pulses when Q finishes (edge in_valid+20); 32 edges later
     the odd phase emits the delayed copy x[n-2] << F.
  2. N-th order CIFF loop (sd_remod_multiplierless.v), registered quantizer:
         e  = x_lat - (out ? 127<<F : -(127<<F))
         v  = 256*e + sum_k a_k*s_k                       (old s values)
         s1' = sat(s1 + e); sk' = sat(sk + s(k-1)) for k = 2..N
         out' = (v >= 0)
     each s_k saturates to cfg.state_bits[k-1] signed bits. x_lat is latched
     from the interpolator on interp_valid *regardless of en* (matches RTL);
     !en zeroes integrators and out.

Plain Python ints are exact (no intermediate in the RTL wraps).

Cycle convention (matches cocotb/tests/test_remod_golden.py):
  in_valid[k], in_i[k], in_q[k], en[k] are the input values sampled at rising
  edge k (k = 0 is the first edge after rst_n deasserts); out_i[k], out_q[k]
  are the register values *after* edge k.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np

OSR = 64


@dataclass(frozen=True)
class RemodConfig:
    name: str
    coeffs: tuple[int, ...]      # Q8 feed-forward taps a1..aN
    frac_bits: int               # interpolator extra fractional bits F
    state_bits: tuple[int, ...]  # signed saturation width of s1..sN


CIFF3 = RemodConfig("ciff3", (334, 89, 10), 2, (13, 14, 16))
LEGACY_CIFF4 = RemodConfig("legacy_ciff4", (377, 106, -8, -8), 0, (16, 16, 16, 16))
DEFAULT = CIFF3

# (left shift, subtract) per term_step, from sd_remod.v's term_value case.
#   19 = 16+2+1, 73 = 64+8+1 (subtracted), 312 = 256+32+16+8
_TERMS = ((4, False), (1, False), (0, False),
          (6, True), (3, True), (0, True),
          (8, False), (5, False), (4, False), (3, False))
# Pair selection per term_step: indices into the history list
# [z0, z1, z2, z3, z4, tail] -> (x[n]+x[n-5]), (x[n-1]+x[n-4]), (x[n-2]+x[n-3])
_PAIR = tuple((0, 5) if s < 3 else (1, 4) if s < 6 else (2, 3) for s in range(10))


class SdRemodRTL:
    """Stateful cycle model. Construct == rst_n asserted (all state zero)."""

    def __init__(self, cfg: RemodConfig = DEFAULT):
        self.cfg = cfg
        self.reset()

    def reset(self):
        n = len(self.cfg.coeffs)
        # Interpolator (sd_remod.v)
        self.zi = [0] * 6          # z0..z4, tail
        self.zq = [0] * 6
        self.interp_i = 0
        self.interp_q = 0
        self.interp_valid = 0
        self.mac_busy = 0
        self.mac_q = 0
        self.term_step = 0
        self.mac_acc = 0
        self.odd_pending = 0
        self.half_count = 0
        # Loop filter core (sd_remod_multiplierless.v)
        self.si = [0] * n
        self.sq = [0] * n
        self.lat_i = 0
        self.lat_q = 0
        self.out_i = 0
        self.out_q = 0

    # ------------------------------------------------------------------
    def run(self, in_valid, in_i, in_q, en=None):
        """Advance len(in_valid) clock edges. Returns (out_i, out_q) as uint8
        arrays of 0/1, one entry per edge (register value after that edge)."""
        cfg = self.cfg
        F = cfg.frac_bits
        fb = 127 << F
        pre = 256 >> F
        sh_out = 9 - F
        imax, imin = (128 << F) - 1, -(128 << F)
        coeffs = cfg.coeffs
        order = len(coeffs)
        hi = [(1 << (w - 1)) - 1 for w in cfg.state_bits]
        lo = [-(1 << (w - 1)) for w in cfg.state_bits]
        rng = range(1, order)

        n = len(in_valid)
        in_valid = np.asarray(in_valid, dtype=np.int64).tolist()
        in_i = np.asarray(in_i, dtype=np.int64).tolist()
        in_q = np.asarray(in_q, dtype=np.int64).tolist()
        en = [1] * n if en is None else np.asarray(en, dtype=np.int64).tolist()
        oi = np.empty(n, dtype=np.uint8)
        oq = np.empty(n, dtype=np.uint8)

        # Hoist state into locals for speed; written back at the end.
        zi, zq = self.zi, self.zq
        ii, iq, iv = self.interp_i, self.interp_q, self.interp_valid
        busy, mq, step, acc = self.mac_busy, self.mac_q, self.term_step, self.mac_acc
        odd, hc = self.odd_pending, self.half_count
        a, b = list(self.si), list(self.sq)
        li, lq, yi, yq = self.lat_i, self.lat_q, self.out_i, self.out_q
        terms, pairs = _TERMS, _PAIR

        def step_loop(s, e):
            v = e << 8
            for k in range(order):
                v += coeffs[k] * s[k]
            t = s[0] + e
            ns = [hi[0] if t > hi[0] else lo[0] if t < lo[0] else t]
            for k in rng:
                t = s[k] + s[k - 1]
                ns.append(hi[k] if t > hi[k] else lo[k] if t < lo[k] else t)
            return ns, 1 if v >= 0 else 0

        for k in range(n):
            e_on = en[k]

            # ---------------- core (uses current interp regs) -------------
            ei = li - (fb if yi else -fb)
            eq = lq - (fb if yq else -fb)
            if iv:
                li, lq = ii, iq
            if not e_on:
                a = [0] * order
                b = [0] * order
                yi = yq = 0
            else:
                a, yi = step_loop(a, ei)
                b, yq = step_loop(b, eq)
            oi[k] = yi
            oq[k] = yq

            # ---------------- interpolator --------------------------------
            if not e_on:
                zi = [0] * 6; zq = [0] * 6
                ii = iq = iv = 0
                busy = mq = step = acc = odd = hc = 0
                continue
            iv = 0
            if in_valid[k]:
                zi = [in_i[k], zi[0], zi[1], zi[2], zi[3], zi[4]]
                zq = [in_q[k], zq[0], zq[1], zq[2], zq[3], zq[4]]
                busy, mq, step, acc = 1, 0, 0, pre
            elif busy:
                z = zq if mq else zi
                pa, pb = pairs[step]
                sh, sub = terms[step]
                tv = (z[pa] + z[pb]) << sh
                acc_next = acc - tv if sub else acc + tv
                if step == 9:
                    r = acc_next >> sh_out
                    r = imax if r > imax else imin if r < imin else r
                    if not mq:
                        ii = r
                        mq, step, acc = 1, 0, pre
                    else:
                        iq = r
                        iv = 1
                        busy = mq = step = acc = 0
                        odd, hc = 1, 32
                else:
                    acc = acc_next
                    step += 1
            elif odd:
                if hc == 1:
                    ii, iq = zi[2] << F, zq[2] << F
                    iv = 1
                    odd = hc = 0
                else:
                    hc -= 1

        self.zi, self.zq = zi, zq
        self.interp_i, self.interp_q, self.interp_valid = ii, iq, iv
        self.mac_busy, self.mac_q, self.term_step, self.mac_acc = busy, mq, step, acc
        self.odd_pending, self.half_count = odd, hc
        self.si, self.sq = a, b
        self.lat_i, self.lat_q, self.out_i, self.out_q = li, lq, yi, yq
        return oi, oq


def production_stream(baseband: np.ndarray, osr: int = OSR):
    """Per-cycle (in_valid, in_i, in_q) for production cadence: one in_valid
    pulse per sample, value held for the remaining osr-1 clocks (same as
    trouper_top's comb_y_valid and cocotb/tests/test_remod_sqnr.py)."""
    x = np.asarray(baseband)
    xi = np.clip(np.round(x.real), -128, 127).astype(np.int64)
    xq = np.clip(np.round(x.imag), -128, 127).astype(np.int64)
    in_valid = np.zeros(len(x) * osr, dtype=np.int64)
    in_valid[::osr] = 1
    return in_valid, np.repeat(xi, osr), np.repeat(xq, osr)


def remodulate(baseband: np.ndarray, osr: int = OSR,
               cfg: RemodConfig = DEFAULT) -> np.ndarray:
    """Run complex int8-range `baseband` (500 kS/s) through a freshly reset
    sd_remod at production cadence. Returns the 32 MS/s output as a complex
    ±1±1j array (len(baseband) * osr)."""
    oi, oq = SdRemodRTL(cfg).run(*production_stream(baseband, osr))
    return (2.0 * oi - 1.0) + 1j * (2.0 * oq - 1.0)
