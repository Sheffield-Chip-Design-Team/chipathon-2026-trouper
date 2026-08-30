"""
test_array_sync.py -- two trouper_top instances sharing one ARRAY_ACQ_N wire.

This is the only suite that tests what planning/array-acquisition-sync.md
actually claims. Every other bench has a single DUT, so it can show that the
pad tie-offs are right and that a synthetic pulse on sc_lock_sync is accepted,
but it cannot show the thing the feature exists for: that a chip which never
sees a preamble can be started by a peer that did.

Topology (cocotb/hdl/tb_array_pair.v):

    chip A  <- CW SDM stimulus on all four branches      -> locks naturally
    chip B  <- IQ inputs held at 0                       -> can never lock alone
    both    <- one shared wired-AND ARRAY_ACQ_N net

Chip B is the measurement. It is starved of RF input on purpose, so any lock it
reports must have arrived over the wire.

The four tests are deliberately ordered as claim / control / exclusion:

  test_peer_sync_starts_idle_chip
      A locks, pulls the net low, B locks. The positive claim.

  test_isolated_chip_never_locks
      Identical run with the net forced to its idle level. B must NOT lock.
      Without this, the test above proves nothing -- a B that locked for some
      unrelated reason would look like a pass.

  test_force_lock_does_not_drive_the_wire
      SC_FORCE_LOCK (0x19) on A must not assert A's OE and must not start B.
      A forced lock has no verified preamble edge behind it, so propagating it
      would give the array an invalid common time origin. This is the one
      protocol rule that is a deliberate exclusion rather than a mechanism, so
      it is the one most likely to be "helpfully" removed later.

  test_open_drain_invariant_and_tieoffs
      Neither chip ever drives a 1, and the pad controls match the bi_t
      configuration in planning/Pinout.md. The wired-AND model in the bench is
      only valid while the first half of that holds.
"""

import math

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

CLK_NS   = 31.25    # 32 MHz
SCK_HALF = 62.5     # 8 MHz SPI half-period (ns)

SF          = 7      # default for the single-configuration tests
BW_KHZ      = 250
CLK_PER_IQ  = 64     # decimator is fixed R=64, so a sample is always 64 clocks


def sample_shift(bw_khz):
    return 1 if bw_khz == 250 else 2      # 250 kHz = 2x oversampled, 125 kHz = 4x


def sym_len(sf, bw_khz):
    """Symbol period in output samples."""
    return 1 << (sf + sample_shift(bw_khz))


def sym_ns(sf, bw_khz):
    return sym_len(sf, bw_khz) * CLK_PER_IQ * CLK_NS


M      = sym_len(SF, BW_KHZ)
SYM_NS = sym_ns(SF, BW_KHZ)

REG_PKT_TIMEOUT   = 0x0B

REG_ARRAY_SYNC_CTRL = 0x1B    # [0] ARRAY_SYNC_EN, resets to 0 (link off)

# Register map (planning/Register Map.md)
REG_SF_CFG        = 0x09
REG_BW_CFG        = 0x0A
REG_SC_THR_HI     = 0x0C
REG_SC_THR_LO     = 0x0D
REG_SC_HITS_REQ   = 0x0E
REG_SC_FORCE_LOCK = 0x19
REG_RX_HOLD       = 0x1A
REG_PACKET_STATUS = 0x1C
REG_SC_DBG_FLAGS  = 0x26
REG_PSRAM_CTRL    = 0x70
REG_PSRAM_STATUS  = 0x71

SC_DBG_LOCK_BIT   = 3     # SC_DBG_FLAGS[3] = sc_lock
PSRAM_INIT_DONE   = 0x08  # PSRAM_STATUS[3]


# ---------------------------------------------------------------------------
# Per-chip SPI. The pair bench prefixes every chip pin with A_ / B_, so each
# helper takes the prefix and reaches the right chip's host interface.
# ---------------------------------------------------------------------------

def _pin(dut, chip, name):
    return getattr(dut, f"{chip}_{name}")


async def _spi_byte(dut, chip, tx):
    rx = 0
    mosi = _pin(dut, chip, "SPI_MOSI")
    sck  = _pin(dut, chip, "SPI_SCK")
    miso = _pin(dut, chip, "SPI_MISO")
    for bit in range(7, -1, -1):
        mosi.value = (tx >> bit) & 1
        await Timer(SCK_HALF, unit="ns")
        sck.value = 1
        await Timer(SCK_HALF, unit="ns")
        rx = (rx << 1) | int(miso.value)
        sck.value = 0
    return rx


async def spi_write(dut, chip, addr, data):
    _pin(dut, chip, "HOST_CS").value = 0
    await Timer(SCK_HALF, unit="ns")
    await _spi_byte(dut, chip, addr & 0x7F)        # R/W = 0
    await _spi_byte(dut, chip, data & 0xFF)
    await Timer(SCK_HALF, unit="ns")
    _pin(dut, chip, "HOST_CS").value = 1
    await Timer(500, unit="ns")


async def spi_read(dut, chip, addr):
    _pin(dut, chip, "HOST_CS").value = 0
    await Timer(SCK_HALF, unit="ns")
    await _spi_byte(dut, chip, 0x80 | (addr & 0x7F))   # R/W = 1
    data = await _spi_byte(dut, chip, 0xFF)
    await Timer(SCK_HALF, unit="ns")
    _pin(dut, chip, "HOST_CS").value = 1
    await Timer(500, unit="ns")
    return data


async def sc_locked(dut, chip):
    dbg = await spi_read(dut, chip, REG_SC_DBG_FLAGS)
    return bool((dbg >> SC_DBG_LOCK_BIT) & 1)


# ---------------------------------------------------------------------------
# Stimulus
# ---------------------------------------------------------------------------

async def sdm_driver(dut, chip):
    """First-order SDM CW on all four branches of one chip.

    Lifted from test_trouper_top.sdm_driver -- same amplitude and period, so
    chip A acquires under exactly the conditions the single-DUT sweep already
    proves work. Only the destination pins differ.
    """
    P = 8       # CW period in iq_valid samples
    A = 31      # satisfies the sc_detector e_slice guard at SF7/BW250

    stim_i = [round(A * math.cos(2 * math.pi * k / P)) for k in range(P)]
    stim_q = [round(A * math.sin(2 * math.pi * k / P)) for k in range(P)]

    di = _pin(dut, chip, "IQ_DATA_I")
    dq = _pin(dut, chip, "IQ_DATA_Q")

    acc_i = acc_q = 0
    sine_ptr = 0
    bit_cnt = 0

    while True:
        await RisingEdge(dut.IQ_CLK)
        xi, xq = stim_i[sine_ptr], stim_q[sine_ptr]

        if acc_i >= 0:
            bit_i = 1; acc_i += xi - 127
        else:
            bit_i = 0; acc_i += xi + 127

        if acc_q >= 0:
            bit_q = 1; acc_q += xq - 127
        else:
            bit_q = 0; acc_q += xq + 127

        di.value = (bit_i << 3) | (bit_i << 2) | (bit_i << 1) | bit_i
        dq.value = (bit_q << 3) | (bit_q << 2) | (bit_q << 1) | bit_q

        bit_cnt += 1
        if bit_cnt >= CLK_PER_IQ:
            bit_cnt = 0
            sine_ptr = (sine_ptr + 1) % P


async def reset_pair(dut):
    cocotb.start_soon(Clock(dut.IQ_CLK, CLK_NS, unit="ns").start())
    for chip in ("A", "B"):
        _pin(dut, chip, "HOST_CS").value    = 1
        _pin(dut, chip, "SPI_SCK").value    = 0
        _pin(dut, chip, "SPI_MOSI").value   = 0
        _pin(dut, chip, "IQ_DATA_I").value  = 0
        _pin(dut, chip, "IQ_DATA_Q").value  = 0
    dut.force_bus_high.value = 0
    dut.RESETB.value = 0
    await Timer(4 * CLK_NS, unit="ns")
    dut.RESETB.value = 1
    await Timer(8 * CLK_NS, unit="ns")


async def configure(dut, chip, sf=SF, bw_khz=BW_KHZ, pkt_timeout_syms=None,
                    array_sync_en=True):
    """Identical LoRa configuration on one chip.

    planning/array-acquisition-sync.md lists identical SF, BW and hit count as
    a coherency prerequisite. Both chips get the same values here, so a
    divergence in this function is itself a bug in the test.

    Order matters: every gated register is written before RX_HOLD is released,
    or the hardware silently refuses the write (see test_trouper_top).
    """
    await spi_read(dut, chip, 0x00)          # prime the SPI interface
    await spi_read(dut, chip, REG_SF_CFG)

    await spi_write(dut, chip, REG_SF_CFG, sf & 0x0F)
    await spi_write(dut, chip, REG_BW_CFG, 0 if bw_khz == 250 else 1)
    await spi_write(dut, chip, REG_ARRAY_SYNC_CTRL, 0x01 if array_sync_en else 0x00)
    if pkt_timeout_syms is not None:
        await spi_write(dut, chip, REG_PKT_TIMEOUT, pkt_timeout_syms & 0xFF)
    await spi_write(dut, chip, REG_SC_THR_HI, 0x01)   # sc_thr = 0x0100
    await spi_write(dut, chip, REG_SC_THR_LO, 0x00)
    await spi_write(dut, chip, REG_SC_HITS_REQ, 0x00)  # 1 hit fires lock
    await spi_write(dut, chip, REG_RX_HOLD, 0x00)      # release; detector runs

    await spi_write(dut, chip, REG_PSRAM_CTRL, 0x01)
    for _ in range(500):
        await Timer(8 * CLK_NS, unit="ns")
        if (await spi_read(dut, chip, REG_PSRAM_STATUS)) & PSRAM_INIT_DONE:
            break
    else:
        raise AssertionError(f"chip {chip}: PSRAM INIT_DONE never set")


async def wait_for_lock(dut, chip, max_syms=20, period_ns=None):
    """Poll one chip's sc_lock for up to max_syms symbol periods."""
    period_ns = SYM_NS if period_ns is None else period_ns
    for _ in range(max_syms):
        await Timer(period_ns, unit="ns")
        if await sc_locked(dut, chip):
            return True
    return False


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_peer_sync_starts_idle_chip(dut):
    """A acquires, pulls ARRAY_ACQ_N low, and B locks off the wire alone."""
    await reset_pair(dut)
    await configure(dut, "A")
    await configure(dut, "B")

    # Only A gets RF. B's inputs stay at 0 for the whole test.
    cocotb.start_soon(sdm_driver(dut, "A"))

    assert not await sc_locked(dut, "B"), "chip B locked before anything happened"

    assert await wait_for_lock(dut, "A"), \
        "chip A never acquired -- the stimulus, not the sync link, is broken"
    dut._log.info("chip A: natural sc_lock")

    # A must be pulling the shared net down, and doing it the open-drain way.
    assert int(dut.A_ARRAY_ACQ_N_OE.value) == 1, \
        "chip A locked but never asserted ARRAY_ACQ_N_OE -- nothing reached the wire"
    assert int(dut.ARRAY_ACQ_N.value) == 0, \
        "ARRAY_ACQ_N did not go low while chip A was asserting"

    # The claim under test.
    assert await wait_for_lock(dut, "B", max_syms=4), \
        "chip B never locked despite a peer event on ARRAY_ACQ_N"
    dut._log.info("chip B: locked from the peer event")

    # B's lock came in over sc_lock_sync, not from its own correlator, so B must
    # not re-drive the wire. If it did, two chips would keep restarting each
    # other for as long as the net stayed low.
    assert int(dut.B_ARRAY_ACQ_N_OE.value) == 0, \
        "chip B drove ARRAY_ACQ_N after a *peer* lock -- sc_lock_natural_pulse " \
        "is firing on a synced lock, which lets the array ring"

    # A peer-synced lock must carry a real time reference, not zero: the whole
    # point of using sc_lock_sync instead of sc_lock_force is that timing_ref is
    # reconstructed with the normal hit-run back-calculation.
    ref_a = int(dut.u_a.u_dut.u_sc.timing_ref.value)
    ref_b = int(dut.u_b.u_dut.u_sc.timing_ref.value)
    assert ref_b != 0, \
        "chip B locked with timing_ref=0 -- no usable time origin was established"

    # Both chips left reset together and count samples off the same IQ_CLK, so
    # a perfectly shared epoch would give ref_a == ref_b. It does not: the
    # natural path latches eval_sample_mark (the correlation window mark) while
    # the peer path reads the live sample_count when the wire edge arrives, and
    # that arrival is delayed by A's detect-to-OE path plus B's two-flop
    # synchroniser. MEASURED, not assumed -- the delta is logged every run.
    delta = ref_b - ref_a
    dut._log.info(f"timing_ref A={ref_a} B={ref_b} delta={delta} samples "
                  f"(M={M} samples/symbol)")

    # The raw peer path runs +2 samples late (measured; see
    # test_epoch_offset_is_stable_across_sf_bw). sc_detector subtracts
    # SYNC_EPOCH_LAG_SAMPLES to cancel exactly that, so the two chips must now
    # agree to the sample. Exact, not bounded: if the evaluation pipeline ever
    # changes depth the constant goes stale, and a tolerance would hide it.
    assert delta == 0, (
        f"peer-synced epoch is {delta} samples off chip A's. "
        f"SYNC_EPOCH_LAG_SAMPLES in src/frontend/sc_detector.v no longer "
        f"matches the real detect-to-sync latency."
    )

    # And B really is running a packet, not just holding a lock bit.
    status = await spi_read(dut, "B", REG_PACKET_STATUS)
    assert status & 0x01, \
        f"chip B: packet_ctrl_fsm did not start (PACKET_STATUS=0x{status:02X})"


@cocotb.test()
async def test_isolated_chip_never_locks(dut):
    """Control for the test above: with the net idle-high, B must stay dark.

    Same stimulus, same configuration, one difference -- the shared wire is
    held at the level the external pull-up gives it. If B locks here, the
    positive test proves nothing.
    """
    await reset_pair(dut)
    dut.force_bus_high.value = 1
    await configure(dut, "A")
    await configure(dut, "B")

    cocotb.start_soon(sdm_driver(dut, "A"))

    assert await wait_for_lock(dut, "A"), "chip A never acquired"
    dut._log.info("chip A: natural sc_lock (bus isolated)")

    for _ in range(6):
        await Timer(SYM_NS, unit="ns")
        assert not await sc_locked(dut, "B"), \
            "chip B locked with ARRAY_ACQ_N held high -- its lock in the sync " \
            "test did not come from the wire"
    dut._log.info("chip B: correctly stayed idle with the bus isolated")


@cocotb.test()
async def test_force_lock_does_not_drive_the_wire(dut):
    """SC_FORCE_LOCK is diagnostic-only and must never reach the array.

    A forced lock has no verified preamble edge behind it, so its timing_ref is
    meaningless. Sharing it would hand every chip in the array an invalid common
    time origin -- worse than not syncing at all, because the result looks
    plausible. planning/array-acquisition-sync.md states the exclusion; this is
    the test that keeps it true.
    """
    await reset_pair(dut)
    await configure(dut, "A")
    await configure(dut, "B")

    # No RF anywhere in this test: the only lock is the forced one.
    assert not await sc_locked(dut, "A")
    assert not await sc_locked(dut, "B")

    await spi_write(dut, "A", REG_SC_FORCE_LOCK, 0x01)
    await Timer(20 * CLK_NS, unit="ns")

    assert await sc_locked(dut, "A"), "SC_FORCE_LOCK did not assert chip A's sc_lock"

    assert int(dut.A_ARRAY_ACQ_N_OE.value) == 0, \
        "SC_FORCE_LOCK drove ARRAY_ACQ_N -- a diagnostic override is being " \
        "propagated to the array as if it were a real acquisition"
    assert int(dut.ARRAY_ACQ_N.value) == 1, "ARRAY_ACQ_N went low on a forced lock"

    for _ in range(4):
        await Timer(SYM_NS, unit="ns")
        assert not await sc_locked(dut, "B"), \
            "chip B locked from chip A's SC_FORCE_LOCK"
    dut._log.info("SC_FORCE_LOCK correctly stayed local to chip A")


@cocotb.test()
async def test_open_drain_invariant_and_tieoffs(dut):
    """Neither chip may drive a 1, and the pad controls must match the spec.

    The bench models the shared net as ~(A_oe | B_oe), which is only equivalent
    to the real wired-AND while both chips hold their pad data at 0. Check that
    continuously rather than trusting it.

    The tie-off values are from planning/Pinout.md: bi_t, Schmitt input enabled,
    slow slew, minimum drive. PDRV is the reason this pad is bi_t and not
    bi_24t.

    PU=1 is the exception worth calling out: this is the ONLY pad on the chip
    with an internal pull enabled. ARRAY_ACQ_N is the one pin a board may
    legitimately leave unpopulated, and an undriven input with IE=1 sits the
    receiver near mid-rail drawing static current. The external pull-up is
    still mandatory on a real multi-chip net -- see planning/Pinout.md.
    """
    await reset_pair(dut)
    await configure(dut, "A")
    await configure(dut, "B")
    cocotb.start_soon(sdm_driver(dut, "A"))

    expected = {
        "IE": 1, "CS": 1, "SL": 1,
        "PU": 1,          # deliberate, and unique on this chip -- see above
        "PD": 0,
        "PDRV0": 0, "PDRV1": 0,
    }
    for name, want in expected.items():
        got = int(getattr(dut, f"A_ARRAY_ACQ_N_{name}").value)
        assert got == want, f"ARRAY_ACQ_N_{name} tied to {got}, expected {want}"

    for _ in range(2000):
        await RisingEdge(dut.IQ_CLK)
        assert int(dut.A_ARRAY_ACQ_N_OUT.value) == 0, "chip A drove ARRAY_ACQ_N high"
        assert int(dut.B_ARRAY_ACQ_N_OUT.value) == 0, "chip B drove ARRAY_ACQ_N high"

    dut._log.info("open-drain invariant and pad tie-offs hold")


@cocotb.test()
async def test_epoch_offset_is_stable_across_sf_bw(dut):
    """Is the A->B epoch offset a fixed constant, or does it move with config?

    This decides whether the offset can be compensated at all. The peer path's
    lateness is set by the detector's evaluation pipeline plus the OE and
    synchroniser delays -- all measured in IQ_CLK cycles. The decimator is
    fixed R=64, so one output sample is always 64 clocks no matter what SF or
    BW is programmed. If that reasoning holds, the offset expressed *in
    samples* is the same for every configuration and a single constant
    corrects it. If it moves, compensation needs a runtime term.

    Measured, not assumed.
    """
    results = {}
    for sf, bw in ((7, 250), (7, 125), (8, 250)):
        await reset_pair(dut)
        await configure(dut, "A", sf=sf, bw_khz=bw)
        await configure(dut, "B", sf=sf, bw_khz=bw)

        stim = cocotb.start_soon(sdm_driver(dut, "A"))
        period = sym_ns(sf, bw)

        assert await wait_for_lock(dut, "A", max_syms=20, period_ns=period), \
            f"SF{sf}/BW{bw}: chip A never acquired"
        assert await wait_for_lock(dut, "B", max_syms=4, period_ns=period), \
            f"SF{sf}/BW{bw}: chip B never synced"

        ref_a = int(dut.u_a.u_dut.u_sc.timing_ref.value)
        ref_b = int(dut.u_b.u_dut.u_sc.timing_ref.value)
        results[(sf, bw)] = ref_b - ref_a
        dut._log.info(f"SF{sf}/BW{bw}: timing_ref A={ref_a} B={ref_b} "
                      f"delta={ref_b - ref_a} (M={sym_len(sf, bw)})")
        stim.kill()

    deltas = set(results.values())
    dut._log.info(f"epoch offsets by config: {results}")
    assert len(deltas) == 1, (
        f"the A->B epoch offset is NOT constant across configurations: {results}. "
        f"SYNC_EPOCH_LAG_SAMPLES is a single constant, so it would be wrong for "
        f"at least one of them -- see planning/array-acquisition-sync.md."
    )
    assert deltas == {0}, (
        f"compensated epoch offset is {deltas}, expected 0 in every "
        f"configuration. Adjust SYNC_EPOCH_LAG_SAMPLES in "
        f"src/frontend/sc_detector.v to the measured raw lag."
    )


@cocotb.test()
async def test_peer_lock_suppresses_local_detector(dut):
    """What happens when B's own detector would fire AFTER a peer sync?

    In a real array both chips hear the packet, so this is the normal case, not
    a corner: whichever chip detects first syncs the other, and the second
    chip's own correlator then reaches its own hit run a moment later.

    sc_detector gates the whole natural-lock block behind
    `metric_valid_pulse && !sc_lock` (src/frontend/sc_detector.v), so once B is
    peer-locked its own detection is suppressed until sc_clr. That matters for
    three separate reasons, all checked here:

      - timing_ref must NOT be rewritten mid-packet. packet_ctrl_fsm latches it
        once in ST_ACQ_SETUP and derives absolute deadlines from it; a late
        overwrite would leave the FSM and the detector disagreeing about when
        the packet started.
      - sc_lock_natural_pulse must NOT fire, or B would drive the shared wire
        on what is really a peer-originated lock.
      - packet_ctrl_fsm has no mid-packet re-lock path. It was removed as
        structurally unreachable (Open Risks #25), and the code comment there
        explicitly warns that a cascade input WITHOUT the !sc_lock gate would
        make it reachable again. This test is what keeps that gate honest.
    """
    await reset_pair(dut)
    await configure(dut, "A")
    await configure(dut, "B")

    cocotb.start_soon(sdm_driver(dut, "A"))

    assert await wait_for_lock(dut, "A"), "chip A never acquired"
    assert await wait_for_lock(dut, "B", max_syms=4), "chip B never synced"

    ref_b_at_sync = int(dut.u_b.u_dut.u_sc.timing_ref.value)
    phase_at_sync = (await spi_read(dut, "B", REG_PACKET_STATUS) >> 1) & 0x7
    dut._log.info(f"chip B synced: timing_ref={ref_b_at_sync} phase={phase_at_sync}")

    # NOW give chip B the same RF it would really have been receiving all along.
    # Its correlator starts finding hits while it is already locked.
    cocotb.start_soon(sdm_driver(dut, "B"))

    for _ in range(6):
        await Timer(SYM_NS, unit="ns")
        ref_now = int(dut.u_b.u_dut.u_sc.timing_ref.value)
        assert ref_now == ref_b_at_sync, (
            f"chip B's timing_ref moved after its own detector saw the packet: "
            f"{ref_b_at_sync} -> {ref_now}. The natural-lock path is no longer "
            f"gated by !sc_lock, and packet_ctrl_fsm's latched deadlines are now "
            f"anchored to a different epoch than the detector's."
        )
        assert int(dut.B_ARRAY_ACQ_N_OE.value) == 0, (
            "chip B asserted ARRAY_ACQ_N after its own detector fired on a "
            "packet it was already peer-locked to -- a synced chip is echoing "
            "back onto the shared wire"
        )

    assert await sc_locked(dut, "B"), "chip B lost its lock"
    dut._log.info("chip B: local detector correctly suppressed while peer-locked")


@cocotb.test()
async def test_sync_releases_and_rearms(dut):
    """How the link resets, and that it can carry a second packet.

    Release is entirely event-driven -- there is no timer in array_acq_sync:

      drive_oe   clears on packet_done, rx_hold, or !array_sync_en
      line_idle_seen clears on packet_done or rx_hold, and is only re-set
                     after the net has been *observed* high again

    That second flop is what makes reset safe. A chip coming out of reset while
    the net is already low must not treat that standing low level as a fresh
    event; it has to see the line released first. The same flop is what makes a
    second packet work.

    packet_done is guaranteed: packet_ctrl_fsm's pkt_cnt deadline always
    returns the FSM to ST_IDLE, so a chip cannot hold the array's wire down
    forever on a false lock. PKT_TIMEOUT_SYMS is set short here so the packet
    ends inside a reasonable sim.
    """
    await reset_pair(dut)
    await configure(dut, "A", pkt_timeout_syms=4)
    await configure(dut, "B", pkt_timeout_syms=4)

    stim = cocotb.start_soon(sdm_driver(dut, "A"))

    assert await wait_for_lock(dut, "A"), "chip A never acquired"
    assert await wait_for_lock(dut, "B", max_syms=4), "chip B never synced"
    assert int(dut.ARRAY_ACQ_N.value) == 0, "net should be low while A drives"

    # Stop the stimulus so the packet runs out rather than re-triggering.
    stim.kill()
    dut.A_IQ_DATA_I.value = 0
    dut.A_IQ_DATA_Q.value = 0

    # Wait for both chips to time out back to IDLE and release the wire.
    released = False
    for _ in range(40):
        await Timer(SYM_NS, unit="ns")
        a_active = (await spi_read(dut, "A", REG_PACKET_STATUS)) & 0x01
        b_active = (await spi_read(dut, "B", REG_PACKET_STATUS)) & 0x01
        if not a_active and not b_active:
            released = True
            break
    assert released, "packet never timed out -- the wire would stay held down"

    assert int(dut.A_ARRAY_ACQ_N_OE.value) == 0, \
        "chip A still driving ARRAY_ACQ_N after packet_done"
    assert int(dut.ARRAY_ACQ_N.value) == 1, \
        "ARRAY_ACQ_N did not return to its idle level after the packet"
    assert not await sc_locked(dut, "A"), "chip A's sc_lock did not clear"
    assert not await sc_locked(dut, "B"), "chip B's sc_lock did not clear"
    dut._log.info("both chips released the wire and re-armed")

    # Second packet over the same link.
    cocotb.start_soon(sdm_driver(dut, "A"))
    assert await wait_for_lock(dut, "A", max_syms=20), \
        "chip A did not re-acquire on the second packet"
    assert await wait_for_lock(dut, "B", max_syms=4), \
        "chip B did not re-sync on the second packet -- line_idle_seen never re-armed"
    dut._log.info("second packet synced over the same link")


@cocotb.test()
async def test_disabled_link_ignores_the_wire(dut):
    """With ARRAY_SYNC_EN=0 the pin is inert in both directions.

    This is the default state out of reset, and it is what protects a
    single-chip board: ARRAY_ACQ_N may be left unpopulated with no pull-up, and
    whatever the floating pad does, nothing can start the receiver.

    Both directions matter, so both are checked:
      - chip A must not DRIVE the wire when it acquires (array_sync_en gates
        drive_oe), so it cannot disturb anything else sharing the net;
      - chip B must not ACCEPT an event (array_sync_en gates `armed`), even
        when a real falling edge is applied.

    The second is forced explicitly rather than left to chance: A is disabled
    here, so nothing would pull the line down on its own.
    """
    await reset_pair(dut)
    await configure(dut, "A", array_sync_en=False)
    await configure(dut, "B", array_sync_en=False)

    # Reset default really is off -- confirm the readback before relying on it.
    ctrl_a = await spi_read(dut, "A", REG_ARRAY_SYNC_CTRL)
    assert (ctrl_a & 0x01) == 0, \
        f"ARRAY_SYNC_EN did not clear (ARRAY_SYNC_CTRL=0x{ctrl_a:02X})"

    cocotb.start_soon(sdm_driver(dut, "A"))
    assert await wait_for_lock(dut, "A"), "chip A never acquired"

    assert int(dut.A_ARRAY_ACQ_N_OE.value) == 0, \
        "chip A drove ARRAY_ACQ_N with ARRAY_SYNC_EN=0"
    assert int(dut.ARRAY_ACQ_N.value) == 1, "net went low with the link disabled"

    for _ in range(4):
        await Timer(SYM_NS, unit="ns")
        assert not await sc_locked(dut, "B"), \
            "chip B locked with ARRAY_SYNC_EN=0"

    dut._log.info("disabled link: chip A did not drive, chip B did not lock")


@cocotb.test()
async def test_disabled_receiver_rejects_a_real_edge(dut):
    """A genuine falling edge on the wire must be ignored when B is disabled.

    Separated from the test above because there the line never moved -- B
    passing proved only that nothing happened. Here chip A has the link ENABLED
    and really does pull the net low; only B is disabled. If ARRAY_SYNC_EN did
    not gate the accept path, B would lock.
    """
    await reset_pair(dut)
    await configure(dut, "A", array_sync_en=True)
    await configure(dut, "B", array_sync_en=False)

    cocotb.start_soon(sdm_driver(dut, "A"))
    assert await wait_for_lock(dut, "A"), "chip A never acquired"
    assert int(dut.A_ARRAY_ACQ_N_OE.value) == 1, "setup: chip A should be driving"
    assert int(dut.ARRAY_ACQ_N.value) == 0, "setup: net should be low"

    for _ in range(4):
        await Timer(SYM_NS, unit="ns")
        assert not await sc_locked(dut, "B"), \
            "chip B accepted a peer event with ARRAY_SYNC_EN=0 -- the enable " \
            "gates only the drive side, not the accept side"

    dut._log.info("disabled receiver correctly ignored a real falling edge")
