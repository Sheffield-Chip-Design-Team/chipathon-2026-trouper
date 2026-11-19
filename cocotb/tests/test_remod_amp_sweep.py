"""
test_remod_amp_sweep.py -- SQNR-vs-input-amplitude cliff sweep for the
canonical sd_remod (2x droop-comp interpolator + 4th-order CIFF multiplierless
core).

Gap this closes
---------------
cocotb/remod_sqnr checks SQNR at 4 scattered (amplitude, frequency) points;
cocotb/remod_flatness sweeps *frequency* at one amplitude; cocotb/remod_stability
is a pass/fail dither check, not SQNR. None of them commit the SQNR-vs-amplitude
*curve*. planning/sd-remod-4th-order-fix-2026-09-04.md sec. 3 characterizes the
deployed loop over a 300-trial amp[0.3, 0.708] x f[1k, 125k] sweep ("no cliff,
monotonic-ish improvement with amplitude") -- but that ran in a throwaway
Verilator batch (SGE job 5575) and was never committed. Section 6 of the same
doc shows why the curve matters: every 5th-order coefficient candidate that
improved fs/4 flatness "failed a broader frequency check" or went *unstable*
(negative SQNR) across amp 0.65-0.72 -- a mid-range dip is the signature of a
marginal loop.

This suite drives real sd_remod at production OSR=64 cadence over 12 amplitudes
from ~-20 dBFS to ~-3.5 dBFS at 3 in-band frequencies, reconstructs with the
repo's 250 kHz brickwall decimator, and checks:

  1. SQNR floor -- above the -6 dBFS spec point (>= 60 counts): SQNR > 40 dB
     (TRPR-RMD-005). Down to ~-20 dBFS: SQNR tracks the signal level down
     without collapsing (a generous absolute floor, since the shaped-noise
     floor is roughly fixed so SQNR falls ~1 dB per dB of backoff).
  2. No cliff -- increasing the amplitude never *costs* more than
     CLIFF_DROP_DB of SQNR. A dip on the rising-amplitude side is a
     stability-margin soft spot, not a measurement artifact.
  3. Monotone trend -- SQNR at the top of the range exceeds SQNR at the
     bottom by a clear margin (the loop is getting quieter with more signal,
     as a healthy noise shaper should).

Amplitudes stay within the TRPR-RMD-004 contract (|v| < 90 counts).
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

N_BB = 1536
EDGE = 128

# int8 full-scale is 127; -6 dBFS ~= 64 counts, -3.5 dBFS ~= 85, -20 dBFS ~= 13.
AMPS = (13, 18, 24, 30, 36, 44, 52, 60, 68, 76, 82, 85)
# Coherent integer FFT bins in the N_BB capture (same discipline as
# remod_flatness) -- ~20.2 / 59.9 / 100.3 kHz, spread across the in-band range.
FREQ_BINS = (62, 184, 308)

SPEC_SQNR_DB = 40.0        # TRPR-RMD-005, applies at/above the -6 dBFS point
SPEC_AMP_MIN = 60          # counts; >= this is "at or above -6 dBFS"
# Generous absolute floor for the backed-off region: measured curve is set as
# the reference on the first SGE run (see the SUMMARY log line); this catches a
# collapse (SQNR -> teens, or negative) without tracking the last dB.
LOW_AMP_FLOOR_DB = 22.0
CLIFF_DROP_DB = 2.0        # raising amplitude must not cost more than this
TREND_MIN_DB = 6.0        # SQNR(top) - SQNR(bottom), minimum


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


async def _drive_and_capture(dut, baseband):
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


def _sqnr(bits_i, bits_q, ref):
    y_rec = brickwall_lp_decim(bits_i + 1j * bits_q, SX1302_BAND_HZ, FS_ADC, OSR) * 127.0
    seg = slice(EDGE, -EDGE)
    r, rec = ref[seg], y_rec[seg]
    g = np.vdot(r, rec) / np.vdot(r, r)
    resid = rec - g * r
    sqnr_db = 10 * np.log10(np.mean(np.abs(g * r) ** 2) / np.mean(np.abs(resid) ** 2))
    return float(sqnr_db), float(abs(g))


async def _sweep_at(dut, tone_bin):
    n = np.arange(N_BB)
    f_hz = tone_bin * FS_OUT / N_BB
    curve = []
    for amp in AMPS:
        await _reset(dut)
        tone = amp * np.exp(1j * 2 * np.pi * tone_bin * n / N_BB)
        bi, bq = await _drive_and_capture(dut, tone)
        sqnr_db, gain = _sqnr(bi, bq, tone)
        curve.append((amp, sqnr_db, gain))
        dut._log.info(
            f"f={f_hz/1e3:6.1f} kHz  amp={amp:3d} ({20*np.log10(amp/127):+.1f} dBFS)  "
            f"SQNR={sqnr_db:6.2f} dB  gain={gain:.4f}"
        )
    return curve, f_hz


@cocotb.test()
async def test_remod_sqnr_vs_amplitude(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())

    for tone_bin in FREQ_BINS:
        curve, f_hz = await _sweep_at(dut, tone_bin)
        amps = [c[0] for c in curve]
        sqnrs = [c[1] for c in curve]
        dut._log.info(
            f"SUMMARY f={f_hz/1e3:.1f} kHz  SQNR range [{min(sqnrs):.2f}, "
            f"{max(sqnrs):.2f}] dB  bottom={sqnrs[0]:.2f}  top={sqnrs[-1]:.2f}  "
            f"trend={sqnrs[-1]-sqnrs[0]:+.2f} dB"
        )

        for amp, sqnr_db, _ in curve:
            if amp >= SPEC_AMP_MIN:
                assert sqnr_db > SPEC_SQNR_DB, (
                    f"f={f_hz/1e3:.1f} kHz amp={amp} ({20*np.log10(amp/127):+.1f} "
                    f"dBFS): SQNR={sqnr_db:.2f} dB < {SPEC_SQNR_DB} (TRPR-RMD-005)"
                )
            else:
                assert sqnr_db > LOW_AMP_FLOOR_DB, (
                    f"f={f_hz/1e3:.1f} kHz amp={amp} ({20*np.log10(amp/127):+.1f} "
                    f"dBFS): SQNR={sqnr_db:.2f} dB collapsed below the "
                    f"{LOW_AMP_FLOOR_DB} dB backoff floor"
                )

        # No cliff: SQNR must not drop as amplitude rises.
        for (a0, s0, _), (a1, s1, _) in zip(curve, curve[1:]):
            assert s1 > s0 - CLIFF_DROP_DB, (
                f"f={f_hz/1e3:.1f} kHz: SQNR dropped {s0-s1:.2f} dB going from "
                f"amp {a0} to {a1} ({s0:.2f} -> {s1:.2f}) -- stability-margin "
                f"dip on the rising-amplitude side (limit {CLIFF_DROP_DB} dB)"
            )

        assert sqnrs[-1] - sqnrs[0] > TREND_MIN_DB, (
            f"f={f_hz/1e3:.1f} kHz: SQNR only improved {sqnrs[-1]-sqnrs[0]:.2f} dB "
            f"from {AMPS[0]} to {AMPS[-1]} counts -- a healthy noise shaper gets "
            f"quieter with more signal (expected > {TREND_MIN_DB} dB)"
        )
