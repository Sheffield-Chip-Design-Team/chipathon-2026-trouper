"""
test_replay_delay.py -- continuous-delay PSRAM replay regression.

Covers the TRPR-RMD-009 redesign
(planning/psram-replay-continuous-delay-redesign.md): replay is a
never-rewinding delay line that starts at training_done +
REPLAY_DELAY_SAMPLES, independent of W_COMMIT. The margin expiry doubles as
the weight-arrival timeout, giving the three-rung failure ladder (doc §4a):

  on-time commit  -> full-packet MRC, no flags
  late commit     -> bypass prefix, mid-stream MRC upgrade, WGT_CTRL[4]
                     W_COMMIT_LATE sticky (cleared at the next packet start)
  no commit       -> whole packet in bypass via the combiner's !W_valid
                     fallback, W_MISSED_PACKET as before -- and REPLAY_MISSED
                     must NOT latch, because the replay itself ran fine

plus (doc §9): the replay stream is monotonic (rd_ptr advances 8 bytes per
rpl_valid, never rewinds -- watched hierarchically), there is exactly one
silence->signal transition per packet (psram_silence falls once and stays
low), and the read slot is handed back to the SC delay-read after
packet_end (observed as the next packet actually re-locking, which needs
del_valid).

The packet_end-before-margin case (margin armed but never met -> replay
never starts, REPLAY_MISSED clean fallback, doc §6) lives in
test_psram_ops.test_replay_missed_late_commit (replay_delay=0xFFFF). The
packet_end-before-training_done variant is not reachable from register
config with a healthy CW stimulus: packet_ctrl_fsm checks PKT_TIMEOUT only
in PAYLOAD_ACTIVE, and training_acc completes its window at
timing_ref + tacc_window*M regardless of the FSM state, so training_done
always fires first while the decimator is streaming.

Register cheat sheet: IRQ_STATUS 0x02 [0]=SC_LOCK [1]=TRAINING_DONE
[2]=W_MISSED [3]=PACKET_DONE; WGT_CTRL 0x1E [1]=W_VALID [2]=W_PENDING
[3]=W_MISSED [4]=W_COMMIT_LATE; PSRAM_STATUS 0x71 [4]=REPLAY_ACTIVE
[5]=REPLAY_MISSED; REPLAY_DELAY 0x77/0x78 (LO/HI).
"""

import cocotb
from cocotb.triggers import RisingEdge, Timer

from test_trouper_top import CLK_NS, spi_read, spi_write, spi_burst_write
from test_bypass_e2e import _reset_and_lock

PKT_TIMEOUT_SYMS = 20


async def _wait_irq(dut, bit, tries, sym_ns, tag, what):
    for _ in range(tries):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & bit:
            return
    assert False, f"{tag}: {what} never fired"


async def _wait_replay_active(dut, tries, sym_ns, tag):
    for _ in range(tries):
        await Timer(sym_ns // 8, unit="ns")
        if (await spi_read(dut, 0x71)) & 0x10:
            return
    assert False, f"{tag}: REPLAY_ACTIVE never set (margin-gated replay did not start)"


async def _watch_monotonic_replay(dut, n_samples, tag):
    """During replay: rd_ptr must advance by exactly 8 bytes per rpl_valid
    pulse (mod the 23-bit wrap) and never move otherwise -- the no-rewind
    property TRPR-RMD-009 requires, watched at the pointer itself."""
    AMASK = (1 << 23) - 1
    prev = None
    pulses = 0
    for _ in range(n_samples * 80):
        await RisingEdge(dut.IQ_CLK)
        if int(dut.u_dut.u_psram.rpl_valid.value):
            cur = int(dut.u_dut.u_psram.rd_ptr.value)
            if prev is not None:
                assert cur == ((prev + 8) & AMASK), \
                    f"{tag}: rd_ptr jumped 0x{prev:06X} -> 0x{cur:06X} " \
                    f"(expected +8) -- replay stream rewound or skipped"
            prev = cur
            pulses += 1
            if pulses >= n_samples:
                break
    assert pulses >= n_samples, \
        f"{tag}: only {pulses}/{n_samples} rpl_valid pulses seen during replay"
    dut._log.info(f"{tag}: {pulses} replay samples strictly monotonic")


@cocotb.test()
async def test_timeout_replay_without_commit(dut):
    """Rung 3: W_COMMIT never sent. Replay must start anyway on margin
    expiry, run the packet in combiner bypass, flag W_MISSED_PACKET (FSM)
    but NOT REPLAY_MISSED (the replay ran), and hand the PSRAM read slot
    back to the SC delay-read afterwards (next packet re-locks)."""
    tag = "timeout_replay"
    sym_ns = await _reset_and_lock(dut, mode=0, ant_mask=0xF, tag=tag,
                                   pkt_timeout_syms=PKT_TIMEOUT_SYMS,
                                   replay_delay=64)

    await _wait_irq(dut, 0x02, 40, sym_ns, tag, "training_done")

    # Margin 64 samples after training_done -- replay must start with no
    # commit ever arriving (the built-in weight-arrival timeout, doc §4a)
    await _wait_replay_active(dut, 40, sym_ns, tag)

    st = await spi_read(dut, 0x71)
    assert not (st & 0x20), \
        f"{tag}: REPLAY_MISSED set while replay is running (0x{st:02X})"
    assert int(dut.u_dut.u_comb.use_mrc_r.value) == 0, \
        f"{tag}: combiner left bypass without any W_COMMIT"
    assert int(dut.u_dut.psram_silence.value) == 0, \
        f"{tag}: psram_silence still 1 with REPLAY_ACTIVE set"

    await _watch_monotonic_replay(dut, 60, tag)

    wgt = await spi_read(dut, 0x1E)
    assert not (wgt & 0x10), \
        f"{tag}: W_COMMIT_LATE set although no commit was ever sent (0x{wgt:02X})"

    # FSM-level miss (wpend timeout at ~13 syms) fires as before
    await _wait_irq(dut, 0x04, 15, sym_ns, tag, "W_MISSED_PACKET IRQ")

    # Packet end: REPLAY_MISSED must stay clear -- the packet was degraded
    # (bypass weights), not lost (old design: whole packet silent + missed)
    await _wait_irq(dut, 0x08, PKT_TIMEOUT_SYMS + 5, sym_ns, tag, "PACKET_DONE IRQ")
    st = await spi_read(dut, 0x71)
    assert not (st & 0x20), \
        f"{tag}: REPLAY_MISSED latched at packet_end although replay ran (0x{st:02X})"
    assert not (st & 0x10), \
        f"{tag}: REPLAY_ACTIVE still set after packet_end (0x{st:02X})"

    # Read-slot handback: the SC detector needs the PSRAM del-read to lock
    # again, so a successful re-lock proves the mux returned to S_WRITE's
    # delay-read (doc §9 two-packet check)
    await spi_write(dut, 0x03, 0xFF)
    await _wait_irq(dut, 0x01, 25, sym_ns, tag, "re-lock after replay packet")
    dut._log.info(f"{tag}: PASS -- commit-less replay, bypass payload, no "
                  f"REPLAY_MISSED, slot handed back (re-locked)")


@cocotb.test()
async def test_commit_late_sets_late_flag(dut):
    """Rung 2: commit lands after replay has started. The stream must
    upgrade to MRC mid-flight, W_COMMIT_LATE must latch sticky, and it must
    clear at the next packet start."""
    tag = "late_commit"
    sym_ns = await _reset_and_lock(dut, mode=0, ant_mask=0xF, tag=tag,
                                   pkt_timeout_syms=PKT_TIMEOUT_SYMS,
                                   replay_delay=32)

    await _wait_irq(dut, 0x02, 40, sym_ns, tag, "training_done")
    await _wait_replay_active(dut, 40, sym_ns, tag)

    wgt = await spi_read(dut, 0x1E)
    assert not (wgt & 0x10), f"{tag}: W_COMMIT_LATE set before any commit (0x{wgt:02X})"
    assert int(dut.u_dut.u_comb.use_mrc_r.value) == 0, \
        f"{tag}: combiner in MRC before the (late) commit"

    # Deliberately-late commit, mid-replay (weights 0x40 everywhere)
    await spi_burst_write(dut, 0x30, [0x40] * 16)
    await spi_write(dut, 0x1E, 0x01)

    late_ok = False
    for _ in range(20):
        await Timer(sym_ns // 8, unit="ns")
        if (await spi_read(dut, 0x1E)) & 0x10:
            late_ok = True
            break
    assert late_ok, f"{tag}: W_COMMIT_LATE never latched on a mid-replay commit"

    # Mid-stream upgrade: weights now applied, replay uninterrupted
    await Timer(3 * 64 * CLK_NS, unit="ns")
    assert int(dut.u_dut.u_comb.use_mrc_r.value) == 1, \
        f"{tag}: use_mrc_r stayed 0 after the late commit -- no mid-stream upgrade"
    st = await spi_read(dut, 0x71)
    assert st & 0x10, f"{tag}: replay stopped at the late commit (0x{st:02X})"
    wgt = await spi_read(dut, 0x1E)
    assert not (wgt & 0x08), \
        f"{tag}: W_MISSED_PACKET set although the commit landed in-packet (0x{wgt:02X})"

    # Sticky through packet end, cleared at the next packet start
    await _wait_irq(dut, 0x08, PKT_TIMEOUT_SYMS + 5, sym_ns, tag, "PACKET_DONE IRQ")
    wgt = await spi_read(dut, 0x1E)
    assert wgt & 0x10, f"{tag}: W_COMMIT_LATE lost at IDLE entry (0x{wgt:02X})"

    await spi_write(dut, 0x03, 0xFF)
    await _wait_irq(dut, 0x01, 25, sym_ns, tag, "re-lock")
    wgt = await spi_read(dut, 0x1E)
    assert not (wgt & 0x10), \
        f"{tag}: W_COMMIT_LATE not cleared at the next packet start (0x{wgt:02X})"
    dut._log.info(f"{tag}: PASS -- late flag latched, mid-stream MRC upgrade, "
                  f"sticky through IDLE, cleared at next lock")


@cocotb.test()
async def test_commit_on_time_no_flags(dut):
    """Rung 1: commit lands before the margin expires. The whole replayed
    packet is MRC-weighted from its first sample; neither W_COMMIT_LATE nor
    W_MISSED_PACKET may set."""
    tag = "ontime_commit"
    # 600-sample margin (~2.3 syms at SF7/BW250): enough room to push 17 SPI
    # writes after the training_done IRQ before the margin expires
    sym_ns = await _reset_and_lock(dut, mode=0, ant_mask=0xF, tag=tag,
                                   pkt_timeout_syms=PKT_TIMEOUT_SYMS,
                                   replay_delay=600)

    await _wait_irq(dut, 0x02, 40, sym_ns, tag, "training_done")

    await spi_burst_write(dut, 0x30, [0x40] * 16)
    await spi_write(dut, 0x1E, 0x01)

    wgt = await spi_read(dut, 0x1E)
    assert wgt & 0x02, f"{tag}: W_VALID not latched after in-time commit (0x{wgt:02X})"
    assert not (wgt & 0x10), \
        f"{tag}: W_COMMIT_LATE set on an in-time commit (0x{wgt:02X}) -- commit " \
        f"landed before replay start, flag must stay clear"

    await _wait_replay_active(dut, 40, sym_ns, tag)
    assert int(dut.u_dut.u_comb.use_mrc_r.value) == 1, \
        f"{tag}: combiner not in MRC during a weight-committed replay"

    wgt = await spi_read(dut, 0x1E)
    assert not (wgt & 0x18), \
        f"{tag}: miss/late flag set on the clean path (WGT_CTRL=0x{wgt:02X})"

    await _wait_irq(dut, 0x08, PKT_TIMEOUT_SYMS + 5, sym_ns, tag, "PACKET_DONE IRQ")
    st = await spi_read(dut, 0x71)
    assert not (st & 0x20), f"{tag}: REPLAY_MISSED on the clean path (0x{st:02X})"
    dut._log.info(f"{tag}: PASS -- on-time commit, MRC replay, no flags")


# ---------------------------------------------------------------------------
# Batch 1 of planning/psram-replay-verification-plan.md (RPV-1..4)
# ---------------------------------------------------------------------------

async def _measure_start_gap(dut, margin, tag):
    """RPV-2/3 core: count dcr_valid samples between the training_done
    rising edge and the first rpl_valid pulse. Expected margin..margin+3:
    the arm cycle itself doesn't decrement (wait_armed is registered), the
    S_REPLAY entry waits for !qpi_busy, and the first replay read completes
    on the following sample's burst -- so the gap is the register value
    plus at most a couple of samples of pipeline skew, never less."""
    sym_ns = await _reset_and_lock(dut, mode=0, ant_mask=0xF,
                                   tag=tag, pkt_timeout_syms=PKT_TIMEOUT_SYMS,
                                   replay_delay=margin)

    seen_train = False
    prev_train = int(dut.u_dut.training_done.value)
    gap = 0
    # 8-sym training window + margin + slack, in clocks
    budget = (8 * 256 + margin + 512) * 64 + 20000
    for _ in range(budget):
        await RisingEdge(dut.IQ_CLK)
        t = int(dut.u_dut.training_done.value)
        if t and not prev_train:
            seen_train = True
        prev_train = t
        if seen_train:
            if int(dut.u_dut.u_psram.rpl_valid.value):
                break
            if int(dut.u_dut.dcr_valid.value):
                gap += 1
    else:
        assert False, (f"{tag}: no rpl_valid within budget after "
                       f"training_done (seen_train={seen_train}, gap={gap})")

    assert margin <= gap <= margin + 3, \
        f"{tag}: replay started {gap} samples after training_done, " \
        f"expected REPLAY_DELAY_SAMPLES={margin} (+<=3 pipeline skew) -- " \
        f"the register does not mean what it says"
    dut._log.info(f"{tag}: PASS -- first rpl_valid {gap} samples after "
                  f"training_done (margin {margin})")


@cocotb.test()
async def test_start_gap_margin_32(dut):
    """RPV-2: replay-start instant is the programmed sample count (small)."""
    await _measure_start_gap(dut, 32, "start_gap_32")


@cocotb.test()
async def test_start_gap_margin_300(dut):
    """RPV-2: same at a distinct larger margin -- proves scaling, not a
    fixed pipeline offset."""
    await _measure_start_gap(dut, 300, "start_gap_300")


@cocotb.test()
async def test_start_gap_margin_0(dut):
    """RPV-3: REPLAY_DELAY_SAMPLES=0 degrades to 'start immediately at
    training_done' (redesign doc §6) -- valid config, no error flags."""
    await _measure_start_gap(dut, 0, "start_gap_0")
    wgt = await spi_read(dut, 0x1E)
    st = await spi_read(dut, 0x71)
    assert not (st & 0x20), \
        f"start_gap_0: REPLAY_MISSED set on a zero-margin replay (0x{st:02X})"
    assert not (wgt & 0x10), \
        f"start_gap_0: W_COMMIT_LATE set with no commit sent (0x{wgt:02X})"


@cocotb.test()
async def test_noise_mode_does_not_arm_replay(dut):
    """RPV-1: TACC_NOISE_TRIG fires training_done WITHOUT sc_lock; only the
    buf_base_valid gate keeps it from arming the replay margin wait. With
    PSRAM enabled and a small margin, a broken gate would show
    REPLAY_ACTIVE within ~32 samples of the noise window's end."""
    from cocotb.clock import Clock
    from test_noise_trig import _StimMode, _noise_or_cw_driver

    tag = "noise_no_arm"
    sf = 7
    clk_per_iq = 64
    sym_ns = (1 << (sf + 1)) * clk_per_iq * CLK_NS

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

    # Low-amplitude independent noise: default SC threshold -> no hits, no
    # lock, buf_base_valid never sets (same recipe as dbg_readback_content)
    mode = _StimMode()
    cocotb.start_soon(_noise_or_cw_driver(dut, mode, sigma=8.0))

    await spi_read(dut, 0x00)
    await spi_write(dut, 0x09, sf & 0x0F)
    await spi_write(dut, 0x0A, 0)
    await spi_write(dut, 0x77, 32)     # small margin: broken gate fails fast
    await spi_write(dut, 0x78, 0)

    await spi_write(dut, 0x70, 0x01)   # PSRAM up (delay line running)
    init_ok = False
    for _ in range(500):
        await Timer(8 * CLK_NS, unit="ns")
        if (await spi_read(dut, 0x71)) & 0x08:
            init_ok = True
            break
    assert init_ok, f"{tag}: PSRAM INIT_DONE never set"

    await spi_write(dut, 0x1F, 0x01)   # TACC_NOISE_TRIG (W1P)

    done_ok = False
    for _ in range(30):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x20)) & 0x01:   # TRAINING_STATUS.DONE
            done_ok = True
            break
    assert done_ok, f"{tag}: noise-mode training_done never fired"
    assert not ((await spi_read(dut, 0x02)) & 0x01), \
        f"{tag}: sc_lock fired on the noise stimulus -- test is vacuous"

    # Watch well past the 32-sample margin: replay must never arm
    for _ in range(8):
        await Timer(sym_ns, unit="ns")
        st = await spi_read(dut, 0x71)
        assert not (st & 0x10), \
            f"{tag}: REPLAY_ACTIVE set after a noise-mode training_done " \
            f"(0x{st:02X}) -- the buf_base_valid arm gate is broken"
    assert not (st & 0x20), \
        f"{tag}: REPLAY_MISSED latched with no packet at all (0x{st:02X})"
    dut._log.info(f"{tag}: PASS -- noise-mode training_done did not arm the "
                  f"replay margin wait (PSRAM_STATUS=0x{st:02X})")


@cocotb.test()
async def test_replay_delay_write_gate(dut):
    """RPV-4: 0x77/0x78 writes during an active packet are dropped (same
    !packet_active gate as SF_CFG/BW_CFG), and land again after the packet
    ends. The reset sweep covers reset values only, not the gating."""
    tag = "delay_wgate"
    sym_ns = await _reset_and_lock(dut, mode=0, ant_mask=0xF, tag=tag,
                                   pkt_timeout_syms=PKT_TIMEOUT_SYMS,
                                   replay_delay=32)

    assert (await spi_read(dut, 0x1C)) & 0x01, f"{tag}: no active packet"
    await spi_write(dut, 0x77, 0x55)
    await spi_write(dut, 0x78, 0x02)
    lo = await spi_read(dut, 0x77)
    hi = await spi_read(dut, 0x78)
    assert (lo, hi) == (32, 0), \
        f"{tag}: REPLAY_DELAY changed mid-packet (0x{hi:02X}{lo:02X}) -- " \
        f"!packet_active write-gate missing"
    dut._log.info(f"{tag}: mid-packet write correctly dropped")
