"""
test_sc_dbg_flags.py -- SC debug/telemetry register readback regression.

Traceability (planning/Traceability.md): TRPR-SCD-010 (primary: SC_DBG_FLAGS
0x26, SC_FIRST_HIT 0x28-0x2B, SC_LOCK_SNAP 0x2C-0x2F), TRPR-SCD-009 (SC_STAT
0x24-0x25 telemetry nonzero).

Regresses the 2026-07-06 status-readback fix: SC_DBG_FLAGS[0] `SC_HIT` was
wired from sc_detector's `sc_hit_dbg`, a 1-cycle pulse (high one clock out of
~16k per symbol -- its internal consumer is the noise-window contamination
latch in trouper_top, where pulse semantics are correct). Read combinationally
over SPI it was firmware-invisible: always 0. Fixed by adding `sc_hit_hold` in
sc_detector.v -- the most recent symbol evaluation's hit decision, held until
the next evaluation, cleared on reset/sc_clr -- and wiring THAT to reg_bank.
Same class of bug as the W_MISSED_PACKET readback fix (see
test_w_missed_packet.py).

Uses SC_HITS_REQ=1 (two consecutive hits to lock) rather than the usual 0, so
SC_FIRST_HIT and SC_LOCK_SNAP latch two DIFFERENT symbol marks exactly M
samples apart -- a strong check of both snapshots' semantics. (With
SC_HITS_REQ=0 the first hit locks immediately and SC_FIRST_HIT reads the
not-yet-latched previous value -- a known quirk of the 1-hit debug config,
not exercised here.)

Checks:
  1. Baseline before PSRAM init (SC has no delay line, so no symbol
     evaluations can have happened): 0x24-0x26 and 0x28-0x2F all read 0.
  2. After sc_lock: SC_DBG_FLAGS = SC_LOCK(bit3) | hit_count==1(bits2:1) |
     SC_HIT(bit0, held from the locking evaluation -- reads 1 only with the
     sc_hit_hold fix); SC_STAT nonzero (frozen at the last pre-lock symbol's
     |C|^2 telemetry); SC_FIRST_HIT > 0; SC_LOCK_SNAP == SC_FIRST_HIT + M.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer

from test_trouper_top import CLK_NS, spi_read, spi_write, sdm_driver


async def _read_be32(dut, base):
    v = 0
    for i in range(4):
        v = (v << 8) | (await spi_read(dut, base + i))
    return v


@cocotb.test()
async def test_sc_dbg_flags_readback(dut):
    tag = "sc_dbg"
    sf, bw_khz = 7, 250
    sample_shift = 1
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

    # SPI settle
    await spi_read(dut, 0x00)
    await spi_read(dut, 0x09)

    await spi_write(dut, 0x09, sf & 0x0F)
    await spi_write(dut, 0x0A, 0)      # 250 kHz
    await spi_write(dut, 0x0C, 0x01)   # SC_THR = 0x01CC-ish low threshold
    await spi_write(dut, 0x0D, 0x00)
    await spi_write(dut, 0x0E, 0x01)   # SC_HITS_REQ=1 -> 2 consecutive hits

    # -- 1. baseline: PSRAM still disabled -> no delay line -> no evals yet --
    for addr, name in ((0x24, "SC_STAT_HI"), (0x25, "SC_STAT_LO"),
                       (0x26, "SC_DBG_FLAGS")):
        v = await spi_read(dut, addr)
        assert v == 0, f"{tag}: {name} (0x{addr:02X}) = 0x{v:02X} before any evaluation"
    for base, name in ((0x28, "SC_FIRST_HIT"), (0x2C, "SC_LOCK_SNAP")):
        v = await _read_be32(dut, base)
        assert v == 0, f"{tag}: {name} = {v} before any evaluation"
    dut._log.info(f"{tag}: pre-init baseline all-zero OK")

    # -- bring up PSRAM (SC delay line), then lock ---------------------------
    await spi_write(dut, 0x70, 0x01)
    init_ok = False
    for _ in range(500):
        await Timer(8 * CLK_NS, unit="ns")
        if (await spi_read(dut, 0x71)) & 0x08:
            init_ok = True
            break
    assert init_ok, f"{tag}: PSRAM INIT_DONE never set"

    sym_ns = M * clk_per_iq * CLK_NS
    lock_ok = False
    for _ in range(25):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x01:
            lock_ok = True
            break
    assert lock_ok, f"{tag}: sc_lock never fired"

    # -- 2. post-lock readback (evaluations stop at lock, values are stable) --
    flags = await spi_read(dut, 0x26)
    assert flags & 0x08, f"{tag}: SC_DBG_FLAGS.SC_LOCK clear after lock (0x{flags:02X})"
    assert flags & 0x01, \
        f"{tag}: SC_DBG_FLAGS.SC_HIT reads 0 after a locking hit (0x{flags:02X}) -- " \
        f"the held sc_hit_hold readback is broken (pulse-wired again?)"
    hit_cnt = (flags >> 1) & 0x3
    assert hit_cnt == 1, \
        f"{tag}: SC_DBG_FLAGS hit counter = {hit_cnt}, expected 1 (hit_count at the " \
        f"locking evaluation with SC_HITS_REQ=1)"

    sc_stat = ((await spi_read(dut, 0x24)) << 8) | (await spi_read(dut, 0x25))
    assert sc_stat != 0, \
        f"{tag}: SC_STAT reads 0 after lock -- |C|^2 telemetry not reaching 0x24-0x25"

    first_hit = await _read_be32(dut, 0x28)
    lock_snap = await _read_be32(dut, 0x2C)
    assert first_hit > 0, f"{tag}: SC_FIRST_HIT = 0 after lock"
    assert lock_snap == first_hit + M, \
        f"{tag}: SC_LOCK_SNAP ({lock_snap}) != SC_FIRST_HIT ({first_hit}) + M ({M}) -- " \
        f"two consecutive hits must be exactly one symbol apart"
    dut._log.info(f"{tag}: PASS -- flags=0x{flags:02X} sc_stat=0x{sc_stat:04X} "
                  f"first_hit={first_hit} lock_snap={lock_snap} (delta={lock_snap-first_hit})")


@cocotb.test()
async def test_low_energy_hit_suppression(dut):
    """TRPR-SCD-016 negative case: at a sub-guard input amplitude, no SC hit
    may ever fire. The divider-free ratio test |C|^2 >= THR*E is
    amplitude-independent for a periodic input, so without the e_slice guard
    (eval_e_acc[25:13] == 0 suppresses the hit) a tiny CW would still lock;
    this drives CW at amplitude 1 (energy slice ~= A^2*256/1024 = 0.25 -> 0,
    vs 240 at the standard A=31) and asserts zero hits across 15 symbols --
    using the held SC_HIT readback (sc_hit_hold) so a hit at ANY evaluated
    symbol would be caught, not just one racing a poll."""
    from test_noise_trig import _StimMode, _noise_or_cw_driver

    tag = "e_slice_neg"
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
    mode.cw = True
    cocotb.start_soon(_noise_or_cw_driver(dut, mode, cw_amp=1))  # sub-guard CW

    await spi_read(dut, 0x00)
    await spi_read(dut, 0x09)
    await spi_write(dut, 0x09, sf & 0x0F)
    await spi_write(dut, 0x0A, 0)
    await spi_write(dut, 0x0C, 0x01)   # same permissive threshold every lock test uses
    await spi_write(dut, 0x0D, 0x00)
    await spi_write(dut, 0x0E, 0x00)   # 1 hit would lock -- strictest setting

    await spi_write(dut, 0x70, 0x01)
    init_ok = False
    for _ in range(500):
        await Timer(8 * CLK_NS, unit="ns")
        if (await spi_read(dut, 0x71)) & 0x08:
            init_ok = True
            break
    assert init_ok, f"{tag}: PSRAM INIT_DONE never set"

    # 15 symbols of evaluations at sub-guard amplitude: zero hits, zero lock
    for n in range(15):
        await Timer(sym_ns, unit="ns")
        irq = await spi_read(dut, 0x02)
        assert not (irq & 0x01), \
            f"{tag}: sc_lock fired at symbol {n} on an amplitude-1 input -- " \
            f"e_slice guard failed to suppress a sub-energy hit"
        flags = await spi_read(dut, 0x26)
        assert not (flags & 0x01), \
            f"{tag}: SC_HIT held bit set at symbol {n} (flags=0x{flags:02X}) -- " \
            f"a low-energy evaluation produced a hit"
    dut._log.info(f"{tag}: PASS -- 15 symbols at amplitude 1, zero hits, no lock")
