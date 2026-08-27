"""
test_mcp_iq_samp_cnt_settle.py -- Open Risks item 43, paced-DSP MCP=3/2 settle
proof for the dcr_valid -> iq_samp_cnt cone (trouper_top level).

Why this test exists
--------------------
`iq_samp_cnt` (src/top/trouper_top.v) is a top-level 32-bit counter:

    always @(posedge clk or negedge rst_n)
        if (!rst_n)          iq_samp_cnt <= 32'd0;
        else if (dcr_valid)  iq_samp_cnt <= iq_samp_cnt + 32'd1;

It is NOT inside u_dec/u_sc/u_tacc/u_comb, so the SDC `paced_nets`
(`{u_dec.* u_sc.* u_tacc.* u_comb.*}`) wildcard never reaches it and the
existing paced-DSP settle benches (test_mcp_decimator_settle.py,
test_mcp_tacc_settle.py) structurally cannot see it -- iq_samp_cnt is a
top-level reg, the decimator bench's DUT is sd_decimator_poly. The
dcr_valid -> iq_samp_cnt increment recurrence therefore has no MCP relaxation
and no settle proof today.

This bench is the honest bar for adding an `iq_samp_cnt` group at
`set_multicycle_path 3 -setup / 2 -hold` -- the paced/quasi-static house
convention (paced_dsp, sc_quasi_static, pcfsm_*, training_window,
timing_ref_*; only psram_barrel_shift and regbank_write differ at 2/1).

The argument being tested
-------------------------
The 32-bit increment adder is the slow arc; MCP=3 -setup is honest iff the
enable `dcr_valid` guarantees a launch->capture separation of >= 3 IQ_CLK
cycles, and MCP=2 -hold (setup-1) is honest iff there is never an adjacent
launch edge carrying different data.

Both reduce to one structural fact: **dcr_valid is a 1-cycle pulse that is
never high on two consecutive IQ_CLK edges.** It is decimator iq_valid
(sd_decimator_poly.v: `iq_valid<=0` default every non-reset cycle, driven to
4'hf only on the single `hb2_stream_last && hb2_mac_ready` cycle) passed
through dc_removal's transparent 1-deep `sample_out_valid <= sample_valid`
register. At R=64 the actual pulse spacing is ~64 cycles, so 3/2 is
conservative -- but the pulse-width fact is load-bearing, so it is asserted
here rather than assumed.

  test_dcr_valid_single_cycle   -- free-running capture; a background monitor
      asserts dcr_valid is never high on two consecutive IQ_CLK edges, and
      records the observed pulse count and min spacing (non-vacuity).
  test_iq_samp_cnt_settle_gating -- same run; the monitor additionally
      asserts iq_samp_cnt changes ONLY on an edge whose preceding edge had
      dcr_valid=1, each change is exactly +1 (mod 2^32), and consecutive
      changes are >= SETTLE cycles apart (setup direction); the absence of an
      adjacent launch edge is the hold direction.
  test_reset_mid_stream_rearm   -- assert RESETB mid-stream (once between
      pulses, once coincident with a dcr_valid pulse); confirm iq_samp_cnt
      clears to 0, then a fresh capture resumes counting under the same
      discipline with the monitor still live.
"""

import math

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge, Timer, with_timeout

from test_trouper_top import CLK_NS, sdm_driver, spi_write

SETTLE = 3          # cycles the MCP=3 -setup exception would claim
HOLD_MULT = 2       # companion MCP=2 -hold (setup - 1)
SF = 7
BW_KHZ = 250
FILL_CLKS = 700     # decimator CIC/HB pipeline fill before the first dcr_valid


async def _boot(dut):
    """Clock + reset + idle SPI, then start the SDM stimulus. The decimator
    and iq_samp_cnt run regardless of RX_HOLD, so no config/release is needed
    for this cone; SF/BW are written only so the DUT sits in a normal state."""
    cocotb.start_soon(Clock(dut.IQ_CLK, CLK_NS, unit="ns").start())
    dut.HOST_CS.value = 1
    dut.SPI_MOSI.value = 0
    dut.SPI_SCK.value = 0
    dut.IQ_DATA_I.value = 0
    dut.IQ_DATA_Q.value = 0
    dut.RESETB.value = 0
    await Timer(4 * CLK_NS, unit="ns")
    dut.RESETB.value = 1
    await Timer(8 * CLK_NS, unit="ns")
    await spi_write(dut, 0x09, SF & 0x0F)
    await spi_write(dut, 0x0A, 0)                 # 250 kHz
    cocotb.start_soon(sdm_driver(dut, SF, BW_KHZ))


def _snap(dut):
    return {
        "rst_n": int(dut.RESETB.value),
        "dcr_valid": int(dut.u_dut.dcr_valid.value),
        "iq_samp_cnt": int(dut.u_dut.iq_samp_cnt.value),
    }


class SettleMonitor:
    """Runs forever; start via cocotb.start_soon(), stop via .task.kill().

    Asserts, every IQ_CLK edge with rst_n high on both this and the prior
    edge:
      - dcr_valid never high two edges running   (pulse-width fact)
      - iq_samp_cnt moves only when prev dcr_valid == 1
      - each move is exactly +1 (mod 2^32)
      - consecutive moves are >= SETTLE cycles apart
    """

    def __init__(self, dut):
        self.dut = dut
        self.violations = []
        self.pulses = 0
        self.increments = 0
        self.min_pulse_gap = None
        self.min_incr_gap = None
        self._since_pulse = 0
        self._since_incr = 0

    async def run(self):
        prev = _snap(self.dut)
        while True:
            await RisingEdge(self.dut.IQ_CLK)
            await ReadOnly()
            cur = _snap(self.dut)
            self._since_pulse += 1
            self._since_incr += 1

            # The reset edge itself is an async clear, not an MCP arc.
            if cur["rst_n"] == 0 or prev["rst_n"] == 0:
                prev = cur
                self._since_pulse = 0
                self._since_incr = 0
                continue

            if cur["dcr_valid"] == 1:
                if prev["dcr_valid"] == 1:
                    self.violations.append(
                        "dcr_valid high on two consecutive IQ_CLK edges -- "
                        "the MCP=3/2 launch->capture separation is not real"
                    )
                self.pulses += 1
                if self._since_pulse > 1:  # skip the first observed pulse
                    gap = self._since_pulse
                    if self.min_pulse_gap is None or gap < self.min_pulse_gap:
                        self.min_pulse_gap = gap
                self._since_pulse = 0

            if cur["iq_samp_cnt"] != prev["iq_samp_cnt"]:
                self.increments += 1
                if prev["dcr_valid"] != 1:
                    self.violations.append(
                        f"iq_samp_cnt moved with prev dcr_valid="
                        f"{prev['dcr_valid']} -- an unpaced launch"
                    )
                delta = (cur["iq_samp_cnt"] - prev["iq_samp_cnt"]) & 0xFFFFFFFF
                if delta != 1:
                    self.violations.append(
                        f"iq_samp_cnt jumped by {delta}, not +1 "
                        f"({prev['iq_samp_cnt']} -> {cur['iq_samp_cnt']})"
                    )
                if self._since_incr < SETTLE and self.increments > 1:
                    self.violations.append(
                        f"iq_samp_cnt moved {self._since_incr} cycle(s) after "
                        f"the previous move, need >= {SETTLE} (MCP=3 -setup)"
                    )
                if self.increments > 1:
                    if self.min_incr_gap is None or self._since_incr < self.min_incr_gap:
                        self.min_incr_gap = self._since_incr
                self._since_incr = 0

            prev = cur


async def _wait_pulse_edge(dut, timeout_clks=4000):
    """Return exactly on the delta the decimator drives dcr_valid high. This
    leaves the sim in a signal-edge (not ReadOnly) phase, so the caller may
    drive RESETB in the same timestep as the pulse."""
    await with_timeout(RisingEdge(dut.u_dut.dcr_valid),
                       timeout_clks * CLK_NS, "ns")


@cocotb.test()
async def test_dcr_valid_single_cycle(dut):
    """The load-bearing fact: dcr_valid is never high on two consecutive
    IQ_CLK edges over a long free-running capture."""
    await _boot(dut)
    mon = SettleMonitor(dut)
    mon.task = cocotb.start_soon(mon.run())

    await ClockCycles(dut.IQ_CLK, FILL_CLKS + 64 * 40)  # ~40 dcr_valid pulses

    mon.task.kill()
    assert mon.pulses >= 20, (
        f"only {mon.pulses} dcr_valid pulse(s) seen -- capture too short to "
        f"be a meaningful check"
    )
    assert not mon.violations, "settle violations:\n  " + "\n  ".join(mon.violations)
    assert mon.min_pulse_gap is not None and mon.min_pulse_gap >= SETTLE, (
        f"min dcr_valid spacing {mon.min_pulse_gap} < {SETTLE}"
    )
    dut._log.info(
        f"dcr_valid: {mon.pulses} pulses, min spacing {mon.min_pulse_gap} "
        f"IQ_CLK cycles (MCP=3 -setup needs >= {SETTLE}; "
        f"MCP={HOLD_MULT} -hold satisfied -- no adjacent launch edge)"
    )


@cocotb.test()
async def test_iq_samp_cnt_settle_gating(dut):
    """iq_samp_cnt moves only on a post-dcr_valid edge, by exactly +1, with
    >= SETTLE cycles between moves."""
    await _boot(dut)
    mon = SettleMonitor(dut)
    mon.task = cocotb.start_soon(mon.run())

    await ClockCycles(dut.IQ_CLK, FILL_CLKS + 64 * 40)

    mon.task.kill()
    assert mon.increments >= 20, (
        f"only {mon.increments} iq_samp_cnt increment(s) -- capture too short"
    )
    assert not mon.violations, "settle violations:\n  " + "\n  ".join(mon.violations)
    dut._log.info(
        f"iq_samp_cnt: {mon.increments} increments, min gap {mon.min_incr_gap} "
        f"IQ_CLK cycles, all +1 and all post-dcr_valid"
    )


@cocotb.test()
async def test_reset_mid_stream_rearm(dut):
    """RESETB mid-stream clears iq_samp_cnt and the counter re-arms cleanly
    under the same settle discipline."""
    await _boot(dut)
    mon = SettleMonitor(dut)
    mon.task = cocotb.start_soon(mon.run())

    # Let the counter get well clear of zero.
    await ClockCycles(dut.IQ_CLK, FILL_CLKS + 64 * 10)
    await ReadOnly()
    assert int(dut.u_dut.iq_samp_cnt.value) > 5, "counter never advanced pre-reset"

    # (a) reset between pulses.
    await RisingEdge(dut.IQ_CLK)
    dut.RESETB.value = 0
    await ClockCycles(dut.IQ_CLK, 4)
    await ReadOnly()
    assert int(dut.u_dut.iq_samp_cnt.value) == 0, "iq_samp_cnt not cleared by reset"
    await RisingEdge(dut.IQ_CLK)
    dut.RESETB.value = 1
    await ClockCycles(dut.IQ_CLK, 2)

    # Let it advance again, then (b) reset coincident with a dcr_valid pulse.
    await ClockCycles(dut.IQ_CLK, FILL_CLKS + 64 * 6)
    await _wait_pulse_edge(dut)
    dut.RESETB.value = 0          # same timestep dcr_valid rose
    await ClockCycles(dut.IQ_CLK, 4)
    await ReadOnly()
    assert int(dut.u_dut.iq_samp_cnt.value) == 0, \
        "iq_samp_cnt not cleared when reset coincided with dcr_valid"
    await RisingEdge(dut.IQ_CLK)
    dut.RESETB.value = 1

    # Clean re-arm: fresh capture must count under the same discipline.
    incr_before = mon.increments
    await ClockCycles(dut.IQ_CLK, FILL_CLKS + 64 * 20)

    mon.task.kill()
    assert mon.increments - incr_before >= 10, (
        f"only {mon.increments - incr_before} increment(s) after re-arm -- "
        f"counter did not resume"
    )
    assert not mon.violations, (
        "settle violations across reset re-arm:\n  " + "\n  ".join(mon.violations)
    )
