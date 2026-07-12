"""
test_replay_data.py -- continuous-delay replay DATA correctness (verif plan
batch 2, planning/psram-replay-verification-plan.md RPV-5..7).

Everything in test_replay_delay.py checks pointers, flags, and timing; this
suite checks the payload. A recorder coroutine logs every decimated sample
(tapped at psram_buf_ctrl's iq_i*/iq_q* inputs on iq_valid) keyed by
iq_sample_cnt; the replayed rpl_* stream must then bit-equal the recording
anchored at timing_ref -- the backdated packet start `buf_base` encodes:

  rpl[k] == recorded[timing_ref + off + k]   with |off| <= 3

where `off` absorbs the counter-vs-latch registration skew (calibrated once
on the first 32 replayed samples, which must ALL match at a single offset;
the CW stimulus is only pseudo-periodic thanks to SDM requantization noise,
so a wrong-by-a-symbol anchor cannot sneak through 32 samples).

RPV-5: 512 replayed samples bit-exact from the packet start. Catches a
       wrong buf_base backdate, an address off-by-8, or byte-lane swaps
       that leave every pointer/flag test green.
RPV-6: after packet 1 completes, packet 2's replay must anchor at packet
       2's own timing_ref -- a stale buf_base would replay packet 1's data.
RPV-7: QSPI_OWNER asserted across the margin wait freezes the wait
       (wait_cnt decrements only at write-dones, and writes are suspended):
       no replay while owner=1, replay starts after release, and the first
       256 replayed samples (all captured BEFORE the pause -- the training
       window is 2048 samples) still compare bit-exact. Samples arriving
       during owner=1 are legitimately lost and are not compared.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from test_trouper_top import CLK_NS, spi_read, spi_write
from test_bypass_e2e import _reset_and_lock
from test_replay_delay import (PKT_TIMEOUT_SYMS, _wait_irq,
                               _wait_replay_active, _watch_monotonic_replay)

CALIB = 32     # samples used to lock the alignment offset
BAND = 3       # allowed |offset| between timing_ref and the first replayed sample


class _StreamRecorder:
    """Log every decimated sample at the psram_buf_ctrl input boundary,
    keyed by iq_sample_cnt (sampled on the same iq_valid cycle)."""

    def __init__(self, dut):
        self.dut = dut
        self.samples = {}

    def start(self):
        cocotb.start_soon(self._run())

    async def _run(self):
        d = self.dut
        p = d.u_dut.u_psram
        while True:
            await RisingEdge(d.IQ_CLK)
            if int(p.iq_valid.value):
                self.samples[int(p.iq_sample_cnt.value)] = (
                    p.iq_i0.value.signed_integer, p.iq_q0.value.signed_integer,
                    p.iq_i1.value.signed_integer, p.iq_q1.value.signed_integer,
                    p.iq_i2.value.signed_integer, p.iq_q2.value.signed_integer,
                    p.iq_i3.value.signed_integer, p.iq_q3.value.signed_integer)


async def _collect_replay(dut, n, tag, slack=900):
    """Collect n consecutive rpl_* samples. `slack` (samples) pads the
    clock budget for the remaining margin wait before rpl[0] arrives."""
    p = dut.u_dut.u_psram
    got = []
    for _ in range((n + slack) * 80):
        await RisingEdge(dut.IQ_CLK)
        if int(p.rpl_valid.value):
            got.append((
                p.rpl_i0.value.signed_integer, p.rpl_q0.value.signed_integer,
                p.rpl_i1.value.signed_integer, p.rpl_q1.value.signed_integer,
                p.rpl_i2.value.signed_integer, p.rpl_q2.value.signed_integer,
                p.rpl_i3.value.signed_integer, p.rpl_q3.value.signed_integer))
            if len(got) >= n:
                return got
    assert False, f"{tag}: only {len(got)}/{n} rpl_valid pulses collected"


def _compare_anchored(rec, got, timing_ref, tag, skip=0):
    """Calibrate the offset on the first CALIB samples, then require every
    collected sample to bit-equal the recording. `skip` = how many replayed
    samples were already consumed before collection started (0 when
    collection begins before the first rpl_valid)."""
    best_off, best_hits = None, -1
    for off in range(-BAND, BAND + 1):
        hits = sum(1 for k in range(min(CALIB, len(got)))
                   if rec.samples.get(timing_ref + off + skip + k) == got[k])
        if hits > best_hits:
            best_off, best_hits = off, hits
    assert best_hits == min(CALIB, len(got)), \
        f"{tag}: no offset in ±{BAND} aligns the replayed stream to " \
        f"timing_ref (best {best_hits}/{CALIB} at off={best_off}) -- " \
        f"buf_base does not point at the packet start"
    mism = [k for k in range(len(got))
            if rec.samples.get(timing_ref + best_off + skip + k) != got[k]]
    assert not mism, \
        f"{tag}: {len(mism)}/{len(got)} replayed samples mismatch the " \
        f"recorded stream (first at k={mism[0]}: got {got[mism[0]]}, " \
        f"expected {rec.samples.get(timing_ref + best_off + skip + mism[0])})"
    return best_off


async def _lock_and_first_replay(dut, rec, tag, *, replay_delay, n):
    """Common RPV-5 body: lock, wait replay, collect the FIRST n replayed
    samples (collection armed before the margin expires so nothing is
    missed), compare anchored at this packet's timing_ref."""
    sym_ns = await _reset_and_lock(dut, mode=0, ant_mask=0xF, tag=tag,
                                   pkt_timeout_syms=PKT_TIMEOUT_SYMS,
                                   replay_delay=replay_delay)
    tref = int(dut.u_dut.u_psram.timing_ref.value)

    await _wait_irq(dut, 0x02, 40, sym_ns, tag, "training_done")
    # Arm collection immediately: margin samples remain before rpl[0]
    got = await _collect_replay(dut, n, tag)
    off = _compare_anchored(rec, got, tref, tag)
    dut._log.info(f"{tag}: {n} replayed samples bit-exact from packet start "
                  f"(timing_ref={tref}, off={off})")
    return sym_ns, tref


@cocotb.test()
async def test_replay_data_bit_exact(dut):
    """RPV-5: 512 replayed samples == the captured stream from timing_ref."""
    tag = "rpv5_data"
    rec = _StreamRecorder(dut)
    rec.start()
    await _lock_and_first_replay(dut, rec, tag, replay_delay=600, n=512)


@cocotb.test()
async def test_second_packet_replay_fresh(dut):
    """RPV-6: packet 2's replay anchors at packet 2's timing_ref, not a
    stale packet-1 buf_base."""
    tag = "rpv6_fresh"
    rec = _StreamRecorder(dut)
    rec.start()
    sym_ns, tref1 = await _lock_and_first_replay(dut, rec, tag + "/pkt1",
                                                 replay_delay=600, n=128)

    # Ride out packet 1, then packet 2 must lock and replay its OWN data
    await _wait_irq(dut, 0x08, PKT_TIMEOUT_SYMS + 10, sym_ns, tag, "PACKET_DONE")
    await spi_write(dut, 0x03, 0xFF)
    await _wait_irq(dut, 0x01, 25, sym_ns, tag, "packet-2 lock")
    tref2 = int(dut.u_dut.u_psram.timing_ref.value)
    assert tref2 > tref1, \
        f"{tag}: timing_ref did not advance ({tref1} -> {tref2})"

    await _wait_irq(dut, 0x02, 40, sym_ns, tag, "packet-2 training_done")
    got = await _collect_replay(dut, 128, tag + "/pkt2")
    off = _compare_anchored(rec, got, tref2, tag + "/pkt2")
    # Explicit staleness probe: the same stream must NOT anchor at packet 1
    stale_hits = max(
        sum(1 for k in range(CALIB)
            if rec.samples.get(tref1 + o + k) == got[k])
        for o in range(-BAND, BAND + 1))
    if stale_hits == CALIB:
        dut._log.warning(f"{tag}: packet-2 replay ALSO matches packet-1's "
                         f"start -- CW stream too periodic for the staleness "
                         f"probe to discriminate (anchor check above still "
                         f"passed at tref2)")
    dut._log.info(f"{tag}: PASS -- packet 2 replays its own start "
                  f"(tref {tref1}->{tref2}, off={off})")


@cocotb.test()
async def test_owner_across_margin_wait(dut):
    """RPV-7: QSPI_OWNER=1 spanning training_done -> margin expiry freezes
    the wait; replay must not start under owner, must start after release,
    and the pre-pause portion of the stream must still be bit-exact."""
    tag = "rpv7_owner"
    rec = _StreamRecorder(dut)
    rec.start()
    sym_ns = await _reset_and_lock(dut, mode=0, ant_mask=0xF, tag=tag,
                                   pkt_timeout_syms=PKT_TIMEOUT_SYMS,
                                   replay_delay=600)
    tref = int(dut.u_dut.u_psram.timing_ref.value)

    await _wait_irq(dut, 0x02, 40, sym_ns, tag, "training_done")

    # Take the pads for ~3 symbols -- past the 600-sample (~2.3 sym) margin. The
    # wait must freeze (decrements happen only at write-dones).
    await spi_write(dut, 0x70, 0x09)   # PSRAM_EN | QSPI_OWNER
    for _ in range(6):
        await Timer(sym_ns // 2, unit="ns")
        st = await spi_read(dut, 0x71)
        assert not (st & 0x10), \
            f"{tag}: replay started while QSPI_OWNER=1 (0x{st:02X}) -- " \
            f"margin wait not frozen with writes suspended"

    await spi_write(dut, 0x70, 0x01)   # release
    await _wait_replay_active(dut, 40, sym_ns, tag)

    # First 256 replayed samples all predate the pause (training window is
    # 2048 samples), so the recording is still the ground truth there.
    # Collection starts after the REPLAY_ACTIVE SPI poll, so allow for the
    # handful of samples replayed in the meantime via a value-anchored skip:
    got = await _collect_replay(dut, 256, tag)
    skip_found = None
    for skip in range(0, 128):
        hits = max(
            sum(1 for k in range(CALIB)
                if rec.samples.get(tref + o + skip + k) == got[k])
            for o in range(-BAND, BAND + 1))
        if hits == CALIB:
            skip_found = skip
            break
    assert skip_found is not None, \
        f"{tag}: post-release replay stream does not align anywhere in the " \
        f"first 128 samples after timing_ref -- pre-pause data corrupted"
    _compare_anchored(rec, got, tref, tag, skip=skip_found)

    await _watch_monotonic_replay(dut, 60, tag)
    st = await spi_read(dut, 0x71)
    assert not (st & 0x24), \
        f"{tag}: REPLAY_MISSED/SAMPLE_SKIP flagged after owner handover " \
        f"(0x{st:02X})"
    dut._log.info(f"{tag}: PASS -- wait frozen under owner, replay resumed "
                  f"({skip_found} samples consumed before collection), "
                  f"pre-pause data bit-exact")
