"""
test_dbg_write.py -- PSRAM debug WRITE port (0x79 PSRAM_DBG_WDATA + 0x75[2]
WR_TRIG).  Mirror of the 0x72-0x76 debug read path, added so first silicon
can write-verify the PSRAM / QPI PHY / PCB without a live capture stream
(marching / address-in-payload bus-fault patterns) -- see
planning/Register Map.md "0x72-0x76, 0x79 -- PSRAM Debug Access Registers".

All tests use the low-amplitude independent-noise recipe from
test_dbg_readback_content: nonzero stored samples but no SC hits -> no lock
-> packet_active stays 0, so the debug engine is unblocked for the whole
test.  Target addresses sit at 4 MiB (halfway into the 8 MB device), far
beyond the circular-capture write pointer's reach inside a test horizon of
a few hundred samples, so a committed line is never overwritten before it
is read back.

test_dbg_write_roundtrip:
  Commit one 8-byte line via 8 single-byte writes to 0x79 + WR_TRIG, poll
  DBG_BUSY, then check it BOTH ways: bit-exact against the behavioural
  psram_model's stored nibbles, and through the debug READ path (RD_TRIG ->
  0x76 x8) at the same address.  This is the "is the memory alive" probe
  the read-only path cannot do -- it has a known ground truth.

test_dbg_write_burst_no_autoinc:
  Fill the shadow with a single SPI burst frame (command byte 0x79 + 8
  data bytes, CS held low).  0x79 is burst-exempt, so all 8 bytes must
  land as pushes at the same port -- without that exemption they would
  scatter across 0x79..0x80.  Verified by read-back.

test_dbg_write_address_in_payload:
  Write several consecutive lines whose payload encodes their own byte
  address, then read every line back.  A dropped/swapped address bit or an
  off-by-8 in the commit path shows up as a line reading back another
  line's address stamp.

test_dbg_write_blocked_by_qspi_owner:
  With QSPI_OWNER=1 (0x70[3]) DBG_BUSY is held and WR_TRIG must not reach
  the bus: the target line stays at its pre-commit value.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from test_trouper_top import (CLK_NS, spi_read, spi_write, spi_burst_write,
                              release_rx_hold)
from test_noise_trig import _StimMode, _noise_or_cw_driver
from test_psram_ops import _model_byte

WR_TRIG   = 0x04   # PSRAM_DBG_CTRL[2]
RD_TRIG   = 0x01   # PSRAM_DBG_CTRL[0]
DBG_BUSY  = 0x80   # PSRAM_DBG_CTRL[7]
# 0x8000 (32 KiB): comfortably past the circular-capture write pointer's reach
# inside a test horizon of a few hundred samples (~few KB from wr_ptr=0), and
# inside the behavioural psram_model's 64 KiB nibble memory so _model_byte()
# can cross-check.  The highest address any test touches is BASE + 0x3000 + 8*N.
BASE      = 0x8000


async def _bringup(dut, tag, sf=7):
    """Reset, start the noise driver, enable + init PSRAM.  Returns nothing;
    leaves the DUT idle with DBG_BUSY clear."""
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
    cocotb.start_soon(_noise_or_cw_driver(dut, mode, sigma=8.0))

    await spi_read(dut, 0x00)
    await spi_write(dut, 0x09, sf & 0x0F)
    await spi_write(dut, 0x0A, 0)
    await release_rx_hold(dut)

    await spi_write(dut, 0x70, 0x01)   # PSRAM_EN
    for _ in range(500):
        await Timer(8 * CLK_NS, unit="ns")
        if (await spi_read(dut, 0x71)) & 0x08:   # INIT_DONE
            break
    else:
        assert False, f"{tag}: PSRAM INIT_DONE never set"


async def _set_dbg_addr(dut, byte_addr):
    await spi_write(dut, 0x72, byte_addr & 0xFF)
    await spi_write(dut, 0x73, (byte_addr >> 8) & 0xFF)
    await spi_write(dut, 0x74, (byte_addr >> 16) & 0x7F)


async def _poll_not_busy(dut, tag, what):
    for _ in range(200):
        if not ((await spi_read(dut, 0x75)) & DBG_BUSY):
            return
    assert False, f"{tag}: DBG_BUSY never cleared after {what}"


async def _dbg_write_line(dut, tag, byte_addr, payload):
    """Full host commit sequence for one 8-byte line."""
    assert len(payload) == 8
    await _set_dbg_addr(dut, byte_addr)
    for b in payload:
        await spi_write(dut, 0x79, b)
    await spi_write(dut, 0x75, WR_TRIG)
    await _poll_not_busy(dut, tag, "WR_TRIG")


async def _dbg_read_line(dut, tag, byte_addr):
    await _set_dbg_addr(dut, byte_addr)
    await spi_write(dut, 0x75, RD_TRIG)
    await _poll_not_busy(dut, tag, "RD_TRIG")
    return [await spi_read(dut, 0x76) for _ in range(8)]


async def _grp_write(dut, addr, data):
    """One Grouper-register write with the bridge's six-IQ-clock hold time."""
    dut.GRP_ADDR.value = addr
    dut.GRP_WDATA.value = data
    dut.GRP_WE.value = 1
    for _ in range(6):
        await RisingEdge(dut.IQ_CLK)
    dut.GRP_WE.value = 0
    await RisingEdge(dut.IQ_CLK)


async def _grp_read(dut, addr):
    """One Grouper-register read with the bridge's six-IQ-clock hold time."""
    dut.GRP_ADDR.value = addr
    dut.GRP_RE.value = 1
    for _ in range(6):
        await RisingEdge(dut.IQ_CLK)
    value = int(dut.GRP_RDATA.value)
    dut.GRP_RE.value = 0
    await RisingEdge(dut.IQ_CLK)
    return value


async def _grp_set_dbg_addr(dut, byte_addr):
    await _grp_write(dut, 0x72, byte_addr & 0xFF)
    await _grp_write(dut, 0x73, (byte_addr >> 8) & 0xFF)
    await _grp_write(dut, 0x74, (byte_addr >> 16) & 0x7F)


async def _grp_poll_not_busy(dut, tag, what):
    for _ in range(200):
        if not ((await _grp_read(dut, 0x75)) & DBG_BUSY):
            return
    assert False, f"{tag}: DBG_BUSY never cleared after {what}"


@cocotb.test()
async def test_dbg_write_roundtrip(dut):
    tag = "dbg_wr_roundtrip"
    await _bringup(dut, tag)

    payload = [0xA5, 0x5A, 0x00, 0xFF, 0x12, 0x34, 0x56, 0x78]
    await _dbg_write_line(dut, tag, BASE, payload)

    # (a) bit-exact vs the behavioural model's stored nibbles
    stored = [await _model_byte(dut, BASE + i) for i in range(8)]
    assert stored == payload, \
        f"{tag}: model storage {stored} != committed {payload} -- debug QPI " \
        f"write path put the wrong bytes on the bus"

    # (b) round-trip through the debug READ path at the same address
    got = await _dbg_read_line(dut, tag, BASE)
    assert got == payload, \
        f"{tag}: read-back {got} != committed {payload} -- write/read debug " \
        f"paths disagree"

    dut._log.info(f"{tag}: PASS -- committed {payload}, model + read-back both match")


@cocotb.test()
async def test_dbg_write_read_from_grouper_ram(dut):
    """Grouper-side debug write/read round trip.

    ``grouper_ram`` models a firmware-resident byte buffer: each byte travels
    over the GRP register bus to 0x79, is committed to PSRAM, then is read
    back over that same bus through 0x76.  The six-cycle holds match the
    production AHB-to-GRP bridge, so this also guards against turning one
    held transaction into six debug pushes/pops.
    """
    tag = "dbg_wr_grp_ram"
    await _bringup(dut, tag)

    addr = BASE + 0x0800
    grouper_ram = [0x47, 0x52, 0x50, 0x2D, 0x52, 0x41, 0x4D, 0x21]

    await _grp_set_dbg_addr(dut, addr)
    for byte in grouper_ram:
        await _grp_write(dut, 0x79, byte)
    await _grp_write(dut, 0x75, WR_TRIG)
    await _grp_poll_not_busy(dut, tag, "WR_TRIG")

    stored = [await _model_byte(dut, addr + i) for i in range(8)]
    assert stored == grouper_ram, \
        f"{tag}: PSRAM stored {stored} != Grouper RAM {grouper_ram}"

    await _grp_set_dbg_addr(dut, addr)
    await _grp_write(dut, 0x75, RD_TRIG)
    await _grp_poll_not_busy(dut, tag, "RD_TRIG")
    got = [await _grp_read(dut, 0x76) for _ in range(8)]
    assert got == grouper_ram, \
        f"{tag}: Grouper readback {got} != Grouper RAM {grouper_ram}"

    dut._log.info(f"{tag}: PASS -- Grouper RAM -> PSRAM -> Grouper readback: {got}")


@cocotb.test()
async def test_dbg_write_burst_no_autoinc(dut):
    tag = "dbg_wr_burst"
    await _bringup(dut, tag)

    payload = [0x11, 0x22, 0x33, 0x44, 0xDE, 0xAD, 0xBE, 0xEF]
    addr = BASE + 0x1000
    await _set_dbg_addr(dut, addr)
    # One SPI frame: command 0x79 then 8 data bytes, CS held low.  0x79 is
    # burst-exempt, so every data byte is a push at 0x79 (not 0x79..0x80).
    await spi_burst_write(dut, 0x79, payload)
    await spi_write(dut, 0x75, WR_TRIG)
    await _poll_not_busy(dut, tag, "WR_TRIG")

    got = await _dbg_read_line(dut, tag, addr)
    assert got == payload, \
        f"{tag}: burst-filled line read back {got} != {payload} -- 0x79 is not " \
        f"holding the burst address (bytes scattered to 0x7A+)"
    dut._log.info(f"{tag}: PASS -- 8-byte burst frame filled one line at 0x79")


@cocotb.test()
async def test_dbg_write_address_in_payload(dut):
    tag = "dbg_wr_addrpat"
    await _bringup(dut, tag)

    NLINES = 6
    addrs = [BASE + 0x2000 + 8 * n for n in range(NLINES)]

    def stamp(a):
        # 8 bytes encoding the line's own byte address + a fixed marker
        return [(a >> 16) & 0xFF, (a >> 8) & 0xFF, a & 0xFF, 0x5A,
                0xA5, (a >> 16) & 0xFF, (a >> 8) & 0xFF, a & 0xFF]

    for a in addrs:
        await _dbg_write_line(dut, tag, a, stamp(a))

    for a in addrs:
        got = await _dbg_read_line(dut, tag, a)
        assert got == stamp(a), \
            f"{tag}: line @0x{a:06X} read back {got} != its own stamp " \
            f"{stamp(a)} -- address aliasing or off-by-8 in the commit path"
    dut._log.info(f"{tag}: PASS -- {NLINES} address-stamped lines all self-consistent")


@cocotb.test()
async def test_dbg_write_blocked_by_qspi_owner(dut):
    tag = "dbg_wr_qspi_owner"
    await _bringup(dut, tag)

    addr = BASE + 0x3000
    seed = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
    await _dbg_write_line(dut, tag, addr, seed)          # establish known content

    # Hand the pads away: QSPI_OWNER=1 (keep PSRAM_EN set).
    await spi_write(dut, 0x70, 0x09)
    assert (await spi_read(dut, 0x75)) & DBG_BUSY, \
        f"{tag}: DBG_BUSY not held with QSPI_OWNER=1"

    await _set_dbg_addr(dut, addr)
    for b in [0xFF] * 8:
        await spi_write(dut, 0x79, b)
    await spi_write(dut, 0x75, WR_TRIG)
    for _ in range(50):
        await Timer(8 * CLK_NS, unit="ns")

    # Give the bus back and read the line: it must still be the seed.
    await spi_write(dut, 0x70, 0x01)
    await _poll_not_busy(dut, tag, "QSPI_OWNER release")
    stored = [await _model_byte(dut, addr + i) for i in range(8)]
    assert stored == seed, \
        f"{tag}: line changed to {stored} -- WR_TRIG reached the bus despite " \
        f"QSPI_OWNER=1 (expected {seed})"
    dut._log.info(f"{tag}: PASS -- commit suppressed while QSPI_OWNER=1")
