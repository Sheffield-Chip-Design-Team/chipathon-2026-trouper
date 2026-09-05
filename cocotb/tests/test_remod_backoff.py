"""
test_remod_backoff.py -- regression for REMOD_BACKOFF_SHIFT (COMB_CFG 0x0F
bits[5:4]), the RTL safety net between the MRC combiner and the sd_remod
re-modulator.

sd_remod.v's own header note (SX1257 6.2.3): "noise shaper should be stable
for input signals lower than -3 dBFS; integrator outputs are saturated to
avoid wraparound." REMOD_BACKOFF_SHIFT right-shifts the combiner output
before it reaches sd_remod specifically to hold that margin (reset default
shift=1, i.e. -6 dB). This test:

  1. verifies the shift is actually applied end-to-end -- remod_in_i/q ==
     comb_y_i/q >>> shift, bit-exact, for shift in {0,1,2,3};
  2. demonstrates the failure mode the shift exists to prevent: a forced
     near-full-scale (~0 dBFS) combiner output makes sd_remod's 1-bit
     quantizer output freeze (lose its dither) for measurably longer runs
     at shift=0 than at the reset-default shift=1, at the same amplitude.
     (sat16 already clips sd_remod's integrators, so they never literally
     wrap around or get permanently stuck -- see `_monitor_remod`'s
     docstring for why the integrator states themselves turned out not to
     be a usable instability signal, and the output stuck-run is used
     instead.)

Rather than driving a stronger analog stimulus to reach a large combiner
output (which would need to propagate through the PSRAM same-packet delay
line before showing up at the combiner -- once REPLAY engages, the
rd_ptr/wr_ptr gap is fixed at 8M+50 samples for the rest of the packet, so
any *upstream* signal change only shows up several ms later), this test
keeps the standard proven-safe SF7/BW250 lock/training stimulus
(`sdm_driver`, A=31, from test_trouper_top.py) unchanged throughout, and
instead forces the combiner itself into saturation via an aggressive MRC
weight (`W_re0=0x7F`, near-unity on antenna 0 only) + maximum
`COMB_POST_GAIN_SHIFT=7`. mrc_combiner.v reads `rb_w_shadow` and
`post_gain_shift` combinationally on every combine cycle (no separate
"active" latch) -- so this takes effect immediately, no re-lock or
PSRAM-delay wait needed, and `sat_i`/`sat_q` in mrc_combiner.v clip to the
full +-127 int8 range whenever the scaled accumulator exceeds it, giving a
reliable full-scale test input.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from test_trouper_top import (CLK_NS, spi_read, spi_write, spi_burst_write,
                              sdm_driver, release_rx_hold)

REPLAY_DELAY = 64      # output samples after training_done before REPLAY engages
                       # (reset default is 1500 ~= 3 ms, far longer than this test
                       # needs to wait; see the 0x77/0x78 write in the config block)
SAT_FLOOR = 100        # comb_y peak must reach at least this to call it "saturated"
# Recalibrated 2026-09-04 for the sd_remod 4th-order excess-loop-delay fix (see
# planning/ss-timing-closure-exploration-2026-09-04.md). The old 3-tap loop was
# only marginally stable near full scale; the new 4th-order loop is properly
# designed and dithers far better everywhere, so the absolute stuck-run numbers
# dropped by ~3x even in the "degraded" case -- the old thresholds (100/120),
# calibrated against job 3293's 3-tap numbers, no longer distinguish anything.
# Job 5572 (post-fix) measured: low-amplitude sanity (both shifts) = 3-4 cycles;
# shift=1 at forced near-full-scale = 5 cycles; shift=0 at forced near-full-scale
# = 54 cycles -- backoff still clearly helps (~10x), just at a smaller absolute
# scale now that the modulator itself doesn't need it as urgently.
STUCK_HEALTHY = 20     # output stuck-run below this = still dithering (~4x margin
                       # above the measured 3-5 cycle healthy ceiling, well below
                       # the 54-cycle degraded case).
STUCK_DEGRADED = 35    # shift=0 at forced near-full-scale measured 54 -- clearly
                       # above STUCK_HEALTHY with margin in both directions.


async def _set_comb_cfg(dut, shift, pgs=7):
    """COMB_CFG (0x0F): bits[5:4]=REMOD_BACKOFF_SHIFT, bits[2:0]=COMB_POST_GAIN_SHIFT."""
    val = ((shift & 0x3) << 4) | (pgs & 0x7)
    await spi_write(dut, 0x0F, val)
    rb = await spi_read(dut, 0x0F)
    assert rb == val, f"COMB_CFG readback 0x{rb:02X} != written 0x{val:02X}"


async def _check_shift_wiring(dut, shift, n=60):
    """Sample (comb_y, remod_in) on comb_y_valid pulses and confirm the RTL
    applies exactly comb_y >>> shift (Verilog arithmetic shift == Python >>
    for signed ints -- both floor towards -inf)."""
    await _set_comb_cfg(dut, shift, pgs=7)
    checked = 0
    silenced = 0
    for _ in range(n * 400):   # comb_y_valid pulses once per 64 IQ_CLK cycles
        await RisingEdge(dut.IQ_CLK)
        yv = dut.u_dut.comb_y_valid.value
        if yv.is_resolvable and int(yv):
            # trouper_top.v:571-573 --
            #   psram_silence = psram_buf_active && !psram_replay_active_w
            #   remod_in_* = psram_silence ? 0 : (comb_y_* >>> shift)
            # While the PSRAM is buffering and replay has not yet engaged, the
            # remod input is deliberately forced to 0 (Open Risk #5: emitting a
            # live combiner output during buffering produced a SigmaDelta DC
            # tone). The shift is genuinely not applied in that window, so
            # sampling there is not a wiring failure -- skip those pulses and
            # require enough post-silence samples instead. Without this the
            # test fails at the first pulse after sc_lock with remod_in=0.
            sil = dut.u_dut.psram_silence.value
            if sil.is_resolvable and int(sil):
                silenced += 1
                continue
            ci = int(dut.u_dut.comb_y_i.value.signed_integer)
            cq = int(dut.u_dut.comb_y_q.value.signed_integer)
            ri = int(dut.u_dut.remod_in_i.value.signed_integer)
            rq = int(dut.u_dut.remod_in_q.value.signed_integer)
            assert ri == (ci >> shift), \
                f"shift={shift}: remod_in_i={ri} expected comb_y_i({ci})>>>{shift}={ci >> shift}"
            assert rq == (cq >> shift), \
                f"shift={shift}: remod_in_q={rq} expected comb_y_q({cq})>>>{shift}={cq >> shift}"
            checked += 1
            if checked >= n:
                break
    assert checked >= n // 2, (
        f"shift={shift}: only {checked} un-silenced comb_y_valid samples observed "
        f"({silenced} skipped while psram_silence was asserted) -- replay may "
        f"never have engaged, so the shift path was never exercised")
    dut._log.info(f"shift={shift}: wiring OK ({checked} samples, bit-exact; "
                  f"{silenced} skipped during psram_silence)")


async def _monitor_remod(dut, cycles):
    """Run `cycles` IQ_CLK edges (sd_remod.clk_32m == the same clock in this
    integration harness) and record sd_remod's three integrator states,
    comb_y (to confirm saturation is actually happening), and REMOD_A_I
    toggling, so the caller can classify healthy vs. railed.

    Note: sd_remod's integrator states (s1/s2/s3) turn out NOT to be a
    usable instability signal on their own -- s3 in particular sits near
    the sat16 rail (+-32767) essentially all the time even in totally
    healthy, low-amplitude, already-proven-good operating conditions
    (job 3292 diagnostic: duty=0.85 at comb_y peak=30, the same amplitude
    test_trouper_top.py's run_scenario already passes its REMOD toggle
    check at). That's normal CIFF cascade-integrator behavior, not a fault.
    The real, unambiguous instability signal is the 1-bit OUTPUT losing its
    dither -- getting stuck at a constant value for an extended run -- so
    this tracks REMOD_A_I/Q's bit sequence for that instead."""
    s1i, s2i, s3i = [], [], []
    s1q, s2q, s3q = [], [], []
    comb_peak = []
    out_i_bits, out_q_bits = [], []
    for _ in range(cycles):
        await RisingEdge(dut.IQ_CLK)
        s1i.append(int(dut.u_dut.u_remod.s1_i.value.signed_integer))
        s2i.append(int(dut.u_dut.u_remod.s2_i.value.signed_integer))
        s3i.append(int(dut.u_dut.u_remod.s3_i.value.signed_integer))
        s1q.append(int(dut.u_dut.u_remod.s1_q.value.signed_integer))
        s2q.append(int(dut.u_dut.u_remod.s2_q.value.signed_integer))
        s3q.append(int(dut.u_dut.u_remod.s3_q.value.signed_integer))
        yv = dut.u_dut.comb_y_valid.value
        if yv.is_resolvable and int(yv):
            comb_peak.append(abs(int(dut.u_dut.comb_y_i.value.signed_integer)))
        out_i_bits.append(int(dut.REMOD_A_I.value) & 1)
        out_q_bits.append(int(dut.REMOD_A_Q.value) & 1)
    return dict(s1i=s1i, s2i=s2i, s3i=s3i, s1q=s1q, s2q=s2q, s3q=s3q,
                comb_peak=(max(comb_peak) if comb_peak else 0),
                out_i_bits=out_i_bits, out_q_bits=out_q_bits)


def _longest_stuck_run(bits):
    """Longest run of consecutive identical bits -- the quantizer output
    losing its dither (frozen at 0 or 1) is the real, unambiguous
    instability signature for a 1-bit noise shaper."""
    longest = cur = 1
    for a, b in zip(bits, bits[1:]):
        cur = cur + 1 if b == a else 1
        longest = max(longest, cur)
    return longest


@cocotb.test()
async def test_remod_backoff(dut):
    sf, bw_khz = 7, 250
    sample_shift = 1
    M = 1 << (sf + sample_shift)
    clk_per_iq = 64

    # -- reset ----------------------------------------------------------------
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

    cocotb.start_soon(sdm_driver(dut, sf, bw_khz))

    # -- SPI settle -------------------------------------------------------
    await spi_read(dut, 0x00)
    await spi_read(dut, 0x09)

    # -- configure SF/BW, SC threshold (1 hit fires lock), default MIMO_CTRL
    # (MRC mode, all antennas) -- mirrors test_trouper_top.py's run_scenario
    await spi_write(dut, 0x09, sf & 0x0F)
    await spi_write(dut, 0x0A, 0)   # 250 kHz
    await spi_write(dut, 0x0C, 0x01)
    await spi_write(dut, 0x0D, 0x00)
    await spi_write(dut, 0x0E, 0x00)

    # Shorten the replay delay (0x77 LO / 0x78 HI, reset default 1500 output
    # samples ~= 3 ms) so REPLAY engages promptly after training_done. Until it
    # does, psram_silence holds remod_in at 0 (trouper_top.v:571-573) and the
    # backoff shift is not observable at all. reg_bank blocks these two
    # addresses while packet_active, so this MUST land before sc_lock.
    await spi_write(dut, 0x77, REPLAY_DELAY & 0xFF)
    await spi_write(dut, 0x78, (REPLAY_DELAY >> 8) & 0xFF)

    # RX_HOLD (0x1A) is SET out of reset and level-gates sc_clr, so the
    # detector can never lock until firmware releases it. The locked config
    # registers above (0x09/0x0A/0x0E) are only writable while it is held, so
    # release must come after them -- see
    # planning/mcp-config-settle-gate-design.md.
    #
    # COMB_CFG (0x0F), written later by _set_comb_cfg during the packet, is
    # NOT in the locked set, so the mid-packet backoff-shift changes this test
    # relies on are unaffected by the interlock.
    await release_rx_hold(dut)

    # -- enable PSRAM + wait INIT_DONE (required: psram_buf_ctrl is the SC
    # detector's delay line, sc_lock can never fire without it) -------------
    await spi_write(dut, 0x70, 0x01)
    init_ok = False
    for _ in range(500):
        await Timer(8 * CLK_NS, unit="ns")
        if (await spi_read(dut, 0x71)) & 0x08:
            init_ok = True
            break
    assert init_ok, "PSRAM INIT_DONE never set"

    # -- poll sc_lock -------------------------------------------------------
    sym_ns = M * clk_per_iq * CLK_NS
    lock_ok = False
    for _ in range(20):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x01:
            lock_ok = True
            break
    assert lock_ok, "sc_lock never fired"
    dut._log.info("sc_lock OK")

    await spi_write(dut, 0x03, 0xFF)   # clear IRQ

    # -- poll training_done ---------------------------------------------------
    train_ok = False
    for _ in range(40):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x02:
            train_ok = True
            break
    assert train_ok, "training_done never fired"
    dut._log.info("training_done OK")

    # -- wait for REPLAY to engage, which lifts psram_silence ------------------
    # remod_in is held at 0 while psram_buf_active && !psram_replay_active, so
    # none of the shift checks below can observe anything until this asserts.
    replay_ok = False
    for _ in range(400_000):
        await RisingEdge(dut.IQ_CLK)
        ra = dut.u_dut.psram_replay_active_w.value
        if ra.is_resolvable and int(ra):
            replay_ok = True
            break
    assert replay_ok, (
        f"psram_replay_active never asserted within 400k cycles of training_done "
        f"(replay_delay_samples={REPLAY_DELAY}) -- remod_in stays silenced at 0, "
        f"so the backoff shift is unobservable")
    dut._log.info("psram_replay_active OK -- psram_silence lifted")

    # -- commit an aggressive, near-unity weight on antenna 0 only + max
    # post_gain_shift: reliably clips comb_y to +-127 (full scale) at our
    # safe A=31 lock/training amplitude, without needing a stronger analog
    # stimulus (see module docstring for why that's avoided). W_SHADOW and
    # COMB_CFG are both read combinationally by mrc_combiner every combine
    # cycle -- no re-lock or settle wait needed after this write.
    await spi_burst_write(dut, 0x30, [
        0x7F, 0x00, 0x00, 0x00,   # ant 0: W_re=127 (near unity), W_im=0
        0x00, 0x00, 0x00, 0x00,   # ant 1: zero
        0x00, 0x00, 0x00, 0x00,   # ant 2: zero
        0x00, 0x00, 0x00, 0x00,   # ant 3: zero
    ])
    await spi_write(dut, 0x1E, 0x01)   # W_COMMIT (WP1)

    # =========================================================================
    # Part 1: register wiring -- remod_in == comb_y >>> shift, for shift 0..3
    # =========================================================================
    for shift in (0, 1, 2, 3):
        await _check_shift_wiring(dut, shift)

    # =========================================================================
    # Part 2: stability -- does the shift actually prevent sd_remod railing?
    # =========================================================================
    MONITOR_CYCLES = 8000   # ~125 comb_y_valid samples at clk_per_iq=64

    # 2a. low-amplitude sanity: pgs=1 (net_rshift=7) keeps comb_y well below
    #     full scale (acc_i_final ~= 127*31 ~= 3937, >>>7 ~= 30, ~-12 dBFS --
    #     the same level test_trouper_top.py's run_scenario already proves
    #     healthy REMOD toggling at). Confirms shift=0 is NOT inherently
    #     broken -- only the amplitude x backoff combination matters.
    for shift in (0, 1):
        await _set_comb_cfg(dut, shift=shift, pgs=1)
        rec = await _monitor_remod(dut, MONITOR_CYCLES)
        run_i = _longest_stuck_run(rec["out_i_bits"])
        run_q = _longest_stuck_run(rec["out_q_bits"])
        dut._log.info(f"shift={shift}, low amplitude: comb_y peak={rec['comb_peak']} "
                      f"out stuck-run i={run_i} q={run_q} (window={MONITOR_CYCLES})")
        assert max(run_i, run_q) < STUCK_HEALTHY, \
            f"shift={shift}, low amplitude: output stuck for {max(run_i, run_q)} cycles -- " \
            f"low-amplitude sanity case should stay healthy (dithering) regardless of backoff"

    # 2b. does the shift actually help at a forced near-full-scale comb_y?
    #     pgs=3 (net_rshift=5) drives comb_y to ~120 (near 0 dBFS) via the
    #     forced weight -- close to full scale but not hard-clipped into a
    #     square wave by mrc_combiner's sat_i/q (pgs=7/net_rshift=1 was
    #     tried first and over-clips comb_y into a near-square, harmonic-rich
    #     wave that overloads sd_remod even at shift=1, job 3290 -- a
    #     misleading result caused by the forcing method, not a real RTL
    #     finding). sd_remod's integrator states (s1/s2/s3) also turned out
    #     to be a red herring here: s3 sits near the sat16 rail almost all
    #     the time even in the definitely-healthy 2a case above (job 3292:
    #     duty=0.85 at comb_y peak=30) -- normal CIFF cascade behavior, not
    #     a fault signature. The real, unambiguous instability signal is the
    #     1-bit quantizer OUTPUT losing its dither (frozen for an extended
    #     run), so this compares shift=0 vs shift=1 on output stuck-run
    #     length instead.
    results = {}
    for shift in (0, 1):
        await _set_comb_cfg(dut, shift=shift, pgs=3)
        rec = await _monitor_remod(dut, MONITOR_CYCLES)
        assert rec["comb_peak"] >= SAT_FLOOR, \
            f"shift={shift}: comb_y peak={rec['comb_peak']} did not reach near-full-scale -- forcing config failed"
        run_i = _longest_stuck_run(rec["out_i_bits"])
        run_q = _longest_stuck_run(rec["out_q_bits"])
        run = max(run_i, run_q)
        dut._log.info(f"shift={shift}, forced near-full-scale: comb_y peak={rec['comb_peak']} "
                      f"out stuck-run i={run_i} q={run_q} (window={MONITOR_CYCLES})")
        results[shift] = dict(run=run, comb_peak=rec["comb_peak"])

    assert abs(results[0]["comb_peak"] - results[1]["comb_peak"]) <= 5, \
        f"comb_y peak differs between shift=0 ({results[0]['comb_peak']}) and shift=1 " \
        f"({results[1]['comb_peak']}) -- not an apples-to-apples comparison"
    assert results[0]["run"] >= STUCK_DEGRADED, \
        f"shift=0: output stuck-run={results[0]['run']} cycles did not reach the degraded " \
        f"threshold -- expected the quantizer to dither noticeably worse with no backoff " \
        f"at a near-0-dBFS input"
    assert results[1]["run"] < STUCK_HEALTHY, \
        f"shift=1: output stuck-run={results[1]['run']} cycles -- backoff should keep the " \
        f"quantizer dithering even at a near-0-dBFS combiner output"

    dut._log.info("PASS -- REMOD_BACKOFF_SHIFT wiring verified bit-exact; shift=0 confirmed healthy "
                   "at low amplitude; at forced near-full-scale amplitude, shift=0 freezes the output "
                   f"({results[0]['run']} cycles stuck) while shift=1 keeps it dithering "
                   f"({results[1]['run']} cycles, healthy)")
