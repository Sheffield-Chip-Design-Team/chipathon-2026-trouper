"""
test_mrc_golden.py -- constrained-random bit-exact regression of
src/combiner/mrc_combiner.v, standalone (no trouper_top around it).

Reference: y = sat_int8( sum_k (W_k * x_k) >>> (8 - pgs) ), complex, with
W_k * x_k = (w_re x_i - w_im x_q) + j (w_re x_q + w_im x_i) -- the integer
contract the RTL header states. Where a vector's weight peak is exactly 120,
the same samples are also pushed through sim/models/receiver.py
nonfft_combine_rtl_int8w (which rescales weights so the peak maps to 120, i.e.
identity on those vectors), tying the RTL and the system model together.

Coverage:
  * full-range random int8 x and W, every post_gain_shift 0..7
  * the documented arithmetic extremes (all -128 -> +131072 accumulator, the
    17-bit product / 19-bit accumulator endpoints) and both int8 rails
  * bypass (mode=1, and W_valid=0) for every bypass_ant; use_mrc flag
  * x inputs scrambled on every non-strobe clock: the result must come from the
    x_valid-cycle latch only (live/replay mux flip mid-burst)
  * exactly one y_valid per x_valid, inside the 64-clock window

Requirements: TRPR-MRC-001 (plain complex w*x MAC; firmware pre-conjugates W),
TRPR-MRC-002 (accumulator width, >>>(8-pgs), int8 saturation), TRPR-MRC-003
(one output per input strobe), TRPR-PCF-011 (bypass routing).
"""

import os
import sys

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge, Timer

_ROOT = os.environ.get("DESIGN_ROOT", "/foss/designs/lora-mimo")
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)

from sim.models.receiver import nonfft_combine_rtl_int8w  # noqa: E402

CLK_NS = 31.25
WINDOW = 64


def _ref(x, w, pgs):
    """x, w: (4,) complex int-valued. Returns (y_i, y_q) ints."""
    acc_i = sum(int(w[k].real) * int(x[k].real) - int(w[k].imag) * int(x[k].imag) for k in range(4))
    acc_q = sum(int(w[k].real) * int(x[k].imag) + int(w[k].imag) * int(x[k].real) for k in range(4))
    sh = 8 - pgs
    return (max(-128, min(127, acc_i >> sh)), max(-128, min(127, acc_q >> sh)))


async def _reset(dut):
    dut.rst_n.value = 0
    for s in ("x_valid", "W_valid", "mode", "bypass_ant", "post_gain_shift"):
        getattr(dut, s).value = 0
    for k in range(4):
        for p in ("x_i", "x_q", "W_re", "W_im"):
            getattr(dut, f"{p}{k}").value = 0
    await ClockCycles(dut.clk_16m, 4)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk_16m, 2)


def _drive_x(dut, x):
    for k in range(4):
        getattr(dut, f"x_i{k}").value = int(x[k].real) & 0xFF
        getattr(dut, f"x_q{k}").value = int(x[k].imag) & 0xFF


def _drive_w(dut, w):
    for k in range(4):
        getattr(dut, f"W_re{k}").value = int(w[k].real) & 0xFF
        getattr(dut, f"W_im{k}").value = int(w[k].imag) & 0xFF


async def _one(dut, rng, x, w, pgs, *, mode=0, w_valid=1, bypass_ant=0):
    """One x_valid strobe; returns (y_i, y_q, use_mrc, y_valid_count)."""
    _drive_w(dut, w)
    dut.W_valid.value = w_valid
    dut.mode.value = mode
    dut.bypass_ant.value = bypass_ant
    dut.post_gain_shift.value = pgs
    _drive_x(dut, x)
    dut.x_valid.value = 1
    await RisingEdge(dut.clk_16m)
    await Timer(1, unit="ns")
    dut.x_valid.value = 0
    got, n_valid, use_mrc = None, 0, None
    for _ in range(WINDOW - 1):
        # scramble x every clock after the strobe: only the latch may matter
        junk = rng.integers(-128, 128, 4) + 1j * rng.integers(-128, 128, 4)
        _drive_x(dut, junk)
        await RisingEdge(dut.clk_16m)
        await ReadOnly()
        if int(dut.y_valid.value):
            n_valid += 1
            got = (dut.y_i.value.to_signed(), dut.y_q.value.to_signed())
            use_mrc = int(dut.use_mrc.value)
        await Timer(1, unit="ns")
    return got, use_mrc, n_valid


def _rand_c(rng, n, lo=-128, hi=128):
    return rng.integers(lo, hi, n) + 1j * rng.integers(lo, hi, n)


@cocotb.test()
async def test_mrc_random_bit_exact(dut):
    """Full-range random x/W at every post_gain_shift: RTL == integer reference."""
    cocotb.start_soon(Clock(dut.clk_16m, CLK_NS, unit="ns").start())
    await _reset(dut)
    rng = np.random.default_rng(2026)
    sat_hits = 0
    for n in range(320):
        pgs = n % 8
        x = _rand_c(rng, 4)
        w = _rand_c(rng, 4)
        got, use_mrc, nv = await _one(dut, rng, x, w, pgs)
        exp = _ref(x, w, pgs)
        assert nv == 1, f"vec {n}: {nv} y_valid pulses in the 64-clock window"
        assert use_mrc == 1, f"vec {n}: use_mrc low with W_valid=1, mode=0"
        assert got == exp, f"vec {n} pgs={pgs} x={x} w={w}: rtl={got} ref={exp}"
        sat_hits += exp[0] in (-128, 127) or exp[1] in (-128, 127)
    assert sat_hits > 20, f"random set only hit an int8 rail {sat_hits} times"


@cocotb.test()
async def test_mrc_model_crosscheck(dut):
    """Weight peak exactly 120 -> RTL == sim/models nonfft_combine_rtl_int8w."""
    cocotb.start_soon(Clock(dut.clk_16m, CLK_NS, unit="ns").start())
    await _reset(dut)
    rng = np.random.default_rng(11)
    for n in range(64):
        pgs = n % 8
        w = _rand_c(rng, 4, -119, 120)
        k = int(rng.integers(0, 4))
        w[k] = (120 if rng.integers(0, 2) else -120) + 1j * w[k].imag
        x = _rand_c(rng, 4, -90, 91)                  # AGC operating range
        got, _, _ = await _one(dut, rng, x, w, pgs)
        y = nonfft_combine_rtl_int8w(x.reshape(4, 1), w.astype(complex), pgs)[0]
        exp = (int(y.real), int(y.imag))
        assert got == exp, f"vec {n} pgs={pgs}: rtl={got} model={exp} (x={x}, w={w})"


@cocotb.test()
async def test_mrc_arithmetic_extremes(dut):
    """17-bit product / 19-bit accumulator endpoints and both rails, every pgs."""
    cocotb.start_soon(Clock(dut.clk_16m, CLK_NS, unit="ns").start())
    await _reset(dut)
    rng = np.random.default_rng(3)
    corners = [
        (np.full(4, -128 - 128j), np.full(4, -128 - 128j)),   # acc_q = +131072
        (np.full(4, 127 + 127j), np.full(4, 127 + 127j)),
        (np.full(4, -128 + 127j), np.full(4, 127 - 128j)),
        (np.full(4, -128 + 0j), np.full(4, -128 + 0j)),       # acc_i = +65536
        (np.full(4, -128 + 0j), np.full(4, 127 + 0j)),        # acc_i = -65024
        (np.array([1 + 0j, 0, 0, 0]), np.array([1 + 0j, 0, 0, 0])),  # LSB / floor
        (np.array([-1 + 0j, 0, 0, 0]), np.array([1 + 0j, 0, 0, 0])),  # -1 >>> s = -1
    ]
    for c, (x, w) in enumerate(corners):
        for pgs in range(8):
            got, _, nv = await _one(dut, rng, x, w, pgs)
            exp = _ref(x, w, pgs)
            assert nv == 1 and got == exp, f"corner {c} pgs={pgs}: rtl={got} ref={exp}"


@cocotb.test()
async def test_bypass_routing(dut):
    """mode=1 or W_valid=0: y = the selected antenna's latched x, use_mrc=0."""
    cocotb.start_soon(Clock(dut.clk_16m, CLK_NS, unit="ns").start())
    await _reset(dut)
    rng = np.random.default_rng(5)
    for mode, w_valid in ((1, 1), (0, 0), (1, 0)):
        for ant in range(4):
            for _ in range(4):
                x = _rand_c(rng, 4)
                w = _rand_c(rng, 4)
                got, use_mrc, nv = await _one(dut, rng, x, w, int(rng.integers(0, 8)),
                                              mode=mode, w_valid=w_valid, bypass_ant=ant)
                exp = (int(x[ant].real), int(x[ant].imag))
                assert nv == 1 and use_mrc == 0, f"mode={mode} W_valid={w_valid}: use_mrc={use_mrc}"
                assert got == exp, f"bypass ant {ant} mode={mode} W_valid={w_valid}: rtl={got} exp={exp}"
