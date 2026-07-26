"""
test_dbg_write_collision.py -- debug-fetch vs. capture-write collision at the
real R=64 iq_valid rate (idle mode).

Traceability: Open Risks #30 (planning/Open Risks.md item 30), extends
TRPR-PSR-020. Verification plan row #16
(planning/verification-plan/psram-buf-ctrl-verification-plan.md).

psram_buf_ctrl.v's header comment budgets the debug-readback path
(PSRAM_DBG_CTRL/PSRAM_DBG_DATA, TRPR-PSR-017) against the OLD CIC-R=128
decimator ("iq_valid every 128 cycles", 84 spare sub-cycles). The chip is
now the fixed R=64 half-band chain (iq_valid every 64 cycles, per
test_trouper_top.py): a normal per-iq_valid S_WRITE transaction (25 write +
19 del-read = 44 sub-cycles) leaves only 64-44=20 idle sub-cycles before the
next iq_valid, but a debug fetch takes a FIXED 31 sub-cycles once launched
and does not abort/restart when the next iq_valid arrives
(psram_buf_ctrl.v ~554-560/562-605) -- so any debug fetch launched in idle
mode collides with the very next capture write, every single time (31 > 20
idle margin -- a structural certainty at this decimator rate, not a rare
corner case; confirmed below: the collision fires on the very first fetch
tried, with no phase-alignment stimulus required).

This test confirms:
  (a) sample_skip correctly sets when the collision happens -- the RTL's own
      documented tradeoff, not a bug;
  (b) the debug fetch itself still returns correct, uncorrupted data despite
      running through a collision;
  (c) the colliding capture write is genuinely and cleanly dropped -- wr_ptr
      does not advance during the fetch (the write launch is gated on
      !qpi_busy, and qpi_busy stays 1 -- dbg_mode -- for the whole fetch, so
      the write sub-FSM never engages at all: not a corrupted/partial
      write, a fully-skipped one);
  (d) normal capture resumes cleanly afterward (wr_ptr advances again, no
      deadlock), and PSRAM_CLR_ERR clears the sticky flag.

Debug reads are only issuable when packet_active=0 (bring-up/idle use), so
this scenario uses the same "independent low-amplitude noise -> no SC hits
-> no lock" stimulus as test_psram_ops.py::test_dbg_readback_content, not a
locked packet -- test_trouper_top.py's existing SAMPLE_SKIP check (row #11)
only covers the packet-active capture/replay path, not this idle-mode
debug-read case.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from test_trouper_top import CLK_NS, spi_read, spi_write
from test_noise_trig import _StimMode, _noise_or_cw_driver
from test_psram_ops import _model_byte

CLK_PER_IQ       = 64   # production half-band decimator: iq_valid every 64 clocks
FETCH_SUBCYCLES  = 31   # fixed debug-fetch length (header comment / RTL)


@cocotb.test()
async def test_dbg_fetch_vs_capture_write_collision(dut):
    tag = "dbg_write_collision"
    sf = 7

    cocotb.start_soon(Clock(dut.IQ_CLK, CLK_NS, unit="ns").start())
    dut.HOST_CS.value   = 1
    dut.SPI_MOSI.value  = 0
    dut.SPI_SCK.value   = 0
    dut.IQ_DATA_I.value = 0
    dut.IQ_DATA_Q.value = 0
    dut.RESETB.value    = 0
    await Timer(4 * CLK_NS, unit="ns")
    dut.RESETB.value = 1
    await Timer(8 * CLK_NS, unit="ns")

    # Low-amplitude independent noise: nonzero stored samples, but no SC hits
    # -> no lock -> packet_active stays 0 for the whole test (debug reads
    # stay unblocked throughout) -- same stimulus as test_dbg_readback_content.
    mode = _StimMode()
    cocotb.start_soon(_noise_or_cw_driver(dut, mode, sigma=8.0))

    await spi_read(dut, 0x00)
    await spi_read(dut, 0x09)
    await spi_write(dut, 0x09, sf & 0x0F)
    await spi_write(dut, 0x0A, 0)   # 250 kHz

    await spi_write(dut, 0x70, 0x01)   # PSRAM_EN
    init_ok = False
    for _ in range(500):
        await Timer(8 * CLK_NS, unit="ns")
        if (await spi_read(dut, 0x71)) & 0x08:
            init_ok = True
            break
    assert init_ok, f"{tag}: PSRAM INIT_DONE never set"

    # Let the circular capture write a comfortable, already-stored prefix.
    await Timer(200 * CLK_PER_IQ * CLK_NS, unit="ns")

    st = await spi_read(dut, 0x71)
    assert not (st & 0x04), \
        f"{tag}: SAMPLE_SKIP already set before any debug fetch (0x{st:02X}) -- " \
        f"normal idle capture alone should never skip"
    assert int(dut.u_dut.u_psram.packet_active.value) == 0, \
        f"{tag}: packet_active unexpectedly asserted -- debug reads would be blocked"

    base = 64 * 8   # sample-aligned byte address, well inside the written prefix

    # -- program the debug address first (no dbg_mode effect by itself) -----
    await spi_write(dut, 0x72, base & 0xFF)
    await spi_write(dut, 0x73, (base >> 8) & 0xFF)
    await spi_write(dut, 0x74, (base >> 16) & 0x7F)

    assert int(dut.u_dut.u_psram.dbg_mode.value) == 0, \
        f"{tag}: dbg_mode already 1 before RD_TRIG was ever issued -- monitor baseline invalid"

    # -- fire RD_TRIG (no AUTO_INC -- exactly one collision) as a background
    # task and start the clock-accurate monitor loop from THIS cycle, not
    # after spi_write() returns: spi_write's own bit-banged SCK + trailing
    # settle time (~84 clk cycles) is longer than the 64-cycle iq_valid
    # period, so by the time a plain `await spi_write(...)` returns the
    # fetch has typically already launched AND run partway through --
    # monitoring only from then on would catch a truncated tail, not the
    # real 31-cycle window (confirmed empirically: an earlier version of
    # this test measured a spurious "21 sub-cycle fetch" this way). Racing
    # the trigger write against the monitor loop, both started from a
    # known dbg_mode==0 baseline (asserted above), catches the genuine
    # 0->1 launch edge.
    cocotb.start_soon(spi_write(dut, 0x75, 0x01))

    # -- clock-accurate monitor across the fetch: launch, collision, completion --
    dbg_start = None
    dbg_end = None
    wr_ptr_at_start = None
    wr_ptr_at_end = None
    collision_cycles = []
    prev_dbg_active = 0
    trace = []

    for n in range(600):
        await RisingEdge(dut.IQ_CLK)
        dbg_mode   = int(dut.u_dut.u_psram.dbg_mode.value)
        qpi_busy   = int(dut.u_dut.u_psram.qpi_busy.value)
        dbg_active = dbg_mode & qpi_busy
        iq_valid   = int(dut.u_dut.u_psram.iq_valid.value)
        wr_ptr     = int(dut.u_dut.u_psram.wr_ptr.value)
        sub        = int(dut.u_dut.u_psram.sub.value)

        if dbg_start is not None and dbg_end is None:
            trace.append((n, dbg_mode, qpi_busy, sub, iq_valid))

        if prev_dbg_active == 0 and dbg_active == 1 and dbg_start is None:
            dbg_start = n
            wr_ptr_at_start = wr_ptr
        if dbg_active == 1 and iq_valid == 1:
            collision_cycles.append(n)
        if prev_dbg_active == 1 and dbg_active == 0 and dbg_start is not None and dbg_end is None:
            dbg_end = n
            wr_ptr_at_end = wr_ptr
            break
        prev_dbg_active = dbg_active

    dut._log.info(f"{tag}: dbg_start={dbg_start} dbg_end={dbg_end} trace={trace}")

    assert dbg_start is not None, \
        f"{tag}: debug fetch never launched (dbg_mode&&qpi_busy) within the monitor window"
    assert dbg_end is not None, \
        f"{tag}: debug fetch never completed within the monitor window"
    fetch_len = dbg_end - dbg_start
    assert fetch_len == FETCH_SUBCYCLES, \
        f"{tag}: debug fetch took {fetch_len} sub-cycles, expected fixed {FETCH_SUBCYCLES}. " \
        f"trace(n,dbg_mode,qpi_busy,sub,iq_valid)={trace}"
    dut._log.info(f"{tag}: debug fetch ran cycles [{dbg_start},{dbg_end}) "
                  f"({fetch_len} sub-cycles), iq_valid collisions at {collision_cycles}")

    assert len(collision_cycles) == 1, \
        f"{tag}: expected exactly 1 iq_valid collision during the {FETCH_SUBCYCLES}-cycle " \
        f"fetch (64-cycle iq_valid period > fetch length, so at most one can land inside " \
        f"it) -- got {collision_cycles}. Zero collisions here would mean the R=64/idle-" \
        f"margin math in Open Risks #30 no longer holds; more than one would be a new bug."

    # (a) sample_skip correctly sets -- the RTL's documented tradeoff, live.
    assert int(dut.u_dut.u_psram.sample_skip.value) == 1, \
        f"{tag}: sample_skip not set internally right after the collision"
    st = await spi_read(dut, 0x71)
    assert st & 0x04, f"{tag}: SAMPLE_SKIP not visible over SPI after the collision (0x{st:02X})"

    # (c) the colliding write was genuinely and cleanly dropped, not
    # partially executed: wr_ptr must not move for the entire fetch duration
    # despite the iq_valid pulse landing mid-fetch (write launch is gated on
    # !qpi_busy, and qpi_busy -- dbg_mode -- held 1 throughout, so the write
    # sub-FSM never engages at all).
    assert wr_ptr_at_end == wr_ptr_at_start, \
        f"{tag}: wr_ptr moved during the debug fetch (0x{wr_ptr_at_start:06X} -> " \
        f"0x{wr_ptr_at_end:06X}) -- the collision should silently drop the write " \
        f"entirely, not partially execute one"

    # (b) the fetch itself still returns correct, uncorrupted data despite
    # running through the collision.
    for _ in range(100):
        if not ((await spi_read(dut, 0x75)) & 0x80):
            break
    else:
        assert False, f"{tag}: DBG_BUSY never cleared after the colliding fetch"

    got = [await spi_read(dut, 0x76) for _ in range(8)]
    exp = [await _model_byte(dut, base + i) for i in range(8)]
    assert got == exp, \
        f"{tag}: sample @0x{base:06X} corrupted by the collision: read {got} != stored {exp}"
    assert any(b != 0 for b in got), \
        f"{tag}: all 8 bytes zero -- stimulus not reaching PSRAM storage, comparison vacuous"
    dut._log.info(f"{tag}: debug fetch data intact despite the collision (bytes={got})")

    # (d) normal capture resumes cleanly: wr_ptr advances again afterward,
    # no deadlock/zombie state left by the collision.
    await Timer(20 * CLK_PER_IQ * CLK_NS, unit="ns")
    wr_ptr_resumed = int(dut.u_dut.u_psram.wr_ptr.value)
    assert wr_ptr_resumed != wr_ptr_at_end, \
        f"{tag}: wr_ptr never advanced again after the fetch completed -- capture stuck"
    dut._log.info(f"{tag}: capture resumed normally (wr_ptr 0x{wr_ptr_at_end:06X} -> "
                  f"0x{wr_ptr_resumed:06X})")

    # PSRAM_CLR_ERR clears the sticky flag (functional, matches the
    # TRPR-PSR-007 precedent in test_psram_ops.py::test_replay_missed_late_commit).
    await spi_write(dut, 0x70, 0x03)   # PSRAM_EN | CLR_ERR
    st = await spi_read(dut, 0x71)
    assert not (st & 0x04), f"{tag}: SAMPLE_SKIP not cleared by PSRAM_CLR_ERR (0x{st:02X})"

    dut._log.info(f"{tag}: PASS -- collision is real and deterministic at R=64 (fixed "
                  f"{FETCH_SUBCYCLES}-cycle fetch > 20-cycle idle margin), matches the "
                  f"documented Open Risks #30 tradeoff exactly: SAMPLE_SKIP sets, debug "
                  f"data stays correct, the dropped write is clean (no corruption), "
                  f"capture resumes, CLR_ERR works")
