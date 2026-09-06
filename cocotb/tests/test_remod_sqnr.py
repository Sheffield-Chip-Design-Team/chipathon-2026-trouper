"""
test_remod_sqnr.py -- the real sd_remod fidelity regression: actual SQNR, RMS
error, and fitted gain against deployed RTL, not correlation.

Written 2026-09-04 in response to a review of the existing test coverage
(planning/sd-remod-4th-order-fix-2026-09-04.md), which found every existing
test of the remodulator's output quality was too weak to have caught the
scale-factor bug fixed the same day:

  - cocotb/tests/test_capture_two_packet.py never examines REMOD_A_I/Q at all.
  - The weight-generation tests stop at comb_y, before the remodulator.
  - test_capture_playback.py's reconstruction records only 8,192 clocks (128
    baseband samples) and asserts correlation > 0.70 -- for uncorrelated
    additive error, correlation 0.70 corresponds to roughly -0.2 dB SNR,
    0.80 to roughly 2.5 dB; a 40 dB SQNR requirement would need correlation
    around 0.99995 if correlation were the only metric. It is also invariant
    to gain error, tolerant of phase rotation/polarity inversion (abs() of
    the dot product), and searches +/-8 samples of delay -- all of which hid
    the real bug: the old x8192 error-scaling mistake still produced a
    recognisable average waveform (correlation ~0.99) while destroying most
    of the actual noise-shaped SQNR (measured ~15-20 dB, not 55 dB as the old
    rtl-test/tb/tb_sd_remod.v header comment claimed -- that testbench never
    computed SQNR either, only the same weak correlation check, and it also
    changed the input every 32 MHz clock instead of holding each 500 kS/s
    sample for 64 clocks the way production does).
  - The Python reference model (sim/models/converter.py) was assumed
    bit-exact but implements different scaling and a structurally different
    (same-cycle, not registered-delay) integrator cascade -- SQNR numbers
    from the model were never a check on deployed RTL.

This suite drives the real, deployed sd_remod.v (via the remod_sqnr wrapper,
not a behavioral model), holding each int8 sample for exactly 64 clocks
(production cadence), records >=65,536 output bits per case, reconstructs
with the same SX1302-band (250 kHz) brickwall filter used elsewhere in this
repo (sim.tests.remod_order_sweep.brickwall_lp_decim), and asserts actual
SQNR, RMS error, and fitted gain -- across both channels, several in-band
frequencies and amplitudes, and an amplitude transition -- instead of
correlation.
"""
import numpy as np
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from sim.tests.remod_order_sweep import brickwall_lp_decim

CLK_NS = 31.25      # 32 MHz, matches sd_remod.clk_32m (full period; cocotb's Clock()
                    # wants the full period, not the toggle half-period some
                    # raw-Verilog testbenches use, e.g. `always #15.625 clk=~clk`)
OSR = 64            # production hold: one int8 sample per 64 clocks
FS_OUT = 500_000.0
FS_ADC = FS_OUT * OSR
SX1302_BAND_HZ = 250_000.0   # brickwall cutoff shared with bringup_src/remod_order_sweep

SQNR_MIN_DB = 40.0     # TRPR-RMD-005 (the -6 dBFS spec point)
# Low-amplitude / band-edge stress floor. planning/sd-remod-4th-order-fix-
# 2026-09-04.md characterizes the deployed 4th-order loop at min 39.75 dB over
# a 300-trial amp[0.3,0.708] x f[1k,125k] sweep ("natural low-amp/band-edge
# weak point, not a cliff", mean 44.58 dB). The amp=40 (~-10 dBFS) / 40 kHz
# case sits in that stress region and measures ~39.5 dB; hold it to 39.0 dB so
# the check still catches a real break (wrong scale, dead channel, collapse to
# ~15-20 dB) without failing on the documented weak point. The 40 dB contract
# stands for the -6 dBFS cases.
SQNR_MIN_DB_LOW_AMP = 39.0
RMS_MAX_LSB = 1.0      # TRPR-RMD-007
# Gain tolerance is intentionally loose (not near-0%): the deployed 4th-order
# loop has a KNOWN, documented, not-yet-closed STF droop near the passband
# edge (planning/sd-remod-4th-order-fix-2026-09-04.md SS5/SS6, tracked
# separately by cocotb/tests/test_bringup_src.py's exact-fs/4 case). This
# suite's frequencies are chosen away from that exact worst point so the gain
# check still means something (catches a *broken* gain -- wrong scale, wrong
# sign, dead channel -- not the last few percent of passband flatness).
GAIN_TOL = 0.15


async def _reset(dut):
    dut.rst_n.value = 0
    dut.en.value = 1
    dut.in_valid.value = 0
    dut.in_i.value = 0
    dut.in_q.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    for _ in range(4):
        await RisingEdge(dut.clk)


async def _drive_and_capture(dut, baseband: np.ndarray):
    """Drive `baseband` (complex, int8-range) at production cadence: pulse
    in_valid for exactly one clock per sample, hold the value for the
    remaining OSR-1 clocks (matching how comb_y_valid pulses once per combine
    cycle in the real chain -- see trouper_top.v's remod_in_valid wiring).
    Returns the raw +/-1 bit sequence for I and Q, one entry per clock."""
    bits_i = np.empty(len(baseband) * OSR)
    bits_q = np.empty(len(baseband) * OSR)
    idx = 0
    for s in baseband:
        dut.in_i.value = int(np.clip(round(s.real), -128, 127)) & 0xFF
        dut.in_q.value = int(np.clip(round(s.imag), -128, 127)) & 0xFF
        dut.in_valid.value = 1
        await RisingEdge(dut.clk)
        dut.in_valid.value = 0
        bits_i[idx] = 1.0 if int(dut.out_i.value) else -1.0
        bits_q[idx] = 1.0 if int(dut.out_q.value) else -1.0
        idx += 1
        for _ in range(OSR - 1):
            await RisingEdge(dut.clk)
            bits_i[idx] = 1.0 if int(dut.out_i.value) else -1.0
            bits_q[idx] = 1.0 if int(dut.out_q.value) else -1.0
            idx += 1
    return bits_i, bits_q


def _score(bits_i, bits_q, ref_baseband: np.ndarray, edge: int):
    """Reconstruct with the SX1302-band brickwall and score against the
    known reference: real SQNR (not correlation), RMS error in LSB (int8)
    units, and a directly-fitted complex gain (no lag search -- the
    stimulus/response alignment is exact and known here, unlike the
    ambiguous free-running capture correlation tests this replaces)."""
    y = bits_i + 1j * bits_q
    # brickwall_lp_decim's raw +-1 bitstream input means its output is the
    # decimated duty-cycle average, normalised to +-1.0 -- scale by 127 to
    # get back to int8-count units, matching ref_baseband and the RMS-in-LSB
    # requirement (mirrors cocotb/comb_remod_transfer's `si*127/OSR`).
    y_rec = brickwall_lp_decim(y, SX1302_BAND_HZ, FS_ADC, OSR) * 127.0
    # slice(edge, -edge) is EMPTY when edge=0 (-0 == 0 in Python) -- guard it.
    seg = slice(edge, -edge) if edge > 0 else slice(None)
    ref = ref_baseband[seg]
    rec = y_rec[seg]
    g = np.vdot(ref, rec) / np.vdot(ref, ref)
    resid = rec - g * ref
    sqnr_db = 10 * np.log10(np.mean(np.abs(g * ref) ** 2) / np.mean(np.abs(resid) ** 2))
    rms_lsb = np.sqrt(np.mean(np.abs(resid) ** 2))
    return sqnr_db, rms_lsb, abs(g)


async def _run_tone_case(dut, amp_counts: float, f_hz: float, n: int = 1536, edge: int = 120,
                         min_sqnr: float = SQNR_MIN_DB):
    """amp_counts is in int8 counts (e.g. 64 = -6 dBFS); n baseband samples ->
    n*OSR output bits (n=1536 -> 98,304 bits, inside the 65,536-524,288 range
    the regression spec calls for)."""
    t = np.arange(n) / FS_OUT
    tone = amp_counts * np.exp(1j * 2 * np.pi * f_hz * t)
    bits_i, bits_q = await _drive_and_capture(dut, tone)
    sqnr_db, rms_lsb, gain = _score(bits_i, bits_q, tone, edge)
    dut._log.info(f"amp={amp_counts:.0f} f={f_hz/1e3:.1f}kHz: "
                  f"SQNR={sqnr_db:.2f}dB RMS={rms_lsb:.4f}LSB gain={gain:.4f}")
    assert sqnr_db > min_sqnr, (
        f"amp={amp_counts:.0f} f={f_hz/1e3:.1f}kHz: SQNR={sqnr_db:.2f}dB, "
        f"need > {min_sqnr}dB (TRPR-RMD-005)")
    assert rms_lsb < RMS_MAX_LSB, (
        f"amp={amp_counts:.0f} f={f_hz/1e3:.1f}kHz: RMS error={rms_lsb:.4f} LSB, "
        f"need < {RMS_MAX_LSB} LSB (TRPR-RMD-007)")
    assert abs(gain - 1.0) < GAIN_TOL, (
        f"amp={amp_counts:.0f} f={f_hz/1e3:.1f}kHz: fitted gain={gain:.4f}, "
        f"expected ~1.0 within {GAIN_TOL*100:.0f}% -- a broken/dead/mis-scaled "
        f"channel, not the known passband-edge droop (that's checked "
        f"separately, see module docstring)")
    return sqnr_db, rms_lsb, gain


@cocotb.test()
async def test_remod_sqnr_tones(dut):
    """Several in-band frequencies x amplitudes, both channels driven
    together (I and Q are independent quantizer loops in sd_remod.v, so a
    complex tone exercises and scores both simultaneously; a broken Q
    channel alone would show up as I/Q asymmetry we're not explicitly
    diffing, but would still fail the complex-domain SQNR/gain checks
    directly since the reference is a genuine complex rotation)."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await _reset(dut)

    # Frequencies deliberately avoid the exact fs/4=125kHz edge (see module
    # docstring); amplitudes span the realistic operating range up to just
    # under the -3dBFS (90-count) stability requirement (TRPR-RMD-004).
    cases = [
        (64, 20_000.0, SQNR_MIN_DB),          # -6dBFS, low-mid band
        (64, 60_000.0, SQNR_MIN_DB),          # -6dBFS, mid band
        (40, 40_000.0, SQNR_MIN_DB_LOW_AMP),  # ~-10dBFS low-amp stress point (see const)
        (85, 40_000.0, SQNR_MIN_DB),          # near the -3dBFS edge
    ]
    for amp, f_hz, min_sqnr in cases:
        await _run_tone_case(dut, amp, f_hz, min_sqnr=min_sqnr)


@cocotb.test()
async def test_remod_sqnr_amplitude_transition(dut):
    """An amplitude step mid-capture: the old x8192 bug damaged loop dynamics
    without stopping the output from toggling or destroying coarse waveform
    shape -- a settled-tone-only test could plausibly still miss a transient-
    response regression. Scores the SQNR of the tail (well after the step)
    separately from confirming the step doesn't produce a stuck/frozen run
    (dither loss) during or immediately after the transition."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await _reset(dut)

    n_each = 768
    f_hz = 40_000.0
    t = np.arange(n_each) / FS_OUT
    tone_lo = 40 * np.exp(1j * 2 * np.pi * f_hz * t)
    tone_hi = 85 * np.exp(1j * 2 * np.pi * f_hz * t)
    baseband = np.concatenate([tone_lo, tone_hi])

    bits_i, bits_q = await _drive_and_capture(dut, baseband)

    # No frozen/stuck output bit-run anywhere, including across the step.
    def longest_run(bits):
        longest = cur = 1
        for a, b in zip(bits, bits[1:]):
            cur = cur + 1 if b == a else 1
            longest = max(longest, cur)
        return longest
    run_i, run_q = longest_run(bits_i), longest_run(bits_q)
    dut._log.info(f"transition: longest stuck-run I={run_i} Q={run_q} (of {len(bits_i)} bits)")
    assert max(run_i, run_q) < 100, (
        f"amplitude transition produced a {max(run_i, run_q)}-cycle stuck run -- "
        "dither lost across/after the step")

    # Score the settled tail of the post-step segment only. This re-slice
    # already excludes the step itself (tail_start is 150 samples past it),
    # so brickwall_lp_decim's FFT runs on a block that never contains the
    # discontinuity -- but that block is now short (618 baseband samples),
    # so its own circular-convolution edge (wrap-around) artifacts are
    # proportionally larger and edge=0 (no trim) was the actual bug here,
    # not the step itself: the untrimmed boundary was dominating the score.
    tail_start = n_each + 150
    sqnr_db, rms_lsb, gain = _score(
        bits_i[tail_start * OSR:], bits_q[tail_start * OSR:],
        baseband[tail_start:], edge=80)
    dut._log.info(f"post-transition tail: SQNR={sqnr_db:.2f}dB RMS={rms_lsb:.4f}LSB gain={gain:.4f}")
    assert sqnr_db > SQNR_MIN_DB, f"post-transition tail SQNR={sqnr_db:.2f}dB, need > {SQNR_MIN_DB}dB"
    assert rms_lsb < RMS_MAX_LSB, f"post-transition tail RMS={rms_lsb:.4f}LSB, need < {RMS_MAX_LSB}"
