"""
test_reg_bank_rx_hold.py -- Open Risks #43, the RX_HOLD config interlock.

Design: planning/mcp-config-settle-gate-design.md §4a/§4c.

The scoped-MCP settling exceptions are only sound if a quasi-static config
source cannot change near the edge that captures it. Rather than add settle
logic to the timing-critical DSP blocks, the design makes "config writable"
and "detector able to lock" mutually exclusive: `RX_HOLD` (0x1A[0]) is ORed
into the level-sensitive `sc_clr` at the top level, and the five MCP'd config
registers accept writes only while it is set.

This file proves the reg_bank half of that interlock -- that the gate is
ENFORCED, not merely documented. A convention firmware is asked to follow is
not evidence; a write the hardware refuses is.

  test_cfg_writes_accepted_while_held   -- baseline: with RX_HOLD set (its
      reset value), all six gated registers take writes normally.
  test_cfg_writes_rejected_while_live   -- with RX_HOLD clear, every one of the
      six is refused and the old value survives.
  test_cfg_wr_rejected_sticky_and_w1c   -- the rejection is latched into
      0x1A[1] and cleared by writing 1 to it, so an out-of-sequence driver is
      detectable. Without this, a dropped write is invisible (cf. Open Risks
      #16, W_MISSED_PACKET).
  test_ungated_registers_unaffected     -- SC_THR (0x0C/0x0D) is deliberately
      NOT gated (it is in no MCP group); confirm the gate did not over-reach.
  test_rx_hold_not_self_gated           -- RX_HOLD itself must remain writable
      in both directions, or firmware could never re-enter configuration.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from test_reg_bank_rw_map import _bring_up

RX_HOLD_ADDR = 0x1A

# (addr, write value, expected stored value, DUT output port)
GATED = [
    (0x09, 0x0A, 0x0A, "sf_cfg"),            # SF_CFG[3:0]
    (0x0A, 0x01, 0x01, "bw_sel"),            # BW_CFG[0]
    (0x0B, 0x33, 0x33, "pkt_timeout_syms"),  # PKT_TIMEOUT_SYMS
    (0x0E, 0x03, 0x03, "sc_hits_req"),       # SC_HITS_REQ[1:0]
    (0x1B, 0x02, 0x02, "sc_ant_sel"),        # SC_ANT_SEL[1:0] (was BW_CFG[2:1])
    (0x27, 0x0C, 0x0C, "tacc_window_syms"),  # TACC_WINDOW_SYMS (clamped >= 8)
]


async def _write(dut, addr, value):
    dut.addr.value = addr
    dut.wdata.value = value
    dut.we.value = 1
    await RisingEdge(dut.clk)
    dut.we.value = 0
    dut.addr.value = 0
    dut.wdata.value = 0
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")


async def _read(dut, addr):
    dut.raddr.value = addr
    dut.re.value = 1
    await RisingEdge(dut.clk)
    dut.re.value = 0
    await Timer(1, unit="ps")
    return int(dut.rdata.value)


async def _set_hold(dut, held):
    await _write(dut, RX_HOLD_ADDR, 1 if held else 0)
    assert int(dut.rx_hold.value) == (1 if held else 0), (
        f"rx_hold did not take the value {int(held)}"
    )


@cocotb.test()
async def test_cfg_writes_accepted_while_held(dut):
    """With the receiver held (the reset state), config writes land."""
    await _bring_up(dut)
    assert int(dut.rx_hold.value) == 1, (
        "RX_HOLD must come out of reset SET -- the receiver starts disabled so "
        "that a driver ignoring the sequence fails loudly rather than silently "
        "losing writes (design doc §4a)"
    )
    for addr, wval, expect, port in GATED:
        await _write(dut, addr, wval)
        got = int(getattr(dut, port).value)
        assert got == expect, f"0x{addr:02X} -> {port}: wrote {wval:#04x}, read {got:#04x}"


@cocotb.test()
async def test_cfg_writes_rejected_while_live(dut):
    """With the receiver live, every gated write is refused."""
    await _bring_up(dut)
    # Establish known values while held, then go live and try to change them.
    for addr, wval, expect, port in GATED:
        await _write(dut, addr, wval)
    await _set_hold(dut, False)

    for addr, wval, expect, port in GATED:
        before = int(getattr(dut, port).value)
        # A different value, so a successful write would be visible.
        await _write(dut, addr, (~wval) & 0xFF)
        after = int(getattr(dut, port).value)
        assert after == before, (
            f"0x{addr:02X} -> {port} changed {before:#04x} -> {after:#04x} while "
            "RX_HOLD was clear; the MCP settling interlock is not enforced"
        )


@cocotb.test()
async def test_cfg_wr_rejected_sticky_and_w1c(dut):
    """A refused write must be visible to firmware, and clearable."""
    await _bring_up(dut)
    await _set_hold(dut, False)

    assert (await _read(dut, RX_HOLD_ADDR)) & 0x02 == 0, "sticky bit set before any rejection"

    await _write(dut, 0x09, 0x0B)               # rejected
    val = await _read(dut, RX_HOLD_ADDR)
    assert val & 0x02, "CFG_WR_REJECTED did not latch on a refused write"
    assert val & 0x01 == 0, "RX_HOLD readback wrong"

    # Sticky: a second rejection keeps it set, and it does not self-clear.
    await _write(dut, 0x0B, 0x77)
    assert (await _read(dut, RX_HOLD_ADDR)) & 0x02, "CFG_WR_REJECTED did not stay set"

    # W1C via bit[1].
    await _write(dut, RX_HOLD_ADDR, 0x02)
    assert (await _read(dut, RX_HOLD_ADDR)) & 0x02 == 0, "CFG_WR_REJECTED did not clear on W1C"


@cocotb.test()
async def test_ungated_registers_unaffected(dut):
    """SC_THR is in no MCP group and must stay writable while live."""
    await _bring_up(dut)
    await _set_hold(dut, False)

    await _write(dut, 0x0C, 0x12)
    await _write(dut, 0x0D, 0x34)
    got = int(dut.sc_thr.value)
    assert got == 0x1234, f"SC_THR should be ungated; expected 0x1234, got {got:#06x}"
    assert (await _read(dut, RX_HOLD_ADDR)) & 0x02 == 0, (
        "an ungated write set CFG_WR_REJECTED -- the gate over-reached"
    )


@cocotb.test()
async def test_hold_does_not_override_packet_active(dut):
    """RX_HOLD must not re-open the mid-packet config hole.

    `rx_hold` does NOT imply `!packet_active`: firmware can assert RX_HOLD
    mid-packet, which holds `sc_clr` and clears the detector but leaves
    `packet_ctrl_fsm`'s `packet_active` high until its own timeout. If the gate
    were `rx_hold` alone, config writes would then land during a live packet --
    exactly the desync closed by Open Risks #31/#32, since sc_detector and
    training_acc consume sf/sample_shift live. The gate is therefore
    `rx_hold && !packet_active`.
    """
    await _bring_up(dut)
    assert int(dut.rx_hold.value) == 1, "expected RX_HOLD set out of reset"

    dut.packet_active.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")

    for addr, wval, expect, port in GATED:
        before = int(getattr(dut, port).value)
        await _write(dut, addr, (~wval) & 0xFF)
        after = int(getattr(dut, port).value)
        assert after == before, (
            f"0x{addr:02X} -> {port} changed {before:#04x} -> {after:#04x} with "
            "RX_HOLD set but packet_active high -- the mid-packet config hole is open"
        )

    val = await _read(dut, RX_HOLD_ADDR)
    assert val & 0x02, "a write refused by the packet_active half did not latch CFG_WR_REJECTED"

    dut.packet_active.value = 0

    # DBG_STATUS (0x05) reads this back; the reg_bank bench drives the

    # module directly, so an undriven input would return X and break

    # any read of that address.

    dut.dbg_pad_value.value = 0
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")
    await _write(dut, 0x09, 0x0A)
    assert int(dut.sf_cfg.value) == 0x0A, "config not writable once the packet ended"


@cocotb.test()
async def test_rx_hold_not_self_gated(dut):
    """RX_HOLD must be writable in both directions, always."""
    await _bring_up(dut)
    await _set_hold(dut, False)
    await _set_hold(dut, True)      # must be able to re-enter configuration
    await _write(dut, 0x09, 0x09)
    assert int(dut.sf_cfg.value) == 0x09, "config not writable after re-asserting RX_HOLD"
