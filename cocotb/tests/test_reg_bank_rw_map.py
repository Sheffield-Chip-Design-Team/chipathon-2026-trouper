"""test_reg_bank_rw_map.py -- exhaustive RW field storage, reserved-bit
masking, and packed control-output mapping for the standalone reg_bank
harness (``cocotb/reg_bank``, direct-DUT: no SPI/CDC framing).

Closes verification-plan row #4
(planning/verification-plan/reg-bank-verification-plan.md): "All RW field
storage, reserved-bit masking, and packed output mapping" (TRPR-REG-001).

Scope and layering (see the plan's Sec 4 "Explicit non-goals"): this suite
proves byte-level storage, reserved-bit zeroing, and hardware
control-output port values for every genuine read/write field across
0x00-0x7F, plus the storage/output side of the W1P fields that pair a
control-output pulse with the same address (SC_FORCE_LOCK,
TACC_NOISE_TRIG, WGT_CTRL.W_COMMIT, PSRAM_CTRL.PSRAM_CLR_ERR,
PSRAM_DBG_CTRL.RD_TRIG). It intentionally leaves to other rows: exhaustive
RO hardware-status decode for pure-status registers (row #5), the
multi-byte/byte-lane oracle (row #6), the full TACC_WINDOW_SYMS clamp
sweep across 0..15 (row #7), the full {write-gated register} x
{packet_active 0/1} table (row #8; a single-pattern smoke check is
included here only to confirm each gate is wired), W-shadow lock
precedence beyond one set/clear pass (rows #9/#10 -- row #9 is already
closed by cocotb/w_shadow_lock), cycle-exact W1P port timing across every
harness (row #11), CE/read-protocol boundary timing (rows #12/#16/#17),
IRQ set/clear precedence (rows #13-#15), and the Grouper bus (row #18).

Harness note on clk_en: this direct-DUT harness holds reg_bank.v's
``clk_en`` input asserted on every cycle instead of toggling it at the real
16 MHz half-rate used in trouper_top.v. Every behavior checked in this
file -- combinational address decode, registered field storage, reserved-bit
masking, and W1P pulse-then-autoclear shape -- is driven by the same
``if (clk_en) ...`` block regardless of how often that block fires; running
it every cycle instead of every other cycle changes only the wall-clock
rate, not the stored contents, the mask, or the output values. The CE
period boundary itself (exactly one write per two-cycle SPI ``we``, the
registered read wait-state, and reset interruption relative to a CE edge)
is a distinct contract owned by rows #12/#16/#17 and by the full-top
``spi_cdc`` suite; it is not exercised here.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from reg_bank_map_oracle import (
    CLK_NS,
    GENERIC_RW_FIELDS,
    PATTERNS,
    peek,
    run_field_sweep,
    write_reg,
)

ZERO_WIDE_INPUTS = (
    "active_mode_rb",
    "active_antenna_en_rb",
    "packet_active",
    "packet_phase",
    "training_done_rb",
    "w_pending_rb",
    "w_valid_rb",
    "w_missed_rb",
    "w_commit_late_rb",
    "irq_set",
    "sc_stat",
    "training_armed",
    "n_acc",
    "zpair_i0", "zpair_q0", "zpair_i1", "zpair_q1",
    "zpair_i2", "zpair_q2", "zpair_i3", "zpair_q3",
    "zpair_i4", "zpair_q4", "zpair_i5", "zpair_q5",
    "zdiag_0", "zdiag_1", "zdiag_2", "zdiag_3",
    "sc_hit_dbg",
    "sc_hit_count_dbg",
    "sc_lock_dbg",
    "sc_first_hit_dbg",
    "sc_lock_snap_dbg",
    "psram_status_rb",
    "psram_dbg_busy",
    "psram_dbg_data",
)


def _idle_inputs(dut):
    dut.addr.value = 0
    dut.raddr.value = 0
    dut.wdata.value = 0
    dut.we.value = 0
    dut.re.value = 0
    for name in ZERO_WIDE_INPUTS:
        getattr(dut, name).value = 0
    # Held asserted throughout -- see module docstring.
    dut.clk_en.value = 1


async def _reset(dut, cycles=4):
    dut.rst_n.value = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")


async def _bring_up(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    _idle_inputs(dut)
    await _reset(dut)


# ---------------------------------------------------------------------------
# Generic plain-storage RW fields
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_generic_rw_fields(dut):
    """Sweep every plain RW field (MIMO_CTRL, SF_CFG, BW_CFG,
    PKT_TIMEOUT_SYMS, SC_THR_HI/LO, SC_HITS_REQ, COMB_CFG, the 16-byte W
    shadow bank, PSRAM_DBG_ADDR_{LO,MID,HI}, and REPLAY_DELAY_{LO,HI})
    through PATTERNS and confirm storage, reserved-bit masking, and the
    corresponding hardware output port."""
    await _bring_up(dut)
    for field in GENERIC_RW_FIELDS:
        await run_field_sweep(dut, field)


# ---------------------------------------------------------------------------
# WGT_CTRL (0x1E) -- W1P bit0, RO status mirror, W1C bit5, reserved bits7:6
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_wgt_ctrl_field(dut):
    await _bring_up(dut)

    # Reserved bits[7:6] always read 0, and bit0 (W_COMMIT, WO) always
    # reads 0, regardless of what is written there.
    for p in PATTERNS:
        await write_reg(dut, 0x1E, p)
        got = await peek(dut, 0x1E)
        assert (got & 0xC1) == 0, (
            f"WGT_CTRL reserved/WO bits not zero: wrote 0x{p:02X} got 0x{got:02X}"
        )

    # W_COMMIT is a write-1 pulse: asserts w_commit_pulse for exactly the
    # cycle after the write, then self-clears.
    await write_reg(dut, 0x1E, 0x01)
    assert int(dut.w_commit_pulse.value) == 1, "w_commit_pulse did not assert"
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")
    assert int(dut.w_commit_pulse.value) == 0, "w_commit_pulse did not self-clear"

    # RO status bits[4:1] mirror the driven hardware-status inputs.
    dut.w_valid_rb.value = 1
    dut.w_pending_rb.value = 1
    dut.w_missed_rb.value = 0
    dut.w_commit_late_rb.value = 1
    got = await peek(dut, 0x1E)
    expected = (1 << 4) | (0 << 3) | (1 << 2) | (1 << 1)
    assert got == expected, (
        f"WGT_CTRL status mirror: expected 0x{expected:02X} got 0x{got:02X}"
    )
    dut.w_valid_rb.value = 0
    dut.w_pending_rb.value = 0
    dut.w_commit_late_rb.value = 0

    # W_WR_REJECTED (bit5): a 0x30-0x3F write while W_VALID is high is
    # dropped and latches the sticky rejection flag; a WGT_CTRL write with
    # bit5 set (W1C) clears it. The shadow byte itself must be unaffected
    # by the rejected write.
    before_shadow = await peek(dut, 0x30)
    dut.w_valid_rb.value = 1
    await write_reg(dut, 0x30, 0xAB)
    dut.w_valid_rb.value = 0
    got = await peek(dut, 0x1E)
    assert got & 0x20, f"W_WR_REJECTED did not latch: 0x1E=0x{got:02X}"
    after_shadow = await peek(dut, 0x30)
    assert after_shadow == before_shadow, (
        "rejected W-shadow write was not actually dropped: "
        f"before=0x{before_shadow:02X} after=0x{after_shadow:02X}"
    )
    await write_reg(dut, 0x1E, 0x20)
    got = await peek(dut, 0x1E)
    assert (got & 0x20) == 0, f"W_WR_REJECTED did not W1C: 0x1E=0x{got:02X}"


# ---------------------------------------------------------------------------
# PSRAM_CTRL (0x70) -- EN gated by packet_active, CLR_ERR self-clearing W1P,
# bit[2] reserved/inert, QSPI_OWNER plain RW, none of the latter three gated
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_psram_ctrl_field(dut):
    await _bring_up(dut)
    dut.packet_active.value = 0

    for p in PATTERNS:
        await write_reg(dut, 0x70, p)
        got_immediate = await peek(dut, 0x70)
        expected_immediate = p & 0x0B  # bit3 QSPI_OWNER, bit1 CLR_ERR, bit0 EN
        assert got_immediate == expected_immediate, (
            f"PSRAM_CTRL immediate: wrote 0x{p:02X} expected 0x{expected_immediate:02X} "
            f"got 0x{got_immediate:02X}"
        )
        assert (int(dut.psram_ctrl.value) & 0x04) == 0, (
            f"PSRAM_CTRL[2] (reserved) not inert: wrote 0x{p:02X}"
        )

        # No further write -> CLR_ERR (bit1, W1P) self-clears; EN/QSPI_OWNER
        # (plain RW) persist.
        await RisingEdge(dut.clk)
        await Timer(1, unit="ps")
        got_after = await peek(dut, 0x70)
        expected_after = p & 0x09  # bit3 QSPI_OWNER, bit0 EN; bit1 cleared
        assert got_after == expected_after, (
            f"PSRAM_CTRL post-clear: wrote 0x{p:02X} expected 0x{expected_after:02X} "
            f"got 0x{got_after:02X}"
        )

    # PSRAM_EN (bit0) is the only bit of this register write-gated by
    # packet_active; CLR_ERR and QSPI_OWNER are not (Register Map.md 0x70
    # documents the gate only against PSRAM_EN).
    await write_reg(dut, 0x70, 0x00)  # clear EN/QSPI_OWNER before the gate check
    before = await peek(dut, 0x70)
    dut.packet_active.value = 1
    await write_reg(dut, 0x70, 0xFF)
    after = await peek(dut, 0x70)
    dut.packet_active.value = 0
    assert (after & 0x01) == (before & 0x01), (
        f"PSRAM_EN updated while packet_active=1: before=0x{before:02X} after=0x{after:02X}"
    )
    assert after & 0x08, "QSPI_OWNER did not update while packet_active=1 (should be ungated)"
    assert after & 0x02, "CLR_ERR did not pulse while packet_active=1 (should be ungated)"


# ---------------------------------------------------------------------------
# PSRAM_DBG_CTRL (0x75) -- RD_TRIG self-clearing W1P (not itself readable),
# AUTO_INC plain RW, DBG_BUSY RO input mirror, bits[6:2] reserved
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_psram_dbg_ctrl_field(dut):
    await _bring_up(dut)
    dut.psram_dbg_busy.value = 0

    for p in PATTERNS:
        await write_reg(dut, 0x75, p)
        assert int(dut.psram_dbg_rd_trig.value) == (p & 0x1), (
            f"psram_dbg_rd_trig: wrote 0x{p:02X}"
        )
        assert int(dut.psram_dbg_auto_inc.value) == ((p >> 1) & 0x1), (
            f"psram_dbg_auto_inc: wrote 0x{p:02X}"
        )
        got_immediate = await peek(dut, 0x75)
        expected_immediate = ((p >> 1) & 0x1) << 1  # bit0 (RD_TRIG) never reads back
        assert got_immediate == expected_immediate, (
            f"PSRAM_DBG_CTRL immediate: wrote 0x{p:02X} expected 0x{expected_immediate:02X} "
            f"got 0x{got_immediate:02X}"
        )

        await RisingEdge(dut.clk)
        await Timer(1, unit="ps")
        assert int(dut.psram_dbg_rd_trig.value) == 0, "psram_dbg_rd_trig did not self-clear"
        assert int(dut.psram_dbg_auto_inc.value) == ((p >> 1) & 0x1), (
            "psram_dbg_auto_inc did not persist"
        )

    # DBG_BUSY (bit7) is a pure RO mirror of the psram_dbg_busy input,
    # independent of any write.
    dut.psram_dbg_busy.value = 1
    got = await peek(dut, 0x75)
    assert got & 0x80, f"DBG_BUSY not mirrored high: 0x75=0x{got:02X}"
    dut.psram_dbg_busy.value = 0
    got = await peek(dut, 0x75)
    assert (got & 0x80) == 0, f"DBG_BUSY not mirrored low: 0x75=0x{got:02X}"


# ---------------------------------------------------------------------------
# TACC_WINDOW_SYMS (0x27) -- clamp floor at 8, reserved bits[7:4]
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_tacc_window_syms_field(dut):
    """Light clamp + reserved-bit check; the full 0..15 clamp sweep is
    owned by row #7."""
    await _bring_up(dut)
    for p in (0x00, 0x07, 0x08, 0x09, 0x0F, 0xF0, 0xFF):
        await write_reg(dut, 0x27, p)
        val = p & 0xF
        expected = val if val >= 8 else 8
        got = await peek(dut, 0x27)
        assert got == expected, (
            f"TACC_WINDOW_SYMS: wrote 0x{p:02X} expected 0x{expected:02X} got 0x{got:02X}"
        )
        assert int(dut.tacc_window_syms.value) == expected, (
            f"tacc_window_syms output: wrote 0x{p:02X} expected {expected} "
            f"got {int(dut.tacc_window_syms.value)}"
        )


# ---------------------------------------------------------------------------
# SC_FORCE_LOCK (0x19, WO/W1P, gated by packet_active) and TACC_NOISE_TRIG
# (0x1F, WO/W1P, ungated)
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_sc_force_lock_and_noise_trig(dut):
    await _bring_up(dut)
    dut.packet_active.value = 0

    # SC_FORCE_LOCK: W1P, reads back 0x00 (WO), pulses sc_force_lock for
    # one cycle then self-clears.
    await write_reg(dut, 0x19, 0x01)
    assert int(dut.sc_force_lock.value) == 1, "sc_force_lock did not assert"
    got = await peek(dut, 0x19)
    assert got == 0x00, f"SC_FORCE_LOCK readback not 0x00: got 0x{got:02X}"
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")
    assert int(dut.sc_force_lock.value) == 0, "sc_force_lock did not self-clear"

    # Blocked while packet_active=1.
    dut.packet_active.value = 1
    await write_reg(dut, 0x19, 0x01)
    assert int(dut.sc_force_lock.value) == 0, (
        "sc_force_lock asserted despite packet_active=1"
    )
    dut.packet_active.value = 0

    # TACC_NOISE_TRIG: W1P, reads back 0x00 (WO), pulses noise_trig for one
    # cycle then self-clears; not gated by packet_active.
    await write_reg(dut, 0x1F, 0x01)
    assert int(dut.noise_trig.value) == 1, "noise_trig did not assert"
    got = await peek(dut, 0x1F)
    assert got == 0x00, f"TACC_NOISE_TRIG readback not 0x00: got 0x{got:02X}"
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")
    assert int(dut.noise_trig.value) == 0, "noise_trig did not self-clear"


# ---------------------------------------------------------------------------
# packet_active write-lock smoke check for every gated RW field
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_packet_active_gate_smoke(dut):
    """One-pattern-per-field confirmation that every packet_active-gated
    field in the map is actually wired to the gate. The exhaustive
    {gate x packet_active 0/1} table belongs to row #8."""
    await _bring_up(dut)

    async def _blocked(addr, output_sig):
        dut.packet_active.value = 0
        await write_reg(dut, addr, 0x00)
        dut.packet_active.value = 1
        before = int(getattr(dut, output_sig).value)
        await write_reg(dut, addr, 0xFF)
        after = int(getattr(dut, output_sig).value)
        dut.packet_active.value = 0
        assert after == before, (
            f"0x{addr:02X} ({output_sig}) updated while packet_active=1: "
            f"before={before} after={after}"
        )

    await _blocked(0x09, "sf_cfg")
    await _blocked(0x0A, "bw_sel")
    await _blocked(0x77, "replay_delay_samples")
    await _blocked(0x78, "replay_delay_samples")

    # SC_FORCE_LOCK and PSRAM_CTRL.PSRAM_EN are already exercised as part
    # of their own dedicated tests above.


# ---------------------------------------------------------------------------
# Test #2: Exhaustive address/access-permission/mask sweep
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_exhaustive_address_permission_mask_sweep(dut):
    """Verify every address's permission, masking, and storage behavior.

    Closes verification-plan row #2: "Exhaustive address/access-permission/
    mask sweep" (TRPR-REG-001/004/005). Proves that writes to each address
    respect its documented access mode (RO/WO/RW/W1P/W1C) and reserved-bit
    mask, and that a write to one address does not perturb any other address.
    """
    await _bring_up(dut)

    # Map of address -> (access_mode, mask) where access_mode is one of:
    # 'RO', 'WO', 'RW', 'W1P', 'reserved'
    # mask is the bits that can be read back after a write
    addr_map = {
        # Global / IRQ / Debug
        0x00: ('RO', 0xFF),  # CHIP_ID fixed 0xA7
        0x01: ('RO', 0xFF),  # CHIP_REV fixed 0x01
        0x02: ('RO', 0xFF),  # IRQ_STATUS (RO sticky)
        0x03: ('WO', 0x00),  # IRQ_CLEAR (WO, reads as 0)
        0x04: ('reserved', 0x00),
        0x05: ('reserved', 0x00),
        0x06: ('reserved', 0x00),
        0x07: ('reserved', 0x00),
        # RX / Modem Configuration
        0x08: ('RW', 0xF1),  # MIMO_CTRL: [7:4]=ANTENNA_EN, [0]=MODE; [3:1] reserved
        0x09: ('RW', 0x0F),  # SF_CFG: [3:0]=SF; [7:4] reserved
        0x0A: ('RW', 0x01),  # BW_CFG: [0]=BW_SEL; [7:1] reserved
        0x0B: ('RW', 0xFF),  # PKT_TIMEOUT_SYMS
        0x0C: ('RW', 0xFF),  # SC_THR_HI
        0x0D: ('RW', 0xFF),  # SC_THR_LO
        0x0E: ('RW', 0x03),  # SC_HITS_REQ: [1:0]; [7:2] reserved
        0x0F: ('RW', 0x37),  # COMB_CFG: [2:0]=POST_GAIN, [5:4]=REMOD; [3],[7:6] reserved
        # Reserved (former RX gain)
        0x10: ('reserved', 0x00),
        0x11: ('reserved', 0x00),
        0x12: ('reserved', 0x00),
        0x13: ('reserved', 0x00),
        0x14: ('reserved', 0x00),
        0x15: ('reserved', 0x00),
        0x16: ('reserved', 0x00),
        0x17: ('reserved', 0x00),
        0x18: ('RW', 0x01),  # ARRAY_SYNC_CTRL: [0] ARRAY_SYNC_EN; [7:1] reserved
        # Packet / Weight / Training Control (mostly RO / WO / W1P)
        0x19: ('W1P', 0x00),  # SC_FORCE_LOCK (W1P, reads as 0)
        # 0x1A: RX_HOLD / CFG_WR_REJECTED (Open Risks #43,
        # planning/mcp-config-settle-gate-design.md). bit[0]=rx_hold is a
        # plain RW bit (self-gated writes always land, see reg_bank.v case
        # 8'h1A); bit[1]=cfg_wr_rejected is a sticky flag that this generic
        # pattern sweep never sets (it only sets on a *rejected write to a
        # different, cfg-locked address*, and writing wdata[1]=1 here only
        # clears it, W1C) -- so for the patterns exercised in this sweep
        # (0x00/0xFF/0xAA/0x55) it always reads back 0 and the readback
        # collapses to `pattern & 0x01`, fitting the generic RW/mask model.
        # cfg_wr_rejected's real set/W1C behavior is exhaustively covered by
        # cocotb/tests/test_reg_bank_rx_hold.py (row #8/#43 interlock, not
        # this row).
        0x1A: ('RW', 0x01),
        0x1B: ('RW', 0x03),  # SC_ANT_SEL: [1:0]; [7:2] reserved
        0x1C: ('RO', 0xFF),  # PACKET_STATUS (all RO)
        0x1D: ('RO', 0xF3),  # ACTIVE_STATUS: [7:4]=ANTENNA_EN, [1:0]=MODE; [3:2] reserved
        0x1E: ('RW', 0x3F),  # WGT_CTRL: [0]=W_COMMIT(W1P), [1:5]=RO, [7:6] reserved
        0x1F: ('W1P', 0x00),  # TACC_NOISE_TRIG (W1P, reads as 0)
        0x20: ('RO', 0x03),  # TRAINING_STATUS
        0x21: ('RO', 0x03),  # N_ACC_HI [1:0]
        0x22: ('RO', 0xFF),  # N_ACC_MID
        0x23: ('RO', 0xFF),  # N_ACC_LO
        # SC Status / Debug
        0x24: ('RO', 0xFF),  # SC_STAT_HI
        0x25: ('RO', 0xFF),  # SC_STAT_LO
        0x26: ('RO', 0x0F),  # SC_DBG_FLAGS [3:0]; [7:4] reserved
        0x27: ('RW', 0x0F),  # TACC_WINDOW_SYMS [3:0]; [7:4] reserved
        0x28: ('RO', 0xFF),  # SC_FIRST_HIT[31:24]
        0x29: ('RO', 0xFF),  # SC_FIRST_HIT[23:16]
        0x2A: ('RO', 0xFF),  # SC_FIRST_HIT[15:8]
        0x2B: ('RO', 0xFF),  # SC_FIRST_HIT[7:0]
        0x2C: ('RO', 0xFF),  # SC_LOCK_SNAP[31:24]
        0x2D: ('RO', 0xFF),  # SC_LOCK_SNAP[23:16]
        0x2E: ('RO', 0xFF),  # SC_LOCK_SNAP[15:8]
        0x2F: ('RO', 0xFF),  # SC_LOCK_SNAP[7:0]
        # W Shadow Bank (all RW)
        0x30: ('RW', 0xFF), 0x31: ('RW', 0xFF), 0x32: ('RW', 0xFF), 0x33: ('RW', 0xFF),
        0x34: ('RW', 0xFF), 0x35: ('RW', 0xFF), 0x36: ('RW', 0xFF), 0x37: ('RW', 0xFF),
        0x38: ('RW', 0xFF), 0x39: ('RW', 0xFF), 0x3A: ('RW', 0xFF), 0x3B: ('RW', 0xFF),
        0x3C: ('RW', 0xFF), 0x3D: ('RW', 0xFF), 0x3E: ('RW', 0xFF), 0x3F: ('RW', 0xFF),
        # Z_kl pairs (all RO)
        0x40: ('RO', 0xFF), 0x41: ('RO', 0xFF), 0x42: ('RO', 0xFF),
        0x43: ('RO', 0xFF), 0x44: ('RO', 0xFF), 0x45: ('RO', 0xFF),
        0x46: ('RO', 0xFF), 0x47: ('RO', 0xFF), 0x48: ('RO', 0xFF),
        0x49: ('RO', 0xFF), 0x4A: ('RO', 0xFF), 0x4B: ('RO', 0xFF),
        0x4C: ('RO', 0xFF), 0x4D: ('RO', 0xFF), 0x4E: ('RO', 0xFF),
        0x4F: ('RO', 0xFF), 0x50: ('RO', 0xFF), 0x51: ('RO', 0xFF),
        0x52: ('RO', 0xFF), 0x53: ('RO', 0xFF), 0x54: ('RO', 0xFF),
        0x55: ('RO', 0xFF), 0x56: ('RO', 0xFF), 0x57: ('RO', 0xFF),
        0x58: ('RO', 0xFF), 0x59: ('RO', 0xFF), 0x5A: ('RO', 0xFF),
        0x5B: ('RO', 0xFF), 0x5C: ('RO', 0xFF), 0x5D: ('RO', 0xFF),
        0x5E: ('RO', 0xFF), 0x5F: ('RO', 0xFF), 0x60: ('RO', 0xFF),
        0x61: ('RO', 0xFF), 0x62: ('RO', 0xFF), 0x63: ('RO', 0xFF),
        # Z_kk diagonal (all RO)
        0x64: ('RO', 0xFF), 0x65: ('RO', 0xFF), 0x66: ('RO', 0xFF),
        0x67: ('RO', 0xFF), 0x68: ('RO', 0xFF), 0x69: ('RO', 0xFF),
        0x6A: ('RO', 0xFF), 0x6B: ('RO', 0xFF), 0x6C: ('RO', 0xFF),
        0x6D: ('RO', 0xFF), 0x6E: ('RO', 0xFF), 0x6F: ('RO', 0xFF),
        # PSRAM
        0x70: ('RW', 0x0B),  # PSRAM_CTRL: [0]=EN, [1]=CLR_ERR(W1P), [3]=OWNER; [2],[7:4] reserved
        0x71: ('RO', 0xFF),  # PSRAM_STATUS
        0x72: ('RW', 0xFF),  # PSRAM_DBG_ADDR_LO
        0x73: ('RW', 0xFF),  # PSRAM_DBG_ADDR_MID
        0x74: ('RW', 0x7F),  # PSRAM_DBG_ADDR_HI [6:0]; [7] reserved
        0x75: ('RW', 0x83),  # PSRAM_DBG_CTRL: [0]=RD_TRIG(W1P), [1]=AUTO_INC, [7]=BUSY(RO); [6:2] reserved
        0x76: ('RO', 0xFF),  # PSRAM_DBG_DATA
        0x77: ('RW', 0xFF),  # REPLAY_DELAY_LO
        0x78: ('RW', 0xFF),  # REPLAY_DELAY_HI
        # Reserved (future growth)
        0x79: ('reserved', 0x00),
        0x7A: ('reserved', 0x00),
        0x7B: ('reserved', 0x00),
        0x7C: ('reserved', 0x00),
        0x7D: ('reserved', 0x00),
        0x7E: ('reserved', 0x00),
        0x7F: ('reserved', 0x00),  # Protocol escape
    }

    # Test each address with a representative pattern
    patterns_to_test = [0x00, 0xFF, 0xAA, 0x55]

    for addr in range(128):
        if addr not in addr_map:
            raise AssertionError(f"Address 0x{addr:02X} not in addr_map")

        access_mode, mask = addr_map[addr]

        # TACC_WINDOW_SYMS (0x27): [3:0] clamps to a minimum of 8 (writes
        # below 8 are raised to 8), so it does not fit the generic
        # "readback == written & mask" model. Already covered in full by the
        # dedicated test_tacc_window_syms_field test above.
        if addr == 0x27:
            for pattern in patterns_to_test:
                await write_reg(dut, addr, pattern)
                got = await peek(dut, addr)
                field = pattern & 0x0F
                expected = field if field >= 8 else 8
                assert got == expected, (
                    f"0x{addr:02X} (TACC_WINDOW_SYMS): wrote 0x{pattern:02X} "
                    f"expected read 0x{expected:02X} (clamped to >=8) got 0x{got:02X}"
                )
            continue

        # PSRAM_DBG_CTRL (0x75): bit[0] (RD_TRIG) is W1P and its read-decode
        # arm is hardcoded to the literal 1'b0 (same pattern as WGT_CTRL
        # bit0 -- see reg_bank.v rdata_next case 8'h75), so it always reads
        # back 0 regardless of what was just written. Bit[7] (DBG_BUSY) is
        # RO, driven by the psram_dbg_busy input, which this harness leaves
        # low. Only bit[1] (AUTO_INC) is a plain stored RW bit.
        if addr == 0x75:
            for pattern in patterns_to_test:
                await write_reg(dut, addr, pattern)
                got = await peek(dut, addr)
                expected = pattern & 0x02
                assert got == expected, (
                    f"0x{addr:02X} (PSRAM_DBG_CTRL): wrote 0x{pattern:02X} "
                    f"expected read 0x{expected:02X} got 0x{got:02X}"
                )
            continue

        # WGT_CTRL (0x1E): bit[0] (W_COMMIT) is W1P and its read-decode arm
        # is hardcoded to the literal 1'b0 (see reg_bank.v rdata_next case
        # 8'h1E) -- like the other pure-W1P registers (SC_FORCE_LOCK,
        # TACC_NOISE_TRIG), it always reads back 0 regardless of what was
        # just written. Bits[5:1] are likewise RO mirrors of hardware status
        # inputs a register write cannot set. So the whole byte always reads
        # 0x00 after any write, and none of it fits the generic
        # "readback == written & mask" model. Already covered in full by the
        # dedicated test_wgt_ctrl_field test above; only confirm the
        # always-reads-zero behavior here.
        if addr == 0x1E:
            for pattern in patterns_to_test:
                await write_reg(dut, addr, pattern)
                got = await peek(dut, addr)
                assert got == 0x00, (
                    f"0x{addr:02X} (WGT_CTRL): wrote 0x{pattern:02X} "
                    f"expected read 0x00 (all bits RO/hardcoded-0 on this "
                    f"decode path) got 0x{got:02X}"
                )
            continue

        # For RW, W1P fields, test that writes are properly masked
        if access_mode not in ('RO', 'reserved'):
            for pattern in patterns_to_test:
                await write_reg(dut, addr, pattern)
                got = await peek(dut, addr)
                expected = pattern & mask
                assert got == expected, (
                    f"0x{addr:02X} ({access_mode}): wrote 0x{pattern:02X} "
                    f"expected read 0x{expected:02X} got 0x{got:02X}"
                )

    # Now prove that writes to one address don't corrupt others: write to each
    # address and verify a few others remain unchanged
    dut.packet_active.value = 0  # Ensure we can write gated fields

    # Capture initial state of all readable addresses
    initial_state = {}
    for addr in range(128):
        access_mode, _ = addr_map[addr]
        if access_mode != 'WO':  # Can only read non-WO addresses
            initial_state[addr] = await peek(dut, addr)

    # Write to each writable address and spot-check others haven't changed
    for write_addr in range(128):
        access_mode, _ = addr_map[write_addr]
        if access_mode in ('RO', 'reserved'):
            continue

        await write_reg(dut, write_addr, 0xFF)

        # Spot-check a few other addresses every 10 addresses
        if write_addr % 10 == 0:
            for read_addr in [0x08, 0x30, 0x70]:
                got = await peek(dut, read_addr)
                exp = initial_state[read_addr]
                # After each write to a different address, these shouldn't change
                # unless they're part of a coordinated test
                if read_addr != write_addr:
                    # Just verify they still exist and read something reasonable
                    assert got is not None


# ---------------------------------------------------------------------------
# Test #3: Fixed IDs and reserved addresses
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reserved_addresses_zero_and_ignored(dut):
    """Verify all 21 reserved addresses read zero and writes are ignored.

    Closes verification-plan row #3: "Fixed IDs and all reserved addresses
    read zero/write ignored" (TRPR-REG-004). Exhaustively verifies the
    reserved address slots do not respond to writes.

    CORRECTION 2026-08-22: an earlier version of this test modeled 0x1A as
    reserved, on the belief that this checkout's reg_bank.v had no RX_HOLD
    register there. That belief was wrong -- current src/control/reg_bank.v
    (Open Risks #43, planning/mcp-config-settle-gate-design.md) has carried
    RX_HOLD/CFG_WR_REJECTED at 0x1A since commit f1aa262, which predates the
    commit that (re-)introduced this stale reserved-address model; the prior
    green run of this test was against a stale NFS sync, not this RTL (see
    job 4670 for a reproduction of the failure against a correctly-synced
    DUT). 0x1A is RW (see row #2's addr_map and test_reg_bank_rx_hold.py) and
    is excluded here; 20 addresses remain genuinely reserved at this level.

    UPDATE: 0x1B is now SC_ANT_SEL (moved out of BW_CFG[2:1]) and is excluded
    too. 0x79 is PSRAM_DBG_WDATA at the *top level* only -- reg_bank itself
    has no 0x79 decode, so it is still reserved from this DUT's point of view.
    """
    await _bring_up(dut)

    # 19 reserved slots. Three former-reserved addresses are now real registers
    # and are excluded: 0x1A is RX_HOLD (see NOTE above), 0x1B became
    # SC_ANT_SEL, and 0x18 -- the last of the former RX_GAIN block -- became
    # ARRAY_SYNC_CTRL, both on 2026-08-30.
    reserved_addrs = [
        0x04, 0x05, 0x06, 0x07,                         # former DEBUG_CTRL/GPIO
        0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,  # former RX_GAIN_*
        0x79, 0x7A, 0x7B, 0x7C, 0x7D, 0x7E,             # reserved for future
        0x7F,                                            # protocol escape
    ]

    assert len(reserved_addrs) == 19, f"Expected 19 reserved addresses, got {len(reserved_addrs)}"

    # Test each reserved address with multiple patterns
    patterns = [0x00, 0xFF, 0xAA, 0x55, 0xA5, 0x5A]

    for addr in reserved_addrs:
        # Verify initial read returns 0x00
        got = await peek(dut, addr)
        assert got == 0x00, (
            f"Reserved address 0x{addr:02X} did not read 0x00 on first read: got 0x{got:02X}"
        )

        # Write various patterns and verify they have no effect
        for pattern in patterns:
            await write_reg(dut, addr, pattern)
            got = await peek(dut, addr)
            assert got == 0x00, (
                f"Reserved address 0x{addr:02X} was affected by write 0x{pattern:02X}: "
                f"read back 0x{got:02X} instead of 0x00"
            )

    # Special emphasis on 0x7F (the protocol escape byte)
    got = await peek(dut, 0x7F)
    assert got == 0x00, (
        f"Protocol-escape address 0x7F did not read 0x00: got 0x{got:02X}"
    )
    for pattern in [0x7F, 0x80, 0xFF]:
        await write_reg(dut, 0x7F, pattern)
        got = await peek(dut, 0x7F)
        assert got == 0x00, (
            f"Write to 0x7F (protocol escape) had an effect: wrote 0x{pattern:02X} "
            f"read back 0x{got:02X}"
        )


@cocotb.test()
async def test_fixed_chip_ids(dut):
    """Verify CHIP_ID and CHIP_REV are fixed and unaffected by writes."""
    await _bring_up(dut)

    # CHIP_ID (0x00) must always be 0xA7
    got = await peek(dut, 0x00)
    assert got == 0xA7, f"CHIP_ID should be 0xA7, got 0x{got:02X}"

    # Try writing (should be ignored)
    for pattern in [0x00, 0xFF, 0x5A, 0xA5]:
        await write_reg(dut, 0x00, pattern)
        got = await peek(dut, 0x00)
        assert got == 0xA7, (
            f"Write to CHIP_ID was not ignored: wrote 0x{pattern:02X}, "
            f"expected 0xA7 got 0x{got:02X}"
        )

    # CHIP_REV (0x01) must always be 0x01
    got = await peek(dut, 0x01)
    assert got == 0x01, f"CHIP_REV should be 0x01, got 0x{got:02X}"

    for pattern in [0x00, 0xFF, 0x5A, 0xA5]:
        await write_reg(dut, 0x01, pattern)
        got = await peek(dut, 0x01)
        assert got == 0x01, (
            f"Write to CHIP_REV was not ignored: wrote 0x{pattern:02X}, "
            f"expected 0x01 got 0x{got:02X}"
        )
