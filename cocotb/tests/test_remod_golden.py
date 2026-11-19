"""
test_remod_golden.py -- bit-exact diff of deployed sd_remod.v against the
cycle-accurate Python model sim/models/sd_remod.py.

Every other remod suite (remod_sqnr, _flatness, _stability, _lora,
_amp_sweep, ...) checks *properties* of the output bitstream. None of them
can say the RTL computes what was designed, because until this model existed
there was no reference matching the RTL (sim/models/converter.py's
SigmaDeltaRemodulator is an idealised 3rd-order same-sample cascade). This
suite closes that: every output bit on every clock must match.

Cycle convention (same as the model): inputs are driven on the falling edge
before rising edge k and outputs are read on the falling edge after it, so
in_*[k] / out_*[k] line up with SdRemodRTL.run() with no lag search.

Scenarios:
  - production-cadence tones, including near -3 dBFS and full-scale overdrive
    (exercises the interpolator's sat8 and the core's sat16 rails)
  - random int8 with random in_valid spacing, including gaps < 21 clocks so
    a new in_valid preempts an in-flight MAC (priority branch in sd_remod.v)
  - en toggling at random points, including while interp_valid is high
    (x_lat latches regardless of en in sd_remod_multiplierless.v)
"""
import numpy as np
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

from sim.models.sd_remod import SdRemodRTL, production_stream

CLK_NS = 31.25
OSR = 64
FS_OUT = 500_000.0


async def _run_and_diff(dut, label, in_valid, in_i, in_q, en=None):
    n = len(in_valid)
    en = np.ones(n, dtype=np.int64) if en is None else np.asarray(en)

    # Fresh reset so DUT and model start from the same state.
    dut.rst_n.value = 0
    dut.en.value = 1
    dut.in_valid.value = 0
    dut.in_i.value = 0
    dut.in_q.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1

    rtl_i = np.empty(n, dtype=np.uint8)
    rtl_q = np.empty(n, dtype=np.uint8)
    for k in range(n):
        dut.in_valid.value = int(in_valid[k])
        dut.in_i.value = int(in_i[k]) & 0xFF
        dut.in_q.value = int(in_q[k]) & 0xFF
        dut.en.value = int(en[k])
        await FallingEdge(dut.clk)          # rising edge k has happened
        rtl_i[k] = int(dut.out_i.value)
        rtl_q[k] = int(dut.out_q.value)

    mdl_i, mdl_q = SdRemodRTL().run(in_valid, in_i, in_q, en)
    bad = np.flatnonzero((rtl_i != mdl_i) | (rtl_q != mdl_q))
    dut._log.info(f"{label}: {n} clocks, {len(bad)} mismatching")
    if len(bad):
        k0 = bad[0]
        lo, hi = max(0, k0 - 4), min(n, k0 + 4)
        ctx = "\n".join(
            f"  k={k:7d} v={in_valid[k]} i={in_i[k]:4d} q={in_q[k]:4d} en={en[k]} "
            f"rtl={rtl_i[k]}{rtl_q[k]} mdl={mdl_i[k]}{mdl_q[k]}"
            for k in range(lo, hi))
        raise AssertionError(
            f"{label}: {len(bad)}/{n} clocks differ, first at k={k0}\n{ctx}")


def _tone(amp, f_hz, n):
    t = np.arange(n) / FS_OUT
    return amp * np.exp(1j * 2 * np.pi * f_hz * t)


@cocotb.test()
async def test_golden_tones(dut):
    """Production cadence, several amplitudes/frequencies incl. overdrive."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    for amp, f_hz, n in [(64, 20e3, 512), (40, 115e3, 512),
                         (85, -60e3, 512), (127, 125e3, 384)]:
        await _run_and_diff(dut, f"tone amp={amp} f={f_hz/1e3:.0f}kHz",
                            *production_stream(_tone(amp, f_hz, n)))


@cocotb.test()
async def test_golden_random_spacing(dut):
    """Full-range random int8 with random in_valid gaps (5..90 clocks)."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    rng = np.random.default_rng(0x5D)
    n = 40_000
    in_valid = np.zeros(n, dtype=np.int64)
    k = 0
    while k < n:
        in_valid[k] = 1
        k += int(rng.integers(5, 91))
    # Value changes on every clock: the RTL only samples it on in_valid, so
    # junk between pulses must not leak in.
    in_i = rng.integers(-128, 128, n)
    in_q = rng.integers(-128, 128, n)
    await _run_and_diff(dut, "random spacing", in_valid, in_i, in_q)


@cocotb.test()
async def test_golden_en_toggle(dut):
    """en dropped at random points (incl. mid-MAC and on interp_valid)."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    rng = np.random.default_rng(0xE7)
    in_valid, in_i, in_q = production_stream(_tone(70, 45e3, 600))
    n = len(in_valid)
    en = np.ones(n, dtype=np.int64)
    for _ in range(25):
        s = int(rng.integers(0, n - 200))
        en[s:s + int(rng.integers(1, 150))] = 0
    # Force en low exactly on clocks where interp_valid is registered high
    # (even phase at in_valid+21, odd at +53 relative to edge numbering).
    for base in (64 * 100, 64 * 300):
        en[base + 21] = 0
        en[base + 64 + 53] = 0
    await _run_and_diff(dut, "en toggle", in_valid, in_i, in_q, en)
