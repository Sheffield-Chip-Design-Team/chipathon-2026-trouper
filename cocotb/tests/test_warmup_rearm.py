"""
test_warmup_rearm.py -- SC delay-line warm-up re-arm when sf/sample_shift
changes mid-session (between packets).

Traceability (planning/Traceability.md): TRPR-PSR-019's re-arm-on-change
clause, previously untested -- "Warm-up hold-off itself is verified... The
re-arm-on-change clause specifically is untested -- no test changes
sf/sample_shift mid-session (formal explicitly *assumes* these are
session-constant, m_sf_valid_range/m_sample_shift_valid_range, to keep the
proof tractable)." Verification plan row #17
(planning/verification-plan/psram-buf-ctrl-verification-plan.md).

psram_buf_ctrl.v's del_rdy counter (~352-367) re-arms whenever
`sf != sf_prev || sample_shift != sample_shift_prev` -- an OR of two
independent conditions, written via two different registers (SF_CFG 0x09,
BW_CFG 0x0A). Both registers are write-gated `!packet_active`
(reg_bank.v:217-219), so "mid-session" in practice means "between packets,
via the normal register-write path" -- exactly what this test drives.

Two cases exercise each disjunct of the OR independently (changing both at
once would only prove the compound case, not that either one alone
re-arms):

  test_warmup_rearm_sf_change:           SF7->SF9, BW250 constant (sample_shift stays 1)
  test_warmup_rearm_sample_shift_change: SF constant at 7, BW250->BW125 (sample_shift 1->2)

Each case: lock and run a first packet to completion at the initial config
(a short PKT_TIMEOUT_SYMS forces a fast packet_end), confirm packet_active
has dropped (registers are writable again), change SF/BW, then -- mirroring
test_startup.py::test_sc_correlator_idle_until_del_rdy's methodology for the
fresh-boot case -- confirm:
  (a) del_rdy and del_cnt genuinely reset (re-arm), not stale carryover from
      the old config's already-satisfied warm-up
  (b) sc_detector's tdm_busy correlator never goes active again before the
      NEW del_rdy fires -- no stale/pre-change delayed sample can produce a
      false lock during the re-arm window
  (c) the measured re-arm warm-up latency matches the NEW M = 2^(SF+shift)
      prediction, not the old (pre-change) one
  (d) the receiver actually locks again afterward at the new config -- a
      functional close, not just an internal-flag check
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from cocotb.utils import get_sim_time

from test_trouper_top import CLK_NS, spi_read, spi_write, sdm_driver

CLK_PER_IQ = 64
PKT_TIMEOUT_SYMS = 20


async def _reset_lock_first_packet(dut, *, sf, bw_khz, tag):
    """Reset, lock at (sf, bw_khz), run the packet to a timeout-forced
    packet_end, and return (sym_ns, M) for that config. Leaves the DUT with
    packet_active=0 and SF_CFG/BW_CFG writable again."""
    sample_shift = 1 if bw_khz == 250 else 2
    M = 1 << (sf + sample_shift)
    sym_ns = M * CLK_PER_IQ * CLK_NS

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

    # Reused verbatim: sdm_driver's CW stimulus is P=8-sample periodic and
    # ignores its sf/bw_khz args for waveform shape (see test_trouper_top.py
    # docstring) -- it stays valid stimulus across the mid-session SF/BW
    # change below.
    cocotb.start_soon(sdm_driver(dut, sf, bw_khz))

    await spi_read(dut, 0x00)
    await spi_read(dut, 0x09)

    await spi_write(dut, 0x09, sf & 0x0F)
    await spi_write(dut, 0x0A, 0 if bw_khz == 250 else 1)
    await spi_write(dut, 0x0C, 0x01)   # sc_thr[15:8]
    await spi_write(dut, 0x0D, 0x00)   # sc_thr[7:0]
    await spi_write(dut, 0x0E, 0x00)   # sc_hits_req -- 1 hit fires lock
    await spi_write(dut, 0x0B, PKT_TIMEOUT_SYMS)  # short packet, before lock

    await spi_write(dut, 0x70, 0x01)   # PSRAM_EN
    init_ok = False
    for _ in range(500):
        await Timer(8 * CLK_NS, unit="ns")
        if (await spi_read(dut, 0x71)) & 0x08:
            init_ok = True
            break
    assert init_ok, f"{tag}: PSRAM INIT_DONE never set"

    lock_ok = False
    for _ in range(20):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x01:
            lock_ok = True
            break
    assert lock_ok, f"{tag}: initial sc_lock never fired (SF{sf}/BW{bw_khz})"
    await spi_write(dut, 0x03, 0xFF)   # clear IRQ_STATUS incl. sc_lock bit

    done_ok = False
    for _ in range(PKT_TIMEOUT_SYMS + 10):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x08:
            done_ok = True
            break
    assert done_ok, f"{tag}: PACKET_DONE never fired for the first packet"
    await spi_write(dut, 0x03, 0xFF)   # clear IRQ_STATUS again (sc_lock/PACKET_DONE)

    assert int(dut.u_dut.u_psram.packet_active.value) == 0, \
        f"{tag}: packet_active still 1 after PACKET_DONE -- SF/BW would stay write-locked"
    dut._log.info(f"{tag}: first packet (SF{sf}/BW{bw_khz}, M={M}) locked and completed cleanly")
    return sym_ns, M


async def _rearm_and_relock(dut, *, new_sf, new_bw_khz, tag):
    """Change SF/BW mid-session (packet_active already 0), then verify the
    del_rdy/tdm_busy re-arm contract and a clean re-lock at the new config."""
    new_sample_shift = 1 if new_bw_khz == 250 else 2
    M2 = 1 << (new_sf + new_sample_shift)
    sym_ns2 = M2 * CLK_PER_IQ * CLK_NS
    predicted_warmup_ns = M2 * CLK_PER_IQ * CLK_NS

    assert int(dut.u_dut.u_psram.del_rdy.value) == 1, \
        f"{tag}: del_rdy not set from the completed first packet -- baseline invalid"

    t_change_start = get_sim_time(unit="ns")
    await spi_write(dut, 0x09, new_sf & 0x0F)
    await spi_write(dut, 0x0A, 0 if new_bw_khz == 250 else 1)

    sf_rb = await spi_read(dut, 0x09) & 0x0F
    bw_rb = await spi_read(dut, 0x0A) & 0x01
    assert sf_rb == new_sf, f"{tag}: SF_CFG readback {sf_rb} != {new_sf} -- write-gate still blocking?"
    assert bw_rb == (0 if new_bw_khz == 250 else 1), \
        f"{tag}: BW_CFG readback {bw_rb} unexpected -- write-gate still blocking?"

    # -- (a) genuinely re-armed, not stale carryover -------------------------
    del_rdy_now = int(dut.u_dut.u_psram.del_rdy.value)
    del_cnt_now = int(dut.u_dut.u_psram.del_cnt.value)
    assert del_rdy_now == 0, \
        f"{tag}: del_rdy still 1 right after the SF/BW change -- old config's warm-up " \
        f"was not invalidated, a stale delayed sample could reach the SC correlator"
    assert del_cnt_now < M2 // 4, \
        f"{tag}: del_cnt={del_cnt_now} not reset to near-zero after the change -- " \
        f"looks like stale carryover from the old config's count, not a genuine re-arm"
    dut._log.info(f"{tag}: re-arm confirmed at the register-write boundary "
                  f"(del_rdy=0, del_cnt={del_cnt_now})")

    # -- (b)+(c): watch every cycle until the NEW del_rdy fires, tdm_busy must
    # stay 0 throughout (mirrors test_startup.py's fresh-boot methodology) --
    del_rdy_seen_ns = None
    watch_cycles = int(predicted_warmup_ns / CLK_NS) + 2000
    for _ in range(watch_cycles):
        await RisingEdge(dut.IQ_CLK)
        del_rdy = int(dut.u_dut.u_psram.del_rdy.value)
        tdm_busy = int(dut.u_dut.u_sc.tdm_busy.value)
        if del_rdy and del_rdy_seen_ns is None:
            del_rdy_seen_ns = get_sim_time(unit="ns")
        assert not (tdm_busy and del_rdy_seen_ns is None), (
            f"{tag}: sc_detector TDM correlator went active before the re-armed del_rdy -- "
            f"SC lock could fire on a stale delayed sample during the post-change warm-up"
        )
        if del_rdy_seen_ns is not None:
            break

    assert del_rdy_seen_ns is not None, \
        f"{tag}: re-armed del_rdy never asserted within {watch_cycles} cycles of the SF/BW change"

    measured_warmup_ns = del_rdy_seen_ns - t_change_start
    dut._log.info(f"{tag}: measured re-arm warm-up = {measured_warmup_ns:.0f} ns "
                  f"(predicted {predicted_warmup_ns:.0f} ns for M={M2})")
    assert abs(measured_warmup_ns - predicted_warmup_ns) < 0.05 * predicted_warmup_ns, \
        f"{tag}: measured re-arm warm-up {measured_warmup_ns:.0f} ns deviates >5% from " \
        f"the NEW-config prediction {predicted_warmup_ns:.0f} ns (M={M2}) -- looks like " \
        f"it is still timed against the OLD config"

    # -- (d) functional close: the receiver actually re-locks at the new config --
    relock_ok = False
    for _ in range(20):
        await Timer(sym_ns2, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x01:
            relock_ok = True
            break
    assert relock_ok, f"{tag}: no re-lock at the new config (SF{new_sf}/{new_bw_khz}kHz) " \
        f"after the re-armed warm-up completed"
    dut._log.info(f"{tag}: PASS -- re-armed cleanly on the SF/BW change, no premature "
                  f"tdm_busy/lock on stale data, warm-up matches the new config, and the "
                  f"receiver re-locked correctly afterward")


@cocotb.test()
async def test_warmup_rearm_sf_change(dut):
    """SF-only change mid-session (BW/sample_shift held constant at 250 kHz):
    SF7 (M=256) -> SF9 (M=1024). Exercises the `sf != sf_prev` disjunct of
    the re-arm condition in isolation."""
    tag = "rearm_sf"
    await _reset_lock_first_packet(dut, sf=7, bw_khz=250, tag=tag)
    await _rearm_and_relock(dut, new_sf=9, new_bw_khz=250, tag=tag)


@cocotb.test()
async def test_warmup_rearm_sample_shift_change(dut):
    """sample_shift-only change mid-session (SF held constant at 7): BW250
    (sample_shift=1, M=256) -> BW125 (sample_shift=2, M=512). Exercises the
    `sample_shift != sample_shift_prev` disjunct in isolation -- a distinct
    register-write path (BW_CFG 0x0A) from the SF case above."""
    tag = "rearm_shift"
    await _reset_lock_first_packet(dut, sf=7, bw_khz=250, tag=tag)
    await _rearm_and_relock(dut, new_sf=7, new_bw_khz=125, tag=tag)
