"""
test_sc_force_lock.py -- SC_FORCE_LOCK (0x19[0]) manual override regression.

Context: the SC correlator (sc_detector.v) has no firmware-triggerable way to
enter lock other than a genuine preamble hit. If the correlator itself were
found broken on silicon (not just a weak/faded antenna -- see the sc_ant_sel
mitigation for that, planning/Register Map.md 0x0A), there was previously no
way to exercise the downstream chain (packet_ctrl_fsm -> PSRAM -> combiner ->
IRQ) at all. SC_FORCE_LOCK is a W1P debug register that asserts sc_lock
directly from reg_bank, bypassing the correlator's hit-count logic.

It is NOT a mechanism to recover a real packet -- timing_ref on a forced lock
is the raw free-running sample_count, not a symbol-boundary-corrected value,
so any MRC training off it is not meaningful. It exists purely as a bring-up
/ catastrophic-failure escape hatch to prove the rest of the chain is alive.
This is also the register-only half of a design discussed for a future
sc_lock_in pin (see planning/NR2-multi-ASIC-cascade.md OR-lock scheme) --
deferred until a spare pad is available (planning/Pinout.md is at the 26-pad
budget today).

test_sc_force_lock_from_idle:
  From IDLE (no packet in progress), strobe SC_FORCE_LOCK and confirm
  SC_DBG_FLAGS.SC_LOCK (0x26[3]) and PACKET_STATUS.PACKET_ACTIVE/PACKET_PHASE
  (0x1C) both reflect a real sc_lock rising edge -- i.e. packet_ctrl_fsm
  actually transitions IDLE -> ST_PREAMBLE_ACQ off the forced signal exactly
  as it would off a real preamble hit.

test_sc_force_lock_blocked_during_packet:
  Force a lock, then attempt a second SC_FORCE_LOCK write while
  PACKET_ACTIVE=1 and confirm it is silently ignored (mirrors the SF_CFG/
  BW_CFG/PSRAM_EN packet_active write-gate pattern) -- a mid-packet force
  must not glitch packet_phase or re-latch timing_ref.

Runs under Verilator (see cocotb/sc_force_lock/Makefile).
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer

from test_trouper_top import CLK_NS, spi_read, spi_write


async def _reset(dut):
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


@cocotb.test()
async def test_sc_force_lock_from_idle(dut):
    await _reset(dut)

    status = await spi_read(dut, 0x1C)
    assert status & 0x01 == 0, f"expected IDLE (PACKET_ACTIVE=0), got 0x{status:02X}"
    dbg = await spi_read(dut, 0x26)
    assert (dbg >> 3) & 0x1 == 0, f"expected sc_lock=0 pre-force, got SC_DBG_FLAGS=0x{dbg:02X}"

    await spi_write(dut, 0x19, 0x01)   # SC_FORCE_LOCK strobe
    await Timer(20 * CLK_NS, unit="ns")

    dbg = await spi_read(dut, 0x26)
    assert (dbg >> 3) & 0x1 == 1, f"sc_lock never asserted after force, SC_DBG_FLAGS=0x{dbg:02X}"

    status = await spi_read(dut, 0x1C)
    assert status & 0x01 == 1, f"packet_ctrl_fsm did not see forced sc_lock, PACKET_STATUS=0x{status:02X}"
    phase = (status >> 1) & 0x7
    assert phase == 1, f"expected ST_PREAMBLE_ACQ (phase=1), got phase={phase} (PACKET_STATUS=0x{status:02X})"

    dut._log.info("SC_FORCE_LOCK: sc_lock + PACKET_ACTIVE/ST_PREAMBLE_ACQ confirmed")


@cocotb.test()
async def test_sc_force_lock_blocked_during_packet(dut):
    await _reset(dut)

    await spi_write(dut, 0x19, 0x01)   # force lock -> enters ST_PREAMBLE_ACQ
    await Timer(20 * CLK_NS, unit="ns")

    status = await spi_read(dut, 0x1C)
    assert status & 0x01 == 1, "setup: expected PACKET_ACTIVE=1 after first force"

    timing_before = []
    for a in (0x2C, 0x2D, 0x2E, 0x2F):
        timing_before.append(await spi_read(dut, a))

    # Second write while PACKET_ACTIVE=1 must be silently dropped (same gate
    # as SF_CFG/BW_CFG/PSRAM_EN) -- no re-latch of timing_ref, no phase glitch.
    await spi_write(dut, 0x19, 0x01)
    await Timer(20 * CLK_NS, unit="ns")

    timing_after = []
    for a in (0x2C, 0x2D, 0x2E, 0x2F):
        timing_after.append(await spi_read(dut, a))
    assert timing_before == timing_after, \
        f"SC_LOCK_SNAP changed on a blocked mid-packet force: {timing_before} -> {timing_after}"

    status = await spi_read(dut, 0x1C)
    phase = (status >> 1) & 0x7
    assert phase == 1, f"packet_phase glitched on blocked force: phase={phase}"

    dut._log.info("SC_FORCE_LOCK correctly blocked while PACKET_ACTIVE=1")
