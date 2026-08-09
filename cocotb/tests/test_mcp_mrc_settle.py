"""
test_mcp_mrc_settle.py -- Open Risks item 43, paced_dsp MCP settle proof,
mrc_combiner leg.

Structural background (src/combiner/mrc_combiner.v): each 8x8 multiply/
subtract MAC sub-stage is ~50 ns at the FD SS corner and cannot settle in
one 31.25 ns IQ_CLK cycle, so every computing state (1..10) is held for
MAC_WAIT+1 = 3 cycles (mac_wait counting 0..MAC_WAIT) before the settled
result is registered -- state 0 is the sole exception (it must catch the
1-clock x_valid pulse immediately and is unpaced by construction). This is
exactly the relaxation the SDC's scoped `set_multicycle_path 3 -setup
-through $paced_nets` (paced_dsp group, u_comb.* in scope) grants.

Consumed result registers checked:
  - prod_i_r/prod_q_r -- written only in states 2/4/6/8 (the SUB2 states
    that form a complex product from a_r/c_r and the current settled
    multiplier outputs), gated by the same state!=0 && mac_wait==MAC_WAIT
    condition as every other paced state transition.
  - y_i/y_q -- the final combiner output (the net the SDC scope and
    downstream sd_remod actually consume), written only in state 10.

  test_mac_settle_gating     -- several full 31-clock combine bursts under
      normal x_valid/W_valid activity; a background monitor asserts neither
      group changes unless (state != 0) && (mac_wait == MAC_WAIT) held on
      the preceding edge.
  test_reset_mid_burst_rearm -- assert rst_n partway through a combine burst
      (state in 1..9, mac_wait < MAC_WAIT); confirms state/mac_wait/y_valid
      all clear, then a fresh x_valid pulse re-arms and completes a clean
      burst (y_valid pulses, no glitched y_i/y_q) under the same discipline.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

CLK_NS = 31.25
MAC_WAIT = 2      # localparam MAC_WAIT = 2'd2 in mrc_combiner.v
BURST_MARGIN = 40  # >= 1 + 10*3 = 31 clocks, plus slack

WEIGHTS = dict(W_re0=40, W_im0=-10, W_re1=20, W_im1=5,
               W_re2=-15, W_im2=30, W_re3=8, W_im3=-8)


async def _reset(dut):
    dut.rst_n.value = 0
    dut.x_valid.value = 0
    dut.W_valid.value = 1
    dut.mode.value = 0
    dut.bypass_ant.value = 0
    dut.post_gain_shift.value = 0
    for k, v in WEIGHTS.items():
        getattr(dut, k).value = v & 0xFF
    for sig in ("x_i0", "x_q0", "x_i1", "x_q1", "x_i2", "x_q2", "x_i3", "x_q3"):
        getattr(dut, sig).value = 0
    await ClockCycles(dut.clk_16m, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk_16m, 2)


async def _pulse_sample(dut, i0, q0, i1, q1, i2, q2, i3, q3):
    dut.x_i0.value = i0 & 0xFF
    dut.x_q0.value = q0 & 0xFF
    dut.x_i1.value = i1 & 0xFF
    dut.x_q1.value = q1 & 0xFF
    dut.x_i2.value = i2 & 0xFF
    dut.x_q2.value = q2 & 0xFF
    dut.x_i3.value = i3 & 0xFF
    dut.x_q3.value = q3 & 0xFF
    dut.x_valid.value = 1
    await RisingEdge(dut.clk_16m)
    dut.x_valid.value = 0
    await ClockCycles(dut.clk_16m, BURST_MARGIN)


def _snap(dut):
    return {
        "rst_n": int(dut.rst_n.value),
        "state": int(dut.state.value),
        "mac_wait": int(dut.mac_wait.value),
        "prod": (int(dut.prod_i_r.value), int(dut.prod_q_r.value)),
        "y": (int(dut.y_i.value), int(dut.y_q.value)),
    }


async def _settle_monitor(dut, violations):
    prev = _snap(dut)
    while True:
        await RisingEdge(dut.clk_16m)
        await ReadOnly()
        cur = _snap(dut)
        if cur["rst_n"] == 1:
            legal = (prev["state"] != 0) and (prev["mac_wait"] == MAC_WAIT)
            if cur["prod"] != prev["prod"] and not legal:
                violations.append(
                    f"prod_i_r/prod_q_r changed with state={prev['state']} "
                    f"mac_wait={prev['mac_wait']} (need state!=0 wait={MAC_WAIT})"
                )
            if cur["y"] != prev["y"] and not legal:
                violations.append(
                    f"y_i/y_q changed with state={prev['state']} "
                    f"mac_wait={prev['mac_wait']} (need state!=0 wait={MAC_WAIT})"
                )
        prev = cur


async def _wait_until(dut, pred, timeout_cycles=200):
    for _ in range(timeout_cycles):
        await ReadOnly()
        if pred():
            return
        await RisingEdge(dut.clk_16m)
    raise TimeoutError("condition never became true")


@cocotb.test()
async def test_mac_settle_gating(dut):
    cocotb.start_soon(Clock(dut.clk_16m, CLK_NS, unit="ns").start())
    await _reset(dut)

    violations = []
    mon = cocotb.start_soon(_settle_monitor(dut, violations))

    samples = [
        (10, -5, 20, 3, -8, 15, 4, -4),
        (127, -128, 0, 0, 1, -1, 6, 6),
        (-30, 30, 9, -9, 2, 2, -3, 7),
    ]
    for s in samples:
        await _pulse_sample(dut, *s)
        assert int(dut.y_valid.value) == 0  # margin drains well past the pulse

    mon.kill()
    assert not violations, "settle violations:\n" + "\n".join(violations)


@cocotb.test()
async def test_reset_mid_burst_rearm(dut):
    cocotb.start_soon(Clock(dut.clk_16m, CLK_NS, unit="ns").start())
    await _reset(dut)

    violations = []
    mon = cocotb.start_soon(_settle_monitor(dut, violations))

    await _pulse_sample(dut, 10, -5, 20, 3, -8, 15, 4, -4)  # baseline good burst

    # Kick a second burst and catch it mid-hold.
    dut.x_i0.value = 50 & 0xFF
    dut.x_q0.value = (-20) & 0xFF
    dut.x_valid.value = 1
    await RisingEdge(dut.clk_16m)
    dut.x_valid.value = 0
    await _wait_until(dut, lambda: 1 <= int(dut.state.value) <= 9)
    for _ in range(2):  # land inside a paced hold (mac_wait < MAC_WAIT)
        await RisingEdge(dut.clk_16m)

    dut.rst_n.value = 0
    await ClockCycles(dut.clk_16m, 4)

    assert int(dut.state.value) == 0, "state not cleared by reset"
    assert int(dut.mac_wait.value) == 0, "mac_wait not cleared by reset"
    assert int(dut.y_valid.value) == 0, "y_valid not cleared by reset"

    dut.rst_n.value = 1
    await ClockCycles(dut.clk_16m, 2)

    # Clean re-arm: a fresh burst must complete (y_valid pulses) under the
    # same settle discipline, with no glitched y_i/y_q recorded in transit.
    await _pulse_sample(dut, 10, -5, 20, 3, -8, 15, 4, -4)

    mon.kill()
    assert not violations, "settle violations after reset re-arm:\n" + "\n".join(violations)
