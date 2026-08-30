"""
test_remod_en.py -- sd_remod enable/disable behaviour (R1,
planning/dsp-block-review-changes-2026-07.md).

Pre-fix hazard: with en=0 the output was forced 0 but the integrators kept
running. A 0 output feeds back as -127, so the error term is +127 every clock
and all three integrator stages rail at +32767 within ~256 cycles. On
re-enable the modulator started from a railed state with a recovery transient
that is unobservable from outside (near-rail integrator states are not a
valid instability signal -- see test_remod_backoff.py).

Post-fix contract: while en=0 the loop is held at its reset state
(s1..s3 = 0, out = 0), so re-enabling is bit-identical to starting from a
fresh reset.

Unit-level bench: TOPLEVEL = sd_remod, no trouper_top (which ties en to 1'b1
-- the en port is only exercised by other integrations, hence a direct
bench). Internals (s1_i etc.) are visible via Verilator --public-flat-rw.

  test_disable_holds_reset      -- integrators pinned at 0 while disabled
                                   (pre-fix: railed at +32767 -> FAIL), and
                                   the output dithers normally on re-enable.
  test_reenable_equals_fresh_start -- output bitstream after (heavy activity
                                   -> disable -> re-enable) is bit-identical
                                   to the same stimulus from a fresh reset.
"""

import math

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

CLK_NS = 31.25
SAMPLE_CLKS = 64          # OSR=64: one int8 input sample per 64 output bits
STUCK_RUN_LIMIT = 100     # Same output-dither health ceiling used by remod_backoff.
TRANSITION_RUN_LIMIT = 200  # Step response has a bounded, longer settling run.


async def _reset(dut):
    dut.rst_n.value = 0
    dut.en.value = 0
    dut.in_valid.value = 0
    dut.in_i.value = 0
    dut.in_q.value = 0
    await ClockCycles(dut.clk_32m, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk_32m, 2)


async def _latch_sample(dut, i, q):
    """One in_valid pulse (works with en high or low -- latching is ungated)."""
    dut.in_i.value = i & 0xFF
    dut.in_q.value = q & 0xFF
    dut.in_valid.value = 1
    await RisingEdge(dut.clk_32m)
    dut.in_valid.value = 0


def _integrators(dut):
    return [int(s.value.signed_integer) for s in
            (dut.s1_i, dut.s2_i, dut.s3_i, dut.s1_q, dut.s2_q, dut.s3_q)]


def _lcg_seq(n, seed=0xC0FFEE):
    """Deterministic int8 sample sequence, |v| <= 80 (inside the -3 dBFS contract)."""
    out = []
    s = seed
    for _ in range(n):
        s = (1103515245 * s + 12345) & 0x7FFFFFFF
        i = (s % 161) - 80
        s = (1103515245 * s + 12345) & 0x7FFFFFFF
        q = (s % 161) - 80
        out.append((i, q))
    return out


async def _run_sequence(dut, seq, nbits):
    """From the held-disabled state (s*=0, out=0): latch seq[0], raise en,
    then feed one sample per 64 clocks and record nbits output-bit pairs.
    Both callers use this identical procedure so the two recordings are
    cycle-aligned relative to the en rising edge."""
    await _latch_sample(dut, *seq[0])
    await RisingEdge(dut.clk_32m)
    dut.en.value = 1
    bits = []
    idx = 1
    clk_in_sample = 0
    while len(bits) < nbits:
        await RisingEdge(dut.clk_32m)
        bits.append((int(dut.out_i.value), int(dut.out_q.value)))
        clk_in_sample += 1
        if clk_in_sample == SAMPLE_CLKS:
            clk_in_sample = 0
            if idx < len(seq):
                await _latch_sample(dut, *seq[idx])
                bits.append((int(dut.out_i.value), int(dut.out_q.value)))
                clk_in_sample = 1
                idx += 1
    return bits


def _max_pair_run(bits):
    return max(_max_run([i for i, _ in bits]), _max_run([q for _, q in bits]))


async def _run_boundary_case(dut, value, nbits=8192):
    await _reset(dut)
    return _max_pair_run(await _run_sequence(dut, [(value, value)], nbits))


def _max_run(bits):
    best = run = 1
    for a, b in zip(bits, bits[1:]):
        run = run + 1 if a == b else 1
        best = max(best, run)
    return best


@cocotb.test()
async def test_boundary_stuck_run_sweep(dut):
    """TRPR-RMD-006 boundary characterization using the quantizer output.

    A CIFF integrator may sit on a saturation rail during normal operation, so
    this deliberately does not inspect integrator state.  For each constant
    signed input, it records the longest identical-bit run in each 1-bit
    output.  ±88 and ±90 are the in-spec boundary points and must retain
    dither; ±100 and ±127 are deliberately out-of-spec characterization
    points, reported without imposing the RMD-006 contract on them.
    """
    cocotb.start_soon(Clock(dut.clk_32m, CLK_NS, unit="ns").start())
    nbits = 8192
    in_spec = {-90, -88, 88, 90}
    results = {}

    for value in (-127, -100, -90, -88, 88, 90, 100, 127):
        await _reset(dut)
        await _reset(dut)
        bits = await _run_sequence(dut, [(value, value)], nbits)
        run_i = _max_run([i for i, _ in bits])
        run_q = _max_run([q for _, q in bits])
        run = max(run_i, run_q)
        results[value] = run
        dut._log.info(
            f"remod boundary input={value:+d}: output stuck-run "
            f"I={run_i} Q={run_q} (window={nbits})"
        )
        if value in in_spec:
            assert run < STUCK_RUN_LIMIT, (
                f"TRPR-RMD-006 input {value:+d}: output stuck for {run} "
                f"cycles (limit {STUCK_RUN_LIMIT}); quantizer lost dither"
            )

    dut._log.info(
        "TRPR-RMD-006 boundary points ±88/±90 retain output dither; "
        "±100/±127 are logged as out-of-spec characterization: "
        f"{results}"
    )


@cocotb.test()
async def test_all_in_spec_dc_codes_retain_dither(dut):
    """Literal TRPR-RMD-006 sweep of every constant int8 code in [-90, +90]."""
    cocotb.start_soon(Clock(dut.clk_32m, CLK_NS, unit="ns").start())
    worst_run = 0
    worst_value = None
    for value in range(-90, 91):
        run = await _run_boundary_case(dut, value)
        if run > worst_run:
            worst_run, worst_value = run, value
        assert run < STUCK_RUN_LIMIT, (
            f"TRPR-RMD-006 DC input {value:+d}: output stuck for {run} cycles "
            f"(limit {STUCK_RUN_LIMIT})"
        )
    dut._log.info(
        f"TRPR-RMD-006 exhaustive DC sweep PASS: 181 codes, worst stuck-run "
        f"{worst_run} cycles at input {worst_value:+d}"
    )


@cocotb.test()
async def test_boundary_transitions_retain_dither(dut):
    """Boundary sign/zero transitions must not create a frozen output run."""
    cocotb.start_soon(Clock(dut.clk_32m, CLK_NS, unit="ns").start())
    patterns = {
        "sign": [(90, -90), (-90, 90)],
        "zero": [(0, 0), (90, -90), (0, 0), (-90, 90)],
    }
    for name, pattern in patterns.items():
        await _reset(dut)
        bits = await _run_sequence(dut, pattern * 32, 8192)
        run = _max_pair_run(bits)
        assert run < TRANSITION_RUN_LIMIT, (
            f"TRPR-RMD-006 {name} boundary transition stuck for {run} cycles "
            f"(limit {TRANSITION_RUN_LIMIT})"
        )
        dut._log.info(f"boundary transition {name}: longest output run={run}")


@cocotb.test()
async def test_bounded_random_iq_retain_dither(dut):
    """Asymmetric, deterministic I/Q activity bounded by the RMD-006 range."""
    cocotb.start_soon(Clock(dut.clk_32m, CLK_NS, unit="ns").start())
    seq = []
    state = 0x5A17
    for _ in range(128):
        state = (1103515245 * state + 12345) & 0x7FFFFFFF
        i = (state % 181) - 90
        state = (1103515245 * state + 12345) & 0x7FFFFFFF
        q = (state % 181) - 90
        seq.append((i, q))
    await _reset(dut)
    run = _max_pair_run(await _run_sequence(dut, seq, 8192))
    assert run < STUCK_RUN_LIMIT, f"bounded random I/Q stuck for {run} cycles"
    dut._log.info(f"bounded random I/Q: longest output run={run}")


@cocotb.test()
async def test_in_valid_holds_sample_and_retains_dither(dut):
    """Invalid-cycle pin changes cannot alter the held remodulator sample."""
    cocotb.start_soon(Clock(dut.clk_32m, CLK_NS, unit="ns").start())
    await _reset(dut)
    await _latch_sample(dut, 33, -33)
    dut.en.value = 1
    bits = []
    for _ in range(80):
        await RisingEdge(dut.clk_32m)
        bits.append((int(dut.out_i.value), int(dut.out_q.value)))
    dut.in_i.value, dut.in_q.value = -90, 90
    for _ in range(127):
        await RisingEdge(dut.clk_32m)
        assert int(dut.in_i_lat.value.signed_integer) == 33
        assert int(dut.in_q_lat.value.signed_integer) == -33
        bits.append((int(dut.out_i.value), int(dut.out_q.value)))
    await _latch_sample(dut, -90, 90)
    for _ in range(4096):
        await RisingEdge(dut.clk_32m)
        bits.append((int(dut.out_i.value), int(dut.out_q.value)))
    assert int(dut.in_i_lat.value.signed_integer) == -90
    assert int(dut.in_q_lat.value.signed_integer) == 90
    run = _max_pair_run(bits)
    assert run < STUCK_RUN_LIMIT, f"in_valid timing sequence stuck for {run} cycles"


@cocotb.test()
async def test_boundary_reenable_equals_fresh_start(dut):
    """Enable recovery at the RMD-006 endpoints is bit-exact to fresh reset."""
    cocotb.start_soon(Clock(dut.clk_32m, CLK_NS, unit="ns").start())
    for value in (-90, 90):
        seq = [(value, -value)] * 48
        await _reset(dut)
        fresh = await _run_sequence(dut, seq, 2048)
        await _reset(dut)
        dut.en.value = 1
        for _ in range(16):
            await _latch_sample(dut, -value, value)
            await ClockCycles(dut.clk_32m, SAMPLE_CLKS - 1)
        dut.en.value = 0
        await ClockCycles(dut.clk_32m, 300)
        resumed = await _run_sequence(dut, seq, 2048)
        assert fresh == resumed, f"boundary {value:+d}: re-enable differs from fresh start"


@cocotb.test()
async def test_boundary_tone_quality(dut):
    """Characterize boundary-tone reconstruction without over-claiming RMD-005/007.

    This is deliberately an output-only check: average 64 one-bit clocks per
    held input sample and compare against the programmed I/Q tone.  It extends
    the RMD-005/007 quality evidence near the RMD-006 boundary without using
    integrator state as a proxy for signal health.  RMD-005/007's quantitative
    SQNR/RMS contract is at -6 dBFS (64 codes), so this intentionally uses a
    looser guard at 88/90 and logs the fitted result for calibration review.
    """
    cocotb.start_soon(Clock(dut.clk_32m, CLK_NS, unit="ns").start())
    for amplitude in (88, 90):
        await _reset(dut)
        dut.en.value = 1
        actual_i, actual_q, expected_i, expected_q = [], [], [], []
        for sample in range(192):
            i = round(amplitude * math.sin(2 * math.pi * sample / 32))
            q = round(amplitude * math.cos(2 * math.pi * sample / 32))
            await _latch_sample(dut, i, q)
            acc_i = acc_q = 0
            for _ in range(SAMPLE_CLKS):
                await RisingEdge(dut.clk_32m)
                acc_i += 1 if int(dut.out_i.value) else -1
                acc_q += 1 if int(dut.out_q.value) else -1
            actual_i.append(acc_i * 127 / SAMPLE_CLKS)
            actual_q.append(acc_q * 127 / SAMPLE_CLKS)
            expected_i.append(i)
            expected_q.append(q)
        # Discard the reset/start transient.  The simple 64-clock boxcar is
        # intentionally only a quality guard, not the production CIC model.
        for actual, expected, channel in ((actual_i, expected_i, "I"), (actual_q, expected_q, "Q")):
            actual, expected = actual[16:], expected[16:]
            # The 64-clock boxcar has deterministic group delay and gain; fit
            # both before assessing residual noise.  This is a quality guard
            # for boundary tones, not a replacement for the production CIC.
            best = None
            for lag in range(-8, 9):
                a = actual[max(0, lag):len(actual) + min(0, lag)]
                e = expected[max(0, -lag):len(expected) - max(0, lag)]
                dot = sum(x * y for x, y in zip(a, e))
                norm = math.sqrt(sum(x * x for x in a) * sum(y * y for y in e))
                corr = dot / norm
                if best is None or corr > best[0]:
                    best = (corr, lag, a, e, dot)
            corr, lag, a, e, dot = best
            gain = dot / sum(x * x for x in e)
            rms = math.sqrt(sum((x - gain * y) ** 2 for x, y in zip(a, e)) / len(a))
            assert corr > 0.80 and rms < 40.0, (
                f"boundary tone amp={amplitude} {channel}: corr={corr:.4f}, "
                f"lag={lag}, fitted rms={rms:.2f}"
            )
            dut._log.info(
                f"boundary tone amp={amplitude} {channel}: corr={corr:.4f}, lag={lag}, "
                f"gain={gain:.4f}, fitted rms={rms:.2f} LSB"
            )


@cocotb.test()
async def test_disable_holds_reset(dut):
    cocotb.start_soon(Clock(dut.clk_32m, CLK_NS, unit="ns").start())
    await _reset(dut)

    # -- Active phase: DC input at 60 counts, confirm the loop is alive ------
    dut.en.value = 1
    saw_nonzero_integrator = False
    out_bits = []
    for _ in range(32):
        await _latch_sample(dut, 60, -60)
        for _ in range(SAMPLE_CLKS - 1):
            await RisingEdge(dut.clk_32m)
            out_bits.append(int(dut.out_i.value))
        if any(v != 0 for v in _integrators(dut)):
            saw_nonzero_integrator = True
    assert saw_nonzero_integrator, "sanity: integrators never moved while enabled"
    assert 0 in out_bits and 1 in out_bits, "sanity: output not toggling while enabled"

    # -- Disable: loop must sit at its reset state, input activity or not ----
    dut.en.value = 0
    await ClockCycles(dut.clk_32m, 2)  # one clock for the hold to take effect
    for n in range(1024):
        await RisingEdge(dut.clk_32m)
        if n % SAMPLE_CLKS == 0:
            await _latch_sample(dut, 60, -60)   # keep stimulus running
        ints = _integrators(dut)
        assert all(v == 0 for v in ints), \
            f"integrators not held at 0 while en=0 (clk {n}): {ints} " \
            "(pre-fix RTL rails these at +32767)"
        assert int(dut.out_i.value) == 0 and int(dut.out_q.value) == 0, \
            f"output not forced 0 while en=0 (clk {n})"

    # -- Re-enable with zero input: output must dither immediately -----------
    dut.en.value = 1
    dut.in_i.value = 0
    dut.in_q.value = 0
    bits = []
    for n in range(4096):
        await RisingEdge(dut.clk_32m)
        if n % SAMPLE_CLKS == 0:
            await _latch_sample(dut, 0, 0)
        bits.append(int(dut.out_i.value))
    ones = sum(bits)
    assert 0.2 < ones / len(bits) < 0.8, \
        f"post-re-enable output not balanced for zero input: {ones}/{len(bits)} ones"
    assert _max_run(bits) < 100, \
        f"post-re-enable output stuck for {_max_run(bits)} cycles " \
        "(healthy zero-input dither runs are well under 100 -- see " \
        "test_remod_backoff.py STUCK_HEALTHY calibration)"


@cocotb.test()
async def test_reenable_equals_fresh_start(dut):
    cocotb.start_soon(Clock(dut.clk_32m, CLK_NS, unit="ns").start())
    seq = _lcg_seq(48)
    nbits = 40 * SAMPLE_CLKS

    # -- Run A: fresh reset -> sequence --------------------------------------
    await _reset(dut)
    bits_a = await _run_sequence(dut, seq, nbits)

    # -- Run B: heavy activity -> long disable -> same sequence --------------
    await _reset(dut)
    dut.en.value = 1
    for i, q in _lcg_seq(30, seed=0xBADF00D):   # different, near-full-scale history
        await _latch_sample(dut, min(i + 40, 90), max(q - 40, -90))
        await ClockCycles(dut.clk_32m, SAMPLE_CLKS - 1)
    dut.en.value = 0
    await ClockCycles(dut.clk_32m, 600)          # long enough to rail pre-fix RTL
    bits_b = await _run_sequence(dut, seq, nbits)

    assert bits_a == bits_b, (
        "re-enabled output diverges from fresh-reset output with identical "
        f"stimulus (first mismatch at bit {next(i for i, (a, b) in enumerate(zip(bits_a, bits_b)) if a != b)} "
        f"of {nbits}) -- disable did not return the loop to its reset state"
    )
