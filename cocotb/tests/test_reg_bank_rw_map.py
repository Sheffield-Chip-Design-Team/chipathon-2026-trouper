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
