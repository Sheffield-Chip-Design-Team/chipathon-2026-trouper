"""
test_qspi_owner.py -- QSPI_OWNER pad handover (TRPR-PSR-010 / TRPR-PSR-011).

Traceability (planning/Traceability.md): TRPR-PSR-010 (owner=1 releases
CE#/SCK/SIO and suspends buffering/replay), TRPR-PSR-011 (no pad glitch on a
mid-BUFFERING/mid-REPLAY owner write; effect deferred to the QPI burst
boundary). TRPR-PSR-012 was REMOVED from the spec 2026-07-06 (no
PAD_CONFLICT signal exists and no second on-chip driver can conflict).

Regresses two RTL fixes made 2026-07-06 when this test was written:
  1. `sck_en` was gated by the RAW qspi_owner -- an ownership request landing
     mid-burst froze SCK immediately while CE# stayed low and SIO kept
     driving for the rest of the internally-stepping burst (up to ~40
     cycles): exactly the pad glitch PSR-011 prohibits. Fixed with
     `qspi_owner_eff`, latched only between bursts, so an in-flight
     transaction completes with its clock running.
  2. S_REPLAY's burst-launch had no `!qspi_owner` gate at all (S_WRITE's
     did) -- an owner request during REPLAY never suspended the replay
     bursts. Gate added.

The pad-safety invariant checked EVERY clock through every handover window:

    CE# low  =>  sck_en high        (a selected device is always clocked)

plus quiescence (CE# high, SIO_OE=0, sck_en=0, and staying that way) within
a bounded window after the owner write, resumption of bursts after owner
returns to 0, and DBG_BUSY held while owner=1.

The mid-burst timing is not left to luck: with the noise driver there is a
capture burst every 64-clock sample period (~44/64 duty), and the owner
write's final SPI edge lands at an uncontrolled phase -- repeated across
the buffering and replay handovers this exercises the deferral path; the
invariant itself is phase-independent either way.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from test_trouper_top import CLK_NS, spi_read, spi_write
from test_noise_trig import _StimMode, _noise_or_cw_driver

QUIESCE_CLKS = 128    # burst is 44 clks; owner must fully release well within this
HOLD_CLKS    = 256    # released pads must stay released this long


async def _pads(dut):
    return (int(dut.psram_ce_n.value),
            int(dut.psram_sio_oe.value),
            int(dut.u_dut.u_psram.sck_en.value))


async def _check_handover_and_release(dut, tag):
    """After an owner=1 SPI write: per-clock CE#-implies-clock invariant,
    quiescence within QUIESCE_CLKS, and no re-activation for HOLD_CLKS."""
    quiesced_at = None
    for n in range(QUIESCE_CLKS + HOLD_CLKS):
        await RisingEdge(dut.IQ_CLK)
        ce_n, oe, sck_en = await _pads(dut)
        assert not (ce_n == 0 and sck_en == 0), \
            f"{tag}: CE# low with SCK gated at clk {n} -- selected device left " \
            f"unclocked mid-transaction (the PSR-011 glitch)"
        idle = (ce_n == 1 and oe == 0 and sck_en == 0)
        if quiesced_at is None:
            if idle:
                quiesced_at = n
            else:
                assert n < QUIESCE_CLKS, \
                    f"{tag}: pads not released within {QUIESCE_CLKS} clks of the " \
                    f"owner write (ce_n={ce_n} oe=0x{oe:X} sck_en={sck_en})"
        else:
            assert idle, \
                f"{tag}: pads re-activated at clk {n} after quiescing at " \
                f"{quiesced_at} (ce_n={ce_n} oe=0x{oe:X} sck_en={sck_en}) -- " \
                f"owner=1 must keep the local controller off the bus"
    dut._log.info(f"{tag}: released cleanly at clk {quiesced_at}, held for {HOLD_CLKS}")


async def _check_activity_resumes(dut, tag, window=512):
    """After owner returns to 0, capture/replay bursts must restart."""
    for n in range(window):
        await RisingEdge(dut.IQ_CLK)
        ce_n, _, sck_en = await _pads(dut)
        assert not (ce_n == 0 and sck_en == 0), \
            f"{tag}: CE# low with SCK gated during resume at clk {n}"
        if ce_n == 0:
            dut._log.info(f"{tag}: bursts resumed at clk {n}")
            return
    assert False, f"{tag}: no QPI activity within {window} clks of owner=0"


@cocotb.test()
async def test_qspi_owner_handover(dut):
    tag = "qspi_owner"
    sf, bw_khz = 7, 250
    sample_shift = 1
    M = 1 << (sf + sample_shift)
    clk_per_iq = 64
    sym_ns = M * clk_per_iq * CLK_NS

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

    mode = _StimMode()   # noise first (no packets), CW later for the replay phase
    cocotb.start_soon(_noise_or_cw_driver(dut, mode, sigma=8.0))

    await spi_read(dut, 0x00)
    await spi_read(dut, 0x09)
    await spi_write(dut, 0x09, sf & 0x0F)
    await spi_write(dut, 0x0A, 0)
    await spi_write(dut, 0x0C, 0x01)
    await spi_write(dut, 0x0D, 0x00)
    await spi_write(dut, 0x0E, 0x00)

    # Small replay margin so REPLAY_ACTIVE lands inside the phase-3 polling
    # window (replay starts at training_done + REPLAY_DELAY_SAMPLES now, not
    # at W_COMMIT; the silicon default is ~1500 samples)
    await spi_write(dut, 0x77, 32)
    await spi_write(dut, 0x78, 0)

    await spi_write(dut, 0x70, 0x01)
    init_ok = False
    for _ in range(500):
        await Timer(8 * CLK_NS, unit="ns")
        if (await spi_read(dut, 0x71)) & 0x08:
            init_ok = True
            break
    assert init_ok, f"{tag}: PSRAM INIT_DONE never set"

    # Buffering free-runs; sanity: bursts happening
    await _check_activity_resumes(dut, f"{tag}/baseline")

    # =========================================================================
    # Phase 1+2: owner=1 during BUFFERING (PSR-010 + PSR-011 write path),
    # DBG_BUSY held, then owner=0 -> buffering resumes.
    # =========================================================================
    await spi_write(dut, 0x70, 0x09)   # PSRAM_EN | QSPI_OWNER
    await _check_handover_and_release(dut, f"{tag}/buffering-handover")

    dbg = await spi_read(dut, 0x75)
    assert dbg & 0x80, f"{tag}: DBG_BUSY not held while QSPI_OWNER=1 (0x{dbg:02X})"

    await spi_write(dut, 0x70, 0x01)   # release ownership
    await _check_activity_resumes(dut, f"{tag}/buffering-resume")

    # =========================================================================
    # Phase 3: owner=1 during REPLAY (regresses the missing S_REPLAY gate).
    # CW stimulus -> lock -> training -> commit -> REPLAY_ACTIVE, then handover.
    # =========================================================================
    mode.cw = True
    lock_ok = False
    for _ in range(25):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x01:
            lock_ok = True
            break
    assert lock_ok, f"{tag}: sc_lock never fired for the replay phase"

    train_ok = False
    for _ in range(40):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x02:
            train_ok = True
            break
    assert train_ok, f"{tag}: training_done never fired"

    await spi_write(dut, 0x1E, 0x01)   # W_COMMIT
    replay_ok = False
    for _ in range(200):
        await Timer(64 * CLK_NS, unit="ns")
        if (await spi_read(dut, 0x71)) & 0x10:
            replay_ok = True
            break
    assert replay_ok, f"{tag}: REPLAY never became active"

    await spi_write(dut, 0x70, 0x09)   # owner=1 mid-REPLAY
    await _check_handover_and_release(dut, f"{tag}/replay-handover")

    # Release: replay bursts must resume (packet still active, replay pending)
    await spi_write(dut, 0x70, 0x01)
    await _check_activity_resumes(dut, f"{tag}/replay-resume")

    dut._log.info(f"{tag}: PASS -- buffering + replay handovers glitch-free, "
                  f"pads released and reclaimed, DBG_BUSY held under owner=1")
