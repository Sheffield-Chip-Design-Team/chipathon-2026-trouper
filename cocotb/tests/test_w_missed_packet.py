"""
test_w_missed_packet.py -- W_MISSED_PACKET regression (no-W_COMMIT packet).

Traceability (planning/Traceability.md): TRPR-PCF-005 (primary), plus the
W_MISSED_PACKET readback halves of TRPR-PCF-009 / TRPR-MRC-011 and the
PACKET_DONE-IRQ sub-gap of TRPR-PCF-007.

TRPR-PCF-005: if firmware never sends W_COMMIT before the payload
boundary, the FSM must stay in bypass, set W_MISSED_PACKET, and assert the
IRQ. The RTL fix landed in commit 46e1da0 ("set W_missed_packet on the
wpend timeout path when W_valid never arrived") with NO regression test --
this is it.

It also regresses a second, related fix found while writing this test
(2026-07-06): W_missed_packet is a 1-cycle FSM pulse consumed by the IRQ
edge-set path, and trouper_top wired that same pulse straight into
reg_bank's combinational w_missed_rb readback -- so PACKET_STATUS[7]
(0x1C) and WGT_CTRL[3] (0x1E), both documented in Register Map.md as
readable status bits, were firmware-INVISIBLE (always 0 outside a 1-clock
race). Fixed by adding a sticky per-packet mirror (`W_missed_q`) in
packet_ctrl_fsm.v: set at both miss sites (ACQ timeout and W_PENDING
timeout with !W_valid), held through IDLE so firmware can still read it
after PACKET_DONE, cleared at the next packet start (both the IDLE and
the back-to-back PAYLOAD->PREAMBLE re-lock paths).

Timeline (SF7/BW250, tacc_window=8 syms, PKT_TIMEOUT_SYMS=20):
  timing_ref + ~8 syms   training_done -> ST_W_PENDING
  timing_ref + 13 syms   wpend timeout (tacc_span + 4M + M) -> miss pulse,
                         IRQ[2], ST_PAYLOAD_ACTIVE in bypass
  timing_ref + 20 syms   pkt_end -> IDLE, PACKET_DONE IRQ[3]
  (driver keeps running) sc re-arms -> next lock clears the sticky bit
"""

import cocotb
from cocotb.triggers import Timer

from test_trouper_top import CLK_NS, spi_read, spi_write
from test_bypass_e2e import _reset_and_lock, _watch_bypass

PKT_TIMEOUT_SYMS = 20


@cocotb.test()
async def test_w_missed_on_wpend_timeout(dut):
    tag = "w_missed"
    sym_ns = await _reset_and_lock(dut, mode=0, ant_mask=0xF, tag=tag,
                                   pkt_timeout_syms=PKT_TIMEOUT_SYMS)

    pkt_status = await spi_read(dut, 0x1C)
    assert pkt_status & 0x01, f"{tag}: PACKET_ACTIVE not set after sc_lock (0x{pkt_status:02X})"

    # -- training_done (IRQ[1]); the miss must NOT have fired yet ----------
    train_ok = False
    for _ in range(40):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x02:
            train_ok = True
            break
    assert train_ok, f"{tag}: training_done never fired"

    irq = await spi_read(dut, 0x02)
    assert not (irq & 0x04), \
        f"{tag}: W_MISSED_PACKET IRQ set already at training_done (0x{irq:02X})"

    pkt_status = await spi_read(dut, 0x1C)
    wgt = await spi_read(dut, 0x1E)
    assert (pkt_status >> 1) & 0x7 == 2, \
        f"{tag}: PACKET_PHASE={((pkt_status >> 1) & 0x7)} != 2 (W_PENDING) after training_done"
    assert pkt_status & 0x10, f"{tag}: PACKET_STATUS.TRAINING_DONE clear (0x{pkt_status:02X})"
    assert pkt_status & 0x20, f"{tag}: PACKET_STATUS.W_PENDING clear (0x{pkt_status:02X})"
    assert not (pkt_status & 0x80), f"{tag}: PACKET_STATUS.W_MISSED set early (0x{pkt_status:02X})"
    assert wgt & 0x04, f"{tag}: WGT_CTRL.W_PENDING clear (0x{wgt:02X})"
    assert not (wgt & 0x0A), \
        f"{tag}: WGT_CTRL W_VALID/W_MISSED set before timeout (0x{wgt:02X})"
    dut._log.info(f"{tag}: W_PENDING confirmed, no miss yet -- withholding W_COMMIT")

    # -- wpend timeout: IRQ[2] must fire, no W_COMMIT ever sent ------------
    miss_ok = False
    for _ in range(15):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x04:
            miss_ok = True
            break
    assert miss_ok, f"{tag}: W_MISSED_PACKET IRQ never fired after withholding W_COMMIT"

    # Sticky readback at both documented register positions (the 2026-07-06
    # W_missed_q fix -- previously these read the 1-cycle pulse, i.e. 0)
    pkt_status = await spi_read(dut, 0x1C)
    wgt = await spi_read(dut, 0x1E)
    assert pkt_status & 0x80, \
        f"{tag}: PACKET_STATUS[7].W_MISSED_PACKET not readable (0x{pkt_status:02X})"
    assert (pkt_status >> 1) & 0x7 == 3, \
        f"{tag}: PACKET_PHASE={((pkt_status >> 1) & 0x7)} != 3 (PAYLOAD_ACTIVE) after miss"
    assert not (pkt_status & 0x40), \
        f"{tag}: PACKET_STATUS.W_VALID set on a missed packet (0x{pkt_status:02X})"
    assert wgt & 0x08, f"{tag}: WGT_CTRL[3].W_MISSED_PACKET not readable (0x{wgt:02X})"
    assert not (wgt & 0x02), f"{tag}: WGT_CTRL.W_VALID set on a missed packet (0x{wgt:02X})"
    dut._log.info(f"{tag}: miss IRQ + sticky readback OK "
                  f"(PACKET_STATUS=0x{pkt_status:02X} WGT_CTRL=0x{wgt:02X})")

    # -- payload must run in BYPASS (no weights): comb_y == raw ant0 -------
    assert int(dut.u_dut.u_comb.use_mrc_r.value) == 0, \
        f"{tag}: use_mrc_r=1 on a missed packet -- combiner left bypass without weights"
    await _watch_bypass(dut, 0, 20, tag=f"{tag}/payload-bypass",
                        expect_silenced=True, check_remod=False)

    # -- packet timeout -> IDLE + PACKET_DONE IRQ[3] (TRPR-PCF-007 sub-gap)
    done_ok = False
    for _ in range(PKT_TIMEOUT_SYMS + 5):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x08:
            done_ok = True
            break
    assert done_ok, f"{tag}: PACKET_DONE IRQ never fired at packet timeout"

    # Sticky bit must survive IDLE (readable post-PACKET_DONE)...
    pkt_status = await spi_read(dut, 0x1C)
    wgt = await spi_read(dut, 0x1E)
    assert not (pkt_status & 0x01), f"{tag}: PACKET_ACTIVE still set in IDLE (0x{pkt_status:02X})"
    assert pkt_status & 0x80, \
        f"{tag}: W_MISSED_PACKET readback lost at IDLE entry -- firmware polling after " \
        f"PACKET_DONE would miss it (0x{pkt_status:02X})"
    assert wgt & 0x08, f"{tag}: WGT_CTRL.W_MISSED lost at IDLE entry (0x{wgt:02X})"

    # ...and clear at the NEXT packet start (driver still running, SC re-arms)
    await spi_write(dut, 0x03, 0xFF)   # clear IRQs
    relock_ok = False
    for _ in range(20):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x01:
            relock_ok = True
            break
    assert relock_ok, f"{tag}: no re-lock after IDLE (SC re-arm)"

    pkt_status = await spi_read(dut, 0x1C)
    assert pkt_status & 0x01, f"{tag}: PACKET_ACTIVE clear after re-lock (0x{pkt_status:02X})"
    assert not (pkt_status & 0x80), \
        f"{tag}: W_MISSED_PACKET not cleared at next packet start (0x{pkt_status:02X})"
    dut._log.info(f"{tag}: PASS -- miss IRQ, sticky readback through IDLE, bypass payload, "
                  f"PACKET_DONE IRQ, clear-on-next-packet all confirmed")
