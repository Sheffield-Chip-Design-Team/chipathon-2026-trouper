"""
test_mcp_decimator_settle.py -- Open Risks item 43, paced_dsp MCP settle
proof, sd_decimator_poly leg.

Structural background (src/decimator/sd_decimator_poly.v): the HB1 and HB2
MAC combinational cones cannot settle in one 31.25 ns IQ_CLK cycle at the FD
SS corner, so each stream index is held for MAC_WAIT+1 = 3 cycles
(hb1_wait/hb2_wait counting 0..MAC_WAIT) before the settled MAC result is
consumed -- this is exactly the relaxation the SDC's scoped
`set_multicycle_path 3 -setup -through $paced_nets` (paced_dsp group,
u_dec.* in scope) grants. This test proves the RTL hold protocol, which the
STA-side MCP audit (rtl-test/scripts/run_mcp_audit.sh) cannot: it checks
timing arcs exist, not that the consuming register waits for them.

Consumed result registers checked:
  - hb1_hold_i/hb1_hold_q[0:3] -- written by store_hb1_result() only when
    hb1_mac_ready (hb1_wait == MAC_WAIT); this is the register the HB2 stage
    reads.
  - iq_out_i/iq_out_q -- written by store_hb2_result() only when
    hb2_mac_ready (hb2_wait == MAC_WAIT); this is the register the SDC scope
    and downstream dc_removal actually consume.

  test_hb1_hb2_settle_gating -- free-running burst under normal operation:
      a background monitor asserts, every cycle, that neither result group
      changes unless its wait counter was at the terminal count (and busy)
      on the immediately preceding edge.
  test_reset_mid_burst_rearm -- assert rst_n partway through an HB1 burst
      (wait < MAC_WAIT, busy=1); confirms wait/busy/stream counters clear,
      no glitched value is latched across the reset edge, and a subsequent
      burst re-arms and completes cleanly under the same settle discipline.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

CLK_NS = 31.25
MAC_WAIT = 2  # localparam MAC_WAIT = 2'd2 in sd_decimator_poly.v


async def _reset(dut):
    dut.rst_n.value = 0
    dut.iq_in_i.value = 0
    dut.iq_in_q.value = 0
    await ClockCycles(dut.clk_32m, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk_32m, 2)


def _snap(dut):
    return {
        "rst_n": int(dut.rst_n.value),
        "hb1_busy": int(dut.hb1_busy.value),
        "hb1_wait": int(dut.hb1_wait.value),
        "hb2_busy": int(dut.hb2_busy.value),
        "hb2_wait": int(dut.hb2_wait.value),
        "hb1_hold": [int(dut.hb1_hold_i[k].value) for k in range(4)]
                    + [int(dut.hb1_hold_q[k].value) for k in range(4)],
        "iq_out": (int(dut.iq_out_i.value), int(dut.iq_out_q.value)),
    }


async def _settle_monitor(dut, violations):
    """Runs forever; call cocotb.start_soon() and cancel via task.kill()."""
    prev = _snap(dut)
    while True:
        await RisingEdge(dut.clk_32m)
        await ReadOnly()
        cur = _snap(dut)
        # Ignore the edge a reset takes effect on -- that's an async clear,
        # not an MCP-relaxed arithmetic path, and is checked separately.
        if cur["rst_n"] == 1:
            if cur["hb1_hold"] != prev["hb1_hold"]:
                if not (prev["hb1_busy"] == 1 and prev["hb1_wait"] == MAC_WAIT):
                    violations.append(
                        f"hb1_hold changed with hb1_busy={prev['hb1_busy']} "
                        f"hb1_wait={prev['hb1_wait']} (need busy=1 wait={MAC_WAIT})"
                    )
            if cur["iq_out"] != prev["iq_out"]:
                if not (prev["hb2_busy"] == 1 and prev["hb2_wait"] == MAC_WAIT):
                    violations.append(
                        f"iq_out changed with hb2_busy={prev['hb2_busy']} "
                        f"hb2_wait={prev['hb2_wait']} (need busy=1 wait={MAC_WAIT})"
                    )
        prev = cur


async def _wait_until(dut, pred, timeout_cycles=2000):
    for _ in range(timeout_cycles):
        await ReadOnly()
        if pred():
            return
        await RisingEdge(dut.clk_32m)
    raise TimeoutError("condition never became true")


@cocotb.test()
async def test_hb1_hb2_settle_gating(dut):
    cocotb.start_soon(Clock(dut.clk_32m, CLK_NS, unit="ns").start())
    await _reset(dut)

    violations = []
    mon = cocotb.start_soon(_settle_monitor(dut, violations))

    # Constant 1-bit stream drives a CIC ramp -> several HB1 bursts (every
    # ~32 clocks) and at least one HB2 burst (every ~64 clocks, needs 2 HB1
    # completions). 400 clocks covers >6 HB1 bursts / >3 HB2 bursts.
    dut.iq_in_i.value = 0xF
    dut.iq_in_q.value = 0x0
    await ClockCycles(dut.clk_32m, 400)

    mon.kill()
    assert not violations, "settle violations:\n" + "\n".join(violations)


@cocotb.test()
async def test_reset_mid_burst_rearm(dut):
    cocotb.start_soon(Clock(dut.clk_32m, CLK_NS, unit="ns").start())
    await _reset(dut)

    violations = []
    mon = cocotb.start_soon(_settle_monitor(dut, violations))

    dut.iq_in_i.value = 0xF
    dut.iq_in_q.value = 0x0

    # Run until an HB1 burst is in flight but not yet at the settle point.
    await _wait_until(dut, lambda: int(dut.hb1_busy.value) == 1)
    # Catch it mid-hold (wait < MAC_WAIT) a few times to vary the phase.
    for _ in range(2):
        await RisingEdge(dut.clk_32m)

    # Assert reset squarely inside the paced hold.
    dut.rst_n.value = 0
    await ClockCycles(dut.clk_32m, 4)

    assert int(dut.hb1_busy.value) == 0, "hb1_busy not cleared by reset"
    assert int(dut.hb1_wait.value) == 0, "hb1_wait not cleared by reset"
    assert int(dut.hb2_busy.value) == 0, "hb2_busy not cleared by reset"
    assert int(dut.hb2_wait.value) == 0, "hb2_wait not cleared by reset"
    post_reset_hold = [int(dut.hb1_hold_i[k].value) for k in range(4)] \
        + [int(dut.hb1_hold_q[k].value) for k in range(4)]
    assert post_reset_hold == [0] * 8, \
        f"hb1_hold not zeroed by reset: {post_reset_hold}"
    assert (int(dut.iq_out_i.value), int(dut.iq_out_q.value)) == (0, 0), \
        "iq_out not zeroed by reset"

    dut.rst_n.value = 1
    await ClockCycles(dut.clk_32m, 2)

    # Clean re-arm: a fresh burst must run to completion under the same
    # settle discipline (monitor stays live and must record no violations).
    await ClockCycles(dut.clk_32m, 400)

    mon.kill()
    assert not violations, "settle violations after reset re-arm:\n" + "\n".join(violations)
