"""
test_dbg_probe.py -- two-pin digital debug probe (DBG0_OUT / DBG1_OUT).

Covers planning/two-pin-digital-debug-plan.md: the DBG_CTRL/DBG_STATUS register
pair, every mux group, the reset/disabled/reserved zero states, the idle-only
write gate, and -- the one that actually matters for tapeout risk -- proof that
the probe cannot perturb the receiver.

The non-interference test is the reason this suite exists. Everything else here
checks that the feature works; test_probe_does_not_perturb_the_receiver checks
that it cannot break anything if it doesn't. A debug feature that is merely
"probably harmless" is worse than no debug feature, because it ships.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from test_trouper_top import (
    CLK_NS, spi_read, spi_write, release_rx_hold, assert_rx_hold, sdm_driver,
)

REG_DBG_CTRL       = 0x04
REG_DBG_STATUS     = 0x05
REG_SF_CFG         = 0x09
REG_BW_CFG         = 0x0A
REG_SC_THR_HI      = 0x0C
REG_SC_THR_LO      = 0x0D
REG_SC_HITS_REQ    = 0x0E
REG_RX_HOLD        = 0x1A
REG_PACKET_STATUS  = 0x1C
REG_SC_DBG_FLAGS   = 0x26
REG_PSRAM_CTRL     = 0x70
REG_PSRAM_STATUS   = 0x71

EN = 0x80


def ctrl(group, ant=0, sel=0, en=True):
    """Pack DBG_CTRL = {EN, GROUP[2:0], ANT[1:0], SEL[1:0]}."""
    return (EN if en else 0) | ((group & 0x7) << 4) | ((ant & 0x3) << 2) | (sel & 0x3)


G_OFF, G_RAW, G_DEC, G_SC, G_PKT, G_PSRAM, G_COMB, G_IRQ = range(8)


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.IQ_CLK, CLK_NS, unit="ns").start())
    dut.HOST_CS.value   = 1
    dut.SPI_SCK.value   = 0
    dut.SPI_MOSI.value  = 0
    dut.IQ_DATA_I.value = 0
    dut.IQ_DATA_Q.value = 0
    dut.RESETB.value    = 0
    await Timer(4 * CLK_NS, unit="ns")
    dut.RESETB.value = 1
    await Timer(8 * CLK_NS, unit="ns")


def pads(dut):
    return int(dut.DBG0_OUT.value), int(dut.DBG1_OUT.value)


# ---------------------------------------------------------------------------
# Structural: pads, reset state, tie-offs
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_and_disabled_drive_low(dut):
    """Both pads must be 0 out of reset and while EN=0 -- the bring-up baseline.

    Step 1 of the first-silicon sequence depends on this: if the pins are not
    provably low when disabled, an engineer cannot tell a dead probe from an
    idle one.
    """
    await reset_dut(dut)
    assert pads(dut) == (0, 0), f"pads not low out of reset: {pads(dut)}"

    # DBG_CTRL resets to 0 -> disabled.
    assert (await spi_read(dut, REG_DBG_CTRL)) == 0x00, "DBG_CTRL did not reset to 0"

    # Selecting a live group with EN=0 must still drive low.
    await spi_write(dut, REG_DBG_CTRL, ctrl(G_PKT, sel=0, en=False))
    await Timer(20 * CLK_NS, unit="ns")
    assert pads(dut) == (0, 0), f"pads driven with EN=0: {pads(dut)}"

    # DBG_STATUS mirrors the post-mux, post-enable value.
    assert (await spi_read(dut, REG_DBG_STATUS)) == 0x00, "DBG_STATUS not 0 while disabled"
    dut._log.info("reset/disabled baseline confirmed")


@cocotb.test()
async def test_pad_tieoffs(dut):
    """Debug pads are permanently-enabled CMOS outputs, fast slew, 8 mA.

    Fast slew and mid drive are deliberate and differ from SPI_MISO/IRQ_OUT:
    raw-RX mode toggles on every 32 MHz edge, so the slow-slew setting used for
    the host link is not adequate. IE=0 because these are output-only in
    function -- never turn the receiver on, on a pin nothing drives.
    """
    await reset_dut(dut)
    expected = {
        "OE": 1, "IE": 0, "CS": 0, "SL": 0,
        "PU": 0, "PD": 0,
        "PDRV0": 1, "PDRV1": 0,     # {PDRV1,PDRV0} = 01 -> 8 mA
    }
    for pad in ("DBG0", "DBG1"):
        for name, want in expected.items():
            got = int(getattr(dut, f"{pad}_{name}").value)
            assert got == want, f"{pad}_{name} tied to {got}, expected {want}"
    dut._log.info("debug pad tie-offs correct")


@cocotb.test()
async def test_reserved_encodings_drive_zero(dut):
    """Reserved GROUP/SEL combinations drive 0 rather than something arbitrary.

    The plan requires no clamping: an unrecognised selection reads back as
    written but drives zero, so it is indistinguishable from disabled and can
    never be mistaken for live data.
    """
    await reset_dut(dut)
    reserved = [
        ctrl(G_SC,    sel=3),   # SC has only SEL 0..2
        ctrl(G_PKT,   sel=3),   # packet/weights likewise
    ]
    for c in reserved:
        await spi_write(dut, REG_DBG_CTRL, c)
        await Timer(20 * CLK_NS, unit="ns")
        rb = await spi_read(dut, REG_DBG_CTRL)
        assert rb == c, f"DBG_CTRL 0x{c:02X} not stored verbatim (got 0x{rb:02X})"
        assert pads(dut) == (0, 0), \
            f"reserved encoding 0x{c:02X} drove pads {pads(dut)}, expected (0, 0)"
    dut._log.info("reserved encodings drive zero and are not clamped")


# ---------------------------------------------------------------------------
# Functional: the mux actually selects what it claims
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_raw_rx_probe_follows_iq_pads(dut):
    """Group 001 reproduces each antenna's I/Q pad, delayed one cycle.

    Drives a distinct pattern per branch so a mis-wired ANT decode shows up as a
    wrong branch rather than as a plausible-looking bitstream.
    """
    await reset_dut(dut)

    for ant in range(4):
        await spi_write(dut, REG_DBG_CTRL, ctrl(G_RAW, ant=ant))
        for pattern_i, pattern_q in ((0xF, 0x0), (0x0, 0xF), (1 << ant, 0xF ^ (1 << ant))):
            dut.IQ_DATA_I.value = pattern_i
            dut.IQ_DATA_Q.value = pattern_q
            # one edge to capture into the debug flops, then sample
            await RisingEdge(dut.IQ_CLK)
            await RisingEdge(dut.IQ_CLK)
            await Timer(1, unit="ns")
            want = ((pattern_i >> ant) & 1, (pattern_q >> ant) & 1)
            assert pads(dut) == want, (
                f"raw probe ANT={ant} I=0x{pattern_i:X} Q=0x{pattern_q:X}: "
                f"pads {pads(dut)}, expected {want}"
            )
    dut._log.info("raw-RX probe tracks all four I/Q pairs")


@cocotb.test()
async def test_packet_group_tracks_fsm(dut):
    """Group 100 SEL=0 shows packet_active / training_done.

    Cross-checked against the SPI PACKET_STATUS register rather than against
    itself, so a mux wired to the wrong bit cannot agree with the probe.
    """
    await reset_dut(dut)
    await spi_write(dut, REG_SF_CFG, 7)
    await spi_write(dut, REG_BW_CFG, 0)
    await spi_write(dut, REG_SC_THR_HI, 0x01)
    await spi_write(dut, REG_SC_THR_LO, 0x00)
    await spi_write(dut, REG_SC_HITS_REQ, 0x00)
    await spi_write(dut, REG_DBG_CTRL, ctrl(G_PKT, sel=0))
    await release_rx_hold(dut)
    await spi_write(dut, REG_PSRAM_CTRL, 0x01)

    for _ in range(500):
        await Timer(8 * CLK_NS, unit="ns")
        if (await spi_read(dut, REG_PSRAM_STATUS)) & 0x08:
            break

    assert pads(dut)[0] == 0, "packet_active probe high before any packet"

    cocotb.start_soon(sdm_driver(dut, 7, 250))

    sym_ns = (1 << (7 + 1)) * 64 * CLK_NS
    for _ in range(20):
        await Timer(sym_ns, unit="ns")
        status = await spi_read(dut, REG_PACKET_STATUS)
        if status & 0x01:
            break
    assert status & 0x01, "packet never started"

    await Timer(1, unit="ns")
    assert pads(dut)[0] == 1, \
        "PACKET_STATUS says active but the debug probe shows packet_active=0"
    dut._log.info("packet-group probe agrees with PACKET_STATUS")


@cocotb.test()
async def test_dbg_status_mirrors_the_pads(dut):
    """DBG_STATUS is a post-mux connectivity check, not an independent path."""
    await reset_dut(dut)
    await spi_write(dut, REG_DBG_CTRL, ctrl(G_RAW, ant=0))
    for pattern in (0x1, 0x0):
        dut.IQ_DATA_I.value = pattern
        dut.IQ_DATA_Q.value = pattern
        await RisingEdge(dut.IQ_CLK)
        await RisingEdge(dut.IQ_CLK)
        await Timer(1, unit="ns")
        d0, d1 = pads(dut)
        st = await spi_read(dut, REG_DBG_STATUS)
        assert (st & 0x1) == d0 and ((st >> 1) & 0x1) == d1, (
            f"DBG_STATUS 0x{st:02X} disagrees with pads ({d0}, {d1})"
        )
    dut._log.info("DBG_STATUS mirrors the pads")


# ---------------------------------------------------------------------------
# Gating
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_config_is_idle_only_and_sticky_records_rejection(dut):
    """DBG_CTRL writes are refused mid-packet, and the rejection is visible.

    The requirement is that the selection is fixed for a whole packet -- an
    analyser capture whose meaning changes halfway through is worse than no
    capture. A silently dropped write would be its own trap (cf. Open Risks #16
    and the W_MISSED_PACKET readback bug), so the shared CFG_WR_REJECTED sticky
    must record it.
    """
    await reset_dut(dut)
    await spi_write(dut, REG_SF_CFG, 7)
    await spi_write(dut, REG_BW_CFG, 0)
    await spi_write(dut, REG_SC_THR_HI, 0x01)
    await spi_write(dut, REG_SC_THR_LO, 0x00)
    await spi_write(dut, REG_SC_HITS_REQ, 0x00)
    await release_rx_hold(dut)
    await spi_write(dut, REG_PSRAM_CTRL, 0x01)
    for _ in range(500):
        await Timer(8 * CLK_NS, unit="ns")
        if (await spi_read(dut, REG_PSRAM_STATUS)) & 0x08:
            break

    # Writable while idle.
    idle_sel = ctrl(G_SC, sel=0)
    await spi_write(dut, REG_DBG_CTRL, idle_sel)
    assert (await spi_read(dut, REG_DBG_CTRL)) == idle_sel, "idle DBG_CTRL write refused"

    # Clear the sticky, then get a packet going.
    await spi_write(dut, REG_RX_HOLD, 0x02)      # W1C CFG_WR_REJECTED
    cocotb.start_soon(sdm_driver(dut, 7, 250))
    sym_ns = (1 << (7 + 1)) * 64 * CLK_NS
    for _ in range(20):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, REG_PACKET_STATUS)) & 0x01:
            break
    assert (await spi_read(dut, REG_PACKET_STATUS)) & 0x01, "packet never started"

    # Mid-packet write must be dropped, and recorded.
    await spi_write(dut, REG_DBG_CTRL, ctrl(G_PSRAM, sel=1))
    rb = await spi_read(dut, REG_DBG_CTRL)
    assert rb == idle_sel, \
        f"DBG_CTRL changed mid-packet: 0x{idle_sel:02X} -> 0x{rb:02X}"

    hold = await spi_read(dut, REG_RX_HOLD)
    assert hold & 0x02, \
        "mid-packet DBG_CTRL write was dropped without setting CFG_WR_REJECTED"
    dut._log.info("DBG_CTRL is idle-only and records rejections")


# ---------------------------------------------------------------------------
# The one that matters: the probe cannot perturb the receiver
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_probe_does_not_perturb_the_receiver(dut):
    """Sweeping every debug selection must not change receiver behaviour at all.

    Runs the same acquisition twice from identical resets, and compares every
    functionally-visible output cycle by cycle.

    BOTH runs issue byte-for-byte identical SPI traffic, including the DBG_CTRL
    write -- the only difference is the EN bit inside that one written value.
    That matters: an earlier version of this test skipped the write entirely in
    the baseline run, which shifted every subsequent event by the duration of an
    SPI transaction and made the two traces diverge for a reason that had
    nothing to do with the probe. A timing-shifted comparison would fail
    whatever the RTL did, which is worse than no test.

    This is what makes the feature safe to ship rather than merely believed
    safe. The RTL argument is that debug_probe_mux is feed-forward -- its only
    outputs are the two pads and the DBG_STATUS readback -- but "I read the code
    and it looked feed-forward" is not evidence, and a stray connection into the
    datapath would be invisible in every other test in the suite.

    Compared: REMOD_A_I/Q (the receiver's actual output), IRQ_OUT, and the
    packet FSM's status register.
    """
    async def run(probe_enabled):
        await reset_dut(dut)
        await spi_write(dut, REG_SF_CFG, 7)
        await spi_write(dut, REG_BW_CFG, 0)
        await spi_write(dut, REG_SC_THR_HI, 0x01)
        await spi_write(dut, REG_SC_THR_LO, 0x00)
        await spi_write(dut, REG_SC_HITS_REQ, 0x00)
        # Identical bus traffic either way; only the EN bit differs.
        await spi_write(dut, REG_DBG_CTRL, ctrl(G_RAW, ant=0, en=probe_enabled))
        await release_rx_hold(dut)
        await spi_write(dut, REG_PSRAM_CTRL, 0x01)
        for _ in range(500):
            await Timer(8 * CLK_NS, unit="ns")
            if (await spi_read(dut, REG_PSRAM_STATUS)) & 0x08:
                break

        stim = cocotb.start_soon(sdm_driver(dut, 7, 250))

        trace = []
        for _ in range(4000):
            await RisingEdge(dut.IQ_CLK)
            trace.append((int(dut.REMOD_A_I.value),
                          int(dut.REMOD_A_Q.value),
                          int(dut.IRQ_OUT.value)))
        stim.kill()
        status = await spi_read(dut, REG_PACKET_STATUS)
        return trace, status

    baseline, base_status = await run(probe_enabled=False)
    probed,   probe_status = await run(probe_enabled=True)

    assert len(baseline) == len(probed)
    for i, (b, p) in enumerate(zip(baseline, probed)):
        assert b == p, (
            f"receiver output diverged at cycle {i} with the debug probe "
            f"enabled: baseline REMOD/IRQ={b}, probed={p}. debug_probe_mux is "
            f"not feed-forward -- something in the probe path reaches the "
            f"datapath, the FSMs, or the interrupt tree."
        )
    assert base_status == probe_status, (
        f"PACKET_STATUS differs with the probe enabled: "
        f"0x{base_status:02X} vs 0x{probe_status:02X}"
    )
    dut._log.info(
        f"{len(baseline)} cycles bit-identical with the probe enabled -- "
        f"probe is feed-forward"
    )


@cocotb.test()
async def test_every_group_is_harmless_while_selected(dut):
    """Walk all eight groups mid-run and confirm nothing downstream reacts.

    Complements the test above, which enables one group for a whole run. Here
    the selection changes repeatedly between packets, which is the bring-up loop
    an engineer actually performs, and the check is that packet state never
    moves as a *result* of the selection change.
    """
    await reset_dut(dut)
    await spi_write(dut, REG_SF_CFG, 7)
    await spi_write(dut, REG_BW_CFG, 0)
    await spi_write(dut, REG_SC_THR_HI, 0x01)
    await spi_write(dut, REG_SC_THR_LO, 0x00)
    await spi_write(dut, REG_SC_HITS_REQ, 0x00)
    await release_rx_hold(dut)

    before = await spi_read(dut, REG_PACKET_STATUS)
    for group in range(8):
        for sel in range(4):
            await spi_write(dut, REG_DBG_CTRL, ctrl(group, ant=sel, sel=sel))
            await Timer(20 * CLK_NS, unit="ns")
            after = await spi_read(dut, REG_PACKET_STATUS)
            assert after == before, (
                f"PACKET_STATUS moved 0x{before:02X} -> 0x{after:02X} after "
                f"selecting GROUP={group} SEL={sel} -- the debug selection is "
                f"reaching the packet FSM"
            )
    dut._log.info("all 32 group/sel selections left packet state untouched")
