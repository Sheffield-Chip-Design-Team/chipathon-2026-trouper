"""test_reg_bank_w1p_precedence.py -- W-shadow reject/W1C precedence and
cycle-exact W1P assert-then-self-clear timing for the standalone reg_bank
harness (``cocotb/reg_bank``, direct-DUT: no SPI/CDC framing).

Closes verification-plan rows #10 and #11
(planning/verification-plan/reg-bank-verification-plan.md):

  #10 "W-shadow reject and W1C clear on the same CE edge" -- reg_bank.v
     implements ``w_wr_rejected`` with:

         if (we && (addr[7:4] == 4'h3) && w_valid_rb)
             w_wr_rejected <= 1'b1;
         else if (we && addr == 8'h1E && wdata[5])
             w_wr_rejected <= 1'b0;

     The set (0x30-0x3F write dropped by W_VALID) and clear (0x1E W1C)
     conditions are keyed off mutually exclusive addresses, so within one
     write cycle they cannot literally collide on the register-bus's single
     address/data port -- this suite instead pins the *sequential*
     precedence the "if / else if" ordering promises: a clear does not
     leave the flag stuck low against a genuinely new rejection on a later
     write (i.e. the set branch is not starved by having been "else if"),
     and a single 0x1E write can carry both the W1C (bit[5]) and a fresh
     W_COMMIT pulse (bit[0]) in the same cycle without either interfering
     with the other -- including the specific case named by the row,
     wdata[5]=1 with wdata[0]=0, which must clear the reject flag and must
     NOT emit a W_COMMIT pulse.
  #11 "All four W1P fields assert for one CE period and self-clear"
     (TRPR-REG-006) -- cycle-exact port checks, for all four bits named by
     the requirement (TACC_NOISE_TRIG 0x1F[0], WGT_CTRL.W_COMMIT 0x1E[0],
     PSRAM_CTRL.PSRAM_CLR_ERR 0x70[1], PSRAM_DBG_CTRL.RD_TRIG 0x75[0]):
     each output asserts high for exactly the one clk_en cycle immediately
     following its triggering write and is low again by the very next
     clk_en cycle, without re-asserting on later idle cycles. (SC_FORCE_LOCK
     0x19[0] is also W1P in the RTL, but TRPR-REG-006 only names these four
     bits -- SC_FORCE_LOCK's pulse shape is exercised functionally by
     ``cocotb/sc_force_lock`` and the packet_active-gated pulse check in
     row #8's ``test_packet_active_blocks_sc_force_lock``.)

Scope and layering (see the plan's Sec 4 "Explicit non-goals"): this suite
reuses ``reg_bank_map_oracle``'s ``peek``/``write_reg`` helpers and the
``_bring_up``/``_idle_inputs`` harness bring-up from ``test_reg_bank_rw_map``
for consistency with the rest of this standalone suite. As documented there,
this harness holds ``clk_en`` asserted every clk cycle, so "one CE period"
here is exactly one clk cycle; the real 16 MHz half-rate CE boundary and the
2-cycle-wide SPI ``we`` contract belong to rows #12/#16/#17 and the full-top
``spi_cdc``/full-block regression, not to this direct-DUT harness.
"""

import cocotb
from cocotb.triggers import RisingEdge, Timer

from reg_bank_map_oracle import peek, write_reg
from test_reg_bank_rw_map import _bring_up

WGT_CTRL_ADDR = 0x1E


async def _settle(dut):
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")


# ---------------------------------------------------------------------------
# Row #10: W-shadow reject / W1C-clear precedence
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_w_wr_rejected_set_then_clear_then_new_rejection_wins(dut):
    """Sequence: a dropped 0x30-0x3F write sets W_WR_REJECTED; a 0x1E W1C
    clears it; a further dropped write (still under W_VALID) re-asserts it
    -- the earlier clear must not leave the set branch starved."""
    await _bring_up(dut)
    dut.packet_active.value = 0
    # DBG_STATUS (0x05) reads this back; the reg_bank bench drives the
    # module directly, so an undriven input would return X and break
    # any read of that address.
    dut.dbg_pad_value.value = 0
    dut.w_valid_rb.value = 1  # combiner holds a live weight set: all shadow writes drop

    # 1) A shadow write while W_VALID is high is dropped and latches the
    #    reject flag; the byte itself must not be perturbed.
    before = await peek(dut, 0x30)
    await write_reg(dut, 0x30, 0xAB)
    after = await peek(dut, 0x30)
    assert after == before, f"0x30 accepted a write while W_VALID=1: got 0x{after:02X}"
    got = await peek(dut, WGT_CTRL_ADDR)
    assert (got >> 5) & 1 == 1, "W_WR_REJECTED did not set on a dropped shadow write"

    # 2) W1C clear via WGT_CTRL bit[5]=1, bit[0]=0 (no commit requested).
    await write_reg(dut, WGT_CTRL_ADDR, 0x20)
    got = await peek(dut, WGT_CTRL_ADDR)
    assert (got >> 5) & 1 == 0, "W_WR_REJECTED did not clear on 0x1E W1C write"
    assert int(dut.w_commit_pulse.value) == 0, (
        "W_COMMIT pulsed on a W1C-only write (wdata[0]=0)"
    )

    # 3) A NEW dropped write (W_VALID still high) must re-assert the flag --
    #    the prior clear must not have starved the set branch.
    await write_reg(dut, 0x31, 0xCD)
    got = await peek(dut, WGT_CTRL_ADDR)
    assert (got >> 5) & 1 == 1, (
        "a new rejection after a clear failed to re-assert W_WR_REJECTED"
    )
    after31 = await peek(dut, 0x31)
    assert after31 == 0x00, "0x31 accepted a write while W_VALID=1 after a prior clear"

    dut.w_valid_rb.value = 0


@cocotb.test()
async def test_w_wr_rejected_clear_and_commit_same_write(dut):
    """A single 0x1E write with wdata[5]=1 (W1C) and wdata[0]=1 (W_COMMIT)
    together must do both: clear the sticky reject flag AND pulse
    w_commit_pulse for that cycle -- the two live in the same always block
    on different regs and must not interfere."""
    await _bring_up(dut)
    dut.packet_active.value = 0
    # DBG_STATUS (0x05) reads this back; the reg_bank bench drives the
    # module directly, so an undriven input would return X and break
    # any read of that address.
    dut.dbg_pad_value.value = 0
    dut.w_valid_rb.value = 1

    await write_reg(dut, 0x32, 0xEE)  # dropped write -> sets W_WR_REJECTED
    got = await peek(dut, WGT_CTRL_ADDR)
    assert (got >> 5) & 1 == 1, "precondition failed: W_WR_REJECTED not set"

    await write_reg(dut, WGT_CTRL_ADDR, 0x21)  # bit[5]=1 (W1C) and bit[0]=1 (W_COMMIT)
    assert int(dut.w_commit_pulse.value) == 1, (
        "W_COMMIT did not pulse on a combined W1C+W_COMMIT write"
    )
    got = await peek(dut, WGT_CTRL_ADDR)
    assert (got >> 5) & 1 == 0, (
        "W_WR_REJECTED did not clear on a combined W1C+W_COMMIT write"
    )

    await _settle(dut)
    assert int(dut.w_commit_pulse.value) == 0, "w_commit_pulse did not self-clear"

    dut.w_valid_rb.value = 0


@cocotb.test()
async def test_w1c_bit_alone_does_not_reject_or_land_shadow_write(dut):
    """A 0x1E write is never itself a 0x3x address, so it can never trip the
    set branch -- confirms the address-exclusivity the row's precedence
    argument rests on, and that WGT_CTRL writes never touch w_shadow."""
    await _bring_up(dut)
    dut.packet_active.value = 0
    # DBG_STATUS (0x05) reads this back; the reg_bank bench drives the
    # module directly, so an undriven input would return X and break
    # any read of that address.
    dut.dbg_pad_value.value = 0
    dut.w_valid_rb.value = 0  # shadow writes would normally be accepted

    before = await peek(dut, 0x30)
    await write_reg(dut, WGT_CTRL_ADDR, 0x20)
    after = await peek(dut, 0x30)
    assert after == before, "a WGT_CTRL write perturbed the W shadow bank"
    got = await peek(dut, WGT_CTRL_ADDR)
    assert (got >> 5) & 1 == 0, "W_WR_REJECTED spuriously set by a WGT_CTRL-only write"


# ---------------------------------------------------------------------------
# Row #11: all four TRPR-REG-006 W1P fields, cycle-exact assert/self-clear
# ---------------------------------------------------------------------------

async def _assert_one_ce_period_pulse(dut, write_addr, wdata, port_getter, label):
    """Drive one write to ``write_addr``/``wdata``, confirm ``port_getter(dut)``
    reads 1 immediately after that write's clk edge, reads 0 on the very next
    clk edge (with no further writes), and stays 0 for a few more idle
    cycles (no re-assertion, no multi-cycle stretch)."""
    assert port_getter(dut) == 0, f"{label}: not idle-low before the triggering write"

    await write_reg(dut, write_addr, wdata)
    assert port_getter(dut) == 1, f"{label}: did not assert on the triggering write's edge"

    await _settle(dut)
    assert port_getter(dut) == 0, f"{label}: did not self-clear the cycle after assertion"

    for _ in range(3):
        await _settle(dut)
        assert port_getter(dut) == 0, f"{label}: re-asserted on a later idle cycle"


@cocotb.test()
async def test_tacc_noise_trig_w1p_cycle_exact(dut):
    """TACC_NOISE_TRIG 0x1F[0] -> noise_trig."""
    await _bring_up(dut)
    await _assert_one_ce_period_pulse(
        dut, 0x1F, 0x01, lambda d: int(d.noise_trig.value), "TACC_NOISE_TRIG"
    )


@cocotb.test()
async def test_wgt_ctrl_w_commit_w1p_cycle_exact(dut):
    """WGT_CTRL.W_COMMIT 0x1E[0] -> w_commit_pulse."""
    await _bring_up(dut)
    await _assert_one_ce_period_pulse(
        dut, WGT_CTRL_ADDR, 0x01, lambda d: int(d.w_commit_pulse.value), "WGT_CTRL.W_COMMIT"
    )


@cocotb.test()
async def test_psram_ctrl_clr_err_w1p_cycle_exact(dut):
    """PSRAM_CTRL.PSRAM_CLR_ERR 0x70[1] -> psram_ctrl[1]. Written alongside
    EN=0/QSPI_OWNER=0 so only bit[1] is exercised; EN/OWNER are plain RW and
    covered elsewhere (rows #4/#8)."""
    await _bring_up(dut)
    await _assert_one_ce_period_pulse(
        dut, 0x70, 0x02, lambda d: (int(d.psram_ctrl.value) >> 1) & 1, "PSRAM_CTRL.PSRAM_CLR_ERR"
    )


@cocotb.test()
async def test_psram_dbg_ctrl_rd_trig_w1p_cycle_exact(dut):
    """PSRAM_DBG_CTRL.RD_TRIG 0x75[0] -> psram_dbg_rd_trig. Written with
    AUTO_INC=0 so only bit[0] is exercised; AUTO_INC is plain RW and covered
    elsewhere (row #4)."""
    await _bring_up(dut)
    await _assert_one_ce_period_pulse(
        dut, 0x75, 0x01, lambda d: int(d.psram_dbg_rd_trig.value), "PSRAM_DBG_CTRL.RD_TRIG"
    )


@cocotb.test()
async def test_w1p_fields_independent_no_cross_trigger(dut):
    """Writing one W1P bit must not spuriously pulse any of the other three
    -- a single shared "auto-clear all W1P regs" block feeding four
    independent set conditions is exactly the kind of RTL where a copy-paste
    address typo would cross-wire two fields."""
    await _bring_up(dut)

    def _all(dut):
        return (
            int(dut.noise_trig.value),
            int(dut.w_commit_pulse.value),
            (int(dut.psram_ctrl.value) >> 1) & 1,
            int(dut.psram_dbg_rd_trig.value),
        )

    assert _all(dut) == (0, 0, 0, 0)

    await write_reg(dut, 0x1F, 0x01)  # TACC_NOISE_TRIG only
    assert _all(dut) == (1, 0, 0, 0), "TACC_NOISE_TRIG write cross-triggered another W1P bit"
    await _settle(dut)

    await write_reg(dut, WGT_CTRL_ADDR, 0x01)  # W_COMMIT only
    assert _all(dut) == (0, 1, 0, 0), "W_COMMIT write cross-triggered another W1P bit"
    await _settle(dut)

    await write_reg(dut, 0x70, 0x02)  # PSRAM_CLR_ERR only
    assert _all(dut) == (0, 0, 1, 0), "PSRAM_CLR_ERR write cross-triggered another W1P bit"
    await _settle(dut)

    await write_reg(dut, 0x75, 0x01)  # PSRAM_DBG_CTRL.RD_TRIG only
    assert _all(dut) == (0, 0, 0, 1), "PSRAM_DBG_CTRL.RD_TRIG write cross-triggered another W1P bit"
    await _settle(dut)

    assert _all(dut) == (0, 0, 0, 0)
