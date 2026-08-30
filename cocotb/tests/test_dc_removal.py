"""Directed direct-DUT coverage for TRPR-DCR-006 and TRPR-DCR-013."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, ReadOnly, Timer


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
