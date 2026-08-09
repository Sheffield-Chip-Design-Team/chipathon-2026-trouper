"""
test_mcp_sc_settle.py -- Open Risks item 43, paced_dsp MCP settle proof,
sc_detector leg.

Structural background (src/frontend/sc_detector.v): the shared TDM 8x8
multiply (tdm_a_r * tdm_b_r -> tdm_mul) is ~76 ns at the FD SS corner and
cannot settle in one 31.25 ns IQ_CLK cycle, so each TDM step is held for
TDM_WAIT+1 = 3 cycles (tdm_wait counting 0..TDM_WAIT) before the settled
product is captured into tdm_mul_r and consumed by the accumulation
case-statement at odd tdm_step values. This is exactly the relaxation the
SDC's scoped `set_multicycle_path 3 -setup -through $paced_nets` (paced_dsp
group, u_sc.* in scope) grants. This test proves the RTL hold protocol.

Consumed result register checked: tdm_mul_r -- written only when
tdm_busy && tdm_wait == TDM_WAIT (the `else` branch of the pacing if/else in
the main sequential block); every accumulator (acc_ci0/acc_cq0/acc_E0cur/
acc_E0del) is built directly from tdm_mul_r and the current (by-then settled)
tdm_mul, so gating tdm_mul_r also gates every downstream accumulation.

  test_tdm_settle_gating   -- several full TDM bursts under normal sample
      arrivals; a background monitor asserts tdm_mul_r never changes unless
      tdm_busy and tdm_wait==TDM_WAIT held on the preceding edge.
  test_reset_mid_burst_rearm -- assert rst_n partway through a TDM burst
      (tdm_wait < TDM_WAIT, tdm_busy=1); confirms tdm_busy/tdm_wait/tdm_step/
      tdm_mul_r all clear, then a subsequent sample re-arms and completes a
      clean TDM burst under the same settle discipline.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

CLK_NS = 31.25
TDM_WAIT = 2      # localparam TDM_WAIT = 2'd2 in sc_detector.v
BURST_MARGIN = 40  # >= 8 steps * 3 cycles = 24, plus slack


async def _reset(dut):
    dut.rst_n.value = 0
    dut.iq_valid.value = 0
    dut.delayed_valid.value = 0
    dut.cur_i0.value = 0
    dut.cur_q0.value = 0
    dut.del_i0.value = 0
    dut.del_q0.value = 0
    dut.sf.value = 7
    dut.sample_shift.value = 0
    dut.sc_thr.value = 0
    dut.sc_hits_req.value = 0
    dut.sc_clr.value = 0
    dut.sc_lock_force.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


async def _pulse_sample(dut, ci, cq, di, dq):
    """One (cur,del) sample pair: iq_valid and delayed_valid coincide (the
    live PSRAM delay-line path can present them together); their registered
    copies (iq_valid_r/delayed_valid_r) fire the TDM burst one cycle later."""
    dut.cur_i0.value = ci & 0xFF
    dut.cur_q0.value = cq & 0xFF
    dut.del_i0.value = di & 0xFF
    dut.del_q0.value = dq & 0xFF
    dut.iq_valid.value = 1
    dut.delayed_valid.value = 1
    await RisingEdge(dut.clk)
    dut.iq_valid.value = 0
    dut.delayed_valid.value = 0
    await ClockCycles(dut.clk, BURST_MARGIN)


def _snap(dut):
    return {
        "rst_n": int(dut.rst_n.value),
        "tdm_busy": int(dut.tdm_busy.value),
        "tdm_wait": int(dut.tdm_wait.value),
        "tdm_mul_r": int(dut.tdm_mul_r.value),
    }


async def _settle_monitor(dut, violations):
    prev = _snap(dut)
    while True:
        await RisingEdge(dut.clk)
        await ReadOnly()
        cur = _snap(dut)
        if cur["rst_n"] == 1 and cur["tdm_mul_r"] != prev["tdm_mul_r"]:
            if not (prev["tdm_busy"] == 1 and prev["tdm_wait"] == TDM_WAIT):
                violations.append(
                    f"tdm_mul_r changed with tdm_busy={prev['tdm_busy']} "
                    f"tdm_wait={prev['tdm_wait']} (need busy=1 wait={TDM_WAIT})"
                )
        prev = cur


async def _wait_until(dut, pred, timeout_cycles=500):
    for _ in range(timeout_cycles):
        await ReadOnly()
        if pred():
            return
        await RisingEdge(dut.clk)
    raise TimeoutError("condition never became true")


@cocotb.test()
async def test_tdm_settle_gating(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await _reset(dut)

    violations = []
    mon = cocotb.start_soon(_settle_monitor(dut, violations))

    samples = [(5, -3, 2, -1), (-7, 4, 1, 6), (0, 0, 3, -3), (127, -128, -1, 1)]
    for ci, cq, di, dq in samples:
        await _pulse_sample(dut, ci, cq, di, dq)
        assert int(dut.tdm_busy.value) == 0, "TDM burst did not drain within margin"

    mon.kill()
    assert not violations, "settle violations:\n" + "\n".join(violations)


@cocotb.test()
async def test_reset_mid_burst_rearm(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await _reset(dut)

    violations = []
    mon = cocotb.start_soon(_settle_monitor(dut, violations))

    dut.cur_i0.value = 5 & 0xFF
    dut.cur_q0.value = (-3) & 0xFF
    dut.del_i0.value = 2 & 0xFF
    dut.del_q0.value = (-1) & 0xFF
    dut.iq_valid.value = 1
    dut.delayed_valid.value = 1
    await RisingEdge(dut.clk)
    dut.iq_valid.value = 0
    dut.delayed_valid.value = 0

    await _wait_until(dut, lambda: int(dut.tdm_busy.value) == 1)
    for _ in range(3):  # land inside a paced hold (wait < TDM_WAIT)
        await RisingEdge(dut.clk)

    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 4)

    assert int(dut.tdm_busy.value) == 0, "tdm_busy not cleared by reset"
    assert int(dut.tdm_wait.value) == 0, "tdm_wait not cleared by reset"
    assert int(dut.tdm_step.value) == 0, "tdm_step not cleared by reset"
    assert int(dut.tdm_mul_r.value) == 0, "tdm_mul_r not cleared by reset"

    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)

    # Clean re-arm: a fresh sample must run a full TDM burst under the same
    # settle discipline (monitor stays live and must record no violations).
    await _pulse_sample(dut, 9, -2, 3, 5)
    assert int(dut.tdm_busy.value) == 0, "post-reset TDM burst did not drain"

    mon.kill()
    assert not violations, "settle violations after reset re-arm:\n" + "\n".join(violations)
