"""
test_noise_trig.py -- firmware-triggered noise measurement, functional.

Traceability (planning/Traceability.md): TRPR-TAC-007 (primary: noise-trigger
MODE, not just the W1P bit mechanics), TRPR-TAC-008 (TRAINING_STATUS 0x20
readback over SPI -- previously internal-signal-only), TRPR-AGC-004
(TACC_NOISE_TRIG as the AGC noise-EMA source). First functional test of the
NOISE_READY IRQ (bit 4) and the sigma2_valid contamination gate in
trouper_top.

The software AGC / noise-EMA strategy rests on: write TACC_NOISE_TRIG (0x1F)
with no packet in flight -> training_acc arms WITHOUT sc_lock, accumulates a
fully-forward window (acc_start = now, unlike lock mode where the window
starts in the past at timing_ref) -> Zdiag_k ~= sigma_k^2 * n_acc,
Z_kl ~= 0 for independent per-antenna noise -> NOISE_READY fires only if no
SC activity contaminated the window.

Phase A (clean): PSRAM left DISABLED, so the SC detector has no delay line
and can produce no hits/lock -- contamination is impossible by construction.
Independent per-antenna Gaussian noise (per-antenna seeded RNG through a
first-order SDM). Checks: NOISE_READY IRQ fires; TRAINING_STATUS.DONE reads 1
over SPI; n_acc == 8*M exactly (forward window -- contrast with the 7*M-1 of
lock-mode training, see the 2026-07-06 sample_count fix); all four Zdiag > 0;
every |Z_kl| / sqrt(Zdiag_k * Zdiag_l) is small (independent noise
decorrelates as ~1/sqrt(n) ~= 0.02; threshold 0.2).

Phase B (contaminated): PSRAM enabled, driver switched to the strong CW
preamble stimulus -> SC hits (and lock) land inside a freshly-triggered noise
window -> training_done still fires (accumulation is unconditional) but
NOISE_READY must NOT: trouper_top's noise-window monitor latches
sc_hit_dbg/sc_lock into noise_window_sc_seen and suppresses sigma2_valid.
"""

import math
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from test_trouper_top import CLK_NS, spi_read, spi_write, release_rx_hold
from test_bypass_e2e import _reset_and_lock


class _StimMode:
    """Shared switch so the driver can be flipped noise -> CW mid-test."""
    def __init__(self):
        self.cw = False


async def _noise_or_cw_driver(dut, mode, sigma=10.0, cw_amp=31, seed=1234):
    """Per-antenna independent Gaussian noise targets (mode.cw=False) or the
    standard identical CW preamble stimulus (mode.cw=True), each through a
    per-antenna first-order SDM. Noise target held per iq-sample period."""
    clk_per_iq = 64
    P = 8
    rngs = [random.Random(seed + a) for a in range(4)]
    cw_i = [round(cw_amp * math.cos(2 * math.pi * k / P)) for k in range(P)]
    cw_q = [round(cw_amp * math.sin(2 * math.pi * k / P)) for k in range(P)]

    acc_i = [0] * 4
    acc_q = [0] * 4
    tgt_i = [0] * 4
    tgt_q = [0] * 4
    sine_ptr = 0
    bit_cnt = 0

    def new_targets():
        for a in range(4):
            if mode.cw:
                tgt_i[a] = cw_i[sine_ptr]
                tgt_q[a] = cw_q[sine_ptr]
            else:
                tgt_i[a] = max(-100, min(100, round(rngs[a].gauss(0, sigma))))
                tgt_q[a] = max(-100, min(100, round(rngs[a].gauss(0, sigma))))

    new_targets()
    while True:
        await RisingEdge(dut.IQ_CLK)
        bits_i = 0
        bits_q = 0
        for a in range(4):
            if acc_i[a] >= 0:
                bits_i |= 1 << a
                acc_i[a] += tgt_i[a] - 127
            else:
                acc_i[a] += tgt_i[a] + 127
            if acc_q[a] >= 0:
                bits_q |= 1 << a
                acc_q[a] += tgt_q[a] - 127
            else:
                acc_q[a] += tgt_q[a] + 127
        dut.IQ_DATA_I.value = bits_i
        dut.IQ_DATA_Q.value = bits_q
        bit_cnt += 1
        if bit_cnt >= clk_per_iq:
            bit_cnt = 0
            sine_ptr = (sine_ptr + 1) % P
            new_targets()


async def _read_s24(dut, base):
    """3-byte big-endian signed read (Z registers expose bits [31:8])."""
    v = 0
    for i in range(3):
        v = (v << 8) | (await spi_read(dut, base + i))
    if v & 0x800000:
        v -= 1 << 24
    return v


async def _read_u24(dut, base):
    v = 0
    for i in range(3):
        v = (v << 8) | (await spi_read(dut, base + i))
    return v


@cocotb.test()
async def test_noise_trig_functional(dut):
    tag = "noise_trig"
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

    mode = _StimMode()
    cocotb.start_soon(_noise_or_cw_driver(dut, mode))

    # SPI settle
    await spi_read(dut, 0x00)
    await spi_read(dut, 0x09)

    await spi_write(dut, 0x09, sf & 0x0F)
    await spi_write(dut, 0x0A, 0)      # 250 kHz
    await spi_write(dut, 0x0C, 0x01)   # low SC threshold (phase B wants hits)
    await spi_write(dut, 0x0D, 0x00)
    await spi_write(dut, 0x0E, 0x00)
    await release_rx_hold(dut)

    # Let the decimator/DC-removal transient die out
    await Timer(4 * sym_ns, unit="ns")

    # =========================================================================
    # Phase A: clean noise window. PSRAM stays DISABLED -> the SC detector has
    # no delay line, so no hit/lock can contaminate the window by construction.
    # =========================================================================
    ts = await spi_read(dut, 0x20)
    assert ts == 0x00, f"{tag}: TRAINING_STATUS=0x{ts:02X} before any trigger"

    await spi_write(dut, 0x1F, 0x01)   # TACC_NOISE_TRIG (W1P)

    armed_seen = False
    ready = False
    for _ in range(20):
        await Timer(sym_ns, unit="ns")
        ts = await spi_read(dut, 0x20)
        if ts & 0x02:
            armed_seen = True
        irq = await spi_read(dut, 0x02)
        if irq & 0x10:                 # NOISE_READY
            ready = True
            break
    assert ready, f"{tag}: NOISE_READY IRQ never fired for a clean noise window"
    assert irq & 0x02, f"{tag}: TRAINING_DONE IRQ missing alongside NOISE_READY (0x{irq:02X})"
    assert not (irq & 0x01), f"{tag}: sc_lock IRQ set with PSRAM disabled?! (0x{irq:02X})"

    # TRPR-TAC-008: TRAINING_STATUS over SPI (previously internal-only)
    ts = await spi_read(dut, 0x20)
    assert ts & 0x01, f"{tag}: TRAINING_STATUS.DONE not set (0x{ts:02X})"
    assert armed_seen, f"{tag}: TRAINING_STATUS.ARMED never observed high during the window"

    # n_acc: noise-mode window is fully forward (acc_start = trigger time), so
    # unlike lock-mode training (7*M-1, see test_trouper_top.py) it must be
    # exactly the full 8-symbol span.
    n_hi  = await spi_read(dut, 0x21)
    n_mid = await spi_read(dut, 0x22)
    n_lo  = await spi_read(dut, 0x23)
    n_acc = ((n_hi & 0x03) << 16) | (n_mid << 8) | n_lo
    assert abs(n_acc - 8 * M) <= 2, f"{tag}: n_acc={n_acc}, expected 8*M={8*M} (forward window)"

    # Zdiag_k = sum |x_k|^2 > 0 for all four branches
    zdiag = [await _read_u24(dut, 0x64 + 3 * k) for k in range(4)]
    for k, z in enumerate(zdiag):
        assert z > 0, f"{tag}: Zdiag_{k}=0 -- branch {k} accumulated nothing"

    # Z_kl ~= 0 for independent per-antenna noise: normalized cross-correlation
    # |Z_kl| / sqrt(Zdiag_k*Zdiag_l) decorrelates as ~1/sqrt(n_acc) ~= 0.02.
    pair_ants = [(0, 1), (0, 2), (0, 3), (1, 2), (1, 3), (2, 3)]
    worst = 0.0
    for p, (k, l) in enumerate(pair_ants):
        zi = await _read_s24(dut, 0x40 + 6 * p)
        zq = await _read_s24(dut, 0x40 + 6 * p + 3)
        rho = math.hypot(zi, zq) / math.sqrt(zdiag[k] * zdiag[l])
        worst = max(worst, rho)
        assert rho < 0.2, \
            f"{tag}: |Z_{k}{l}|/sqrt(Zd_{k}*Zd_{l}) = {rho:.3f} -- independent noise " \
            f"branches should be uncorrelated (Z_kl ~= 0)"
    dut._log.info(f"{tag}: phase A clean OK -- n_acc={n_acc} zdiag={zdiag} "
                  f"worst |rho|={worst:.3f}")

    await spi_write(dut, 0x03, 0xFF)   # clear IRQs

    # =========================================================================
    # Phase B: contaminated window. PSRAM up, driver -> strong CW: SC hits and
    # lock land inside the freshly-triggered window -> NOISE_READY suppressed.
    # =========================================================================
    await spi_write(dut, 0x70, 0x01)
    init_ok = False
    for _ in range(500):
        await Timer(8 * CLK_NS, unit="ns")
        if (await spi_read(dut, 0x71)) & 0x08:
            init_ok = True
            break
    assert init_ok, f"{tag}: PSRAM INIT_DONE never set"

    mode.cw = True
    await spi_write(dut, 0x1F, 0x01)   # trigger while the CW ramps into the SC path

    lock_seen = False
    train_seen = False
    for _ in range(25):
        await Timer(sym_ns, unit="ns")
        irq = await spi_read(dut, 0x02)
        lock_seen  = lock_seen  or bool(irq & 0x01)
        train_seen = train_seen or bool(irq & 0x02)
        assert not (irq & 0x10), \
            f"{tag}: NOISE_READY fired (0x{irq:02X}) despite SC activity inside the " \
            f"noise window -- contamination gate broken"
        if lock_seen and train_seen:
            break
    assert lock_seen, f"{tag}: CW stimulus never produced sc_lock in phase B " \
                      f"(contamination case not actually exercised)"
    assert train_seen, f"{tag}: training_done never fired in phase B"

    # A few more symbols of margin: NOISE_READY must stay clear
    for _ in range(5):
        await Timer(sym_ns, unit="ns")
        irq = await spi_read(dut, 0x02)
        assert not (irq & 0x10), \
            f"{tag}: NOISE_READY fired late (0x{irq:02X}) after contaminated window"

    dut._log.info(f"{tag}: PASS -- clean window measured (NOISE_READY + Zdiag/Z_kl sane), "
                  f"contaminated window suppressed")


@cocotb.test()
async def test_noise_trig_rejected_during_live_training(dut):
    """A busy normal-training window must reject, not mislabel, a noise request.

    Before the fix, the top-level noise qualifier opened a window on every
    TACC_NOISE_TRIG, while training_acc ignored a trigger if already armed.
    The normal training_done could therefore be misreported as NOISE_READY.
    """
    tag = "noise_trig_live_reject"
    sym_ns = await _reset_and_lock(dut, mode=0, ant_mask=0xF, tag=tag,
                                   pkt_timeout_syms=20, replay_delay=600)

    assert int(dut.u_dut.training_armed.value) == 1, \
        f"{tag}: normal training was not armed after sc_lock"
    await spi_write(dut, 0x1F, 0x01)

    # 0x1F[1] is a sticky, W1C rejection acknowledgement.  It means the
    # firmware cannot mistake a dropped W1P request for an accepted window.
    rejected = False
    for _ in range(8):
        await Timer(8 * CLK_NS, unit="ns")
        if (await spi_read(dut, 0x1F)) & 0x02:
            rejected = True
            break
    assert rejected, f"{tag}: busy TACC_NOISE_TRIG was not reported rejected"

    # The original training window still completes, but its TRAINING_DONE is
    # never promoted into NOISE_READY by the rejected request.
    done = False
    for _ in range(40):
        await Timer(sym_ns, unit="ns")
        irq = await spi_read(dut, 0x02)
        assert not (irq & 0x10), \
            f"{tag}: false NOISE_READY after rejected trigger (IRQ=0x{irq:02X})"
        if irq & 0x02:
            done = True
            break
    assert done, f"{tag}: original live training did not complete"

    await spi_write(dut, 0x1F, 0x02)  # W1C clear NOISE_TRIG_REJECTED
    assert not ((await spi_read(dut, 0x1F)) & 0x02), \
        f"{tag}: NOISE_TRIG_REJECTED did not clear W1C"
    dut._log.info(f"{tag}: PASS -- busy trigger rejected, normal training completed, "
                  "and NOISE_READY stayed clear")


@cocotb.test()
async def test_noise_trig_rejected_after_training_during_active_packet(dut):
    """An idle-only noise request cannot overwrite a completed packet's Z data.

    This is deliberately distinct from the early live-training test above:
    normal training has completed and its Z snapshot is now firmware-visible,
    but packet_active remains high during replay/payload. The implementation
    keeps TRAINING_ARMED high until packet completion, and the explicit
    packet-active interlock protects this same boundary against a future
    training-lifetime change.
    """
    tag = "noise_trig_packet_reject"
    sym_ns = await _reset_and_lock(dut, mode=0, ant_mask=0xF, tag=tag,
                                   pkt_timeout_syms=24, replay_delay=600)

    done = False
    for _ in range(24):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x02:
            done = True
            break
    assert done, f"{tag}: normal training did not complete"
    assert int(dut.u_dut.packet_active.value) == 1, f"{tag}: packet ended before test"
    assert int(dut.u_dut.training_armed.value) == 1, f"{tag}: training unexpectedly disarmed"

    z_before = await _read_u24(dut, 0x64)
    await spi_write(dut, 0x1F, 0x01)

    rejected = False
    for _ in range(8):
        await Timer(8 * CLK_NS, unit="ns")
        if (await spi_read(dut, 0x1F)) & 0x02:
            rejected = True
            break
    assert rejected, f"{tag}: active-packet TACC_NOISE_TRIG was not rejected"
    assert int(dut.u_dut.training_armed.value) == 1, f"{tag}: rejected trigger altered training state"
    assert await _read_u24(dut, 0x64) == z_before, f"{tag}: rejected trigger overwrote Zdiag"
    assert not ((await spi_read(dut, 0x02)) & 0x10), f"{tag}: rejected trigger raised NOISE_READY"
    dut._log.info(f"{tag}: PASS -- active-packet trigger rejected after normal training")
