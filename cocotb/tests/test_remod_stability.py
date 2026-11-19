"""
test_remod_stability.py -- long constrained-random + adversarial stability
confirmation for the canonical sd_remod (2x droop-comp interpolator +
4th-order CIFF multiplierless core).

Gap this closes
---------------
The 4th-order loop's stability evidence was breadth-limited:

  - cocotb/remod_en/test_remod_en.py sweeps every DC code in [-90, +90] and a
    few boundary transitions / 128-sample bounded-random bursts (8,192 output
    bits each) -- thorough but short.
  - The 2026-09-04 fix's own confidence came from a 300-trial randomized tone
    sweep + 200-trial LoRa chirp sweep run in a throwaway Verilator batch
    (SGE job 5575), never committed.
  - planning/sd-remod-error-feedback-investigation-2026-09-09.md names the
    missing bar explicitly: promotion of any remod topology needs "a
    bounded-state proof or substantially longer constrained-random/adversarial
    testing" over step / alternating / period-3 / fixed-seed random / DC
    inputs within the realizable [-89, +89] range.

This suite is that longer run for the *incumbent*: millions of output clocks
of constrained-random and deliberately adversarial int8 I/Q through the real
RTL at production OSR=64 cadence, checking the instability signatures the
design docs identify as the correct ones for a 1-bit noise shaper.

What "unstable" means here (planning/Traceability.md sec. 4.9)
------------------------------------------------------------
  1. Output dither loss -- the longest identical-bit run on out_i / out_q.
     Near-rail integrator state is NOT a valid instability signal (a CIFF
     cascade sits near a rail even when healthy); a frozen 1-bit output is.
     TRPR-RMD-006 ceiling: 100 clocks over an 8,192-clock window. Here we
     track the global longest run across the whole multi-million-clock stream.
  2. saturation wrap -- every integrator must stay inside its own signed
     width (CIFF3, 2026-10-03: s1 13-bit, s2 14-bit, s3 16-bit). The sat
     functions clip by construction; a value outside the range means the
     saturation was removed/broken (TRPR-RMD-003).
  3. Loop latch-up -- the first integrator frozen at one value for an
     extended span means the loop has stopped shaping. A healthy loop keeps
     moving even under sustained rail input.
  4. No permanent degradation -- after every adversarial burst, a clean
     -6 dBFS tone must still reconstruct above 40 dB SQNR with dither intact.
     This is the correct test of the requirement's "permanent instability"
     framing: a healthy loop recovers from railing, it does not stick.

Inputs stay within the TRPR-RMD-004/006 contract, |v| <= 90. Out-of-contract
amplitudes are logged characterization in test_remod_en.py and are not
exercised here.
"""
import numpy as np
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from sim.tests.remod_order_sweep import brickwall_lp_decim

CLK_NS = 31.25
OSR = 64
FS_OUT = 500_000.0
FS_ADC = FS_OUT * OSR
SX1302_BAND_HZ = 250_000.0

STUCK_RUN_LIMIT = 100      # TRPR-RMD-006, same ceiling as remod_en / remod_backoff
# s1_i, s2_i, s3_i, s1_q, s2_q, s3_q signed widths (sd_remod_multiplierless.v)
STATE_BITS = (13, 14, 16, 13, 14, 16)
S1_HOLD_LIMIT = 4096       # first integrator frozen this many samples => latch-up
SQNR_RECOVER_DB = 40.0     # TRPR-RMD-005 after an adversarial burst

SAMPLES_RANDOM = 20_000    # per seed; * OSR = 1.28 M output clocks each
RANDOM_SEEDS = (0x00C0FFEE, 0x1357BDF9, 0x2468ACE0, 0x5A5A0F0F)
SAMPLES_ADVERSARIAL = 3_000


async def _reset(dut):
    dut.rst_n.value = 0
    dut.en.value = 0
    dut.in_valid.value = 0
    dut.in_i.value = 0
    dut.in_q.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk_32m)
    dut.rst_n.value = 1
    for _ in range(2):
        await RisingEdge(dut.clk_32m)
    dut.en.value = 1


def _integrators(dut):
    c = dut.u_remod   # sd_remod_multiplierless child (canonical since 7f64c88)
    return [int(s.value.signed_integer) for s in
            (c.s1_i, c.s2_i, c.s3_i, c.s1_q, c.s2_q, c.s3_q)]


# ---- deterministic stimulus generators (all within |v| <= 90) --------------

def _lcg_random(n, seed):
    s = seed & 0x7FFFFFFF
    out = []
    for _ in range(n):
        s = (1103515245 * s + 12345) & 0x7FFFFFFF
        i = (s % 181) - 90
        s = (1103515245 * s + 12345) & 0x7FFFFFFF
        q = (s % 181) - 90
        out.append((i, q))
    return out


def _pat_alternating(n):
    """Maximum step every sample: +-90 hard toggle."""
    return [((-90, 90) if k & 1 else (90, -90)) for k in range(n)]


def _pat_period3(n):
    """Period-3 -- the sequence class the EF2 doc found grew states on an
    exact double-zero NTF."""
    base = [(90, 90), (-90, -90), (0, 0)]
    return [base[k % 3] for k in range(n)]


def _pat_dc(n, v):
    return [(v, v)] * n


def _pat_rail_flip(n):
    """Sit at +90 then a single -90 spike, repeating -- worst case for an
    integrator that has wound up against a rail."""
    return [((-90, -90) if (k % 51) == 50 else (90, 90)) for k in range(n)]


def _pat_triangle(n):
    """Slow triangular ramp -90 -> +90 -> -90 over 360 samples, I and Q
    anti-phase."""
    out = []
    for k in range(n):
        p = k % 360
        v = -90 + p if p <= 180 else 90 - (p - 180)
        out.append((v, -v))
    return out


def _pat_iq_skew(n):
    """Asymmetric loading: I toggles every sample, Q toggles every 64."""
    return [((90 if k & 1 else -90), (90 if (k // 64) & 1 else -90))
            for k in range(n)]


# ---- drive / measure ------------------------------------------------------

async def _drive_sample(dut, si, sq):
    dut.in_i.value = int(si) & 0xFF
    dut.in_q.value = int(sq) & 0xFF
    dut.in_valid.value = 1
    await RisingEdge(dut.clk_32m)
    dut.in_valid.value = 0


async def _stream(dut, seq):
    """Drive seq at OSR=64 cadence through the already-enabled DUT, streaming
    (no multi-million-entry lists). Returns:
      max_run     -- longest identical-bit run seen on out_i or out_q
      s1_hold     -- longest run of an unchanged first-integrator value
      (imin,imax) -- per-integrator value extremes over the whole burst
    """
    max_run = 1
    run_i = run_q = 1
    last_i = last_q = -1
    s1_hold = s1_run = 1
    last_s1i = last_s1q = None
    imin = [0] * len(STATE_BITS)
    imax = [0] * len(STATE_BITS)

    for si, sq in seq:
        await _drive_sample(dut, si, sq)
        bi = int(dut.out_i.value)
        bq = int(dut.out_q.value)
        run_i = run_i + 1 if bi == last_i else 1
        run_q = run_q + 1 if bq == last_q else 1
        last_i, last_q = bi, bq
        max_run = max(max_run, run_i, run_q)
        for _ in range(OSR - 1):
            await RisingEdge(dut.clk_32m)
            bi = int(dut.out_i.value)
            bq = int(dut.out_q.value)
            run_i = run_i + 1 if bi == last_i else 1
            run_q = run_q + 1 if bq == last_q else 1
            last_i, last_q = bi, bq
            max_run = max(max_run, run_i, run_q)

        ints = _integrators(dut)
        imin = [min(a, b) for a, b in zip(imin, ints)]
        imax = [max(a, b) for a, b in zip(imax, ints)]
        s1i, s1q = ints[0], ints[3]
        s1_run = s1_run + 1 if (s1i == last_s1i and s1q == last_s1q) else 1
        last_s1i, last_s1q = s1i, s1q
        s1_hold = max(s1_hold, s1_run)

    return max_run, s1_hold, (imin, imax)


def _assert_burst(dut, label, max_run, s1_hold, rng):
    imin, imax = rng
    dut._log.info(
        f"{label}: longest output run={max_run}, s1 hold={s1_hold} samples, "
        f"integ range=[{imin}, {imax}]"
    )
    assert max_run < STUCK_RUN_LIMIT, (
        f"{label}: output dither lost -- {max_run}-clock identical-bit run "
        f"(limit {STUCK_RUN_LIMIT}, TRPR-RMD-006)"
    )
    for k, w in enumerate(STATE_BITS):
        lo, hi = -(1 << (w - 1)), (1 << (w - 1)) - 1
        assert lo <= imin[k] and imax[k] <= hi, (
            f"{label}: integrator {k} left its {w}-bit range "
            f"[{imin[k]}, {imax[k]}] -- saturation wrap (TRPR-RMD-003)"
        )
    assert s1_hold < S1_HOLD_LIMIT, (
        f"{label}: first integrator frozen for {s1_hold} samples -- loop "
        f"latch-up"
    )


async def _recover_and_check(dut, ctx):
    """Clean -6 dBFS 40 kHz tone through the already-enabled DUT: it must still
    reconstruct above spec with dither intact. A healthy loop recovers from
    any preceding burst; an unstable one stays degraded."""
    n, edge, f_hz, amp = 2048, 128, 40_000.0, 64
    t = np.arange(n) / FS_OUT
    tone = amp * np.exp(1j * 2 * np.pi * f_hz * t)
    bits_i = np.empty(n * OSR)
    bits_q = np.empty(n * OSR)
    idx = 0
    max_run = 1
    run_i = run_q = 1
    last_i = last_q = -1
    for s in tone:
        await _drive_sample(dut, round(s.real), round(s.imag))
        for c in range(OSR):
            if c:
                await RisingEdge(dut.clk_32m)
            bi = int(dut.out_i.value)
            bq = int(dut.out_q.value)
            bits_i[idx] = 1.0 if bi else -1.0
            bits_q[idx] = 1.0 if bq else -1.0
            run_i = run_i + 1 if bi == last_i else 1
            run_q = run_q + 1 if bq == last_q else 1
            last_i, last_q = bi, bq
            max_run = max(max_run, run_i, run_q)
            idx += 1
    y_rec = brickwall_lp_decim(bits_i + 1j * bits_q, SX1302_BAND_HZ, FS_ADC, OSR) * 127.0
    seg = slice(edge, -edge)
    ref, rec = tone[seg], y_rec[seg]
    g = np.vdot(ref, rec) / np.vdot(ref, ref)
    resid = rec - g * ref
    sqnr = 10 * np.log10(np.mean(np.abs(g * ref) ** 2) / np.mean(np.abs(resid) ** 2))
    dut._log.info(f"recovery probe [{ctx}]: SQNR={sqnr:.2f} dB, longest run={max_run}, "
                  f"gain={abs(g):.4f}")
    assert sqnr > SQNR_RECOVER_DB, (
        f"recovery [{ctx}]: SQNR only {sqnr:.2f} dB after burst -- permanent "
        f"degradation (TRPR-RMD-003/005)"
    )
    assert max_run < STUCK_RUN_LIMIT, (
        f"recovery [{ctx}]: output stuck {max_run} clocks after burst"
    )


# ---- tests --------------------------------------------------------------

@cocotb.test()
async def test_long_constrained_random_stability(dut):
    """4 fixed seeds x 20,000 i.i.d. uniform int8 samples in [-90, +90], OSR=64
    cadence (1.28 M output clocks each), each followed by a clean-tone recovery
    probe."""
    cocotb.start_soon(Clock(dut.clk_32m, CLK_NS, unit="ns").start())
    worst = 0
    for seed in RANDOM_SEEDS:
        await _reset(dut)
        mr, s1h, rng = await _stream(dut, _lcg_random(SAMPLES_RANDOM, seed))
        _assert_burst(dut, f"random seed={seed:#010x} ({SAMPLES_RANDOM} samples)",
                      mr, s1h, rng)
        await _recover_and_check(dut, f"rand {seed:#010x}")
        worst = max(worst, mr)
    dut._log.info(
        f"long constrained-random stability PASS: {len(RANDOM_SEEDS)} seeds x "
        f"{SAMPLES_RANDOM} samples, worst output run {worst}"
    )


@cocotb.test()
async def test_adversarial_sequences_stability(dut):
    """Deterministic worst-case sequences: max-step alternating, period-3,
    sustained +-90 DC, rail-and-flip, triangular ramp, and asymmetric I/Q
    loading. Each is 3,000 samples (192 k output clocks) + a recovery probe."""
    cocotb.start_soon(Clock(dut.clk_32m, CLK_NS, unit="ns").start())
    n = SAMPLES_ADVERSARIAL
    patterns = {
        "alternating +-90":  _pat_alternating(n),
        "period-3":          _pat_period3(n),
        "DC +90":            _pat_dc(n, 90),
        "DC -90":            _pat_dc(n, -90),
        "rail-and-flip":     _pat_rail_flip(n),
        "triangle ramp":     _pat_triangle(n),
        "I/Q skew":          _pat_iq_skew(n),
    }
    for label, seq in patterns.items():
        await _reset(dut)
        mr, s1h, rng = await _stream(dut, seq)
        _assert_burst(dut, f"adversarial [{label}]", mr, s1h, rng)
        await _recover_and_check(dut, label)
    dut._log.info(f"adversarial stability PASS: {len(patterns)} sequences x {n} samples")
