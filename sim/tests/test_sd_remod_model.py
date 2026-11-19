"""Self-checks for sim/models/sd_remod.py (the bit-true sd_remod model).

These pin the model's own arithmetic and cadence; bit-exactness against the
RTL itself is cocotb/tests/test_remod_golden.py.
"""
import numpy as np
import pytest

from sim.models.sd_remod import (SdRemodRTL, production_stream, remodulate, OSR,
                                 CIFF3, LEGACY_CIFF4)
from sim.tests.remod_order_sweep import brickwall_lp_decim

FS_OUT = 500_000.0
CONFIGS = pytest.mark.parametrize("cfg", [CIFF3, LEGACY_CIFF4], ids=lambda c: c.name)


def _interp_trace(x, cfg):
    """Run the model and record (cycle, interp_i) at every interp_valid."""
    m = SdRemodRTL(cfg)
    v, i, q = production_stream(x)
    out = []
    for k in range(len(v)):
        m.run(v[k:k + 1], i[k:k + 1], q[k:k + 1])
        if m.interp_valid:
            out.append((k, m.interp_i))
    return out


@CONFIGS
def test_interpolator_matches_closed_form(cfg):
    F = cfg.frac_bits
    rng = np.random.default_rng(1)
    x = rng.integers(-128, 128, 40).astype(float)
    trace = _interp_trace(x, cfg)
    xp = np.concatenate([np.zeros(5), x])            # x[n-5] history from reset
    for n in range(len(x)):
        h = xp[n:n + 6][::-1]                         # x[n], x[n-1], ..., x[n-5]
        acc = (256 >> F) + 19 * (h[0] + h[5]) - 73 * (h[1] + h[4]) + 312 * (h[2] + h[3])
        even = int(np.clip(np.floor(acc / (512 >> F)), -(128 << F), (128 << F) - 1))
        assert trace[2 * n] == (64 * n + 20, even)
        assert trace[2 * n + 1] == (64 * n + 52, int(h[2]) << F)


@CONFIGS
@pytest.mark.parametrize("amp,f_hz,min_db", [(64, 20e3, 40.0), (64, 60e3, 40.0),
                                             (40, 40e3, 39.0), (85, 40e3, 40.0)])
def test_tone_sqnr(amp, f_hz, min_db, cfg):
    """Same cases/limits as cocotb/tests/test_remod_sqnr.py."""
    n = 1536
    x = amp * np.exp(2j * np.pi * f_hz * np.arange(n) / FS_OUT)
    y = brickwall_lp_decim(remodulate(x, cfg=cfg), 250e3, FS_OUT * OSR, OSR) * 127.0
    r, c = x[120:-120], y[120:-120]
    g = np.vdot(r, c) / np.vdot(r, r)
    sqnr = 10 * np.log10(np.mean(np.abs(g * r) ** 2) / np.mean(np.abs(c - g * r) ** 2))
    assert sqnr > min_db
    assert abs(abs(g) - 1) < 0.15


@CONFIGS
def test_chunked_run_equals_single_run(cfg):
    rng = np.random.default_rng(2)
    v, i, q = production_stream(rng.integers(-100, 100, 200) * (1 + 1j))
    en = np.ones(len(v), dtype=int)
    en[3000:3100] = 0
    a = SdRemodRTL(cfg).run(v, i, q, en)
    m = SdRemodRTL(cfg)
    parts = [m.run(v[s:s + 777], i[s:s + 777], q[s:s + 777], en[s:s + 777])
             for s in range(0, len(v), 777)]
    assert np.array_equal(a[0], np.concatenate([p[0] for p in parts]))
    assert np.array_equal(a[1], np.concatenate([p[1] for p in parts]))


@CONFIGS
def test_en_low_clears_loop_and_output(cfg):
    m = SdRemodRTL(cfg)
    v, i, q = production_stream(np.full(10, 60 + 60j))
    m.run(v, i, q)
    oi, oq = m.run([0] * 5, [0] * 5, [0] * 5, en=[0] * 5)
    assert not oi.any() and not oq.any()
    zero = [0] * len(cfg.coeffs)
    assert m.si == zero and m.sq == zero
    assert m.zi == [0] * 6 and not m.mac_busy and not m.odd_pending


def test_ciff3_integrators_stay_off_the_rails():
    """The redesign's whole point: at -1.9 dBFS (amp 0.8 of int8 full scale)
    no integrator saturates, so the loop really is 3rd order. LEGACY_CIFF4
    pins s3/s4 at +32767 even at zero input."""
    for f_hz in (7e3, 40e3, 110e3):
        x = 0.8 * 127 * np.exp(2j * np.pi * f_hz * np.arange(1024) / FS_OUT)
        m = SdRemodRTL(CIFF3)
        v, i, q = production_stream(x)
        peak = [0] * 3
        for s0 in range(0, len(v), 64):
            m.run(v[s0:s0 + 64], i[s0:s0 + 64], q[s0:s0 + 64])
            peak = [max(p, abs(a), abs(b)) for p, a, b in zip(peak, m.si, m.sq)]
        limits = [(1 << (w - 1)) - 1 for w in CIFF3.state_bits]
        assert all(p < lim for p, lim in zip(peak, limits)), (f_hz, peak)

    m = SdRemodRTL(LEGACY_CIFF4)
    m.run(*production_stream(np.zeros(16)))
    assert m.si[2] == 32767 and m.si[3] == 32767
