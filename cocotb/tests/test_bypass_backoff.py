"""
test_bypass_backoff.py -- Open Risk #65.

TRPR-PCF-011 / TRPR-RMD-008: in Mode 1 (passthrough) the selected antenna's
int8 decimated sample must reach sd_remod's input directly, unweighted and
unscaled. trouper_top.v:922-923 instead applies

    remod_in_* = psram_silence ? 0 : (comb_y_* >>> rb_remod_backoff_shift)

for every mode, and reg_bank.v resets remod_backoff_shift to 1. So at power-up
defaults the bypass stream is right-shifted by one (~6 dB) before the
re-modulator. test_bypass_e2e.py masks this by writing COMB_CFG=0x01 (shift 0)
before its bit-exact compare; this test keeps the RESET DEFAULT shift.

Flow: lock in Mode 1, restore COMB_CFG to its reset value (0x10 = backoff
shift 1, post-gain 0), wait for PSRAM replay to lift psram_silence, then on
every clean combiner pairing require remod_in == comb_y. Regresses the #65 fix
(REMOD_BACKOFF_SHIFT gated to the MRC path via mrc_combiner's use_mrc output;
branch rtl/open-risk-fixes): bypass now passes the raw int8 sample through
unshifted. PASS once the fix is in.

Top-level bench, TOPLEVEL = tb_trouper_cocotb.
"""

import cocotb
from cocotb.triggers import RisingEdge, Timer

from test_trouper_top import spi_read, spi_write
from test_bypass_e2e import _reset_and_lock

COMB_CFG_RESET = 0x10        # {REMOD_BACKOFF_SHIFT=1[5:4], COMB_POST_GAIN_SHIFT=0[2:0]}
N_PAIRS = 50
NONZERO_FLOOR = 10           # pairings whose |comb_y_i| >= 2 (so >>1 loses a bit)


@cocotb.test()
async def test_bypass_keeps_reset_backoff_and_attenuates(dut):
    tag = "bypass_backoff"

    # mode=1 passthrough, all antennas -> bypass_ant = 0. _reset_and_lock writes
    # COMB_CFG=0x01 (shift 0) for its own compare; we undo that next.
    sym_ns = await _reset_and_lock(dut, mode=1, ant_mask=0xF, tag=tag,
                                   replay_delay=64)

    # Restore the value the chip powers up with. 0x0F is not in the RX_HOLD
    # locked set, so this mid-packet write takes effect immediately.
    await spi_write(dut, 0x0F, COMB_CFG_RESET)
    rb = await spi_read(dut, 0x0F)
    assert rb == COMB_CFG_RESET, f"{tag}: COMB_CFG readback 0x{rb:02X} != 0x{COMB_CFG_RESET:02X}"
    assert int(dut.u_dut.rb_remod_backoff_shift.value) == 1, \
        f"{tag}: rb_remod_backoff_shift != 1 after restoring the reset default"

    # training_done, then wait for replay to engage (psram_silence -> 0)
    for _ in range(40):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x02:
            break
    replay_ok = False
    for _ in range(400_000):
        await RisingEdge(dut.IQ_CLK)
        ra = dut.u_dut.psram_replay_active_w.value
        if ra.is_resolvable and int(ra):
            replay_ok = True
            break
    assert replay_ok, f"{tag}: psram_replay_active never asserted -- remod_in stays silenced"

    # -- compare remod_in vs comb_y on clean pairings ----------------------
    pend_valid = False
    checked = nonzero = attenuated = 0
    exact = 0
    for _ in range(N_PAIRS * 400):
        await RisingEdge(dut.IQ_CLK)
        yv = dut.u_dut.comb_y_valid.value
        if not (yv.is_resolvable and int(yv)):
            continue
        sil = dut.u_dut.psram_silence.value
        if sil.is_resolvable and int(sil):
            continue
        ci = int(dut.u_dut.comb_y_i.value.signed_integer)
        cq = int(dut.u_dut.comb_y_q.value.signed_integer)
        ri = int(dut.u_dut.remod_in_i.value.signed_integer)
        rq = int(dut.u_dut.remod_in_q.value.signed_integer)
        checked += 1
        if (ri, rq) == (ci, cq):
            exact += 1
        if (ri, rq) == (ci >> 1, cq >> 1):
            attenuated += 1
        if abs(ci) >= 2 or abs(cq) >= 2:
            nonzero += 1
        if checked >= N_PAIRS:
            break

    dut._log.info(f"{tag}: {checked} pairings -- remod_in==comb_y on {exact}, "
                  f"remod_in==comb_y>>1 on {attenuated}, {nonzero} with |comb_y|>=2")

    assert checked >= N_PAIRS, f"{tag}: only {checked}/{N_PAIRS} clean pairings"
    assert nonzero >= NONZERO_FLOOR, \
        f"{tag}: only {nonzero} pairings had |comb_y|>=2 -- stimulus too weak to show a >>1 loss"
    assert exact == checked, (
        f"{tag}: remod_in matched comb_y on only {exact}/{checked} pairings "
        f"({attenuated} were comb_y>>1) -- Mode 1 bypass is attenuated by the reset-default "
        f"REMOD_BACKOFF_SHIFT=1 instead of delivering the raw antenna sample "
        f"(TRPR-PCF-011 / TRPR-RMD-008, Open Risk #65)")
