"""
test_mcp_cfg_hold_settle.py -- Open Risks #43, the settling proof for the
config-sourced MCP groups, via the RX_HOLD mutual exclusion.

Design: planning/mcp-config-settle-gate-design.md §2/§4, verification §8 tests
2 and 3.

Groups covered
--------------
`sc_quasi_static`, `timing_ref_hits`, `timing_ref_config`, `training_window`
(and, redundantly with cocotb/mcp_pcfsm_settle, `pcfsm_quasi_static` /
`pcfsm_mval`). Every one of them takes a quasi-static reg_bank source into a
register captured at or after an sc_lock-driven event.

The argument being tested
-------------------------
Rather than add settle logic to the timing-critical DSP blocks, the design
makes two things mutually exclusive:

    config writable  <->  RX_HOLD == 1
    detector can lock <->  RX_HOLD == 0

If both halves hold, no capture edge can occur in any window where a source can
change, so the MCP=3 settling requirement is satisfied vacuously -- for an
unbounded number of cycles, not merely 3.

This file asserts BOTH halves against the real trouper_top wiring, plus the one
timing obligation the interlock creates (a release must not follow a config
write too closely -- §5).

  test_no_lock_while_held        -- half 1: with RX_HOLD set, a stimulus that
      normally locks within a few symbols produces no sc_lock, and neither does
      SC_FORCE_LOCK (sc_clr re-clears the forced lock every cycle).
  test_config_changes_only_while_held -- half 2: a background monitor watches
      every MCP'd config net for the whole run (configure, release, lock,
      packet) and requires every change to land on a cycle where RX_HOLD was
      set. A change while the detector is live is exactly the hazard.
  test_release_waits_for_settled_config -- the §5 obligation: at the release
      edge the config must already have been stable for >= SETTLE cycles, or
      the first capture after release could see a too-fresh value.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge, Timer

from test_trouper_top import (
    CLK_NS, spi_read, spi_write, sdm_driver, release_rx_hold, assert_rx_hold,
)

SETTLE = 3          # cycles the MCP=3 setup exception claims
CLK_PER_IQ = 64
SF = 7
BW_KHZ = 250
M = 1 << (SF + 1)   # sample_shift = 1 at 250 kHz
SYM_NS = M * CLK_PER_IQ * CLK_NS


def _cfg(dut):
    """Every reg_bank source named by a config-sourced MCP group."""
    top = dut.u_dut
    return {
        "rb_sf_cfg": int(top.rb_sf_cfg.value),
        "rb_bw_sel": int(top.rb_bw_sel.value),
        "rb_sample_shift": int(top.rb_sample_shift.value),
        "rb_sc_hits_req": int(top.rb_sc_hits_req.value),
        "rb_pkt_timeout_syms": int(top.rb_pkt_timeout_syms.value),
        "rb_tacc_window_syms": int(top.rb_tacc_window_syms.value),
    }


class CfgHoldMonitor:
    """Requires every config change to land while RX_HOLD is set, and every
    release to follow a settled config."""

    def __init__(self, dut):
        self.dut = dut
        self.changes = 0
        self.releases = 0
        self.violations = []

    async def run(self):
        prev_cfg = None
        prev_hold = None
        stable_for = 0
        while True:
            await RisingEdge(self.dut.IQ_CLK)
            await ReadOnly()
            if int(self.dut.RESETB.value) == 0:
                prev_cfg = None
                prev_hold = None
                stable_for = 0
                continue

            cfg = _cfg(self.dut)
            hold = int(self.dut.u_dut.rb_rx_hold.value)

            if prev_cfg is not None and cfg != prev_cfg:
                self.changes += 1
                changed = sorted(k for k in cfg if cfg[k] != prev_cfg[k])
                # The change is visible on this edge; it was accepted on this
                # edge, so RX_HOLD must have been set going into it.
                if not prev_hold:
                    self.violations.append(
                        f"config {changed} changed while RX_HOLD was clear -- "
                        f"the detector could have captured a moving source"
                    )
                stable_for = 0
            elif prev_cfg is not None:
                stable_for += 1

            # Release edge: RX_HOLD 1 -> 0 hands the detector back.
            if prev_hold == 1 and hold == 0:
                self.releases += 1
                if stable_for < SETTLE:
                    self.violations.append(
                        f"RX_HOLD released {stable_for} cycle(s) after the last "
                        f"config change, need >= {SETTLE} (design doc §5)"
                    )

            prev_cfg = cfg
            prev_hold = hold


async def _boot(dut, *, start_stim=True):
    """Reset and bring the SPI interface up. Leaves RX_HOLD set (reset state)."""
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
    if start_stim:
        cocotb.start_soon(sdm_driver(dut, SF, BW_KHZ))
    await spi_read(dut, 0x00)
    await spi_read(dut, 0x09)


async def _write_config(dut):
    """The gated set, plus the ungated bits a lock needs."""
    await spi_write(dut, 0x09, SF & 0x0F)
    await spi_write(dut, 0x0A, 0)          # 250 kHz
    await spi_write(dut, 0x0C, 0x01)       # permissive threshold
    await spi_write(dut, 0x0D, 0x00)
    await spi_write(dut, 0x0E, 0x00)       # 1 hit fires lock
    await spi_write(dut, 0x0B, 0x50)


async def _psram_up(dut):
    await spi_write(dut, 0x70, 0x01)
    for _ in range(500):
        await Timer(8 * CLK_NS, unit="ns")
        if (await spi_read(dut, 0x71)) & 0x08:
            return True
    return False


@cocotb.test()
async def test_no_lock_while_held(dut):
    """With RX_HOLD set the detector cannot lock, SC_FORCE_LOCK included."""
    await _boot(dut)
    await _write_config(dut)
    assert await _psram_up(dut), "PSRAM INIT_DONE never set"
    assert int(dut.u_dut.rb_rx_hold.value) == 1, "RX_HOLD not set out of reset"

    # Long enough that the same stimulus locks comfortably once released.
    for _ in range(12):
        await Timer(SYM_NS, unit="ns")
        assert int(dut.u_dut.sc_lock.value) == 0, "sc_lock asserted while RX_HOLD held"
        assert (await spi_read(dut, 0x02)) & 0x01 == 0, "CORR_LOCK IRQ set while held"

    # The manual override must not punch through either: sc_clr re-clears the
    # forced lock every cycle while the hold is asserted.
    await spi_write(dut, 0x19, 0x01)       # SC_FORCE_LOCK (W1P)
    for _ in range(4):
        await Timer(SYM_NS, unit="ns")
        assert int(dut.u_dut.sc_lock.value) == 0, \
            "SC_FORCE_LOCK punched through RX_HOLD -- mutual exclusion broken"

    # Control: the very same setup locks once released, so the checks above
    # were not passing merely because the stimulus was inadequate.
    await release_rx_hold(dut)
    locked = False
    for _ in range(20):
        await Timer(SYM_NS, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x01:
            locked = True
            break
    assert locked, "no lock even after release -- the no-lock result above is vacuous"


@cocotb.test()
async def test_config_changes_only_while_held(dut):
    """No MCP'd config source may change while the detector can lock."""
    await _boot(dut)
    mon = CfgHoldMonitor(dut)
    cocotb.start_soon(mon.run())

    await _write_config(dut)
    # Two further gated writes with values that differ from the reset defaults,
    # so the monitor is guaranteed to observe real changes: _write_config
    # happens to rewrite several registers with their reset values (SF=7,
    # bw=0, pkt_timeout=0x50), which are no-ops on the nets being watched.
    await spi_write(dut, 0x27, 0x0A)       # TACC_WINDOW_SYMS 8 -> 10
    await spi_write(dut, 0x0B, 0x40)       # PKT_TIMEOUT_SYMS 0x50 -> 0x40
    assert await _psram_up(dut), "PSRAM INIT_DONE never set"
    await release_rx_hold(dut)

    locked = False
    for _ in range(20):
        await Timer(SYM_NS, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x01:
            locked = True
            break
    assert locked, "sc_lock never fired -- monitor never saw a live detector"

    # Attempt the hazard directly: rewrite every gated register while live.
    # Hardware must refuse, so the monitor must see no change.
    changes_before = mon.changes
    for addr, val in ((0x09, 0x0C), (0x0A, 0x01), (0x0B, 0x20),
                      (0x0E, 0x03), (0x27, 0x0F)):
        await spi_write(dut, addr, val)
    await Timer(2 * SYM_NS, unit="ns")
    assert mon.changes == changes_before, \
        "a gated register moved while the detector was live"

    # Re-asserting RX_HOLD mid-packet must NOT re-open the window: the gate is
    # rx_hold && !packet_active, so these writes are refused too.
    await assert_rx_hold(dut)
    await spi_write(dut, 0x09, 0x09)
    await Timer(SYM_NS, unit="ns")
    assert mon.changes == changes_before, \
        "RX_HOLD asserted mid-packet re-opened the config window (Open Risks #31/#32)"

    # ...and every one of those refusals must be visible to firmware.
    assert (await spi_read(dut, 0x1A)) & 0x02, \
        "CFG_WR_REJECTED never latched -- refused writes are silent"
    await release_rx_hold(dut)

    assert mon.changes >= 2, (
        f"monitor saw only {mon.changes} config change(s) -- too few to be a "
        "meaningful check"
    )
    assert not mon.violations, (
        "config/lock mutual exclusion violated:\n  " + "\n  ".join(mon.violations)
    )
    dut._log.info(f"mutual exclusion holds: {mon.changes} config change(s), "
                  f"{mon.releases} release(s), all while held")


@cocotb.test()
async def test_release_waits_for_settled_config(dut):
    """A release must not follow a config write inside the settle window."""
    await _boot(dut, start_stim=False)
    mon = CfgHoldMonitor(dut)
    cocotb.start_soon(mon.run())

    # Back-to-back SPI writes are inherently far apart (one frame is ~51 clocks
    # at 32 MHz), so this is the realistic host cadence; the adversarial
    # same-cycle Grouper case is design-doc §8 test 4.
    await _write_config(dut)
    await release_rx_hold(dut)
    await ClockCycles(dut.IQ_CLK, 20)

    assert mon.releases >= 1, "no RX_HOLD release observed -- test is vacuous"
    assert not mon.violations, (
        "release-ordering violated:\n  " + "\n  ".join(mon.violations)
    )
