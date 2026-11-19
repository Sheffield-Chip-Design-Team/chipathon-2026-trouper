"""Direct-DUT coverage for dc_removal: TRPR-DCR-006/013 (settling), TRPR-DCR-007
(int8 output saturation, Open Risk #75), and a bit-exact differential against
sim/models/dc_removal.py DCRemovalRTL with distinct per-path stimulus,
irregular sample_valid gaps and the 1-clock sample_out_valid delay
(TRPR-DCR-001/002/003/009/011)."""

import os
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, ReadOnly, Timer
import numpy as np

_ROOT = os.environ.get("DESIGN_ROOT", "/foss/designs/lora-mimo")
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)

from sim.models.dc_removal import DCRemovalRTL  # noqa: E402


CLK_NS = 31.25
CHANNEL_INPUTS = (
    "sample_i0", "sample_i1", "sample_i2", "sample_i3",
    "sample_q0", "sample_q1", "sample_q2", "sample_q3",
)
CHANNEL_OUTPUTS = (
    "sample_out_i0", "sample_out_i1", "sample_out_i2", "sample_out_i3",
    "sample_out_q0", "sample_out_q1", "sample_out_q2", "sample_out_q3",
)


async def _reset(dut):
    dut.rst_n.value = 0
    dut.sample_valid.value = 0
    for name in CHANNEL_INPUTS:
        getattr(dut, name).value = 0
    await ClockCycles(dut.clk_32m, 4)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk_32m)


async def _sample(dut, value):
    for name in CHANNEL_INPUTS:
        getattr(dut, name).value = value & 0xFF
    dut.sample_valid.value = 1
    await RisingEdge(dut.clk_32m)
    await ReadOnly()
    outputs = [getattr(dut, name).value.to_signed() for name in CHANNEL_OUTPUTS]
    # Advance beyond the read-only callback before the next call drives input.
    await Timer(1, unit="ps")
    return outputs


@cocotb.test()
async def test_constant_dc_is_zero_within_256_samples(dut):
    """TRPR-DCR-006: all I/Q paths remove every practical constant DC code."""
    cocotb.start_soon(Clock(dut.clk_32m, CLK_NS, unit="ns").start())

    for dc in (-127, -64, -8, -1, 1, 8, 64, 127):
        await _reset(dut)
        outputs = []
        for _ in range(256):
            outputs = await _sample(dut, dc)
        assert outputs == [0] * 8, (
            f"TRPR-DCR-006 DC={dc}: residuals after 256 samples are {outputs}"
        )


@cocotb.test()
async def test_reset_dc_settles_by_one_time_constant(dut):
    """TRPR-DCR-013: 74 samples reduce full-scale DC by at least 90 percent.

    A 32-sample first-order IIR has a one-time-constant residual of about 10%,
    not <1 LSB for a full-scale offset.  The full-scale bound is therefore
    13 LSB after 74 samples; the stricter zero-residual requirement is checked
    separately by TRPR-DCR-006 at 256 samples.
    """
    cocotb.start_soon(Clock(dut.clk_32m, CLK_NS, unit="ns").start())

    for dc in (-127, 127):
        await _reset(dut)
        outputs = []
        for _ in range(74):
            outputs = await _sample(dut, dc)
        assert all(abs(value) <= 13 for value in outputs), (
            f"TRPR-DCR-013 DC={dc}: residuals after 74 samples are {outputs}; "
            "expected no more than 13 LSB"
        )


async def _step8(dut, values):
    """One valid sample with a distinct value per path; returns the 8 outputs
    and sample_out_valid as seen after the edge."""
    for name, v in zip(CHANNEL_INPUTS, values):
        getattr(dut, name).value = int(v) & 0xFF
    dut.sample_valid.value = 1
    await RisingEdge(dut.clk_32m)
    await ReadOnly()
    out = [getattr(dut, name).value.to_signed() for name in CHANNEL_OUTPUTS]
    await Timer(1, unit="ps")
    dut.sample_valid.value = 0
    return out


@cocotb.test()
async def test_transient_saturates_not_wraps(dut):
    """TRPR-DCR-007 / Open Risk #75: 127 against a -20 estimate is +127 (was
    the wrapped -109); -128 against a +20 estimate is -128."""
    cocotb.start_soon(Clock(dut.clk_32m, CLK_NS, unit="ns").start())
    for dc, step, expect in ((-20, 127, 127), (20, -128, -128)):
        await _reset(dut)
        for _ in range(256):
            await _sample(dut, dc)                 # estimate settles to dc
        outputs = await _sample(dut, step)
        assert outputs == [expect] * 8, (
            f"DC={dc} then step {step}: outputs {outputs}, expected {expect} "
            f"(raw diff {step - dc} must saturate, not wrap)")


@cocotb.test()
async def test_bit_exact_vs_model_distinct_paths(dut):
    """8 distinct streams (DC steps + tone + noise, incl. int8-overflowing
    transients), irregular valid gaps: every output == DCRemovalRTL, outputs
    hold between valids, sample_out_valid = sample_valid delayed 1 clock."""
    cocotb.start_soon(Clock(dut.clk_32m, CLK_NS, unit="ns").start())
    await _reset(dut)
    rng = np.random.default_rng(75)
    n = 1500
    t = np.arange(n)
    x = np.empty((8, n))
    for k in range(8):
        dc = np.repeat(rng.integers(-60, 61, n // 250 + 1), 250)[:n]
        x[k] = dc + (40 + 8 * k) * np.sin(2 * np.pi * (k + 1) * t / 97 + k) \
            + 6 * rng.standard_normal(n)
    x = np.clip(np.round(x), -128, 127).astype(np.int32)

    acc = np.zeros(8, dtype=np.int32)
    clipped = 0
    for i in range(n):
        out = await _step8(dut, x[:, i])
        exp, acc = DCRemovalRTL._step(x[:, i], acc)
        exp = [int(v) for v in exp]
        clipped += sum(abs(int(x[k, i]) - (int(acc[k]) >> 5)) > 127 for k in range(8))
        assert out == exp, f"sample {i}: rtl={out} model={exp} in={list(x[:, i])}"
        # sample_out_valid is registered: high exactly on the edge after valid
        await ReadOnly()
        assert int(dut.sample_out_valid.value) == 1, f"sample {i}: sample_out_valid not 1 clock after valid"
        await RisingEdge(dut.clk_32m)
        await ReadOnly()
        assert int(dut.sample_out_valid.value) == 0, f"sample {i}: sample_out_valid longer than 1 clock"
        held = [getattr(dut, name).value.to_signed() for name in CHANNEL_OUTPUTS]
        assert held == out, f"sample {i}: output changed without sample_valid"
        await Timer(1, unit="ps")
        gap = int(rng.choice([0, 0, 1, 3, 62]))
        if gap:
            await ClockCycles(dut.clk_32m, gap)
    assert clipped > 0, "stimulus never drove |raw - dc_est| past int8 (saturation path unexercised)"
    dut._log.info(f"{n} samples x 8 paths exact; {clipped} overflow-range diffs exercised")
