"""
test_remod_lora.py -- absolute LoRa symbol-error gate for the canonical
sd_remod (2x droop-comp interpolator + 4th-order CIFF multiplierless core).

Gap this closes
---------------
Nothing committed gated the *production* re-modulator's LoRa performance.
rtl-test/tb/remod_compare/test_remod_lora_compare.py drives the same
reconstruction but only asserts `ef2_errors <= prod_errors + 1` -- it measures
the experimental EF2 core *relative to* production and never bounds
production's own symbol-error rate. The dense paired curves (SGE job 5752)
live in planning/sd-remod-error-feedback-investigation-2026-09-09.md +
reports/, not in a regression.

This suite reconstructs canonical sd_remod's 1-bit output through the
repository's bit-true CIC3/HB1/HB2 decimator (models.decimator) and LoRa
demodulator (models.lora) and asserts ABSOLUTE bounds:

  test_lora_clean_all_sf_bw  -- every supported SF7..SF12 x BW125/250 combo,
                                no noise: 0 symbol errors. The "LoRa decodes
                                through this RTL at all" gate.
  test_lora_awgn_margin      -- representative SF7/SF9/SF12 x BW125/250 at
                                (50% SER threshold + 6 dB), no CFO: 0 errors.
                                A sensitivity-margin gate -- a modulator
                                regression shows up here before the clean
                                test breaks.
  test_lora_awgn_cfo         -- same modes at (threshold + 6 dB) + 0.25-bin
                                CFO: SER <= 10%. NOT a zero-error gate -- the
                                repo demod (models.lora.demodulate) is a raw
                                FFT argmax with no CFO tracking, so a residual
                                offset costs a few percent SER at low SF for
                                *any* modulator (the 2026-09-09 CFO curves show
                                it for both production and EF2). This bound
                                catches a gross modulator regression (errors
                                jumping to tens of percent) while tolerating
                                the proxy demod's own CFO sensitivity.

The receiver proxy is not an SX1302 model -- SX1302 channelizer / packet
detector / RSSI internals are proprietary and unmodelled (a documented
residual integration risk, see the 2026-09-09 investigation). It is a bit-true
model of the same 1-bit, 32 MS/s SX1257-style stream Trouper controls, and is
the strongest available system-level gate without the receiver hardware.

Production 50% SER crossings (THRESH_DB below) are from the job 5752 dense
curves; the margin points are derived from them, not re-measured here.
"""
import random

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

from models.decimator import SigmaDeltaDecimator, sample_shift_for_bw
from models.lora import demodulate, modulate

CLK_NS = 31.25
OSR = 64
GUARD = 48
TOTAL_RMS = 36.0          # matches the job 5752 curve normalisation

# Production 50% SER threshold (dB) per mode -- from the 2026-09-09 dense curves.
THRESH_DB = {
    (7, 250e3): -15.000, (7, 125e3): -17.867,
    (9, 250e3): -20.356, (9, 125e3): -22.467,
    (12, 250e3): -28.333, (12, 125e3): -31.500,
}

# Symbols per point -- scaled down with SF to bound RTL runtime (SF12/BW125 is
# m = 1 << 14 = 16,384 baseband samples => ~1.05 M output clocks per symbol).
NSYM_CLEAN = {7: 8, 8: 8, 9: 6, 10: 4, 11: 3, 12: 2}
NSYM_STRESS = {7: 24, 9: 12, 12: 4}
STRESS_SF = (7, 9, 12)



async def _reset(dut):
    await FallingEdge(dut.clk)
    dut.rst_n.value = 0
    dut.en.value = 0
    dut.in_valid.value = 0
    dut.in_i.value = 0
    dut.in_q.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    dut.en.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)


async def _drive_capture(dut, samples):
    """Drive one int8 complex sample per OSR clocks (in_valid pulsed once then
    held), capture the +/-1 output stream. Mirrors the production cadence and
    rtl-test/tb/remod_compare's drive loop."""
    out = np.empty(len(samples) * OSR, dtype=np.complex64)
    oi = 0
    for s in samples:
        i = int(np.clip(np.rint(s.real), -89, 89))
        q = int(np.clip(np.rint(s.imag), -89, 89))
        await FallingEdge(dut.clk)
        dut.in_i.value = i & 0xFF
        dut.in_q.value = q & 0xFF
        dut.in_valid.value = 1
        for cycle in range(OSR):
            await RisingEdge(dut.clk)
            out[oi] = ((1 if int(dut.out_i.value) else -1)
                       + 1j * (1 if int(dut.out_q.value) else -1))
            oi += 1
            if cycle == 0:
                await FallingEdge(dut.clk)
                dut.in_valid.value = 0
    return out


def _best_lag(reference, received, limit=24):
    """Remove only the fixed causal filter latency, as packet sync would --
    no per-symbol timing recovery, no gain/phase fit."""
    best = None
    for lag in range(limit + 1):
        n = min(len(reference), len(received) - lag)
        if n <= 0:
            continue
        score = abs(np.vdot(reference[:n], received[lag:lag + n]))
        if best is None or score > best[0]:
            best = (score, lag)
    return best[1]


def _build(sf, bw_hz, symbols, snr_db=None, cfo_bins=0.0, seed=0):
    shift = sample_shift_for_bw(bw_hz)
    m = 1 << (sf + shift)
    rng = np.random.default_rng(seed)
    body = np.concatenate([modulate(sym, m) for sym in symbols])
    if cfo_bins:
        n = np.arange(len(body))
        body = body * np.exp(1j * 2 * np.pi * cfo_bins * n / m)
    if snr_db is None:
        body = body * 64.0
    else:
        snr = 10 ** (snr_db / 10.0)
        sig_rms = TOTAL_RMS * np.sqrt(snr / (1.0 + snr))
        noise_rms = TOTAL_RMS / np.sqrt(1.0 + snr)
        noise = rng.normal(size=len(body)) + 1j * rng.normal(size=len(body))
        body = sig_rms * body + noise_rms / np.sqrt(2.0) * noise
    guarded = np.concatenate([np.zeros(GUARD, complex), body, np.zeros(GUARD, complex)])
    return guarded, m


def _decode(bits, reference, symbols, m, bw_hz):
    recovered = SigmaDeltaDecimator(bw_hz=bw_hz).process_int8(bits)
    aligned = recovered[_best_lag(reference, recovered):]
    decoded = []
    for k in range(len(symbols)):
        chunk = aligned[GUARD + k * m: GUARD + (k + 1) * m]
        if len(chunk) != m:
            raise AssertionError("decimator output too short after latency alignment")
        decoded.append(demodulate(chunk))
    return decoded


async def _run(dut, sf, bw_hz, symbols, snr_db=None, cfo_bins=0.0, seed=0):
    samples, m = _build(sf, bw_hz, symbols, snr_db=snr_db, cfo_bins=cfo_bins, seed=seed)
    await _reset(dut)
    bits = await _drive_capture(dut, samples)
    decoded = _decode(bits, samples, symbols, m, bw_hz)
    return sum(g != w for g, w in zip(decoded, symbols))


@cocotb.test()
async def test_lora_clean_all_sf_bw(dut):
    """Every supported SF x BW, no noise: zero symbol errors."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    rng = random.Random(0x10A0C1EA)
    total = 0
    for bw_hz in (125e3, 250e3):
        for sf in range(7, 13):
            m = 1 << (sf + sample_shift_for_bw(bw_hz))
            syms = [rng.randrange(m) for _ in range(NSYM_CLEAN[sf])]
            errs = await _run(dut, sf, bw_hz, syms)
            total += errs
            dut._log.info(f"clean SF{sf}/BW{bw_hz/1e3:.0f}: {errs}/{len(syms)} symbol errors")
            assert errs == 0, (
                f"clean SF{sf}/BW{bw_hz/1e3:.0f}: {errs}/{len(syms)} symbol "
                f"errors with no noise -- LoRa does not decode cleanly through "
                f"canonical sd_remod"
            )
    dut._log.info(f"clean LoRa grid PASS: 12 SFxBW combos, {total} total errors")


@cocotb.test()
async def test_lora_awgn_margin(dut):
    """Representative modes at (threshold + 6 dB), no CFO: zero errors."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    rng = random.Random(0x5A6E1B02)
    for bw_hz in (125e3, 250e3):
        for sf in STRESS_SF:
            m = 1 << (sf + sample_shift_for_bw(bw_hz))
            snr_db = THRESH_DB[(sf, bw_hz)] + 6.0
            syms = [rng.randrange(m) for _ in range(NSYM_STRESS[sf])]
            errs = await _run(dut, sf, bw_hz, syms, snr_db=snr_db, seed=0x6DB0 + sf)
            dut._log.info(
                f"margin SF{sf}/BW{bw_hz/1e3:.0f} SNR={snr_db:.2f}dB: "
                f"{errs}/{len(syms)} symbol errors"
            )
            assert errs == 0, (
                f"margin SF{sf}/BW{bw_hz/1e3:.0f} at threshold+6dB "
                f"(SNR={snr_db:.2f}dB): {errs}/{len(syms)} errors, expected 0 "
                f"-- sensitivity regression"
            )


@cocotb.test()
async def test_lora_awgn_cfo(dut):
    """Representative modes at (threshold + 6 dB) + 0.25-bin CFO: SER <= 10%.
    A ceiling, not a zero-error gate -- see the module docstring: the repo
    demod does not track CFO, so a residual offset costs a few percent SER at
    low SF for any modulator. This catches a gross modulator regression while
    tolerating that."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    rng = random.Random(0x0CF01302)
    for bw_hz in (125e3, 250e3):
        for sf in STRESS_SF:
            m = 1 << (sf + sample_shift_for_bw(bw_hz))
            snr_db = THRESH_DB[(sf, bw_hz)] + 6.0
            cfo = 0.25 if sf != 9 else -0.25
            syms = [rng.randrange(m) for _ in range(NSYM_STRESS[sf])]
            errs = await _run(dut, sf, bw_hz, syms, snr_db=snr_db, cfo_bins=cfo,
                              seed=0xC0F0 + sf + int(bw_hz))
            budget = max(1, round(0.10 * len(syms)))   # 10% SER ceiling
            dut._log.info(
                f"cfo SF{sf}/BW{bw_hz/1e3:.0f} SNR={snr_db:.2f}dB CFO={cfo:+.2f}: "
                f"{errs}/{len(syms)} symbol errors (ceiling {budget})"
            )
            assert errs <= budget, (
                f"cfo SF{sf}/BW{bw_hz/1e3:.0f} at threshold+6dB with "
                f"{cfo:+.2f}-bin CFO: {errs}/{len(syms)} errors exceeds the "
                f"10% ceiling ({budget}) -- modulator CFO-robustness regression"
            )
