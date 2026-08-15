"""
test_mcp_psram_bshift_settle.py -- Open Risks #43 settling proof for the
`psram_barrel_shift` MCP group.

What the SDC claims
-------------------
`pnr_32m_scoped_v25_b6.sdc` grants MCP=2 setup / 1 hold `-to` the
`u_psram.del_n_r[*]` / `u_psram.del_offset_r[*]` register endpoints, i.e. the
variable-shift cone

    del_offset_c = 8 << (sf + sample_shift)
    del_n_c      = 1 << (sf + sample_shift)

gets two cycles to settle before it is captured.

Why this group is different
---------------------------
It is the one group in the manifest whose guarantee was already structural
before any of the config-settle work: `psram_buf_ctrl.v:314` loads the two
registers **only** when `sf == sf_prev && sample_shift == sample_shift_prev`.
Since `sf_prev` is `sf` delayed one cycle, that condition holding at the capture
edge C means the shift operands were identical across C-1 and C-2 -- exactly
the two settled cycles MCP=2 requires. No RTL change was needed here; this file
is the missing evidence, not a fix.

Note the required window is 2 cycles, not the 3 that the MCP=3 groups need --
`SETTLE = 2` below is the SDC's own number for this group, not a weaker check.

  test_bshift_settle_normal        -- a sweep of in-spec (SF, sample_shift)
      configurations; a background monitor asserts that on every edge where
      either register changes, the operands were stable for the preceding
      2 cycles, and that the loaded values are arithmetically correct.
  test_no_load_while_operands_move -- the adversarial converse: drive sf so it
      changes every single cycle, and require that neither register loads at
      all during that run. Then let it settle and confirm the load resumes with
      the correct value.
  test_reset_rearm                 -- reset asserted mid-change returns both
      registers to their reset values (0 / 1) and the gate re-arms cleanly.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

CLK_NS = 31.25
SETTLE = 2          # cycles this group's MCP=2 setup exception claims

# In-spec configuration space: SF_CFG 7-12, sample_shift 1-2 (250/125 kHz).
CONFIGS = [(7, 1), (9, 1), (12, 1), (7, 2), (10, 2)]


def _ops(dut):
    return (int(dut.sf.value), int(dut.sample_shift.value))


def _regs(dut):
    return (int(dut.del_offset_r.value), int(dut.del_n_r.value))


class BShiftMonitor:
    """Asserts the load gate really does buy SETTLE cycles."""

    def __init__(self, dut):
        self.dut = dut
        self.history = []       # operand samples, newest last
        self.loads = 0
        self.violations = []

    async def run(self):
        prev_regs = None
        while True:
            await RisingEdge(self.dut.clk_32m)
            await ReadOnly()
            if int(self.dut.rst_n.value) == 0:
                self.history.clear()
                prev_regs = None
                continue

            self.history.append(_ops(self.dut))
            regs = _regs(self.dut)

            if prev_regs is not None and regs != prev_regs:
                self.loads += 1
                # The capture used operands as they stood after the previous
                # edge; the gate should have required the one before that to
                # match. Window = the SETTLE samples preceding this one.
                window = self.history[-(SETTLE + 1):-1]
                if len(window) < SETTLE:
                    self.violations.append(
                        f"load #{self.loads}: only {len(window)} cycle(s) of "
                        f"history since reset, cannot prove {SETTLE}"
                    )
                elif any(o != window[-1] for o in window):
                    self.violations.append(
                        f"load #{self.loads}: operands moved within {SETTLE} "
                        f"cycles of the capture; window(oldest->newest)={window}, "
                        f"regs {prev_regs} -> {regs}"
                    )
                else:
                    sf, shift = window[-1]
                    want = ((8 << (sf + shift)), (1 << (sf + shift)))
                    # del_offset_r is ABITS wide and may truncate; compare the
                    # low bits actually stored.
                    mask = (1 << len(self.dut.del_offset_r.value)) - 1
                    if regs != (want[0] & mask, want[1] & 0x7FFF):
                        self.violations.append(
                            f"load #{self.loads}: sf={sf} shift={shift} gave "
                            f"{regs}, expected {(want[0] & mask, want[1] & 0x7FFF)}"
                        )
            prev_regs = regs


def _idle(dut):
    """Tie off everything the barrel-shift load does not depend on."""
    for name in ("psram_en", "init_start", "qspi_owner", "iq_valid", "sc_lock",
                 "training_done", "W_commit", "packet_end", "packet_active",
                 "clr_err", "sio_in", "sc_ant_sel", "timing_ref",
                 "iq_sample_cnt", "replay_delay_samples"):
        if hasattr(dut, name):
            getattr(dut, name).value = 0
    for name in ("iq_i0", "iq_i1", "iq_i2", "iq_i3",
                 "iq_q0", "iq_q1", "iq_q2", "iq_q3"):
        if hasattr(dut, name):
            getattr(dut, name).value = 0


async def _start(dut, sf=7, shift=1):
    cocotb.start_soon(Clock(dut.clk_32m, CLK_NS, unit="ns").start())
    _idle(dut)
    dut.sf.value = sf
    dut.sample_shift.value = shift
    dut.rst_n.value = 0
    await ClockCycles(dut.clk_32m, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk_32m, 3)
    mon = BShiftMonitor(dut)
    cocotb.start_soon(mon.run())
    # Let the monitor accumulate SETTLE+1 operand samples before any config
    # change, otherwise the first load lands with too little history to judge
    # and the monitor (correctly) refuses to call it proven.
    await ClockCycles(dut.clk_32m, SETTLE + 2)
    return mon


@cocotb.test()
async def test_bshift_settle_normal(dut):
    """Every load across the in-spec config space is 2-cycle settled."""
    # Start OUTSIDE the swept set, so every entry in CONFIGS is a genuine
    # change and the load count below stays a strict check.
    mon = await _start(dut, sf=8, shift=2)
    for sf, shift in CONFIGS:
        dut.sf.value = sf
        dut.sample_shift.value = shift
        await ClockCycles(dut.clk_32m, 6)
        off, n = _regs(dut)
        assert n == (1 << (sf + shift)) & 0x7FFF, \
            f"SF{sf}/shift{shift}: del_n_r={n}, expected {1 << (sf + shift)}"

    assert mon.loads >= len(CONFIGS), \
        f"only {mon.loads} load(s) for {len(CONFIGS)} configs -- test is vacuous"
    assert not mon.violations, (
        "barrel-shift settle property violated:\n  " + "\n  ".join(mon.violations)
    )
    dut._log.info(f"{mon.loads} load(s), all {SETTLE}-cycle settled")


@cocotb.test()
async def test_no_load_while_operands_move(dut):
    """While sf changes every cycle, neither register may load at all."""
    mon = await _start(dut)
    await ClockCycles(dut.clk_32m, 4)          # settle at the initial config

    loads_before = mon.loads
    regs_before = _regs(dut)
    for i in range(20):
        dut.sf.value = 7 + (i % 6)             # a different SF every cycle
        await ClockCycles(dut.clk_32m, 1)

    assert mon.loads == loads_before, (
        f"{mon.loads - loads_before} load(s) occurred while sf changed every "
        "cycle -- the sf==sf_prev gate is not holding the capture off"
    )
    assert _regs(dut) == regs_before, "registers moved during the unstable run"

    # Settle and confirm the gate re-opens with the right value.
    dut.sf.value = 11
    dut.sample_shift.value = 1
    await ClockCycles(dut.clk_32m, 6)
    assert mon.loads > loads_before, "no load after the operands settled"
    assert _regs(dut)[1] == (1 << 12), f"del_n_r={_regs(dut)[1]}, expected {1 << 12}"
    assert not mon.violations, (
        "settle property violated:\n  " + "\n  ".join(mon.violations)
    )


@cocotb.test()
async def test_reset_rearm(dut):
    """Reset mid-change restores the reset values and the gate re-arms."""
    mon = await _start(dut, sf=9, shift=2)
    await ClockCycles(dut.clk_32m, 6)
    assert _regs(dut)[1] == (1 << 11), "precondition: expected a settled load"

    dut.sf.value = 12                           # change, then reset immediately
    dut.rst_n.value = 0
    await ClockCycles(dut.clk_32m, 2)
    await ReadOnly()
    assert _regs(dut) == (0, 1), \
        f"reset values wrong: del_offset_r/del_n_r = {_regs(dut)}, expected (0, 1)"

    await RisingEdge(dut.clk_32m)
    dut.rst_n.value = 1
    dut.sf.value = 8
    dut.sample_shift.value = 1
    await ClockCycles(dut.clk_32m, 6)
    assert _regs(dut)[1] == (1 << 9), \
        f"no clean re-arm after reset: del_n_r={_regs(dut)[1]}, expected {1 << 9}"
    assert not mon.violations, (
        "settle property violated across reset:\n  " + "\n  ".join(mon.violations)
    )
