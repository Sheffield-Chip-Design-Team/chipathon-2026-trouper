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

test_overflow_unreachable_stress_sf12_bw125 (verif plan #20): corroborates
       test #14's formal OVERFLOW/pointer-gap k-induction invariants under a
       real simulated worst-case stimulus -- SF12/BW125 (deepest symbol
       period, M = 1<<(12+2) = 16384) plus REPLAY_DELAY_SAMPLES at its
       16-bit register maximum (0xFFFF), the largest wr_ptr/rd_ptr gap the
       RTL can produce (8*M training-window samples + 65535-sample margin =
       196607 samples = 1,572,856 bytes) -- still well under the 8 MB
       (2^23-byte = 1,048,576-sample) circular buffer, so OVERFLOW must
       stay clear and the gap must stay perfectly constant throughout
       replay (both pointers advance +8 bytes per iq_valid in lockstep).
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from test_trouper_top import CLK_NS, spi_read, spi_write, sdm_driver
from test_bypass_e2e import _reset_and_lock
from test_replay_delay import (PKT_TIMEOUT_SYMS, _wait_irq,
                               _wait_replay_active, _watch_monotonic_replay)

CALIB = 32     # samples used to lock the alignment offset
BAND = 3       # allowed |offset| between timing_ref and the first replayed sample
AMASK23 = (1 << 23) - 1   # 8 MB circular buffer address mask


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


async def _reset_and_lock_sfbw(dut, sf, bw_khz, tag, *, replay_delay):
    """Like test_bypass_e2e._reset_and_lock, generalized to arbitrary SF/BW
    -- that helper hardcodes SF7/BW250. Needed here for the SF12/BW125
    worst-case symbol period (largest M, and therefore the largest possible
    training-window + REPLAY_DELAY_SAMPLES byte gap between wr_ptr/rd_ptr)
    that test #20 stresses."""
    sample_shift = 1 if bw_khz == 250 else 2
    M = 1 << (sf + sample_shift)
    clk_per_iq = 64

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

    cocotb.start_soon(sdm_driver(dut, sf, bw_khz))

    await spi_read(dut, 0x00)
    await spi_read(dut, 0x09)
    await spi_write(dut, 0x09, sf & 0x0F)
    await spi_write(dut, 0x0A, 0 if bw_khz == 250 else 1)   # BW_CFG bw_sel
    await spi_write(dut, 0x0C, 0x01)   # sc_thr[15:8] -- 1 hit fires lock
    await spi_write(dut, 0x0D, 0x00)
    await spi_write(dut, 0x0E, 0x00)   # sc_hits_req = 0

    # Replay margin (must land before lock: write-gated !packet_active)
    await spi_write(dut, 0x77, replay_delay & 0xFF)
    await spi_write(dut, 0x78, (replay_delay >> 8) & 0xFF)

    await spi_write(dut, 0x70, 0x01)   # PSRAM up
    init_ok = False
    for _ in range(500):
        await Timer(8 * CLK_NS, unit="ns")
        if (await spi_read(dut, 0x71)) & 0x08:
            init_ok = True
            break
    assert init_ok, f"{tag}: PSRAM INIT_DONE never set"

    sym_ns = M * clk_per_iq * CLK_NS
    lock_ok = False
    for _ in range(20):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x01:
            lock_ok = True
            break
    assert lock_ok, f"{tag}: sc_lock never fired"
    return sym_ns, M


@cocotb.test()
async def test_overflow_unreachable_stress_sf12_bw125(dut):
    """#20 (verif plan): SF12/BW125 (deepest symbol period, M=1<<14=16384)
    with REPLAY_DELAY_SAMPLES at its register maximum (0xFFFF) -- pushes
    the wr_ptr/rd_ptr gap the RTL will ever produce to its worst realistic
    case (8*M=131072-sample training window + 65535-sample margin =
    196607 samples = 1,572,856 bytes), still under 1/5th of the 8 MB
    (2^23-byte = 1,048,576-sample) circular buffer. Corroborates test #14's
    formal OVERFLOW/pointer-gap k-induction invariants (m_* properties in
    formal/psram_buf_ctrl_formal.sv) under a real simulated worst-case
    stimulus rather than only formally: OVERFLOW must stay clear and the
    wr_ptr/rd_ptr gap must stay perfectly constant (both pointers advance
    +8 bytes per iq_valid in lockstep during S_REPLAY) for the whole
    observation window, and the replayed payload must still be bit-exact
    at this extreme config (reuses #5's _StreamRecorder/_compare_anchored
    infrastructure)."""
    tag = "overflow_stress_sf12"
    sf, bw_khz = 12, 125
    replay_delay = 0xFFFF
    N_WATCH = 300   # rpl_valid pulses watched for gap-constancy/OVERFLOW

    rec = _StreamRecorder(dut)
    rec.start()

    sym_ns, M = await _reset_and_lock_sfbw(dut, sf, bw_khz, tag,
                                           replay_delay=replay_delay)
    tref = int(dut.u_dut.u_psram.timing_ref.value)

    await _wait_irq(dut, 0x02, 15, sym_ns, tag, "training_done")
    st = await spi_read(dut, 0x71)
    assert not (st & 0x40), \
        f"{tag}: OVERFLOW set before replay even started (0x{st:02X})"

    # Margin = 0xFFFF samples = 65535/16384 ~= 4.0 symbols -- poll well past it,
    # checking OVERFLOW stays clear at every step of the wait too.
    replay_ok = False
    for _ in range(80):
        await Timer(sym_ns // 8, unit="ns")
        st = await spi_read(dut, 0x71)
        assert not (st & 0x40), \
            f"{tag}: OVERFLOW set while waiting for the max-margin replay " \
            f"to start (0x{st:02X})"
        if st & 0x10:
            replay_ok = True
            break
    assert replay_ok, \
        f"{tag}: REPLAY_ACTIVE never set at the max REPLAY_DELAY_SAMPLES margin"

    wr0 = int(dut.u_dut.u_psram.wr_ptr.value)
    rd0 = int(dut.u_dut.u_psram.rd_ptr.value)
    gap0 = (wr0 - rd0) & AMASK23
    assert 0 < gap0 < (1 << 23), \
        f"{tag}: wr_ptr/rd_ptr gap 0x{gap0:06X} at replay start is degenerate " \
        f"(0 or the whole 8 MB address space) -- the worst-case gap this test " \
        f"is meant to stress didn't actually materialize"
    dut._log.info(f"{tag}: replay started, wr_ptr=0x{wr0:06X} rd_ptr=0x{rd0:06X} "
                  f"gap=0x{gap0:06X} ({gap0} bytes of {1 << 23} buffer depth)")

    # Constant-gap + OVERFLOW-stays-clear watch across a real replay run:
    # wr_ptr and rd_ptr both advance +8 bytes per iq_valid in lockstep once
    # replay starts, so the gap must never change and rd_ptr must never
    # catch wr_ptr (the OVERFLOW condition) at this gap size.
    prev_rd = None
    pulses = 0
    p = dut.u_dut.u_psram
    for _ in range(N_WATCH * 100):
        await RisingEdge(dut.IQ_CLK)
        if int(p.rpl_valid.value):
            cur_wr = int(p.wr_ptr.value)
            cur_rd = int(p.rd_ptr.value)
            gap = (cur_wr - cur_rd) & AMASK23
            assert gap == gap0, \
                f"{tag}: wr_ptr/rd_ptr gap drifted from 0x{gap0:06X} to " \
                f"0x{gap:06X} at pulse {pulses} -- replay pointers not in lockstep"
            if prev_rd is not None:
                assert cur_rd == ((prev_rd + 8) & AMASK23), \
                    f"{tag}: rd_ptr jumped 0x{prev_rd:06X}->0x{cur_rd:06X} " \
                    f"(expected +8) at pulse {pulses}"
            prev_rd = cur_rd
            pulses += 1
            if pulses >= N_WATCH:
                break
    assert pulses >= N_WATCH, \
        f"{tag}: only {pulses}/{N_WATCH} rpl_valid pulses observed"

    st = await spi_read(dut, 0x71)
    assert not (st & 0x40), \
        f"{tag}: OVERFLOW set after {N_WATCH} replayed samples at the " \
        f"max gap (0x{st:02X})"

    # Reuse #5's payload-correctness infra: the replayed stream itself must
    # still be bit-exact at this extreme config, not just the pointers.
    # Collection starts well after the packet's own first rpl_valid (the
    # margin-wait poll + N_WATCH pulses above), so the alignment skip is
    # unknown a priori -- search for it the same way test_owner_across_
    # margin_wait does.
    got = await _collect_replay(dut, 64, tag)
    skip_found = None
    for skip in range(0, N_WATCH + 400):
        hits = max(
            sum(1 for k in range(min(CALIB, len(got)))
                if rec.samples.get(tref + o + skip + k) == got[k])
            for o in range(-BAND, BAND + 1))
        if hits == min(CALIB, len(got)):
            skip_found = skip
            break
    assert skip_found is not None, \
        f"{tag}: post-watch replay stream does not align anywhere in the " \
        f"expected skip range -- payload corrupted at this extreme config"
    off = _compare_anchored(rec, got, tref, tag, skip=skip_found)

    dut._log.info(f"{tag}: PASS -- OVERFLOW stayed clear and the wr/rd gap "
                  f"(0x{gap0:06X} bytes) stayed constant across {N_WATCH} "
                  f"replayed samples at SF12/BW125 + max REPLAY_DELAY_SAMPLES "
                  f"(skip={skip_found}, off={off}); formal OVERFLOW-"
                  f"unreachability corroborated in sim at the deepest "
                  f"realistic stress point")
