"""
test_w_shadow_lock.py -- W-shadow write-lock regression (B4 hardening).

B4 (area roadmap SS8) deleted the mrc_combiner per-burst weight latches, so
the combiner reads reg_bank's w_shadow_r flops live.  The compensating
hardware invariant is a write-lock in reg_bank: 0x30-0x3F writes are
DROPPED while W_VALID is high, and the rejection is latched sticky in
WGT_CTRL[5] W_WR_REJECTED (W1C).  This test proves:

  1. shadow writes are accepted while W_VALID=0 (normal weight-load window,
     including the post-training pre-commit window of an active packet);
  2. after W_COMMIT (W_VALID=1) a shadow write is a hardware no-op: readback
     unchanged, combiner still sees the committed bytes;
  3. the rejected write sets WGT_CTRL[5], readable over SPI;
  4. W1C: writing WGT_CTRL with bit5 set clears the flag WITHOUT pulsing
     W_COMMIT (bit0=0);
  5. after packet end (W_VALID auto-clears at !packet_active) shadow writes
     are accepted again.

See planning/Register Map.md (0x1E / 0x30-0x3F sections).
"""

import cocotb
from cocotb.triggers import Timer

from test_trouper_top import spi_read, spi_write
from test_trouper_top import spi_burst_write
from test_bypass_e2e import _reset_and_lock

PKT_TIMEOUT_SYMS = 40

W_INITIAL = 0x40    # committed weight pattern (all 16 bytes)
W_ATTACK = 0x7F     # value the locked-out write tries to plant


@cocotb.test()
async def test_w_shadow_lock(dut):
    tag = "w_shadow_lock"
    sym_ns = await _reset_and_lock(dut, mode=0, ant_mask=0xF, tag=tag,
                                   pkt_timeout_syms=PKT_TIMEOUT_SYMS,
                                   replay_delay=0xFFFF)

    # -- (1) pre-commit window: writes must land -------------------------
    await spi_burst_write(dut, 0x30, [W_INITIAL] * 16)
    for a in (0x30, 0x37, 0x3F):
        v = await spi_read(dut, a)
        assert v == W_INITIAL, \
            f"{tag}: shadow write dropped while W_VALID=0 (0x{a:02X}=0x{v:02X})"
    wgt = await spi_read(dut, 0x1E)
    assert not (wgt & 0x20), \
        f"{tag}: W_WR_REJECTED set by an accepted write (0x{wgt:02X})"

    # wait for training_done, then commit -> W_VALID=1
    train_ok = False
    for _ in range(40):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x02:
            train_ok = True
            break
    assert train_ok, f"{tag}: training_done never fired"
    await spi_write(dut, 0x1E, 0x01)   # W_COMMIT (W1P)
    await Timer(sym_ns, unit="ns")
    wgt = await spi_read(dut, 0x1E)
    assert wgt & 0x02, f"{tag}: W_VALID clear after W_COMMIT (0x{wgt:02X})"

    # -- (2)+(3) locked window: write is a no-op, flag goes sticky -------
    await spi_write(dut, 0x30, W_ATTACK)
    await spi_write(dut, 0x3F, W_ATTACK)
    for a in (0x30, 0x3F):
        v = await spi_read(dut, a)
        assert v == W_INITIAL, \
            f"{tag}: shadow 0x{a:02X} CHANGED to 0x{v:02X} while W_VALID=1 -- lock broken"
    wgt = await spi_read(dut, 0x1E)
    assert wgt & 0x20, \
        f"{tag}: W_WR_REJECTED not set after locked-out write (0x{wgt:02X})"
    assert wgt & 0x02, f"{tag}: W_VALID dropped mid-packet (0x{wgt:02X})"
    # combiner-side view: the live weight port still carries the committed
    # value (W_re0 = shadow byte 0 = rb_w_shadow[127:120])
    w_port = (int(dut.u_dut.rb_w_shadow.value) >> 120) & 0xFF
    assert w_port == W_INITIAL, \
        f"{tag}: combiner W port sees 0x{w_port:02X} != committed 0x{W_INITIAL:02X}"
    dut._log.info(f"{tag}: locked write rejected + flagged (WGT_CTRL=0x{wgt:02X})")

    # -- (4) W1C clears the flag without side effects --------------------
    await spi_write(dut, 0x1E, 0x20)   # bit5 W1C, bit0=0 (no commit pulse)
    wgt = await spi_read(dut, 0x1E)
    assert not (wgt & 0x20), f"{tag}: W_WR_REJECTED not W1C-cleared (0x{wgt:02X})"
    assert wgt & 0x02, f"{tag}: W1C write disturbed W_VALID (0x{wgt:02X})"

    # a second locked-out write must re-set the flag
    await spi_write(dut, 0x35, W_ATTACK)
    v = await spi_read(dut, 0x35)
    wgt = await spi_read(dut, 0x1E)
    assert v == W_INITIAL and (wgt & 0x20), \
        f"{tag}: flag did not re-arm (0x35=0x{v:02X} WGT_CTRL=0x{wgt:02X})"
    await spi_write(dut, 0x1E, 0x20)

    # -- (5) packet end unlocks ------------------------------------------
    done_ok = False
    for _ in range(PKT_TIMEOUT_SYMS + 10):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x08:   # PACKET_DONE
            done_ok = True
            break
    assert done_ok, f"{tag}: PACKET_DONE never fired"
    wgt = await spi_read(dut, 0x1E)
    assert not (wgt & 0x02), f"{tag}: W_VALID still set after packet end (0x{wgt:02X})"

    await spi_write(dut, 0x30, 0x55)
    v = await spi_read(dut, 0x30)
    wgt = await spi_read(dut, 0x1E)
    assert v == 0x55, f"{tag}: post-packet shadow write dropped (0x30=0x{v:02X})"
    assert not (wgt & 0x20), \
        f"{tag}: W_WR_REJECTED set by a post-packet accepted write (0x{wgt:02X})"
    dut._log.info(f"{tag}: PASS -- lock, sticky flag, W1C, and unlock all verified")
