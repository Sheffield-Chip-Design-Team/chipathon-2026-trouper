"""
test_w_missed_packet.py -- W_MISSED_PACKET regression (no-W_COMMIT packet).

Traceability (planning/Traceability.md): TRPR-PCF-005 (primary), plus the
W_MISSED_PACKET readback halves of TRPR-PCF-009 / TRPR-MRC-011, the
PACKET_DONE-IRQ sub-gap of TRPR-PCF-007, and (added 2026-07-06, retargeted
2026-07-26) TRPR-PCF-002 / TRPR-PCF-008: the packet-phase output asserted at
packet start, held through PAYLOAD_ACTIVE, de-asserted at IDLE entry,
re-asserted at the next packet start. These checks originally observed
buf_freeze; that output was deleted 2026-07-26 (bit-identical to
packet_active, consumed by nothing), so they now watch packet_active
directly at the same four points.

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

Extended (verification-plan rows #7/#8, Open Risk #42) with the two other
ways a packet can reach PAYLOAD_ACTIVE without a clean on-time W_COMMIT:
  * test_w_missed_on_acq_timeout -- training never completes at all (forced
    via u_tacc.training_done), so the miss comes from the ACQ_CNT==0 branch
    in ST_PREAMBLE_ACQ, a direct PREAMBLE_ACQ -> PAYLOAD_ACTIVE transition
    that skips ST_W_PENDING entirely -- a different RTL branch than the
    wpend-timeout miss above.
  * test_w_commit_late_during_payload -- a W_COMMIT that arrives AFTER the
    wpend-timeout miss has already happened, mid-ST_PAYLOAD_ACTIVE; proves
    the late-commit upgrade path is burst-atomic at the combiner boundary
    and the sticky miss bit stays historical.
"""

import cocotb
from cocotb.triggers import RisingEdge, Timer

from test_trouper_top import CLK_NS, spi_read, spi_write, spi_burst_write
from test_bypass_e2e import _reset_and_lock, _watch_bypass

PKT_TIMEOUT_SYMS = 20

# SF7/BW250 (sample_shift=1): M = 1<<(sf+shift) = 256 samples/symbol, and
# _reset_and_lock's sdm_driver_multi runs at 64 clocks/decimated IQ sample --
# both hardcoded there. Rows #7/#8 below use this to size clock-level watch
# windows relative to the symbol-level SPI polling the other tests use.
CLKS_PER_SYM = 256 * 64


@cocotb.test()
async def test_w_missed_on_wpend_timeout(dut):
    tag = "w_missed"
    # replay_delay=0xFFFF: margin never met inside the 20-sym packet, so the
    # PSRAM delay-line replay never starts and the whole packet stays in the
    # modulated-silence phase (the FSM miss path under test is orthogonal to
    # the replay timeout ladder -- that lives in test_replay_delay.py).
    sym_ns = await _reset_and_lock(dut, mode=0, ant_mask=0xF, tag=tag,
                                   pkt_timeout_syms=PKT_TIMEOUT_SYMS,
                                   replay_delay=0xFFFF)

    pkt_status = await spi_read(dut, 0x1C)
    assert pkt_status & 0x01, f"{tag}: PACKET_ACTIVE not set after sc_lock (0x{pkt_status:02X})"

    # TRPR-PCF-002: packet_active asserts at packet start (sc_lock edge) and
    # holds through the packet -- checked at the FSM output, not just via the
    # PACKET_STATUS readback above.
    assert int(dut.u_dut.packet_active.value) == 1, \
        f"{tag}: packet_active not asserted after sc_lock (TRPR-PCF-002)"

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
    assert int(dut.u_dut.packet_active.value) == 1, \
        f"{tag}: packet_active dropped during PAYLOAD_ACTIVE (TRPR-PCF-002)"
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
    # TRPR-PCF-008: packet_active de-asserts on IDLE entry
    assert int(dut.u_dut.packet_active.value) == 0, \
        f"{tag}: packet_active still asserted after return to IDLE (TRPR-PCF-008)"
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
    assert int(dut.u_dut.packet_active.value) == 1, \
        f"{tag}: packet_active not re-asserted at the next packet start (TRPR-PCF-002)"
    dut._log.info(f"{tag}: PASS -- miss IRQ, sticky readback through IDLE, bypass payload, "
                  f"PACKET_DONE IRQ, clear-on-next-packet all confirmed")


async def _force_no_training_done(dut):
    """Continuously pin u_tacc.training_done low (row #7).

    training_acc.v declares `output reg training_done`, written only inside
    its own sequential always block (set once at window completion, cleared
    at reset/re-arm) -- NOT a continuously-recomputed combinational copy of
    some other register (that would need the psram_en-style "force the real
    state-holding element" workaround from test_psram_status_overflow_bit_
    wiring/test_psram_en_glitch.py). A single poke would still be silently
    overwritten the instant the real accumulator completes, so this re-pokes
    it to 0 every clock, for as long as the coroutine runs, to guarantee the
    FSM can never observe a training_done edge -- the only way out of
    ST_PREAMBLE_ACQ is then the acq_cnt==0 timeout branch under test."""
    while True:
        await RisingEdge(dut.IQ_CLK)
        dut.u_dut.u_tacc.training_done.value = 0


@cocotb.test()
async def test_w_missed_on_acq_timeout(dut):
    """Row #7 (TRPR-PCF-001/005/010, Open Risk #42): acquisition-timeout
    path -- training never completes, so the FSM must leave ST_PREAMBLE_ACQ
    through the acq_cnt==0 branch directly into ST_PAYLOAD_ACTIVE, WITHOUT
    ever passing through ST_W_PENDING. Proves:
      * the direct PREAMBLE_ACQ -> PAYLOAD_ACTIVE transition (packet_phase
        never reads 2/W_PENDING);
      * W_missed_packet is a genuine 1-cycle pulse at that transition;
      * the sticky PACKET_STATUS[7]/WGT_CTRL[3] mirror is readable;
      * PACKET_STATUS.TRAINING_DONE ([4]) stays clear and IRQ_STATUS.
        TRAINING_DONE ([1]) never fires;
      * payload runs in bypass (no weights ever existed to apply);
      * the packet still reaches PACKET_DONE and the sticky bit clears at
        the next lock -- firmware is never deadlocked by an all-noise/no-
        preamble-completion packet (TRPR-PCF-010).

    training_done is forced low every clock from before lock (see
    _force_no_training_done) through the whole acquisition window, so
    ST_W_PENDING's `training_done` branch can never fire; the only exit
    from ST_PREAMBLE_ACQ is the acq_cnt==0 timeout under test.

    Sizing (SF7/BW250, tacc_window_syms=8 default, M=256): acq_span =
    tacc_window_span + 2M = 10*M = 2560 samples = 10 symbols after
    ST_ACQ_SETUP (packet_ctrl_fsm.v acq_span/acq_load). The test confirms
    phase stays PREAMBLE_ACQ for 7 full symbols (coarse, symbol-granularity,
    no SPI needed) before switching to a clock-accurate watch for the
    timeout edge itself, sized generously (6 more symbols) to absorb the
    small elapsed-since-lock correction in acq_load without needing the
    exact cycle."""
    tag = "w_missed_acq"

    force_task = cocotb.start_soon(_force_no_training_done(dut))

    sym_ns = await _reset_and_lock(dut, mode=0, ant_mask=0xF, tag=tag,
                                   pkt_timeout_syms=PKT_TIMEOUT_SYMS,
                                   replay_delay=0xFFFF)

    pkt_status = await spi_read(dut, 0x1C)
    assert pkt_status & 0x01, f"{tag}: PACKET_ACTIVE not set after sc_lock (0x{pkt_status:02X})"
    assert (pkt_status >> 1) & 0x7 == 1, \
        f"{tag}: PACKET_PHASE != PREAMBLE_ACQ right after lock (0x{pkt_status:02X})"

    # -- coarse: confirm no premature timeout/training_done for 7 symbols --
    for i in range(7):
        await Timer(sym_ns, unit="ns")
        ph = int(dut.u_dut.u_pcfsm.packet_phase.value)
        assert ph == 1, \
            f"{tag}: packet_phase={ph} != 1 (PREAMBLE_ACQ) prematurely at symbol " \
            f"{i + 1} -- unexpected relative to the acq_span=10*M sizing assumption"
        irq = await spi_read(dut, 0x02)
        assert not (irq & 0x02), \
            f"{tag}: TRAINING_DONE IRQ fired despite the u_tacc force (0x{irq:02X})"

    # -- fine: clock-accurate watch for the timeout edge + pulse width -----
    watch_cycles = 6 * CLKS_PER_SYM
    saw_w_pending = False
    pulses = 0
    run = 0
    max_run = 0
    prev_missed = 0
    phase3_at = None
    for c in range(watch_cycles):
        await RisingEdge(dut.IQ_CLK)
        ph = int(dut.u_dut.u_pcfsm.packet_phase.value)
        if ph == 2:
            saw_w_pending = True
        missed = int(dut.u_dut.u_pcfsm.W_missed_packet.value)
        if missed and not prev_missed:
            pulses += 1
        run = run + 1 if missed else 0
        max_run = max(max_run, run)
        prev_missed = missed
        if ph == 3 and phase3_at is None:
            phase3_at = c
            break

    assert phase3_at is not None, \
        f"{tag}: acquisition timeout never fired within {watch_cycles} clocks " \
        f"({watch_cycles / CLKS_PER_SYM:.1f} extra symbols past the 7-symbol coarse wait)"
    assert not saw_w_pending, \
        f"{tag}: packet_phase passed through W_PENDING (2) -- acquisition timeout must go " \
        f"directly PREAMBLE_ACQ -> PAYLOAD_ACTIVE (TRPR-PCF-001)"
    assert pulses == 1, \
        f"{tag}: W_missed_packet pulsed {pulses} times, expected exactly 1"
    assert max_run == 1, \
        f"{tag}: W_missed_packet held high for {max_run} clocks, expected a 1-cycle pulse"
    dut._log.info(f"{tag}: direct ACQ->PAYLOAD transition confirmed, 1-cycle miss pulse "
                  f"at clock {phase3_at} of the fine watch window")

    # -- sticky readback (both documented positions), no TRAINING_DONE -----
    pkt_status = await spi_read(dut, 0x1C)
    wgt = await spi_read(dut, 0x1E)
    irq = await spi_read(dut, 0x02)
    assert (pkt_status >> 1) & 0x7 == 3, \
        f"{tag}: PACKET_PHASE != PAYLOAD_ACTIVE after acq timeout (0x{pkt_status:02X})"
    assert pkt_status & 0x80, \
        f"{tag}: PACKET_STATUS[7].W_MISSED_PACKET not readable (0x{pkt_status:02X})"
    assert wgt & 0x08, f"{tag}: WGT_CTRL[3].W_MISSED_PACKET not readable (0x{wgt:02X})"
    assert not (pkt_status & 0x10), \
        f"{tag}: PACKET_STATUS.TRAINING_DONE set despite the u_tacc force (0x{pkt_status:02X})"
    assert not (pkt_status & 0x40), \
        f"{tag}: PACKET_STATUS.W_VALID set on an acq-timeout packet (0x{pkt_status:02X})"
    assert not (wgt & 0x02), f"{tag}: WGT_CTRL.W_VALID set on an acq-timeout packet (0x{wgt:02X})"
    assert not (irq & 0x02), \
        f"{tag}: IRQ_STATUS.TRAINING_DONE set despite the u_tacc force (0x{irq:02X})"
    assert irq & 0x04, f"{tag}: IRQ_STATUS.W_MISSED_PACKET not set (0x{irq:02X})"
    dut._log.info(f"{tag}: sticky readback + no-TRAINING_DONE confirmed "
                  f"(PACKET_STATUS=0x{pkt_status:02X} WGT_CTRL=0x{wgt:02X} IRQ=0x{irq:02X})")

    # -- payload runs in bypass (no weights ever existed) -------------------
    assert int(dut.u_dut.u_comb.use_mrc_r.value) == 0, \
        f"{tag}: use_mrc_r=1 on an acq-timeout packet -- combiner left bypass without weights"
    assert int(dut.u_dut.packet_active.value) == 1, \
        f"{tag}: packet_active dropped during PAYLOAD_ACTIVE (TRPR-PCF-002)"
    await _watch_bypass(dut, 0, 10, tag=f"{tag}/payload-bypass",
                        expect_silenced=True, check_remod=False)

    # -- packet still reaches PACKET_DONE and re-arms (no deadlock) --------
    done_ok = False
    for _ in range(PKT_TIMEOUT_SYMS + 5):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x08:
            done_ok = True
            break
    assert done_ok, f"{tag}: PACKET_DONE IRQ never fired at packet timeout"

    pkt_status = await spi_read(dut, 0x1C)
    assert not (pkt_status & 0x01), f"{tag}: PACKET_ACTIVE still set in IDLE (0x{pkt_status:02X})"
    assert int(dut.u_dut.packet_active.value) == 0, \
        f"{tag}: packet_active still asserted after return to IDLE (TRPR-PCF-008)"
    assert pkt_status & 0x80, \
        f"{tag}: W_MISSED_PACKET readback lost at IDLE entry (0x{pkt_status:02X})"

    await spi_write(dut, 0x03, 0xFF)   # clear IRQs
    relock_ok = False
    for _ in range(20):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x01:
            relock_ok = True
            break
    assert relock_ok, f"{tag}: no re-lock after IDLE (SC re-arm) -- deadlock (TRPR-PCF-010)"

    pkt_status = await spi_read(dut, 0x1C)
    assert not (pkt_status & 0x80), \
        f"{tag}: W_MISSED_PACKET not cleared at next packet start (0x{pkt_status:02X})"
    dut._log.info(f"{tag}: PASS -- direct ACQ timeout transition, 1-cycle pulse, sticky "
                  f"readback, no TRAINING_DONE, bypass payload, PACKET_DONE, re-arm all "
                  f"confirmed")

    force_task.cancel()


@cocotb.test()
async def test_w_commit_late_during_payload(dut):
    """Row #8 (Open Risk #42, EDGE-SIM): a W_COMMIT that arrives AFTER the
    FSM has already declared a W-pending-timeout miss and entered
    ST_PAYLOAD_ACTIVE in bypass (same entry path as
    test_w_missed_on_wpend_timeout). Proves:
      * W_VALID (WGT_CTRL[1]/PACKET_STATUS[6]) asserts from the late commit;
      * the sticky W_MISSED_PACKET mirror stays set -- it is HISTORICAL for
        this packet and a late commit does not un-happen the miss;
      * the bypass->MRC switch at the combiner is burst-atomic: exactly one
        use_mrc_r transition, coincident with mrc_combiner's own state==0
        x_valid burst-start boundary (mrc_combiner.v line ~129:
        `use_mrc_r <= W_valid && !mode` is sampled only in state 0), never
        mid-burst;
      * only the post-commit remainder of the packet actually combines --
        the pre-commit pairings stay bit-exact bypass, the post-commit ones
        diverge (weights applied)."""
    tag = "w_commit_late"
    sym_ns = await _reset_and_lock(dut, mode=0, ant_mask=0xF, tag=tag,
                                   pkt_timeout_syms=PKT_TIMEOUT_SYMS,
                                   replay_delay=0xFFFF)

    # -- reach PAYLOAD_ACTIVE via the wpend-timeout miss path (row #6) -----
    train_ok = False
    for _ in range(40):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x02:
            train_ok = True
            break
    assert train_ok, f"{tag}: training_done never fired"

    miss_ok = False
    for _ in range(15):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x04:
            miss_ok = True
            break
    assert miss_ok, f"{tag}: W_MISSED_PACKET IRQ never fired after withholding W_COMMIT"

    pkt_status = await spi_read(dut, 0x1C)
    wgt = await spi_read(dut, 0x1E)
    assert (pkt_status >> 1) & 0x7 == 3, \
        f"{tag}: PACKET_PHASE != PAYLOAD_ACTIVE after wpend timeout (0x{pkt_status:02X})"
    assert pkt_status & 0x80, f"{tag}: PACKET_STATUS.W_MISSED not set (0x{pkt_status:02X})"
    assert wgt & 0x08, f"{tag}: WGT_CTRL.W_MISSED not set (0x{wgt:02X})"
    assert not (wgt & 0x02), \
        f"{tag}: WGT_CTRL.W_VALID already set before any commit (0x{wgt:02X})"
    assert int(dut.u_dut.u_comb.use_mrc_r.value) == 0, \
        f"{tag}: use_mrc_r=1 before any W_COMMIT -- combiner not in bypass"

    # -- confirm still-bypass output BEFORE the late commit -----------------
    await _watch_bypass(dut, 0, 10, tag=f"{tag}/pre-commit",
                        expect_silenced=True, check_remod=False)

    # -- late W_COMMIT: watch the combiner's own use_mrc_r/state boundary --
    switch = {"changes": 0, "cycle": None, "state_at_switch": None}

    async def _watch_switch():
        prev_use = int(dut.u_dut.u_comb.use_mrc_r.value)
        for c in range(2000):
            await RisingEdge(dut.IQ_CLK)
            use = int(dut.u_dut.u_comb.use_mrc_r.value)
            if use != prev_use:
                switch["changes"] += 1
                switch["cycle"] = c
                switch["state_at_switch"] = int(dut.u_dut.u_comb.state.value)
                prev_use = use
                if use == 1:
                    break

    watch_task = cocotb.start_soon(_watch_switch())

    await spi_burst_write(dut, 0x30, [0x40] * 16)   # deliberately non-trivial weights
    await spi_write(dut, 0x1E, 0x01)                # late W_COMMIT (W1P)

    await watch_task

    assert switch["changes"] == 1, \
        f"{tag}: use_mrc_r changed {switch['changes']} times -- expected exactly one " \
        f"bypass->MRC transition (glitch, or the late commit never took effect)"
    # use_mrc_r and the state==1 advance are written by the same state==0
    # x_valid clause in the same always block -- observing state==1 at the
    # cycle use_mrc_r first reads 1 proves the switch landed exactly at a
    # burst-start boundary (state was 0 the cycle before), not mid-burst.
    assert switch["state_at_switch"] == 1, \
        f"{tag}: use_mrc_r flipped with combiner state={switch['state_at_switch']}, " \
        f"expected 1 (i.e. the switch coincided with a state==0 x_valid burst start, " \
        f"not a mid-burst glitch)"
    dut._log.info(f"{tag}: bypass->MRC switch burst-atomic (1 transition, landed at "
                  f"burst-start boundary, clock {switch['cycle']} of the watch window)")

    pkt_status = await spi_read(dut, 0x1C)
    wgt = await spi_read(dut, 0x1E)
    assert wgt & 0x02, f"{tag}: WGT_CTRL.W_VALID not set after late commit (0x{wgt:02X})"
    assert pkt_status & 0x40, \
        f"{tag}: PACKET_STATUS.W_VALID not set after late commit (0x{pkt_status:02X})"
    # the miss is HISTORICAL for this packet -- a late commit must not erase it
    assert pkt_status & 0x80, \
        f"{tag}: PACKET_STATUS.W_MISSED cleared by a late commit -- must stay historical " \
        f"for this packet (0x{pkt_status:02X})"
    assert wgt & 0x08, \
        f"{tag}: WGT_CTRL.W_MISSED cleared by a late commit -- must stay historical " \
        f"for this packet (0x{wgt:02X})"
    assert (pkt_status >> 1) & 0x7 == 3, \
        f"{tag}: PACKET_PHASE left PAYLOAD_ACTIVE after a late commit (0x{pkt_status:02X})"

    # -- post-commit remainder: MRC now applied, output diverges from raw --
    diffs = await _watch_bypass(dut, 0, 20, tag=f"{tag}/post-commit",
                                expect_silenced=True, check_remod=False,
                                expect_bypass=False)
    assert int(dut.u_dut.u_comb.use_mrc_r.value) == 1, \
        f"{tag}: use_mrc_r reverted to bypass after the switch"
    assert diffs >= 5, \
        f"{tag}: only {diffs}/20 post-commit outputs differ from the raw ant0 sample -- " \
        f"weights do not appear applied to the remainder of the packet"

    dut._log.info(f"{tag}: PASS -- late commit during PAYLOAD_ACTIVE sets W_VALID, sticky "
                  f"miss stays historical, bypass->MRC switch burst-atomic, only the "
                  f"post-commit remainder combines")
