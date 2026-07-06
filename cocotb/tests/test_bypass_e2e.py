"""
test_bypass_e2e.py -- Mode-1 passthrough END-TO-END regression.

Traceability (planning/Traceability.md): TRPR-RMD-008, TRPR-MRC-005, TRPR-PCF-011.

All three requirements converge on one previously-untested claim: that
MIMO_CTRL.MODE=1 (passthrough) delivers the lowest-enabled antenna's RAW
decimated sample -- unweighted, no MRC math -- all the way to sd_remod's
input. Prior coverage stopped short on purpose:

  * test_bypass_antenna.py proves only the bypass_ant antenna-select mux
    (a combinational wire), explicitly "without needing bypass mode's
    downstream routing to be exercised";
  * test_remod_backoff.py deliberately used MRC mode with a forced
    single-branch weight instead of true bypass mode, to sidestep the
    PSRAM-replay delay-line lag.

This test drives the real thing. Each antenna input gets a DIFFERENT CW
amplitude (ant0=31 fixed for the sc_detector e_slice guard; ants 1-3 get
22/15/10), so routing the wrong antenna -- or leaking any MRC weighting --
cannot pass the bit-exact compares. Flow per case:

  1. Write MIMO_CTRL (mode + ANTENNA_EN mask) before lock so the packet FSM
     latches it at the sc_lock IDLE edge (active_mode/active_antenna_en).
  2. COMB_CFG: REMOD_BACKOFF_SHIFT=0 so remod_in must equal comb_y exactly
     (makes the TRPR-RMD-008 "raw sample reaches the re-modulator"
     assertion literal, no shift arithmetic in the way).
  3. Phase A (post-lock, pre-W_COMMIT, PSRAM BUFFERING): on every clean
     x_valid -> y_valid pairing, comb_y_i/q must bit-equal the selected
     antenna's combiner input port latched at that x_valid. The remod input
     must stay silenced (psram_silence gates in_valid) -- BUFFERING means
     no output yet, by design.
  4. Commit deliberately non-trivial weights (0x40 in every W-shadow byte,
     which under MRC would scale/mix all four branches) + W_COMMIT. In
     mode 1 these MUST be ignored (use_mrc_r = W_valid && !mode == 0).
  5. Poll PSRAM_STATUS[4] REPLAY_ACTIVE over SPI (also the first test to
     read this status bit at its register position -- TRPR-PSR-006 was
     previously INIT_DONE-only).
  6. Phase B (REPLAY): same bit-exact bypass compare (combiner inputs are
     now the PSRAM-replayed stream -- the compare is input-vs-output, so
     the delay-line lag doesn't matter), PLUS remod_in_i/q == comb_y_i/q,
     psram_silence == 0, and REMOD_A_I actually toggling.

The mode-0 companion case closes TRPR-MRC-005's other gap: the
pre-training AUTO-fallback (no W_valid yet -> bypass output) is exercised
as such, then W_COMMIT is sent and use_mrc_r must flip to 1 and the output
must stop tracking the raw antenna sample (weights now applied).

Run under Verilator (see cocotb/bypass_e2e/Makefile): needs --timing for
the Timer()-based SPI bit-bang and --public-flat-rw for the hierarchical
internal reads (dut.u_dut.u_comb.*, comb_y_*, psram_silence, remod_in_*).
"""

import math

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from test_trouper_top import CLK_NS, spi_read, spi_write, spi_burst_write

# Per-antenna CW amplitudes. ant0 must stay at 31: the sc_detector keys on
# branch 0 only and its e_slice guard needs A^2*256/1024 >> 91 at SF7/BW250
# (see sdm_driver in test_trouper_top.py). The others just need to be
# distinct and healthy.
ANT_AMPS = (31, 22, 15, 10)

PHASE_A_SAMPLES = 40   # clean bypass pairings required pre-commit
PHASE_B_SAMPLES = 60   # clean bypass pairings required during replay
NONZERO_FLOOR   = 8    # at least this many matched samples must be nonzero
REMOD_TOGGLE_FLOOR = 10


async def sdm_driver_multi(dut, amps=ANT_AMPS):
    """First-order SDM per antenna, DIFFERENT amplitude per branch (NT=1
    waveform, per-branch gain) -- unlike test_trouper_top.sdm_driver which
    drives all four IQ_DATA bits identically. CW period P=8 iq samples,
    same rationale as the original (dc_removal attenuation <3%)."""
    clk_per_iq = 64
    P = 8

    stim_i = [[round(a * math.cos(2 * math.pi * k / P)) for k in range(P)]
              for a in amps]
    stim_q = [[round(a * math.sin(2 * math.pi * k / P)) for k in range(P)]
              for a in amps]

    acc_i = [0] * 4
    acc_q = [0] * 4
    sine_ptr = 0
    bit_cnt = 0

    while True:
        await RisingEdge(dut.IQ_CLK)
        bits_i = 0
        bits_q = 0
        for a in range(4):
            xi, xq = stim_i[a][sine_ptr], stim_q[a][sine_ptr]
            if acc_i[a] >= 0:
                bits_i |= 1 << a
                acc_i[a] += xi - 127
            else:
                acc_i[a] += xi + 127
            if acc_q[a] >= 0:
                bits_q |= 1 << a
                acc_q[a] += xq - 127
            else:
                acc_q[a] += xq + 127
        dut.IQ_DATA_I.value = bits_i
        dut.IQ_DATA_Q.value = bits_q
        bit_cnt += 1
        if bit_cnt >= clk_per_iq:
            bit_cnt = 0
            sine_ptr = (sine_ptr + 1) % P


async def _reset_and_lock(dut, *, mode, ant_mask, tag):
    """Reset, configure (MIMO_CTRL before lock so the FSM latches it),
    bring up PSRAM, and poll to sc_lock. Returns sym_ns."""
    sf, bw_khz = 7, 250
    sample_shift = 1
    M = 1 << (sf + sample_shift)
    clk_per_iq = 64

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

    cocotb.start_soon(sdm_driver_multi(dut))

    # SPI settle
    await spi_read(dut, 0x00)
    await spi_read(dut, 0x09)

    # SF/BW + SC threshold (1 hit fires lock)
    await spi_write(dut, 0x09, sf & 0x0F)
    await spi_write(dut, 0x0A, 0)      # 250 kHz
    await spi_write(dut, 0x0C, 0x01)
    await spi_write(dut, 0x0D, 0x00)
    await spi_write(dut, 0x0E, 0x00)

    # MIMO_CTRL: [0]=MODE, [7:4]=ANTENNA_EN -- must land before sc_lock so
    # packet_ctrl_fsm latches active_mode/active_antenna_en from the shadow
    mimo = ((ant_mask & 0x0F) << 4) | (mode & 0x01)
    await spi_write(dut, 0x08, mimo)
    rb = await spi_read(dut, 0x08)
    assert rb == mimo, f"{tag}: MIMO_CTRL readback 0x{rb:02X} != 0x{mimo:02X}"

    # COMB_CFG: REMOD_BACKOFF_SHIFT=0 (bits[5:4]), pgs=1 (bits[2:0]) -- with
    # shift 0, remod_in must EQUAL comb_y, so the phase-B remod check is a
    # literal bit-compare. pgs only matters for the mode-0 MRC phase.
    await spi_write(dut, 0x0F, 0x01)

    # PSRAM up (required: it is the SC detector's delay line)
    await spi_write(dut, 0x70, 0x01)
    init_ok = False
    for _ in range(500):
        await Timer(8 * CLK_NS, unit="ns")
        if (await spi_read(dut, 0x71)) & 0x08:
            init_ok = True
            break
    assert init_ok, f"{tag}: PSRAM INIT_DONE never set"

    # Poll sc_lock (IRQ_STATUS[0])
    sym_ns = M * clk_per_iq * CLK_NS
    lock_ok = False
    for _ in range(20):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x01:
            lock_ok = True
            break
    assert lock_ok, f"{tag}: sc_lock never fired"

    # FSM must have latched the shadow config at the lock edge
    am = int(dut.u_dut.active_mode.value)
    ae = int(dut.u_dut.active_antenna_en.value)
    assert am == mode,     f"{tag}: active_mode={am}, expected {mode}"
    assert ae == ant_mask, f"{tag}: active_antenna_en=0x{ae:X}, expected 0x{ant_mask:X}"
    dut._log.info(f"{tag}: locked, active_mode={am} active_antenna_en=0x{ae:X}")
    return sym_ns


async def _watch_bypass(dut, ant, n, *, tag, expect_silenced, check_remod,
                        expect_bypass=True):
    """Watch n clean x_valid->y_valid pairings on the combiner boundary.

    A capture is taken from the combiner's own input ports (u_comb.x_i<ant>/
    x_q<ant>) whenever x_valid is high -- the same value state 0 latches on
    the following edge. A pairing is 'clean' when exactly one x_valid was
    seen since the previous y_valid (the burst is ~31 clocks inside a
    64-clock sample window, so this is the norm; anything else -- e.g. the
    buffering->replay source handover -- is skipped, not judged).

    expect_bypass=True : y must bit-equal the captured raw antenna sample.
    expect_bypass=False: count how many clean pairings DIFFER instead
                         (returned as 'diffs'; used by the mode-0 case to
                         show weights took effect after W_COMMIT).
    expect_silenced    : True  -> u_remod.in_valid must never pulse;
                         False -> psram_silence must be 0 at every y_valid.
    check_remod        : also require remod_in_i/q == comb_y_i/q (backoff
                         shift is 0) and count REMOD_A_I toggles.
    """
    xi_sig = getattr(dut.u_dut.u_comb, f"x_i{ant}")
    xq_sig = getattr(dut.u_dut.u_comb, f"x_q{ant}")

    pend = None
    caps_since_y = 0
    matched = nonzero = diffs = 0
    toggles = 0
    prev_out = None

    for _ in range(n * 200):
        await RisingEdge(dut.IQ_CLK)

        if int(dut.u_dut.u_comb.x_valid.value):
            pend = (int(xi_sig.value.signed_integer),
                    int(xq_sig.value.signed_integer))
            caps_since_y += 1

        if expect_silenced:
            assert int(dut.u_dut.u_remod.in_valid.value) == 0, \
                f"{tag}: remod in_valid pulsed while PSRAM BUFFERING should silence it"

        if check_remod:
            out = int(dut.REMOD_A_I.value) & 1
            if prev_out is not None and out != prev_out:
                toggles += 1
            prev_out = out

        if int(dut.u_dut.comb_y_valid.value):
            if pend is not None and caps_since_y == 1:
                yi = int(dut.u_dut.comb_y_i.value.signed_integer)
                yq = int(dut.u_dut.comb_y_q.value.signed_integer)
                if expect_bypass:
                    assert (yi, yq) == pend, \
                        f"{tag}: comb_y=({yi},{yq}) != raw ant{ant} sample {pend} -- " \
                        f"bypass output is not the selected antenna's unweighted sample"
                elif (yi, yq) != pend:
                    diffs += 1
                if not expect_silenced:
                    assert int(dut.u_dut.psram_silence.value) == 0, \
                        f"{tag}: psram_silence=1 during replay -- remod input still muted"
                if check_remod:
                    ri = int(dut.u_dut.remod_in_i.value.signed_integer)
                    rq = int(dut.u_dut.remod_in_q.value.signed_integer)
                    assert (ri, rq) == (yi, yq), \
                        f"{tag}: remod_in=({ri},{rq}) != comb_y=({yi},{yq}) at backoff shift 0"
                matched += 1
                if pend != (0, 0):
                    nonzero += 1
                if matched >= n:
                    break
            pend = None
            caps_since_y = 0

    assert matched >= n, f"{tag}: only {matched}/{n} clean pairings observed"
    assert nonzero >= NONZERO_FLOOR, \
        f"{tag}: only {nonzero} nonzero samples -- stimulus not reaching antenna {ant}"
    if check_remod:
        assert toggles >= REMOD_TOGGLE_FLOOR, \
            f"{tag}: REMOD_A_I toggled only {toggles} times -- re-modulator output dead"
        dut._log.info(f"{tag}: {matched} pairings bit-exact, {nonzero} nonzero, "
                      f"REMOD toggles={toggles}")
    else:
        dut._log.info(f"{tag}: {matched} pairings checked, {nonzero} nonzero, diffs={diffs}")
    return diffs


async def _train_commit_replay(dut, sym_ns, *, tag):
    """Wait training_done, commit deliberately non-trivial weights, then
    poll PSRAM_STATUS[4] REPLAY_ACTIVE over SPI."""
    train_ok = False
    for _ in range(40):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x02:
            train_ok = True
            break
    assert train_ok, f"{tag}: training_done never fired"

    # 0x40 in every W-shadow byte: under MRC this scales/mixes all four
    # branches (HI bytes feed the combiner) -- if mode 1 fails to ignore
    # weights, the bypass bit-compare in phase B cannot pass.
    await spi_burst_write(dut, 0x30, [0x40] * 16)
    await spi_write(dut, 0x1E, 0x01)   # W_COMMIT (W1P)

    replay_ok = False
    for _ in range(200):
        await Timer(64 * CLK_NS, unit="ns")
        if (await spi_read(dut, 0x71)) & 0x10:
            replay_ok = True
            break
    assert replay_ok, f"{tag}: PSRAM_STATUS.REPLAY_ACTIVE never set after W_COMMIT"
    dut._log.info(f"{tag}: replay active")


async def _mode1_case(dut, ant_mask, ant):
    tag = f"mode1/ANTENNA_EN=0x{ant_mask:X}/ant{ant}"
    sym_ns = await _reset_and_lock(dut, mode=1, ant_mask=ant_mask, tag=tag)

    # Phase A: pre-commit -- bypass already live at the combiner, remod muted
    assert int(dut.u_dut.u_comb.use_mrc_r.value) == 0
    await _watch_bypass(dut, ant, PHASE_A_SAMPLES, tag=f"{tag}/phaseA",
                        expect_silenced=True, check_remod=False)

    await _train_commit_replay(dut, sym_ns, tag=tag)

    # Phase B: replay -- weights committed but MUST be ignored in mode 1,
    # and the raw stream must now reach sd_remod unsilenced
    await _watch_bypass(dut, ant, PHASE_B_SAMPLES, tag=f"{tag}/phaseB",
                        expect_silenced=False, check_remod=True)
    assert int(dut.u_dut.u_comb.use_mrc_r.value) == 0, \
        f"{tag}: use_mrc_r=1 in mode 1 -- committed weights are NOT being ignored"
    dut._log.info(f"{tag}: PASS")


@cocotb.test()
async def test_mode1_e2e_ant0(dut):
    """MODE=1, all antennas enabled -> antenna 0's raw stream to sd_remod.
    Closes TRPR-RMD-008 / TRPR-PCF-011 for the default mask."""
    await _mode1_case(dut, ant_mask=0xF, ant=0)


@cocotb.test()
async def test_mode1_e2e_ant2(dut):
    """MODE=1, antennas 2+3 enabled -> antenna 2 (lowest enabled, distinct
    amplitude 15) -- proves antenna identity end-to-end, not just 'some
    unweighted stream'."""
    await _mode1_case(dut, ant_mask=0xC, ant=2)


@cocotb.test()
async def test_mode0_pretraining_auto_bypass(dut):
    """TRPR-MRC-005: in MRC mode (MODE=0), BEFORE any W_COMMIT the combiner
    must auto-fall-back to bypass (use_mrc_r = W_valid && !mode with
    W_valid=0) -- exercised here as the pre-training trigger itself, not
    via explicit MODE=1. After W_COMMIT, use_mrc_r must flip and the output
    must stop tracking the raw antenna sample."""
    tag = "mode0/pretraining"
    sym_ns = await _reset_and_lock(dut, mode=0, ant_mask=0xF, tag=tag)

    # Pre-commit: auto-bypass on antenna 0
    assert int(dut.u_dut.u_comb.use_mrc_r.value) == 0
    await _watch_bypass(dut, 0, PHASE_A_SAMPLES, tag=f"{tag}/pre-commit",
                        expect_silenced=True, check_remod=False)

    await _train_commit_replay(dut, sym_ns, tag=tag)

    # Give the combiner a couple of sample periods to latch W_valid at its
    # next state-0 pass, then it must be in MRC mode
    await Timer(3 * 64 * CLK_NS, unit="ns")
    assert int(dut.u_dut.u_comb.use_mrc_r.value) == 1, \
        f"{tag}: use_mrc_r stayed 0 after W_COMMIT in mode 0"

    # Output must now differ from the raw ant0 sample on most pairings
    # (weights 0x40 on all four branches sum ~2.5x ant0 alone at pgs=1)
    diffs = await _watch_bypass(dut, 0, PHASE_B_SAMPLES, tag=f"{tag}/post-commit",
                                expect_silenced=False, check_remod=False,
                                expect_bypass=False)
    assert diffs >= PHASE_B_SAMPLES // 4, \
        f"{tag}: only {diffs}/{PHASE_B_SAMPLES} MRC outputs differ from the raw " \
        f"ant0 sample -- weights do not appear to be applied after W_COMMIT"
    dut._log.info(f"{tag}: PASS (auto-bypass pre-commit, MRC after commit, {diffs} diffs)")
