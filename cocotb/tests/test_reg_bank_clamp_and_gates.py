"""test_reg_bank_clamp_and_gates.py -- TACC_WINDOW_SYMS clamp exhaustive
sweep and the packet_active write-lock table for the standalone reg_bank
harness (``cocotb/reg_bank``, direct-DUT: no SPI/CDC framing).

Closes verification-plan rows #7 and #8
(planning/verification-plan/reg-bank-verification-plan.md):

  #7 "TACC_WINDOW_SYMS clamp for all inputs" -- row #4's
     ``test_tacc_window_syms_field`` only checked a light sample (0/7/8/9/0xF/
     0xF0/0xFF); this sweeps every value 0..255 so the clamp-floor-at-8
     behavior and the reserved bits[7:4] mask are proven for every input,
     not a sample.
  #8 "Packet-active write locks" -- a table-driven direct check of every
     register the write-decode gates on ``packet_active`` (SF_CFG, BW_CFG,
     PKT_TIMEOUT_SYMS, SC_HITS_REQ, SC_FORCE_LOCK, TACC_WINDOW_SYMS,
     PSRAM_CTRL.PSRAM_EN, REPLAY_DELAY_LO/HI), and confirms every other
     writable register is NOT blocked by packet_active.

Scope note: since commit f1aa262 (Open Risks #43), SF_CFG/BW_CFG/
PKT_TIMEOUT_SYMS/SC_HITS_REQ/TACC_WINDOW_SYMS are gated by
``cfg_wr_ok = rx_hold && !packet_active``, not packet_active alone. This
suite isolates the packet_active half of that gate by holding ``rx_hold``
at its default (reset-high, permissive) value throughout -- the rx_hold half
of the interlock is exhaustively covered separately by
``test_reg_bank_rx_hold.py``. SC_FORCE_LOCK and PSRAM_CTRL.PSRAM_EN are
packet_active-gated only (no rx_hold term) per reg_bank.v's write case.
"""

import cocotb

from reg_bank_map_oracle import peek, write_reg
from test_reg_bank_rw_map import _bring_up

# ---------------------------------------------------------------------------
# Row #7: TACC_WINDOW_SYMS (0x27) clamp -- full 0..255 sweep
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_tacc_window_syms_full_clamp_sweep(dut):
    """Every possible write byte 0x00-0xFF: floor-clamp wdata[3:0] to a
    minimum of 8, and confirm reserved bits[7:4] never leak into storage or
    readback."""
    await _bring_up(dut)
    assert int(dut.rx_hold.value) == 1, "expected RX_HOLD set out of reset (cfg_wr_ok gate)"

    for wval in range(256):
        await write_reg(dut, 0x27, wval)
        field = wval & 0x0F
        expected = field if field >= 8 else 8
        got = await peek(dut, 0x27)
        assert got == expected, (
            f"TACC_WINDOW_SYMS: wrote 0x{wval:02X} expected 0x{expected:02X} got 0x{got:02X}"
        )
        assert (got & 0xF0) == 0, (
            f"TACC_WINDOW_SYMS reserved bits[7:4] leaked: wrote 0x{wval:02X} got 0x{got:02X}"
        )
        assert int(dut.tacc_window_syms.value) == expected, (
            f"tacc_window_syms output: wrote 0x{wval:02X} expected {expected} "
            f"got {int(dut.tacc_window_syms.value)}"
        )


# ---------------------------------------------------------------------------
# Row #8: packet_active write-lock table (rx_hold held permissive)
# ---------------------------------------------------------------------------

# (addr, write value while unblocked, blocked-attempt value, output port(s),
#  mask applied to the stored field)
SINGLE_PORT_GATED = [
    (0x09, 0x0A, 0x05, "sf_cfg", 0x0F),
    (0x0B, 0x33, 0xCC, "pkt_timeout_syms", 0xFF),
    (0x0E, 0x03, 0x01, "sc_hits_req", 0x03),
    (0x27, 0x0C, 0x09, "tacc_window_syms", 0x0F),
    (0x77, 0xA5, 0x5A, None, None),  # checked via replay_delay_samples[7:0]
    (0x78, 0xB4, 0x4B, None, None),  # checked via replay_delay_samples[15:8]
]


@cocotb.test()
async def test_packet_active_blocks_single_port_gated_fields(dut):
    await _bring_up(dut)
    dut.packet_active.value = 0
    # DBG_STATUS (0x05) reads this back; the reg_bank bench drives the
    # module directly, so an undriven input would return X and break
    # any read of that address.
    dut.dbg_pad_value.value = 0
    assert int(dut.rx_hold.value) == 1, "expected RX_HOLD permissive out of reset"

    for addr, unblocked_val, blocked_val, port, mask in SINGLE_PORT_GATED:
        dut.packet_active.value = 0
        # DBG_STATUS (0x05) reads this back; the reg_bank bench drives the
        # module directly, so an undriven input would return X and break
        # any read of that address.
        dut.dbg_pad_value.value = 0
        await write_reg(dut, addr, unblocked_val)

        if addr == 0x77:
            before = int(dut.replay_delay_samples.value) & 0xFF
        elif addr == 0x78:
            before = (int(dut.replay_delay_samples.value) >> 8) & 0xFF
        else:
            before = int(getattr(dut, port).value)

        dut.packet_active.value = 1
        await write_reg(dut, addr, blocked_val)

        if addr == 0x77:
            after = int(dut.replay_delay_samples.value) & 0xFF
        elif addr == 0x78:
            after = (int(dut.replay_delay_samples.value) >> 8) & 0xFF
        else:
            after = int(getattr(dut, port).value)

        assert after == before, (
            f"0x{addr:02X}: updated while packet_active=1: "
            f"before=0x{before:02X} after=0x{after:02X}"
        )

        # Confirm the block is real, not a coincidence: releasing
        # packet_active lets the same write land.
        dut.packet_active.value = 0
        # DBG_STATUS (0x05) reads this back; the reg_bank bench drives the
        # module directly, so an undriven input would return X and break
        # any read of that address.
        dut.dbg_pad_value.value = 0
        await write_reg(dut, addr, blocked_val)
        if addr == 0x77:
            released = int(dut.replay_delay_samples.value) & 0xFF
        elif addr == 0x78:
            released = (int(dut.replay_delay_samples.value) >> 8) & 0xFF
        else:
            released = int(getattr(dut, port).value)
        assert released == (blocked_val & (mask if mask is not None else 0xFF)), (
            f"0x{addr:02X}: write did not land once packet_active=0: "
            f"expected 0x{blocked_val & (mask if mask is not None else 0xFF):02X} "
            f"got 0x{released:02X}"
        )

    dut.packet_active.value = 0



    # DBG_STATUS (0x05) reads this back; the reg_bank bench drives the

    # module directly, so an undriven input would return X and break

    # any read of that address.

    dut.dbg_pad_value.value = 0
@cocotb.test()
async def test_packet_active_blocks_bw_cfg(dut):
    """BW_CFG (0x0A) carries bw_sel[0] only; gated by cfg_wr_ok."""
    await _bring_up(dut)
    dut.packet_active.value = 0

    # DBG_STATUS (0x05) reads this back; the reg_bank bench drives the
    # module directly, so an undriven input would return X and break
    # any read of that address.
    dut.dbg_pad_value.value = 0
    await write_reg(dut, 0x0A, 0x01)  # bw_sel=1
    assert int(dut.bw_sel.value) == 1

    dut.packet_active.value = 1
    await write_reg(dut, 0x0A, 0x00)  # bw_sel=0 -- should be blocked
    assert int(dut.bw_sel.value) == 1, "bw_sel updated while packet_active=1"

    dut.packet_active.value = 0

    # DBG_STATUS (0x05) reads this back; the reg_bank bench drives the

    # module directly, so an undriven input would return X and break

    # any read of that address.

    dut.dbg_pad_value.value = 0
    await write_reg(dut, 0x0A, 0x00)
    assert int(dut.bw_sel.value) == 0, "bw_sel did not update once packet_active=0"
    dut.packet_active.value = 0


    # DBG_STATUS (0x05) reads this back; the reg_bank bench drives the
    # module directly, so an undriven input would return X and break
    # any read of that address.
    dut.dbg_pad_value.value = 0
@cocotb.test()
async def test_packet_active_blocks_sc_ant_sel(dut):
    """SC_ANT_SEL (0x1B) carries the correlator branch select, moved out of
    BW_CFG. It keeps the same cfg_wr_ok gate: psram_buf_ctrl's delay-line
    addressing must not change mid-packet."""
    await _bring_up(dut)
    dut.packet_active.value = 0

    # DBG_STATUS (0x05) reads this back; the reg_bank bench drives the
    # module directly, so an undriven input would return X and break
    # any read of that address.
    dut.dbg_pad_value.value = 0
    await write_reg(dut, 0x1B, 0x02)
    assert int(dut.sc_ant_sel.value) == 2

    dut.packet_active.value = 1
    await write_reg(dut, 0x1B, 0x03)  # should be blocked
    assert int(dut.sc_ant_sel.value) == 2, "sc_ant_sel updated while packet_active=1"

    dut.packet_active.value = 0

    # DBG_STATUS (0x05) reads this back; the reg_bank bench drives the

    # module directly, so an undriven input would return X and break

    # any read of that address.

    dut.dbg_pad_value.value = 0
    await write_reg(dut, 0x1B, 0x03)
    assert int(dut.sc_ant_sel.value) == 3, "sc_ant_sel did not update once packet_active=0"
    dut.packet_active.value = 0


    # DBG_STATUS (0x05) reads this back; the reg_bank bench drives the
    # module directly, so an undriven input would return X and break
    # any read of that address.
    dut.dbg_pad_value.value = 0
@cocotb.test()
async def test_packet_active_blocks_sc_force_lock(dut):
    """SC_FORCE_LOCK (0x19) is a W1P gated by packet_active alone (no
    rx_hold term)."""
    await _bring_up(dut)
    # Clear any earlier sticky so this test owns the bit (0x1A[1] is W1C).
    await write_reg(dut, 0x1A, 0x02 | (int(dut.rx_hold.value) & 1))
    dut.packet_active.value = 1
    await write_reg(dut, 0x19, 0x01)
    assert int(dut.sc_force_lock.value) == 0, (
        "sc_force_lock pulsed while packet_active=1"
    )
    # The refused write must be reported, not silently dropped -- the
    # firmware-invisible-drop class of Open Risks #16 / W_MISSED_PACKET.
    assert (await peek(dut, 0x1A)) & 0x02, (
        "a 0x19 write refused by packet_active did not latch CFG_WR_REJECTED"
    )
    dut.packet_active.value = 0
    # DBG_STATUS (0x05) reads this back; the reg_bank bench drives the
    # module directly, so an undriven input would return X and break
    # any read of that address.
    dut.dbg_pad_value.value = 0
    await write_reg(dut, 0x19, 0x01)
    assert int(dut.sc_force_lock.value) == 1, (
        "sc_force_lock did not pulse once packet_active=0"
    )
    dut.packet_active.value = 0


    # DBG_STATUS (0x05) reads this back; the reg_bank bench drives the
    # module directly, so an undriven input would return X and break
    # any read of that address.
    dut.dbg_pad_value.value = 0
@cocotb.test()
async def test_packet_active_blocks_psram_en_only(dut):
    """PSRAM_CTRL (0x70): bit[0] EN is gated by packet_active; bit[1]
    CLR_ERR (W1P) and bit[3] QSPI_OWNER are not, in the same register."""
    await _bring_up(dut)
    dut.packet_active.value = 0
    # DBG_STATUS (0x05) reads this back; the reg_bank bench drives the
    # module directly, so an undriven input would return X and break
    # any read of that address.
    dut.dbg_pad_value.value = 0
    await write_reg(dut, 0x70, 0x00)  # clear EN/OWNER

    dut.packet_active.value = 1
    before_en = int(dut.psram_ctrl.value) & 0x01
    await write_reg(dut, 0x70, 0x09)  # attempt EN=1, OWNER=1
    after_en = int(dut.psram_ctrl.value) & 0x01
    after_owner = int(dut.psram_ctrl.value) & 0x08
    assert after_en == before_en == 0, "PSRAM_EN updated while packet_active=1"
    assert after_owner == 0x08, "QSPI_OWNER (ungated) did not update while packet_active=1"

    await write_reg(dut, 0x70, 0x02)  # CLR_ERR (ungated W1P)
    assert int(dut.psram_ctrl.value) & 0x02, "CLR_ERR (ungated) did not pulse while packet_active=1"

    dut.packet_active.value = 0

    # DBG_STATUS (0x05) reads this back; the reg_bank bench drives the

    # module directly, so an undriven input would return X and break

    # any read of that address.

    dut.dbg_pad_value.value = 0
    await write_reg(dut, 0x70, 0x01)
    assert int(dut.psram_ctrl.value) & 0x01, "PSRAM_EN did not update once packet_active=0"
    dut.packet_active.value = 0


    # DBG_STATUS (0x05) reads this back; the reg_bank bench drives the
    # module directly, so an undriven input would return X and break
    # any read of that address.
    dut.dbg_pad_value.value = 0
# ---------------------------------------------------------------------------
# Ungated fields must remain writable while packet_active=1
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_ungated_fields_unaffected_by_packet_active(dut):
    """Every writable register NOT in the gated set above must accept
    writes normally while packet_active=1 -- the gate must not over-reach."""
    await _bring_up(dut)
    dut.packet_active.value = 1

    # MIMO_CTRL (0x08): plain RW, no gate.
    await write_reg(dut, 0x08, 0xF1)
    assert int(dut.antenna_en.value) == 0xF and int(dut.mimo_mode.value) == 1, (
        "MIMO_CTRL blocked while packet_active=1"
    )

    # SC_THR_HI/LO (0x0C/0x0D): explicitly ungated per reg_bank.v comment.
    await write_reg(dut, 0x0C, 0x12)
    await write_reg(dut, 0x0D, 0x34)
    assert int(dut.sc_thr.value) == 0x1234, "SC_THR blocked while packet_active=1"

    # COMB_CFG (0x0F): plain RW, no gate.
    await write_reg(dut, 0x0F, 0x23)
    assert int(dut.comb_post_gain_shift.value) == 0x3
    assert int(dut.remod_backoff_shift.value) == 0x2

    # RX_HOLD (0x1A) bit[0]: intentionally NOT self-gated by anything.
    await write_reg(dut, 0x1A, 0x00)
    assert int(dut.rx_hold.value) == 0, "RX_HOLD blocked while packet_active=1"
    await write_reg(dut, 0x1A, 0x01)
    assert int(dut.rx_hold.value) == 1, "RX_HOLD could not be re-asserted while packet_active=1"

    # WGT_CTRL.W_COMMIT (0x1E) and TACC_NOISE_TRIG (0x1F): ungated W1Ps.
    await write_reg(dut, 0x1E, 0x01)
    assert int(dut.w_commit_pulse.value) == 1, "W_COMMIT blocked while packet_active=1"
    await write_reg(dut, 0x1F, 0x01)
    assert int(dut.noise_trig.value) == 1, "TACC_NOISE_TRIG blocked while packet_active=1"

    # W shadow bank (0x30-0x3F): ungated (locked only by W_VALID, row #9).
    await write_reg(dut, 0x30, 0xAB)
    await write_reg(dut, 0x3F, 0xCD)
    got_first = await peek(dut, 0x30)
    got_last = await peek(dut, 0x3F)
    assert got_first == 0xAB and got_last == 0xCD, (
        "W shadow bank blocked while packet_active=1"
    )

    # PSRAM_DBG_ADDR_{LO,MID,HI} / PSRAM_DBG_CTRL.AUTO_INC (0x72-0x75):
    # ungated debug window.
    await write_reg(dut, 0x72, 0x11)
    await write_reg(dut, 0x73, 0x22)
    await write_reg(dut, 0x74, 0x33)
    assert int(dut.psram_dbg_addr.value) == 0x332211, (  # {HI,MID,LO} = {0x33,0x22,0x11}
        "PSRAM_DBG_ADDR blocked while packet_active=1"
    )
    await write_reg(dut, 0x75, 0x02)
    assert int(dut.psram_dbg_auto_inc.value) == 1, (
        "PSRAM_DBG_CTRL.AUTO_INC blocked while packet_active=1"
    )

    dut.packet_active.value = 0


    # DBG_STATUS (0x05) reads this back; the reg_bank bench drives the

    # module directly, so an undriven input would return X and break

    # any read of that address.

    dut.dbg_pad_value.value = 0
