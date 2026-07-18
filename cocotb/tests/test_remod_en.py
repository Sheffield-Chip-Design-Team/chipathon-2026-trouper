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

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

CLK_NS = 31.25
SAMPLE_CLKS = 64          # OSR=64: one int8 input sample per 64 output bits


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


def _max_run(bits):
    best = run = 1
    for a, b in zip(bits, bits[1:]):
        run = run + 1 if a == b else 1
        best = max(best, run)
    return best


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
