"""
test_bringup_src.py -- deterministic bring-up sample source (BRINGUP_SRC).

Covers planning/foundational-block-bringup-plan.md "Required implementation
evidence": reset-to-normal selection, the RX_HOLD && !PACKET_ACTIVE arming
gate, no normal-path functional change while disabled, every generator mode,
and deterministic restart after reset.

The load-bearing test here is test_disabled_source_does_not_perturb_the_path.
Everything else checks the feature works; that one checks it cannot break the
receiver if it doesn't. A bring-up aid that is merely "probably harmless" is
worse than none, because it ships on the die either way.

The source injects at the RE-MODULATOR input, not the combiner input (moved
2026-09-02 -- see bringup_src.v's header for why). The mux under test is
therefore trouper_top's remod_in_i/remod_in_q/remod_in_valid, and the combiner
is entirely out of the path while the source is armed.

Internal reads (dut.u_dut.u_bringup_src.*, remod_in_*, comb_y_*) require
--public-flat-rw, which the suite Makefile passes.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer, RisingEdge

from test_trouper_top import (
    CLK_NS, spi_read, spi_write, release_rx_hold, assert_rx_hold,
)

REG_BRINGUP_CTRL = 0x10
REG_BRINGUP_AMPL = 0x11
REG_MIMO_CTRL    = 0x08
REG_COMB_CFG     = 0x0F
REG_RX_HOLD      = 0x1A

MODE_ZERO, MODE_DC, MODE_TONE, MODE_PRBS = range(4)

AMPL_MAX = 64
DECIM    = 64          # generator cadence, in 32 MHz clocks


def ctrl(mode, en=True):
    """Pack BRINGUP_CTRL = {..., MODE[2:1], EN[0]}."""
    return ((mode & 0x3) << 1) | (1 if en else 0)


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.IQ_CLK, CLK_NS, unit="ns").start())
    dut.HOST_CS.value   = 1
    dut.SPI_SCK.value   = 0
    dut.SPI_MOSI.value  = 0
    dut.IQ_DATA_I.value = 0
    dut.IQ_DATA_Q.value = 0
    dut.RESETB.value    = 0
    await Timer(4 * CLK_NS, unit="ns")
    dut.RESETB.value = 1
    await Timer(8 * CLK_NS, unit="ns")


async def arm(dut, mode, ampl):
    """Arm the source. RX_HOLD is set out of reset, so this is the legal path."""
    await spi_write(dut, REG_BRINGUP_AMPL, ampl & 0xFF)
    await spi_write(dut, REG_BRINGUP_CTRL, ctrl(mode))


async def collect(dut, n, timeout_clks=None):
    """Collect n (i, q) pairs presented at the combiner's own input ports."""
    src = dut.u_dut.u_bringup_src
    out = []
    limit = timeout_clks if timeout_clks is not None else n * DECIM * 4
    for _ in range(limit):
        await RisingEdge(dut.IQ_CLK)
        if int(src.src_valid.value):
            out.append((src.src_i.value.signed_integer,
                        src.src_q.value.signed_integer))
            if len(out) == n:
                return out
    raise AssertionError(
        f"only {len(out)}/{n} samples in {limit} clocks -- generator not running"
    )


# ---------------------------------------------------------------------------
# Reset / default selection
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_selects_the_normal_path(dut):
    """Out of reset the source is disabled and the mux is transparent."""
    await reset_dut(dut)

    assert int(await spi_read(dut, REG_BRINGUP_CTRL)) == 0x00, \
        "BRINGUP_CTRL must reset to 0 -- a chip that comes up injecting test " \
        "samples cannot receive"
    assert int(await spi_read(dut, REG_BRINGUP_AMPL)) == 0x00

    assert int(dut.u_dut.bringup_en_q.value) == 0
    for _ in range(4 * DECIM):
        await RisingEdge(dut.IQ_CLK)
        assert int(dut.u_dut.u_bringup_src.src_valid.value) == 0, \
            "generator emitted a sample while disabled"


@cocotb.test()
async def test_disabled_source_does_not_perturb_the_path(dut):
    """With EN=0 the combiner input stream is bit-identical to the baseline.

    This is the test that makes the feature safe to ship. The mux sits on
    sd_remod's own input, which is the receiver's output stage; if the disabled
    source changes a single sample the whole feature is a liability.

    Both arms issue the SAME SPI traffic -- same transaction count, same
    timing -- and differ only in the data written. Without that the decimator
    and DC-removal pipelines are simply at different points when the capture
    starts, and the comparison fails on a timing artifact rather than on
    anything the source did.
    """
    async def run(ampl, ctrl_armed, ctrl_final):
        await reset_dut(dut)
        await spi_write(dut, REG_BRINGUP_AMPL, ampl)
        await spi_write(dut, REG_BRINGUP_CTRL, ctrl_armed)
        await spi_write(dut, REG_BRINGUP_CTRL, ctrl_final)
        await release_rx_hold(dut)
        trace = []
        for _ in range(3000):
            await RisingEdge(dut.IQ_CLK)
            trace.append((
                int(dut.u_dut.remod_in_valid.value),
                dut.u_dut.remod_in_i.value.signed_integer,
                dut.u_dut.remod_in_q.value.signed_integer,
            ))
        return trace

    # Baseline: the register pair is written, but never armed.
    baseline = await run(0x00, 0x00, 0x00)
    # Armed at full tone amplitude, then disarmed before the capture.
    after = await run(AMPL_MAX, ctrl(MODE_TONE), ctrl(MODE_TONE, en=False))

    assert int(dut.u_dut.bringup_en_q.value) == 0, "source left armed"
    assert after == baseline, (
        "disabled BRINGUP_SRC perturbed the re-modulator input stream at clock "
        f"{next(i for i, (a, b) in enumerate(zip(after, baseline)) if a != b)}"
    )


# ---------------------------------------------------------------------------
# Arming gate
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_arming_is_refused_unless_rx_hold(dut):
    """BRINGUP_CTRL/AMPL are quasi-static config: writes need RX_HOLD=1.

    Rejection is latched in CFG_WR_REJECTED (0x1A[1]); a dropped write is
    otherwise invisible to firmware, which is the bug class Open Risks #16 and
    the W_MISSED_PACKET readback fix both came from.
    """
    await reset_dut(dut)
    await release_rx_hold(dut)          # RX_HOLD now 0 -> config locked

    await spi_write(dut, REG_BRINGUP_CTRL, ctrl(MODE_DC))
    assert int(await spi_read(dut, REG_BRINGUP_CTRL)) == 0x00, \
        "BRINGUP_CTRL accepted a write while the receiver was released"

    await spi_write(dut, REG_BRINGUP_AMPL, 0x20)
    assert int(await spi_read(dut, REG_BRINGUP_AMPL)) == 0x00

    status = int(await spi_read(dut, REG_RX_HOLD))
    assert status & 0x02, "CFG_WR_REJECTED did not latch the refused write"

    # And the legal sequence still works: hold -> write -> release.
    await assert_rx_hold(dut)
    await arm(dut, MODE_DC, 0x20)
    assert int(await spi_read(dut, REG_BRINGUP_CTRL)) == ctrl(MODE_DC)
    assert int(await spi_read(dut, REG_BRINGUP_AMPL)) == 0x20


@cocotb.test()
async def test_enable_drops_when_rx_hold_is_released(dut):
    """The level term is qualified continuously, not just at the write."""
    await reset_dut(dut)
    await arm(dut, MODE_DC, AMPL_MAX)
    await RisingEdge(dut.IQ_CLK)
    assert int(dut.u_dut.bringup_en_q.value) == 1

    await release_rx_hold(dut)
    await RisingEdge(dut.IQ_CLK)
    assert int(dut.u_dut.bringup_en_q.value) == 0, \
        "source stayed armed after RX_HOLD was released -- it would fight the " \
        "live datapath"
    assert int(await spi_read(dut, REG_BRINGUP_CTRL)) & 1, \
        "the CTRL bit itself should be unchanged; only the qualified enable drops"


# ---------------------------------------------------------------------------
# Generator modes
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_zero_mode(dut):
    await reset_dut(dut)
    await arm(dut, MODE_ZERO, AMPL_MAX)
    for i, q in await collect(dut, 8):
        assert (i, q) == (0, 0), f"zero mode emitted ({i},{q})"


@cocotb.test()
async def test_dc_mode_polarity(dut):
    """Signed DC, both polarities, on I and Q independently.

    BRINGUP_AMPL's sign carries through DC mode -- Register Map 0x10-0x11
    documents the density as the *signed* BRINGUP_AMPL / 127, and the board
    procedure compares against that signed reference. (Fixed 2026-09-04:
    DC mode used to hardcode the magnitude, silently dropping the sign --
    0xE0 = -32 produced +32.)
    """
    for ampl, want in ((0x20, 32), (0xE0, -32), (0x10, 16)):
        await reset_dut(dut)
        await arm(dut, MODE_DC, ampl)
        for i, q in await collect(dut, 6):
            assert i == want and q == want, \
                f"DC ampl=0x{ampl:02X}: expected ({want},{want}), got ({i},{q})"


@cocotb.test()
async def test_amplitude_is_clamped(dut):
    """Commanded amplitude above +/-64 must clamp, not wrap.

    sd_remod's 3rd-order NTF goes permanently unstable on input wrap-around,
    so this bound is a functional requirement, not a nicety.
    """
    for ampl in (0x7F, 0x80, 0x41):
        await reset_dut(dut)
        await arm(dut, MODE_DC, ampl)
        for i, q in await collect(dut, 4):
            assert abs(i) <= AMPL_MAX and abs(q) <= AMPL_MAX, \
                f"ampl=0x{ampl:02X} produced ({i},{q}), outside +/-{AMPL_MAX}"


@cocotb.test()
async def test_tone_mode_is_a_quadrature_rotation(dut):
    """fs/4 tone: (A,0), (0,A), (-A,0), (0,-A), repeating.

    I leads Q by one phase, so an I/Q swap or a sign inversion on either rail
    is visible directly in this sequence -- that is the point of using a
    rotation rather than a DC level for the modulation-fidelity check.
    """
    A = 48
    await reset_dut(dut)
    await arm(dut, MODE_TONE, A)

    got = await collect(dut, 9)
    want = [(A, 0), (0, A), (-A, 0), (0, -A)]
    for n, (i, q) in enumerate(got):
        assert (i, q) == want[n % 4], \
            f"tone sample {n}: expected {want[n % 4]}, got ({i},{q})"

    # Mean over a whole number of cycles is zero on both rails -- a DC offset
    # here would bias the re-modulator.
    cyc = got[:8]
    assert sum(i for i, _ in cyc) == 0 and sum(q for _, q in cyc) == 0


@cocotb.test()
async def test_prbs_mode_switches_and_stays_bounded(dut):
    await reset_dut(dut)
    await arm(dut, MODE_PRBS, AMPL_MAX)
    got = await collect(dut, 40)

    assert all(abs(i) <= AMPL_MAX and abs(q) <= AMPL_MAX for i, q in got)
    assert len({i for i, _ in got}) > 1, "PRBS I rail never switched"
    assert len({q for _, q in got}) > 1, "PRBS Q rail never switched"


@cocotb.test()
async def test_deterministic_restart_after_reset(dut):
    """Two resets must produce bit-identical streams in every mode.

    Bring-up compares a captured stream against a precomputed reference; a
    generator whose phase depends on when it happened to be armed makes that
    comparison useless.
    """
    for mode in (MODE_DC, MODE_TONE, MODE_PRBS):
        await reset_dut(dut)
        await arm(dut, mode, 40)
        first = await collect(dut, 24)

        await reset_dut(dut)
        await arm(dut, mode, 40)
        second = await collect(dut, 24)

        assert first == second, f"mode {mode} was not deterministic across reset"


# ---------------------------------------------------------------------------
# Reaching the re-modulator
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_samples_reach_the_remod_input(dut):
    """The programmed sample must arrive at sd_remod's input unmodified.

    This is the whole insertion-point claim: nothing sits between the generator
    and the modulator, so a bad 1-bit output stream is unambiguously
    sd_remod's fault. At the old combiner insertion point the bypass path was
    also implicated and the pads could not tell you which.
    """
    A = 32
    await reset_dut(dut)
    await arm(dut, MODE_DC, A)

    seen = []
    for _ in range(12 * DECIM):
        await RisingEdge(dut.IQ_CLK)
        if int(dut.u_dut.remod_in_valid.value):
            seen.append((dut.u_dut.remod_in_i.value.signed_integer,
                         dut.u_dut.remod_in_q.value.signed_integer))

    assert seen, "no sample reached the re-modulator while the source was armed"
    assert all(s == (A, A) for s in seen), \
        f"re-modulator input did not carry the programmed sample: {seen[:4]}"


@cocotb.test()
async def test_combiner_is_out_of_the_path_while_armed(dut):
    """Whatever the combiner produces must not reach the modulator.

    The point of moving the source here was isolation. If the combiner output
    still leaked through -- a mux written the wrong way round, or an OR where a
    select belongs -- the isolation claim would be false while every value
    check above still passed, because with the IQ pads idle the combiner output
    is small and would perturb rather than replace the stimulus.
    """
    A = 32
    await reset_dut(dut)
    cocotb.start_soon(_iq_square(dut))
    await arm(dut, MODE_DC, A)

    comb_moved = set()
    for _ in range(24 * DECIM):
        await RisingEdge(dut.IQ_CLK)
        comb_moved.add(dut.u_dut.comb_y_i.value.signed_integer)
        if int(dut.u_dut.remod_in_valid.value):
            i = dut.u_dut.remod_in_i.value.signed_integer
            q = dut.u_dut.remod_in_q.value.signed_integer
            assert (i, q) == (A, A), \
                f"combiner output leaked into the re-modulator: ({i},{q})"

    assert len(comb_moved) > 1, (
        "the combiner output never moved, so the isolation check would be "
        f"vacuous: {sorted(comb_moved)[:4]}"
    )


@cocotb.test()
async def test_armed_source_overrides_the_backoff_shift(dut):
    """REMOD_BACKOFF_SHIFT must not scale the injected sample.

    The shift is deliberately bypassed for the bring-up source: if it applied,
    the signature at the pads would depend on COMB_CFG and would no longer be
    the value the engineer programmed. Safe because the generator clamps to
    +/-64 (-6 dBFS), already inside sd_remod's -3 dBFS stability bound, so no
    backoff is needed to keep the NTF out of wrap-around.
    """
    A = 48
    for shift in (0, 1, 2, 3):
        await reset_dut(dut)
        await spi_write(dut, REG_COMB_CFG, (shift & 0x3) << 4)
        await arm(dut, MODE_DC, A)
        for _ in range(4 * DECIM):
            await RisingEdge(dut.IQ_CLK)
            if int(dut.u_dut.remod_in_valid.value):
                i = dut.u_dut.remod_in_i.value.signed_integer
                assert i == A, (
                    f"REMOD_BACKOFF_SHIFT={shift} scaled the injected sample "
                    f"to {i}; the programmed reference is {A}"
                )
                break
        else:
            raise AssertionError(f"shift={shift}: no sample reached sd_remod")


# ---------------------------------------------------------------------------
# Generator timing and golden sequences
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_sample_cadence_is_500ksps(dut):
    """src_valid must be a single clock every DECIM=64, with no drift.

    Every downstream consumer -- the combiner's sub-cycle sequencer, and the
    OSR=64 assumption baked into sd_remod's NTF -- is paced by this. A wrong
    divider still produces a plausible-looking sample stream, so none of the
    value checks above would catch it; the reconstruction tests below silently
    become meaningless if the rate is wrong.
    """
    await reset_dut(dut)
    await arm(dut, MODE_DC, 32)

    src = dut.u_dut.u_bringup_src
    gaps, last, width = [], None, 0
    for clk in range(40 * DECIM):
        await RisingEdge(dut.IQ_CLK)
        if int(src.src_valid.value):
            width += 1
            if last is not None:
                gaps.append(clk - last)
            last = clk
        elif width:
            assert width == 1, f"src_valid was high for {width} clocks, not 1"
            width = 0

    assert len(gaps) >= 20, f"only {len(gaps)+1} samples in 40 periods"
    assert set(gaps) == {DECIM}, \
        f"sample period is not a constant {DECIM} clocks: saw {sorted(set(gaps))}"


def _golden_prbs(n, a_pos):
    """Reference model of the generator's Galois LFSR (x^9 + x^5 + 1).

    Mirrors bringup_src.v exactly: seed 0x1FF, and the sample presented on the
    tick AFTER the shift, because the output register and the LFSR update on
    the same edge -- src_* takes the pre-shift state.
    """
    lfsr, out = 0x1FF, []
    for _ in range(n):
        i = a_pos if (lfsr & 0x001) else -a_pos
        q = a_pos if (lfsr & 0x010) else -a_pos
        out.append((i, q))
        fb = lfsr & 1
        lfsr = ((fb << 8) | (((lfsr >> 5) & 0xF) ^ (0xF if fb else 0)) << 4
                | ((lfsr >> 1) & 0xF))
    return out


@cocotb.test()
async def test_prbs_matches_the_golden_lfsr(dut):
    """The PRBS stream must match a reference model sample for sample.

    test_prbs_mode_switches_and_stays_bounded only proves both rails move.
    Bring-up compares a captured stream against a precomputed reference, so
    the actual sequence -- not merely its liveness -- is the contract. A
    mis-tapped or mis-ordered LFSR still "switches" and still stays bounded.
    """
    A = 40
    await reset_dut(dut)
    await arm(dut, MODE_PRBS, A)
    got = await collect(dut, 64)
    want = _golden_prbs(64, A)

    assert got == want, (
        "PRBS diverged from the x^9+x^5+1 reference at sample "
        f"{next(n for n, (g, w) in enumerate(zip(got, want)) if g != w)}: "
        f"got {got[:8]}, want {want[:8]}"
    )

    # Period 511 with a nine-bit state: the stream must not collapse to a short
    # cycle (the classic symptom of a lost tap).
    assert len(set(got)) > 2, "PRBS collapsed to a two-state cycle"


# ---------------------------------------------------------------------------
# End to end: the programmed sample vs the 1-bit output pads
#
# planning/foundational-block-bringup-plan.md requirement 3 -- "compare
# captured 1-bit outputs after external/Python decimation with the programmed
# DC/tone reference; test I and Q independently and together". Every test
# above stops at the combiner INPUT. That proves the mux, not the feature:
# the whole justification for BRINGUP_SRC is that a bring-up engineer can
# scope REMOD_A_I/Q and compare against a known signature, and until the
# 1-bit output is actually checked against the programmed reference nothing
# establishes that the signature they will compare against is right.
# ---------------------------------------------------------------------------


# sd_remod feeds back +/-127 counts for a 1/0 output, so a full-scale +/-1
# reconstructed stream corresponds to +/-127 at the int8 input.
REMOD_FULL_SCALE = 127.0


async def capture_remod(dut, n_clks, settle_clks=6 * DECIM):
    """Record REMOD_A_I/Q as a +/-1 stream, after letting the loop settle.

    settle_clks discards the start-up transient: the integrators leave reset
    at zero and need a few output samples to track a newly applied level.
    """
    for _ in range(settle_clks):
        await RisingEdge(dut.IQ_CLK)
    bits_i, bits_q = [], []
    for _ in range(n_clks):
        await RisingEdge(dut.IQ_CLK)
        bits_i.append(1 if int(dut.REMOD_A_I.value) else -1)
        bits_q.append(1 if int(dut.REMOD_A_Q.value) else -1)
    return bits_i, bits_q


@cocotb.test()
async def test_armed_source_overrides_psram_silence(dut):
    """psram_silence must not be able to zero the injected stimulus.

    `remod_src` is `psram_silence ? 0 : comb_y >>> backoff`, and psram_silence
    is `psram_buf_active && !replay_active`. The bring-up source is muxed in
    AHEAD of that term deliberately: silence at the pads is indistinguishable
    from a dead re-modulator, which is the exact diagnosis this source exists
    to make possible, so a buffer state must never be able to produce it.

    Checked both ways: that the normal bring-up sequence does not assert
    psram_silence at all, and that the override holds even when it is forced.
    """
    A = 32
    await reset_dut(dut)
    await arm(dut, MODE_DC, A)

    for _ in range(8 * DECIM):
        await RisingEdge(dut.IQ_CLK)
        assert int(dut.u_dut.psram_silence.value) == 0, \
            "psram_silence asserted during an ordinary bring-up sequence"

    # Force the silencing term and confirm the stimulus survives it.
    saw = 0
    for _ in range(6 * DECIM):
        dut.u_dut.u_psram.buf_active.value = 1
        await RisingEdge(dut.IQ_CLK)
        if int(dut.u_dut.psram_silence.value) and int(dut.u_dut.remod_in_valid.value):
            i = dut.u_dut.remod_in_i.value.signed_integer
            q = dut.u_dut.remod_in_q.value.signed_integer
            saw += 1
            assert (i, q) == (A, A), \
                f"psram_silence zeroed the armed bring-up source: ({i},{q})"

    assert saw, "psram_silence never took -- the override check would be vacuous"


@cocotb.test()
async def test_dc_signature_at_the_remod_output(dut):
    """DC mode: the 1-bit output density must encode the programmed level.

    This is the plan's "one-bit output density check". The mean of the +/-1
    stream is the modulator's DC transfer: level/127. It needs no filter and
    no phase alignment, so it is the cleanest first-silicon signature -- and
    the one a bring-up engineer can compute from a logic-analyser capture with
    nothing but a bit count.

    I and Q are checked independently here; DC drives both rails to the same
    value, so a swap is invisible in this mode -- the tone test below is what
    separates them.

    Includes negative levels (2026-09-04): DC mode used to hardcode the
    magnitude of BRINGUP_AMPL, silently dropping the sign, so this check was
    previously vacuous for the negative half of the documented signed range.
    """
    for A in (16, 32, 48, -16, -32, -48):
        await reset_dut(dut)
        await spi_write(dut, REG_MIMO_CTRL, 0xF1)
        await spi_write(dut, REG_COMB_CFG, 0x01)
        await arm(dut, MODE_DC, A)

        bits_i, bits_q = await capture_remod(dut, 128 * DECIM)
        want = A / REMOD_FULL_SCALE
        got_i = sum(bits_i) / len(bits_i)
        got_q = sum(bits_q) / len(bits_q)

        for rail, got in (("I", got_i), ("Q", got_q)):
            assert abs(got - want) < 0.02, (
                f"DC ampl={A}: REMOD_A_{rail} density {got:+.4f} does not "
                f"match the programmed level {want:+.4f}"
            )


@cocotb.test()
async def test_tone_signature_at_the_remod_output(dut):
    """Tone mode: reconstruct the 1-bit output and compare with the reference.

    The fs/4 rotation is the mandatory modulation-fidelity check. Decimating
    R=64 with the same brickwall the remod SQNR model uses gives the complex
    baseband the bring-up engineer would reconstruct externally; it must match
    A/127 * exp(+j*pi/2*n) in amplitude AND in rotation direction.

    Direction is the point of testing I and Q *together*: a swapped or
    inverted rail leaves both per-rail densities and the residual magnitude
    untouched, and shows up only as the conjugate tone. The test fails a
    conjugated reconstruction explicitly rather than accepting |correlation|.
    """
    import numpy as np
    from sim.tests.remod_order_sweep import brickwall_lp_decim

    A = 48
    await reset_dut(dut)
    await spi_write(dut, REG_MIMO_CTRL, 0xF1)
    await spi_write(dut, REG_COMB_CFG, 0x01)
    await arm(dut, MODE_TONE, A)

    bits_i, bits_q = await capture_remod(dut, 256 * DECIM)
    y = np.asarray(bits_i, float) + 1j * np.asarray(bits_q, float)
    rec = brickwall_lp_decim(y, 250e3, 32e6, DECIM)

    # Drop the filter's circular-convolution edges before fitting.
    seg = rec[16:-16]
    n = np.arange(len(seg))
    ideal = np.exp(1j * np.pi / 2 * n)

    # Least-squares complex gain against the tone and against its conjugate.
    g = np.vdot(ideal, seg) / np.vdot(ideal, ideal)
    g_conj = np.vdot(np.conj(ideal), seg) / np.vdot(ideal, ideal)

    assert abs(g) > 4 * abs(g_conj), (
        f"reconstructed tone is not a clean positive rotation "
        f"(|g|={abs(g):.4f} vs |g_conj|={abs(g_conj):.4f}) -- I/Q swapped or "
        "a rail inverted"
    )

    want = A / REMOD_FULL_SCALE
    assert abs(abs(g) - want) < 0.05 * want + 0.01, (
        f"reconstructed tone amplitude {abs(g):.4f} does not match the "
        f"programmed {want:.4f}"
    )

    resid = seg - g * ideal
    sqnr = 10 * np.log10(np.mean(np.abs(g * ideal) ** 2) /
                         np.mean(np.abs(resid) ** 2))
    # The 250 kHz brickwall is the repo's standard reconstruction (it matches
    # sim.tests.remod_order_sweep and test_capture_playback), and it passes the
    # entire 500 kS/s output band -- including all of the shaped noise the NTF
    # pushed to the upper edge. The in-band figure that comes out is therefore
    # a whole-band number, not a narrowband one: 18.2 dB measured here. The bar
    # is a liveness-and-fidelity floor, not an SQNR spec; a re-modulator that
    # is not tracking lands near 0 dB, not near 15.
    assert sqnr > 15.0, (
        f"reconstructed tone SQNR {sqnr:.1f} dB -- the re-modulator is not "
        "tracking the programmed reference"
    )


async def _iq_square(dut, half_period=256):
    """Drive the IQ pads with a slow square wave so the decimator arm is live.

    A constant bitstream is useless here: dc_removal strips it within ~32
    samples and the normal path settles back to zero, which would make the
    precedence check below vacuous in exactly the way it is trying to rule
    out. 62.5 kHz sits well inside the 125/250 kHz passband and survives the
    leaky integrator.
    """
    level = 0
    while True:
        level ^= 1
        dut.IQ_DATA_I.value = level
        dut.IQ_DATA_Q.value = level
        for _ in range(half_period):
            await RisingEdge(dut.IQ_CLK)


@cocotb.test()
async def test_bringup_overrides_the_live_normal_path(dut):
    """An armed source must dominate the live receive path into sd_remod.

    Every other test in this file runs with the IQ pads tied low, so the normal
    arm the source is supposed to override carries near-silence -- and a mux
    with the priority written the wrong way round would pass all of them. Here
    the whole chain is made demonstrably live first, so the override is
    actually being tested.
    """
    A = 32

    # -- the normal arm is live: disarmed, sd_remod sees a moving stream ------
    await reset_dut(dut)
    cocotb.start_soon(_iq_square(dut))
    seen = set()
    for _ in range(24 * DECIM):
        await RisingEdge(dut.IQ_CLK)
        if int(dut.u_dut.remod_in_valid.value):
            seen.add((dut.u_dut.remod_in_i.value.signed_integer,
                      dut.u_dut.remod_in_q.value.signed_integer))
    assert len(seen) > 1 and seen != {(A, A)}, (
        "the normal path never moved, so the override check would be vacuous: "
        f"{sorted(seen)[:4]}"
    )

    # -- armed, the same live stream must be completely displaced -------------
    await arm(dut, MODE_DC, A)
    got = []
    for _ in range(24 * DECIM):
        await RisingEdge(dut.IQ_CLK)
        if int(dut.u_dut.remod_in_valid.value):
            got.append((dut.u_dut.remod_in_i.value.signed_integer,
                        dut.u_dut.remod_in_q.value.signed_integer))

    assert got, "no sample reached sd_remod while armed"
    assert all(g == (A, A) for g in got), (
        "the live receive stream leaked past the armed bring-up source: "
        f"{[g for g in got if g != (A, A)][:4]}"
    )


@cocotb.test()
async def test_disarm_returns_the_path_without_a_stuck_output(dut):
    """Disarming mid-stream must hand sd_remod back to the live path cleanly.

    sd_remod's integrators carry state across samples, so the handover is not
    free: the loop is mid-conversion on the injected level when the mux flips.
    What must not happen is the modulator latching the last injected sample and
    holding it as a DC tone, or the valid cadence stalling -- both would look
    like a dead or stuck re-modulator during bring-up, which is precisely the
    failure this source exists to rule out. (That stuck-DC mode is the same one
    Open Risks #5 fixed for the PSRAM buffering path.)
    """
    A = 32
    await reset_dut(dut)
    cocotb.start_soon(_iq_square(dut))
    await arm(dut, MODE_DC, A)

    # Land the disarm just after a sample is presented, while sd_remod's
    # integrators are still converting it.
    for _ in range(4 * DECIM):
        await RisingEdge(dut.IQ_CLK)
        if int(dut.u_dut.remod_in_valid.value):
            break
    else:
        raise AssertionError("source never presented a sample")
    await RisingEdge(dut.IQ_CLK)

    dut.u_dut.u_rb.bringup_ctrl.value = 0x00        # EN low, mid-stream
    await RisingEdge(dut.IQ_CLK)
    assert int(dut.u_dut.bringup_en_q.value) == 0

    # The live path resumes: valid keeps pulsing and the input stops being the
    # injected constant.
    after = []
    for _ in range(24 * DECIM):
        await RisingEdge(dut.IQ_CLK)
        if int(dut.u_dut.remod_in_valid.value):
            after.append((dut.u_dut.remod_in_i.value.signed_integer,
                          dut.u_dut.remod_in_q.value.signed_integer))

    assert len(after) >= 8, \
        f"only {len(after)} samples after disarm -- the valid cadence stalled"
    assert set(after) != {(A, A)}, \
        "the input stayed pinned at the injected level after disarm"

    # And the modulator is still modulating, not stuck at a rail.
    bits_i, bits_q = await capture_remod(dut, 64 * DECIM, settle_clks=2 * DECIM)
    assert len(set(bits_i)) > 1 and len(set(bits_q)) > 1, \
        "REMOD_A_I/Q stopped toggling after the source was disarmed"


# ---------------------------------------------------------------------------
# The !packet_active term of the arming gate
#
# bringup_en_q has three terms (trouper_top.v:889) and only two were covered:
# the register bit and rx_hold. The third turns out to be defence-in-depth
# rather than the sole barrier, and it is worth recording WHY, because the
# reasoning is not obvious from trouper_top alone:
#
#   packet_ctrl_fsm does not take rx_hold, so raising RX_HOLD mid-packet does
#   NOT abort the packet -- packet_active stays 1. That looks like a window in
#   which the register bit and rx_hold are both satisfied while a packet runs.
#   It is closed one level up: reg_bank's write gate is
#   `cfg_wr_ok = rx_hold && !packet_active` (reg_bank.v:212), the same pair, so
#   the CTRL bit cannot even be written there.
#
# Both barriers are checked below. The level term is not independently
# reachable -- arming needs rx_hold, and rx_hold holds the SC detector cleared
# (`sc_clr = packet_done_pulse | rx_hold`, trouper_top.v:593) so no lock and no
# packet can begin while the source is armed; releasing rx_hold drops
# bringup_en_q on the rx_hold term before packet_active can rise.
# ---------------------------------------------------------------------------

REG_SC_FORCE_LOCK = 0x19


@cocotb.test()
async def test_arming_is_refused_during_a_live_packet(dut):
    """RX_HOLD raised mid-packet must not let the source seize sd_remod.

    Raising RX_HOLD during reception does not end the packet, so this is the
    one sequence where a host could plausibly try to arm the source while the
    receiver is live. Two independent mechanisms must both hold: the config
    write is refused (and the refusal latched, or firmware cannot tell), and
    the qualified enable stays low regardless.
    """
    A = 32
    await reset_dut(dut)
    await release_rx_hold(dut)
    await spi_write(dut, REG_SC_FORCE_LOCK, 0x01)      # force sc_lock

    for _ in range(8 * DECIM):
        await RisingEdge(dut.IQ_CLK)
        if int(dut.u_dut.packet_active.value):
            break
    else:
        raise AssertionError("packet never became active -- check is vacuous")

    await assert_rx_hold(dut)
    assert int(dut.u_dut.packet_active.value) == 1, \
        "the packet ended when RX_HOLD was raised -- the window is gone and " \
        "this test no longer covers what it claims"

    # Barrier 1: reg_bank refuses the write (cfg_wr_ok = rx_hold && !packet_active).
    await arm(dut, MODE_DC, A)
    assert int(await spi_read(dut, REG_BRINGUP_CTRL)) == 0x00, \
        "BRINGUP_CTRL was written during a live packet"
    assert int(await spi_read(dut, REG_RX_HOLD)) & 0x02, \
        "CFG_WR_REJECTED did not latch the refused mid-packet write -- a " \
        "dropped write is otherwise invisible to firmware"

    # Barrier 2: the qualified enable stays low even so.
    for _ in range(4 * DECIM):
        await RisingEdge(dut.IQ_CLK)
        assert int(dut.u_dut.bringup_en_q.value) == 0, \
            "BRINGUP_SRC armed during a live packet -- it would seize " \
            "sd_remod's input mid-reception"
        assert int(dut.u_dut.u_bringup_src.src_valid.value) == 0, \
            "the generator ran during a live packet"


@cocotb.test()
async def test_level_term_holds_if_the_bit_is_forced_during_a_packet(dut):
    """With the write gate bypassed, the level term alone must still hold.

    Barrier 1 above makes the CTRL bit unwritable mid-packet, which would leave
    the level term in trouper_top.v:889 permanently unexercised -- and an
    unexercised barrier is one that can be deleted as "redundant" by someone
    reading only reg_bank. Forcing the register models exactly that: the day
    cfg_wr_ok changes, or an SEU flips the bit, this is what is left.
    """
    await reset_dut(dut)
    await release_rx_hold(dut)
    await spi_write(dut, REG_SC_FORCE_LOCK, 0x01)

    for _ in range(8 * DECIM):
        await RisingEdge(dut.IQ_CLK)
        if int(dut.u_dut.packet_active.value):
            break
    else:
        raise AssertionError("packet never became active -- check is vacuous")

    await assert_rx_hold(dut)
    dut.u_dut.u_rb.bringup_ctrl.value = ctrl(MODE_DC)   # bypass the write gate

    for _ in range(4 * DECIM):
        await RisingEdge(dut.IQ_CLK)
        assert int(dut.u_dut.packet_active.value) == 1, \
            "the packet ended mid-check -- the level term is no longer under test"
        assert int(dut.u_dut.bringup_en_q.value) == 0, \
            "the !packet_active term did not hold with the CTRL bit forced set"


# ---------------------------------------------------------------------------
# Debug-probe interaction (a consequence of the move)
#
# The two-pin probe's COMB group taps remod_in_i/remod_in_q
# (trouper_top.v:1269-1270), which is now DOWNSTREAM of the bring-up mux. So an
# armed source is visible on DBG0/DBG1 as well as on REMOD_A_I/Q. That is worth
# having -- it gives a second, byte-level view of the stimulus without a radio
# -- but it changed with the insertion point, and an untested side effect of a
# mux move is how a debug aid ends up lying to the person relying on it.
# ---------------------------------------------------------------------------

REG_DBG_CTRL = 0x04
G_COMB       = 6


def _dbg_ctrl(group, ant=0, sel=0, en=True):
    """Pack DBG_CTRL = {EN, GROUP[2:0], ANT[1:0], SEL[1:0]}."""
    return (0x80 if en else 0) | ((group & 0x7) << 4) | ((ant & 0x3) << 2) | (sel & 0x3)


@cocotb.test()
async def test_debug_probe_comb_group_shows_the_injected_sample(dut):
    """DBG0's COMB group must carry the programmed sample's bits.

    Amplitude 64 (0x40) is chosen because exactly one of the four probed bit
    lanes is set: comb_i_lane = {bit0, bit1, bit6, bit7} and lane[1] is bit 6.
    A lane mapping that silently changed, or a probe still tapping the old
    pre-mux node, would show a different one-hot position or none at all.
    """
    A = 64                                  # 0b0100_0000 -> only bit 6 set
    await reset_dut(dut)
    await arm(dut, MODE_DC, A)

    # Let the generator present its first sample.
    for _ in range(3 * DECIM):
        await RisingEdge(dut.IQ_CLK)
        if int(dut.u_dut.remod_in_i.value) == A:
            break
    else:
        raise AssertionError("the injected sample never reached remod_in_i")

    seen = {}
    for sel in range(4):
        await spi_write(dut, REG_DBG_CTRL, _dbg_ctrl(G_COMB, sel=sel))
        await RisingEdge(dut.IQ_CLK)
        await RisingEdge(dut.IQ_CLK)
        seen[sel] = int(dut.DBG0_OUT.value)

    assert seen == {0: 0, 1: 1, 2: 0, 3: 0}, (
        f"DBG0 COMB lanes read {seen} for a programmed +{A}; expected bit 6 "
        "(sel=1) alone. The probe is not observing the injected sample."
    )
