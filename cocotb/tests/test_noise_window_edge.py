"""
test_noise_window_edge.py -- Open Risk #66.

Drives the same-cycle race in trouper_top.v's noise-window qualification block
(reproduced verbatim in cocotb/noise_window_edge/noise_window_qual.v):

    if (noise_window_active && (sc_hit_dbg || sc_lock))
        noise_window_sc_seen <= 1'b1;
    if (noise_window_active && training_done) begin
        sigma2_valid_r <= ~noise_window_sc_seen && !sc_lock;   // reads OLD sc_seen
        ...
    end

Cases (contamination one cycle before / on / one cycle after training_done):

  test_clean_window_qualifies            -- PASS: no contamination -> sigma2_valid
  test_hit_before_completion_rejected    -- PASS: hit a few cycles early ->
                                            noise_window_sc_seen latches -> rejected
  test_lock_on_completion_edge_rejected  -- PASS: sc_lock coincident with
                                            training_done -> the !sc_lock term rejects
  test_nonlocking_hit_on_completion_edge -- EXPECTED FAIL: sc_hit_dbg (no sc_lock)
                                            coincident with training_done -> the NBA
                                            reads noise_window_sc_seen == 0 and
                                            sigma2_valid asserts for a contaminated window
  test_hit_after_completion_ignored      -- PASS: hit one cycle after the window
                                            closed does not matter
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, ReadOnly, Timer

CLK_NS = 31.25


async def _settle():
    # leave the ReadOnly region so the caller can drive inputs again
    await Timer(1, unit="ns")


async def _reset(dut):
    dut.rst_n.value = 0
    dut.noise_trig_accept.value = 0
    dut.sc_hit_dbg.value = 0
    dut.sc_lock.value = 0
    dut.training_done.value = 0
    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


async def _open_window(dut):
    dut.noise_trig_accept.value = 1
    await RisingEdge(dut.clk)
    dut.noise_trig_accept.value = 0
    await RisingEdge(dut.clk)
    await ReadOnly()
    active = int(dut.noise_window_active_o.value)
    await _settle()
    assert active == 1, "window did not open"


async def _pulse_hit(dut, cycles_high=1):
    dut.sc_hit_dbg.value = 1
    for _ in range(cycles_high):
        await RisingEdge(dut.clk)
    dut.sc_hit_dbg.value = 0


async def _read(dut, name):
    await ReadOnly()
    v = int(getattr(dut, name).value)
    await _settle()
    return v


async def _sigma2_pulsed(dut, over_cycles=4):
    seen = 0
    for _ in range(over_cycles):
        await RisingEdge(dut.clk)
        await ReadOnly()
        seen |= int(dut.sigma2_valid.value)
        await _settle()
    return bool(seen)


@cocotb.test()
async def test_clean_window_qualifies(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await _reset(dut)
    await _open_window(dut)
    await ClockCycles(dut.clk, 10)

    dut.training_done.value = 1                 # window completes, uncontaminated
    got = await _sigma2_pulsed(dut)
    dut.training_done.value = 0
    assert got, "clean noise window did not assert sigma2_valid"


@cocotb.test()
async def test_hit_before_completion_rejected(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await _reset(dut)
    await _open_window(dut)
    await ClockCycles(dut.clk, 5)

    await _pulse_hit(dut)                       # contamination, well before completion
    await ClockCycles(dut.clk, 5)
    assert await _read(dut, "noise_window_sc_seen_o") == 1, "early hit did not latch sc_seen"

    dut.training_done.value = 1
    got = await _sigma2_pulsed(dut)
    dut.training_done.value = 0
    assert not got, "sigma2_valid asserted for a window contaminated before completion"


@cocotb.test()
async def test_lock_on_completion_edge_rejected(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await _reset(dut)
    await _open_window(dut)
    await ClockCycles(dut.clk, 10)

    # sc_lock and training_done rise together
    dut.sc_lock.value = 1
    dut.training_done.value = 1
    got = await _sigma2_pulsed(dut)
    dut.sc_lock.value = 0
    dut.training_done.value = 0
    assert not got, "sigma2_valid asserted with sc_lock coincident with training_done"


@cocotb.test()
async def test_nonlocking_hit_on_completion_edge(dut):
    """EXPECTED FAIL: a non-locking sc_hit_dbg on the exact training_done edge.
    noise_window_sc_seen is still 0 when the NBA for sigma2_valid_r is
    evaluated, so NOISE_READY is asserted for a contaminated window."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await _reset(dut)
    await _open_window(dut)
    await ClockCycles(dut.clk, 10)

    # sc_hit_dbg (NO sc_lock) rises on the same edge as training_done
    dut.sc_hit_dbg.value = 1
    dut.training_done.value = 1
    got = await _sigma2_pulsed(dut)
    dut.sc_hit_dbg.value = 0
    dut.training_done.value = 0

    assert not got, (
        "sigma2_valid asserted although a contaminating sc_hit_dbg arrived on the "
        "training_done completion edge -- the qualification NBA reads the stale "
        "noise_window_sc_seen == 0 (Open Risk #66); fix: reject on "
        "`noise_window_sc_seen || sc_hit_dbg || sc_lock`")


@cocotb.test()
async def test_hit_after_completion_ignored(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await _reset(dut)
    await _open_window(dut)
    await ClockCycles(dut.clk, 10)

    dut.training_done.value = 1
    await RisingEdge(dut.clk)                   # window closes here
    dut.training_done.value = 0
    await _pulse_hit(dut)                       # too late to matter
    assert await _read(dut, "noise_window_active_o") == 0, "window did not close on training_done"
