"""
test_remod_flatness.py -- swept-frequency STF gain flatness of the canonical
sd_remod.v (2x droop-comp interpolator + 4th-order CIFF multiplierless core).

Why this exists
---------------
Committed remod coverage checked gain at a *handful* of points and never as a
flatness metric:

  - cocotb/remod_sqnr/test_remod_sqnr.py drives 4 scattered tones and its gain
    check is deliberately +/-15% -- "catches a broken/dead/mis-scaled channel,
    not the last few percent of passband flatness" (its own comment).
  - cocotb/tests/test_bringup_src.py checks ONE point, at exactly fs/4, with a
    5% tolerance.

The only real swept measurement -- rtl-test/tb/remod_interp2x/
test_sd_remod_interp2x.py, 16 coherent bins from 7.8 kHz to 125 kHz -- was
never committed, never wired into a regression runner, and its harness compared
canonical sd_remod against the experimental sd_remod_interp2x module that the
2026-09-05 promotion (commit 7f64c88) folded into sd_remod itself, so its
negative-control assertion ("baseline must show 125 kHz droop") is now false by
construction. This module is that sweep, salvaged: one DUT (canonical
sd_remod), the two-variant control dropped, a denser grid, and a second
amplitude near the -3 dBFS operating edge.

Method (matches remod_sqnr): drive one int8 complex sample per OSR=64 clocks
(production cadence), capture the +/-1 bit stream, reconstruct with the repo's
standard 250 kHz brickwall decimator, fit a complex gain per tone, and report
peak-to-peak gain ripple across the swept band. Frequencies are coherent in
the N_BB-sample capture so FFT reconstruction does not confuse spectral leakage
with modulator noise.

Requirement: TRPR-RMD-001 (STF flatness half of it; the interpolator was added
2026-09-05 specifically to close the fs/4 droop) and TRPR-RMD-005 (>40 dB
in-band SQNR, re-confirmed here per-point across the band).
"""
import numpy as np
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from sim.tests.remod_order_sweep import brickwall_lp_decim

CLK_NS = 31.25          # 32 MHz, sd_remod.clk_32m (full period for cocotb Clock())
OSR = 64                # production hold: one int8 sample per 64 clocks
FS_OUT = 500_000.0
FS_ADC = FS_OUT * OSR
SX1302_BAND_HZ = 250_000.0   # brickwall cutoff shared with remod_sqnr / bringup_src

N_BB = 1024             # baseband samples per tone (coherent FFT grid); 65,536 output bits
EDGE = 96              # trim brickwall circular-convolution edges before fitting

# Swept grid: coherent integer FFT bins, ~4.9 kHz spacing, from bin 8
# (3.906 kHz) through bin 256 = exactly fs/4 = 125 kHz, the BW=250 kHz chirp
# band edge. Covers the BW=125 kHz edge (62.5 kHz, bin 128) too.
BINS = tuple(range(8, 257, 8))   # 32 points

# Amplitudes in int8 counts: -6 dBFS (the RMD-005 spec point) and ~-3.5 dBFS
# (just inside the <90-count / -3 dBFS stability limit, TRPR-RMD-004).
AMPS = (64, 85)

SQNR_MIN_DB = 40.0     # TRPR-RMD-005, per point across the whole swept band

# STF flatness gate. The interpolator holds the analytic 125 kHz droop to
# ~-0.18 dB net (planning/sd-remod-interp2x-pnr-investigation-2026-09-05.md);
# the half-band's own passband adds a little ripple on top. Measured on
# canonical sd_remod (SGE job 5753, 2026-09-09): 0.188 dB ripple at amp=64,
# 0.190 dB at amp=85, edge gain -0.14/-0.15 dB, monotonic roll-off with no
# resonance. Gate set at 0.30 dB (~1.6x margin) as a regression guard against a
# change that eats a meaningful fraction of the interpolator's benefit -- not a
# re-derivation of the filter spec.
RIPPLE_MAX_DB = 0.30
# Edge must not droop back toward the un-compensated ~-0.9 dB hole.
EDGE_GAIN_MIN = 0.95


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
    """One in_valid pulse per sample, value held for the remaining OSR-1
    clocks -- matches how comb_y_valid pulses once per combine cycle in the
    real chain. Returns the raw +/-1 bit sequences for I and Q, one per clock."""
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


def _score(bits_i, bits_q, ref_baseband):
    """Reconstruct with the SX1302-band brickwall and fit a complex gain
    against the known reference (exact alignment, no lag search). Returns
    (|gain|, SQNR dB, RMS error in int8 LSB)."""
    y = bits_i + 1j * bits_q
    # brickwall_lp_decim's raw +-1 input => output is the decimated duty-cycle
    # average normalised to +-1.0; *127 back to int8-count units.
    y_rec = brickwall_lp_decim(y, SX1302_BAND_HZ, FS_ADC, OSR) * 127.0
    seg = slice(EDGE, -EDGE)
    ref = ref_baseband[seg]
    rec = y_rec[seg]
    g = np.vdot(ref, rec) / np.vdot(ref, ref)
    resid = rec - g * ref
    sqnr_db = 10 * np.log10(np.mean(np.abs(g * ref) ** 2) / np.mean(np.abs(resid) ** 2))
    rms_lsb = float(np.sqrt(np.mean(np.abs(resid) ** 2)))
    return float(abs(g)), float(sqnr_db), rms_lsb


async def _sweep(dut, amp_counts):
    gains = np.empty(len(BINS))
    sqnrs = np.empty(len(BINS))
    for k, tone_bin in enumerate(BINS):
        await _reset(dut)
        f_hz = tone_bin * FS_OUT / N_BB
        n = np.arange(N_BB)
        tone = amp_counts * np.exp(1j * 2 * np.pi * tone_bin * n / N_BB)
        bits_i, bits_q = await _drive_and_capture(dut, tone)
        g, sqnr_db, rms_lsb = _score(bits_i, bits_q, tone)
        gains[k] = g
        sqnrs[k] = sqnr_db
        dut._log.info(
            f"amp={amp_counts:3.0f}  f={f_hz/1e3:8.3f} kHz  "
            f"gain={g:.5f} ({20*np.log10(g):+.3f} dB)  "
            f"SQNR={sqnr_db:6.2f} dB  RMS={rms_lsb:.4f} LSB"
        )
    return gains, sqnrs


@cocotb.test()
async def test_remod_stf_gain_flatness(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())

    worst_ripple = 0.0
    for amp in AMPS:
        gains, sqnrs = await _sweep(dut, amp)
        gains_db = 20.0 * np.log10(gains)
        ripple = float(np.ptp(gains_db))
        worst_ripple = max(worst_ripple, ripple)
        dut._log.info(
            f"SUMMARY amp={amp:3.0f}  gain range [{gains_db.min():+.3f}, "
            f"{gains_db.max():+.3f}] dB  ripple={ripple:.3f} dB  "
            f"min SQNR={sqnrs.min():.2f} dB  edge gain={gains[-1]:.5f}"
        )

        assert gains[-1] > EDGE_GAIN_MIN, (
            f"amp={amp}: fs/4 (125 kHz) gain {gains[-1]:.5f} droops below "
            f"{EDGE_GAIN_MIN} -- the interpolator is not holding the band edge "
            f"(TRPR-RMD-001 STF flatness)"
        )
        assert ripple < RIPPLE_MAX_DB, (
            f"amp={amp}: STF passband ripple {ripple:.3f} dB over "
            f"{BINS[0]*FS_OUT/N_BB/1e3:.1f}-{BINS[-1]*FS_OUT/N_BB/1e3:.1f} kHz "
            f"exceeds {RIPPLE_MAX_DB} dB (TRPR-RMD-001 STF flatness)"
        )
        assert np.all(sqnrs > SQNR_MIN_DB), (
            f"amp={amp}: min in-band SQNR {sqnrs.min():.2f} dB at "
            f"{BINS[int(np.argmin(sqnrs))]*FS_OUT/N_BB/1e3:.1f} kHz, "
            f"need > {SQNR_MIN_DB} dB (TRPR-RMD-005)"
        )

    dut._log.info(f"worst-case ripple across all amplitudes: {worst_ripple:.3f} dB")
