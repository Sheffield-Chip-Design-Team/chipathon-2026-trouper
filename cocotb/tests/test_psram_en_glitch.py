"""
test_psram_en_glitch.py -- PSRAM_EN dropped mid-transaction with
state==S_REPLAY, port driven directly (TRPR-PSR-009, closes verification
plan gap #15/#19).

Traceability (planning/verification-plan/psram-buf-ctrl-verification-plan.md
§2 row 19): TRPR-PSR-009 requires PSRAM_EN=0 => no QSPI pad assertion. Row
15 covers the steady-state (idle, PSRAM_EN held 0 from reset) half via
formal (`a_buf_active_needs_en`). Row 19 is the dynamic half: PSRAM_EN
dropping WHILE state==S_REPLAY (an in-flight same-packet delay-line replay).

Why this can't be a formal proof (see this session's reachability probe):
formal/psram_buf_ctrl_formal.sv's environment assumptions
`m_buf_active_implies_packet_active` + `m_psram_en_stable_in_packet` jointly
forbid PSRAM_EN from ever changing while packet_active=1 -- and buf_active
(hence packet_active, by the first assumption) is asserted throughout
S_REPLAY. A temporary `cover (state==S_REPLAY && $past(psram_en) &&
!psram_en)` added to the checker and run at depth 90 (`mode cover`) came
back "Unreached cover statement" -- confirmed formally unreachable under
those assumptions, not just unproven. This is *correct* modelling of the
real firmware/register contract: reg_bank.v (`8'h70: if (!packet_active)
psram_ctrl[0] <= wdata[0];`) makes it physically impossible for firmware to
write PSRAM_EN=0 while a packet (hence a replay) is in flight -- the formal
proof is telling us the truth about that path.

But the verification-plan row explicitly asks for the port "driven
directly", i.e. bypassing reg_bank's write-gate entirely -- modelling a
fault (SEU, ESD glitch, corrupted register cell) that flips the PSRAM_EN
bit itself, not a firmware register write through the SPI path.

Implementation note on WHERE the force is applied, found empirically this
session: `dut.u_dut.u_psram.psram_en` (the psram_buf_ctrl port net) is a
pure continuous copy of `rb_psram_ctrl[0]` -- Verilator's flattened model
recomputes it from that source on every eval pass, so a Python `.value = 0`
poke there gets silently overwritten before the next posedge samples it
(confirmed: an early version of this test forcing that net saw a "new
burst" launch anyway, because the FSM's own `iq_valid && psram_en` check
still read the true upstream value). The genuine state-holding element is
`rb_psram_ctrl` itself -- `reg_bank.v`'s `psram_ctrl` register
(`output reg [3:0] psram_ctrl`, instantiated as `u_rb`, only bit 1 self-
clears every `clk_en` cycle; bit 0/2/3 hold unless an explicit write
executes) -- forcing THAT persists exactly like a real fault would, and is
electrically the same node the psram_buf_ctrl port reads. This test forces
`dut.u_dut.u_rb.psram_ctrl` bit 0, bypassing spi_write/reg_bank's
`if (!packet_active) psram_ctrl[0] <= wdata[0];` gate entirely -- never
going through the register-write path.

What's checked once PSRAM_EN is forced low while state==S_REPLAY:
  1. Pad safety invariant (same as test_qspi_owner.py): CE# low always
     implies SCK running -- an in-flight burst must complete glitch-free,
     not get chopped off mid-transaction just because PSRAM_EN dropped.
  2. No NEW burst launches while PSRAM_EN stays forced low (the S_REPLAY
     launch gate is `iq_valid && psram_en && !qspi_owner` -- RTL line
     ~715): qpi_busy stays low once any in-flight burst finishes.
  3. wr_ptr/rd_ptr are frozen (no forward progress) once the in-flight
     burst finishes -- confirms buffering/replay is genuinely paused, not
     silently corrupting the delay line.
  4. packet_end (which fires independently of PSRAM_EN, via PKT_TIMEOUT_SYMS)
     still cleanly returns the FSM to S_WRITE -- not stuck/deadlocked by
     the glitch. Uses a short PKT_TIMEOUT_SYMS (test_replay_delay.py's
     precedent) so packet_end is reachable within a bounded sim window.
  5. After release (SPI PSRAM_EN=1, now legal again since packet_active=0
     post packet_end) the NEXT packet buffers and replays normally --
     full recovery, no latched-bad state left over from the glitch.
"""

import cocotb
from cocotb.triggers import RisingEdge, Timer

from test_trouper_top import spi_read, spi_write
from test_bypass_e2e import _reset_and_lock

PKT_TIMEOUT_SYMS = 20   # same short window used by test_replay_delay.py
GLITCH_HOLD_CLKS = 96   # several full QPI bursts' worth (burst = 56 sub-cycles in S_REPLAY)


async def _pads(dut):
    return (int(dut.psram_ce_n.value),
            int(dut.psram_sio_oe.value),
            int(dut.u_dut.u_psram.sck_en.value))


def _force_psram_en(dut, value):
    """Force PSRAM_EN (bit 0 of reg_bank's psram_ctrl register) directly,
    bypassing spi_write/reg_bank's write-gate entirely -- see module
    docstring for why this is the register itself, not the psram_buf_ctrl
    port net (which is a continuously-re-driven copy that a plain .value
    poke cannot persistently override in the Verilator flattened model)."""
    cur = int(dut.u_dut.u_rb.psram_ctrl.value)
    new = (cur | 0x1) if value else (cur & ~0x1)
    dut.u_dut.u_rb.psram_ctrl.value = new


@cocotb.test()
async def test_psram_en_glitch_mid_replay(dut):
    tag = "psram_en_glitch"

    # _reset_and_lock starts the CW driver (sdm_driver_multi) internally.
    sym_ns = await _reset_and_lock(dut, mode=0, ant_mask=0xF, tag=tag,
                                    pkt_timeout_syms=PKT_TIMEOUT_SYMS,
                                    replay_delay=64)

    # training_done -> small margin -> REPLAY_ACTIVE
    train_ok = False
    for _ in range(40):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x02:
            train_ok = True
            break
    assert train_ok, f"{tag}: training_done never fired"

    await spi_write(dut, 0x1E, 0x01)   # W_COMMIT
    replay_ok = False
    for _ in range(40):
        await Timer(sym_ns // 4, unit="ns")
        if (await spi_read(dut, 0x71)) & 0x10:
            replay_ok = True
            break
    assert replay_ok, f"{tag}: REPLAY never became active"

    # ---------------------------------------------------------------------
    # Get genuinely mid-transaction: wait for a burst to start (qpi_busy
    # 0->1) then run a few more cycles into it, so the fault really lands
    # inside an in-flight QPI transaction, not at an idle boundary.
    # ---------------------------------------------------------------------
    started = False
    for _ in range(1000):
        await RisingEdge(dut.IQ_CLK)
        if int(dut.u_dut.u_psram.qpi_busy.value) == 1:
            started = True
            break
    assert started, f"{tag}: no QPI burst observed in S_REPLAY within 1000 clks"

    for _ in range(5):
        await RisingEdge(dut.IQ_CLK)

    assert int(dut.u_dut.u_psram.state.value) == 3, \
        f"{tag}: expected state==S_REPLAY(3) at glitch injection, got {int(dut.u_dut.u_psram.state.value)}"
    assert int(dut.u_dut.u_psram.qpi_busy.value) == 1, \
        f"{tag}: burst ended before injection point -- not actually mid-transaction"
    dut._log.info(f"{tag}: confirmed mid-transaction (state==S_REPLAY, qpi_busy=1) -- injecting fault")

    # ---------------------------------------------------------------------
    # Inject the fault: force PSRAM_EN low at the register bit that feeds
    # the psram_buf_ctrl port (see _force_psram_en / module docstring) --
    # NOT via spi_write/reg_bank. Held low every cycle for GLITCH_HOLD_CLKS.
    #
    # "New burst launch" is tracked via qpi_busy (the RTL's own in-flight
    # marker), not raw CE#/SIO_OE: a SINGLE S_REPLAY transaction toggles
    # CE# high for exactly one cycle at the write-phase/read-phase boundary
    # (sub==24->25, RTL lines ~750-758) while qpi_busy stays 1 throughout --
    # that internal blip must not be mistaken for "idle then relaunched".
    # ---------------------------------------------------------------------
    quiesced_at = None
    wr_at_quiesce = rd_at_quiesce = None
    prev_busy = 1
    for n in range(GLITCH_HOLD_CLKS):
        _force_psram_en(dut, 0)
        await RisingEdge(dut.IQ_CLK)
        ce_n, oe, sck_en = await _pads(dut)
        # Invariant #1: never leave a selected device unclocked mid-burst
        # (the in-flight transaction must finish glitch-free).
        assert not (ce_n == 0 and sck_en == 0), \
            f"{tag}: CE# low with SCK gated at glitch-hold clk {n} -- pad glitch"

        busy = int(dut.u_dut.u_psram.qpi_busy.value)
        if prev_busy == 1 and busy == 0 and quiesced_at is None:
            quiesced_at = n
            wr_at_quiesce = int(dut.u_dut.u_psram.wr_ptr.value)
            rd_at_quiesce = int(dut.u_dut.u_psram.rd_ptr.value)
        elif quiesced_at is not None:
            assert busy == 0, \
                f"{tag}: a NEW QPI burst launched (qpi_busy 0->1) at clk {n}, " \
                f"after the in-flight one finished at clk {quiesced_at}, " \
                f"despite PSRAM_EN being forced low the whole time"
        prev_busy = busy

    assert quiesced_at is not None, \
        f"{tag}: the in-flight burst never finished (qpi_busy stuck at 1) within {GLITCH_HOLD_CLKS} clks"
    dut._log.info(f"{tag}: in-flight burst finished cleanly at glitch-hold clk {quiesced_at}, "
                   f"no new burst launched through clk {GLITCH_HOLD_CLKS}")

    # Invariant #3: no forward progress on either pointer after the
    # already-in-flight burst finished -- buffering/replay genuinely
    # paused once EN dropped, not silently corrupting data.
    wr_after = int(dut.u_dut.u_psram.wr_ptr.value)
    rd_after = int(dut.u_dut.u_psram.rd_ptr.value)
    assert wr_after == wr_at_quiesce, \
        f"{tag}: wr_ptr advanced ({wr_at_quiesce}->{wr_after}) after quiescing while PSRAM_EN forced low"
    assert rd_after == rd_at_quiesce, \
        f"{tag}: rd_ptr advanced ({rd_at_quiesce}->{rd_after}) after quiescing while PSRAM_EN forced low"

    # ---------------------------------------------------------------------
    # Invariant #4: packet_end (independent of PSRAM_EN, driven by the
    # short PKT_TIMEOUT_SYMS configured above) still cleanly returns the
    # FSM to S_WRITE -- the glitch does not deadlock the FSM. PSRAM_EN
    # stays forced low the whole way through packet_end -- it is a real
    # register (see _force_psram_en), so a single force here persists
    # without needing to be re-applied every cycle.
    # ---------------------------------------------------------------------
    _force_psram_en(dut, 0)
    end_ok = False
    for _ in range(PKT_TIMEOUT_SYMS + 15):
        await Timer(sym_ns, unit="ns")
        if int(dut.u_dut.u_psram.state.value) == 2:  # S_WRITE
            end_ok = True
            break
    assert end_ok, f"{tag}: FSM never returned to S_WRITE after packet_end -- deadlock"
    assert int(dut.u_dut.u_rb.psram_ctrl.value) & 0x1 == 0, \
        f"{tag}: PSRAM_EN unexpectedly changed on its own while forced low"
    dut._log.info(f"{tag}: FSM returned to S_WRITE cleanly after packet_end "
                   f"with PSRAM_EN still forced low -- no deadlock")

    # ---------------------------------------------------------------------
    # Invariant #5: release the glitch and restore control the legitimate
    # way (SPI write -- legal now that packet_active=0), confirm full
    # recovery on the next packet.
    # ---------------------------------------------------------------------
    await spi_write(dut, 0x70, 0x01)   # PSRAM_EN=1 via the real register path
    await Timer(200, unit="ns")
    assert int(dut.u_dut.u_psram.psram_en.value) == 1, \
        f"{tag}: PSRAM_EN did not restore to 1 after the recovery SPI write"

    lock2_ok = False
    for _ in range(40):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x01:
            lock2_ok = True
            break
    assert lock2_ok, f"{tag}: sc_lock never re-fired on the next packet after recovery"

    replay2_ok = False
    for _ in range(160):
        await Timer(sym_ns // 4, unit="ns")
        if (await spi_read(dut, 0x71)) & 0x10:
            replay2_ok = True
            break
    assert replay2_ok, f"{tag}: REPLAY never became active again after recovery"

    dut._log.info(f"{tag}: PASS -- PSRAM_EN forced low mid-S_REPLAY caused no pad glitch, "
                  f"no spurious burst, no pointer corruption, no deadlock; "
                  f"full recovery confirmed on the next packet")
