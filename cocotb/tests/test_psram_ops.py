"""
test_psram_ops.py -- PSRAM replay-miss handling + debug-readback content.

Traceability (planning/Traceability.md): TRPR-PSR-004 (late `W_COMMIT` ->
`REPLAY_MISSED`, no zombie replay, next-packet recovery), TRPR-PSR-017
(debug readback returns REAL stored PSRAM content incl. `AUTO_INC` advance
-- previously only the register mechanics were tested), plus more of
TRPR-PSR-006's status bits at their register positions (`REPLAY_MISSED`
bit[5] set AND cleared, `REPLAY_ACTIVE` bit[4] negative case) and the
functional half of `PSRAM_CLR_ERR` (TRPR-PSR-007 / REG-006 previously
covered the W1P mechanics only).

test_replay_missed_late_commit:
  lock -> training_done -> W_COMMIT withheld -> packet timeout. PSRAM must
  latch sticky REPLAY_MISSED (packet_end with a latched packet base but no
  commit). A LATE commit sent while IDLE must NOT start a replay (the
  packet base was invalidated at packet_end) -- the weights simply sit in
  the shadow for the next packet, which is the documented fallback.
  PSRAM_CLR_ERR then clears the sticky flag over SPI, and a second packet
  with an in-time commit must replay normally (recovery) with
  REPLAY_MISSED staying clear.

test_dbg_readback_content:
  No packet at all (low-amplitude independent noise -> no SC hits). After
  INIT_DONE the controller free-runs the circular capture; the test picks
  an early, already-written, not-soon-rewritten byte address (the 8 MB
  buffer wraps far too slowly to race), runs the full host protocol --
  DBG_ADDR bytes -> RD_TRIG+AUTO_INC -> poll DBG_BUSY -> 8 reads of
  PSRAM_DBG_DATA -- and compares every byte against the behavioural
  psram_model's nibble memory at the same addresses (read hierarchically,
  so the expectation is exactly what the QPI engine physically stored).
  The AUTO_INC re-fetch is then drained and compared at base+8..+15.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer

from test_trouper_top import CLK_NS, spi_read, spi_write
from test_bypass_e2e import _reset_and_lock
from test_noise_trig import _StimMode, _noise_or_cw_driver

PKT_TIMEOUT_SYMS = 20


@cocotb.test()
async def test_replay_missed_late_commit(dut):
    tag = "replay_missed"
    sym_ns = await _reset_and_lock(dut, mode=0, ant_mask=0xF, tag=tag,
                                   pkt_timeout_syms=PKT_TIMEOUT_SYMS)

    # -- training done, but never commit ------------------------------------
    train_ok = False
    for _ in range(40):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x02:
            train_ok = True
            break
    assert train_ok, f"{tag}: training_done never fired"

    st = await spi_read(dut, 0x71)
    assert not (st & 0x20), f"{tag}: REPLAY_MISSED set before packet end (0x{st:02X})"

    # -- packet timeout -> packet_end with no W_COMMIT -----------------------
    done_ok = False
    for _ in range(PKT_TIMEOUT_SYMS + 10):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x08:
            done_ok = True
            break
    assert done_ok, f"{tag}: PACKET_DONE IRQ never fired"

    st = await spi_read(dut, 0x71)
    assert st & 0x20, \
        f"{tag}: REPLAY_MISSED not latched after packet_end without W_COMMIT (0x{st:02X})"
    assert not (st & 0x10), f"{tag}: REPLAY_ACTIVE set on a missed packet (0x{st:02X})"
    dut._log.info(f"{tag}: REPLAY_MISSED latched (PSRAM_STATUS=0x{st:02X})")

    # -- LATE commit while IDLE: must NOT start a zombie replay --------------
    await spi_write(dut, 0x1E, 0x01)
    for _ in range(3):
        await Timer(sym_ns, unit="ns")
        st = await spi_read(dut, 0x71)
        assert not (st & 0x10), \
            f"{tag}: late W_COMMIT started a replay after packet_end (0x{st:02X}) -- " \
            f"packet base should have been invalidated"
    assert st & 0x20, f"{tag}: REPLAY_MISSED lost without PSRAM_CLR_ERR (0x{st:02X})"

    # -- PSRAM_CLR_ERR clears the sticky flag (functional, not just W1P) -----
    await spi_write(dut, 0x70, 0x03)   # PSRAM_EN | CLR_ERR
    st = await spi_read(dut, 0x71)
    assert not (st & 0x20), f"{tag}: REPLAY_MISSED not cleared by PSRAM_CLR_ERR (0x{st:02X})"

    # -- recovery: commit in time on a live packet ---------------------------
    # SC re-arms the instant the FSM returns to IDLE, so with the CW driver
    # running packets keep auto-starting -- one may already be mid-flight
    # after the late-commit checks above, and any packet that completes
    # uncommitted (correctly!) re-latches REPLAY_MISSED. (The first draft of
    # this test waited on IRQ *edges* whose events had already been consumed,
    # slept through an entire packet, and then flagged that correct re-latch
    # as a failure -- job 3312.) So instead: catch whatever packet is live by
    # polling PACKET_STATUS for W_PENDING, clear any interim re-latch, and
    # commit inside that same packet's window.
    caught = False
    for _ in range(60):
        await Timer(sym_ns, unit="ns")
        ps = await spi_read(dut, 0x1C)
        if (ps & 0x01) and ((ps >> 1) & 0x7) == 2:   # PACKET_ACTIVE, phase W_PENDING
            caught = True
            break
    assert caught, f"{tag}: no packet reached W_PENDING for the recovery commit"

    await spi_write(dut, 0x70, 0x03)   # clear any miss re-latched meanwhile
    await spi_write(dut, 0x1E, 0x01)   # in-time commit (W_PENDING lasts ~5 syms)

    replay_ok = False
    for _ in range(200):
        await Timer(64 * CLK_NS, unit="ns")
        st = await spi_read(dut, 0x71)
        if st & 0x10:
            replay_ok = True
            break
    assert replay_ok, f"{tag}: recovery packet never entered REPLAY (0x{st:02X})"
    assert not (st & 0x20), \
        f"{tag}: REPLAY_MISSED re-latched on a successfully-committed packet (0x{st:02X})"
    dut._log.info(f"{tag}: PASS -- miss latched, late commit inert, CLR_ERR works, "
                  f"committed packet replays clean (PSRAM_STATUS=0x{st:02X})")


async def _model_byte(dut, byte_addr):
    """Byte stored in the behavioural PSRAM model (nibble-addressed, high
    nibble first -- matches the QPI wire order the controller writes)."""
    hi = int(dut.u_psram.mem[2 * byte_addr].value)
    lo = int(dut.u_psram.mem[2 * byte_addr + 1].value)
    return ((hi << 4) | lo) & 0xFF


@cocotb.test()
async def test_dbg_readback_content(dut):
    tag = "dbg_content"
    sf = 7
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

    # Low-amplitude independent noise: nonzero stored samples, but no SC hits
    # -> no lock -> packet_active stays 0 (debug reads are unblocked).
    mode = _StimMode()
    cocotb.start_soon(_noise_or_cw_driver(dut, mode, sigma=8.0))

    await spi_read(dut, 0x00)
    await spi_read(dut, 0x09)
    await spi_write(dut, 0x09, sf & 0x0F)
    await spi_write(dut, 0x0A, 0)

    await spi_write(dut, 0x70, 0x01)
    init_ok = False
    for _ in range(500):
        await Timer(8 * CLK_NS, unit="ns")
        if (await spi_read(dut, 0x71)) & 0x08:
            init_ok = True
            break
    assert init_ok, f"{tag}: PSRAM INIT_DONE never set"

    # Let the circular capture write a comfortable prefix (wr_ptr starts at 0;
    # ~200 samples -> bytes 0..1599 written; they won't be rewritten until the
    # 8 MB buffer wraps, far beyond this test's horizon).
    await Timer(200 * clk_per_iq * CLK_NS, unit="ns")

    base = 64 * 8   # sample-aligned byte address, well inside the written prefix

    # Host debug protocol: address -> RD_TRIG (+AUTO_INC) -> poll DBG_BUSY
    await spi_write(dut, 0x72, base & 0xFF)
    await spi_write(dut, 0x73, (base >> 8) & 0xFF)
    await spi_write(dut, 0x74, (base >> 16) & 0x7F)
    await spi_write(dut, 0x75, 0x03)   # RD_TRIG | AUTO_INC

    for _ in range(100):
        if not ((await spi_read(dut, 0x75)) & 0x80):
            break
    else:
        assert False, f"{tag}: DBG_BUSY never cleared after RD_TRIG"

    got = [await spi_read(dut, 0x76) for _ in range(8)]
    exp = [await _model_byte(dut, base + i) for i in range(8)]
    assert got == exp, \
        f"{tag}: sample @0x{base:06X}: read {got} != stored {exp} -- debug QPI read " \
        f"path returns wrong content"
    assert any(b != 0 for b in got), \
        f"{tag}: all 8 bytes zero -- stimulus not reaching PSRAM storage, content " \
        f"comparison is vacuous"

    # AUTO_INC: the 8th pop re-arms a fetch at base+8; drain and compare again
    for _ in range(100):
        if not ((await spi_read(dut, 0x75)) & 0x80):
            break
    else:
        assert False, f"{tag}: DBG_BUSY never cleared after AUTO_INC re-fetch"

    got2 = [await spi_read(dut, 0x76) for _ in range(8)]
    exp2 = [await _model_byte(dut, base + 8 + i) for i in range(8)]
    assert got2 == exp2, \
        f"{tag}: AUTO_INC sample @0x{base + 8:06X}: read {got2} != stored {exp2}"

    dut._log.info(f"{tag}: PASS -- 16 bytes bit-exact vs stored PSRAM content "
                  f"(sample={got}, auto-inc sample={got2})")
