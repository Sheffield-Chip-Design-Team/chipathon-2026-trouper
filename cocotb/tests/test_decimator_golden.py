"""
test_decimator_golden.py -- diff src/decimator/sd_decimator_poly.v against the
bit-true Python model sim/models/decimator.py (CIC-3 R=16 -> HB1 /2 -> HB2 /2),
sample for sample, on all 8 TDM streams (4 branches x I/Q).

Alignment. The RTL integrator cascade is registered (int2 += old int1,
int3 += old int2) and the comb reads the registered int3, so int3 at the comb
instant lags the model's unregistered cascade by LEAD_BITS input bits. Since
CIC, HB1 and HB2 are all FIRs, that is a pure delay: the RTL equals the model
fed LEAD_BITS filler bits ahead of the same stream, once every filter window
has filled (WARMUP outputs: CIC 3 + HB1 11 taps + HB2 15 taps, ~10 outputs).
LEAD_BITS / OUT_SHIFT are pinned constants -- a change in either is a latency
change and must fail, not be searched away. _diagnose() searches only to
report what the new alignment would be.

Each stream carries its own stimulus (distinct tone frequency/amplitude/phase,
first-order SD-modulated by the same loop as iq_capture.sigma_delta_1bit), so
a branch/I-Q swap or cross-talk in the TDM MAC sharing shows up as a mismatch.

Requirements: TRPR-DEC-001 (1-bit in -> int8 out, saturating), TRPR-DEC-002
(bit-true R=64 CIC/HB1/HB2 chain vs the Python model), TRPR-DEC-004 (TDM branch
independence), TRPR-DEC-006 (iq_valid every 64 clocks).
"""

import os
import sys

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge, Timer

_ROOT = os.environ.get("DESIGN_ROOT", "/foss/designs/lora-mimo")
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)

from sim.models.decimator import _cic_r16_int8, _hb1, _hb2  # noqa: E402
from iq_capture import sigma_delta_1bit  # noqa: E402

CLK_NS = 31.25
R = 64
N_OUT = 160            # decimated outputs per run (160 * 64 = 10240 clocks)
WARMUP = 12            # outputs skipped before the bit-exact compare
LEAD_BITS = 3          # registered-integrator lag (see module docstring)
OUT_SHIFT = 0          # RTL output index - model output index


def _model_stream(bits01, lead=LEAD_BITS):
    """Model output for one 0/1 bitstream, with `lead` filler bits prepended."""
    pm = np.concatenate([np.ones(lead), 2.0 * np.asarray(bits01, float) - 1.0])
    return _hb2(_hb1(_cic_r16_int8(pm)))


def _tone_bits(n_bits, f_out_hz, amp, phase, rng):
    """First-order SD bitstreams (I, Q) for a complex tone at the 32 MS/s rate."""
    t = np.arange(n_bits) / 32e6
    x = amp * np.exp(1j * (2 * np.pi * f_out_hz * t + phase))
    x = x + 1e-3 * (rng.standard_normal(n_bits) + 1j * rng.standard_normal(n_bits))
    return sigma_delta_1bit(x, 1.0)


async def _run(dut, bits_i, bits_q):
    """bits_i/bits_q: [4][n_bits] uint8. Returns (rtl[8][n_out], valid_gaps)."""
    n_bits = len(bits_i[0])
    dut.rst_n.value = 0
    dut.iq_in_i.value = 0
    dut.iq_in_q.value = 0
    await ClockCycles(dut.clk_32m, 4)
    await Timer(1, unit="ns")
    dut.rst_n.value = 1

    out = [[] for _ in range(8)]
    valid_cycles = []
    word_i = [sum(int(bits_i[b][n]) << b for b in range(4)) for n in range(n_bits)]
    word_q = [sum(int(bits_q[b][n]) << b for b in range(4)) for n in range(n_bits)]
    for n in range(n_bits):
        dut.iq_in_i.value = word_i[n]
        dut.iq_in_q.value = word_q[n]
        await RisingEdge(dut.clk_32m)
        await ReadOnly()
        v = int(dut.iq_valid.value)
        if v:
            assert v == 0xF, f"iq_valid=0x{v:x} at cycle {n}: branches not in lock-step"
            valid_cycles.append(n)
            wi = int(dut.iq_out_i.value)
            wq = int(dut.iq_out_q.value)
            for b in range(4):
                out[b].append(((wi >> (8 * b)) & 0xFF) - (256 if (wi >> (8 * b + 7)) & 1 else 0))
                out[4 + b].append(((wq >> (8 * b)) & 0xFF) - (256 if (wq >> (8 * b + 7)) & 1 else 0))
        await Timer(1, unit="ns")
    return out, valid_cycles


def _diagnose(rtl, bits01):
    hits = []
    for lead in range(0, 16):
        m = _model_stream(bits01, lead)
        for sh in range(-2, 3):
            a = np.asarray(rtl[WARMUP:], int)
            idx = np.arange(WARMUP, len(rtl)) - sh
            ok = (idx >= 0) & (idx < len(m))
            if ok.sum() > len(a) // 2 and np.array_equal(a[ok], m[idx[ok]]):
                hits.append((lead, sh))
    return hits


def _check_exact(rtl_streams, ref_bits, label):
    names = [f"I{b}" for b in range(4)] + [f"Q{b}" for b in range(4)]
    for s in range(8):
        rtl = np.asarray(rtl_streams[s], int)
        ref = _model_stream(ref_bits[s])
        n = min(len(rtl), len(ref) + OUT_SHIFT)
        assert n - WARMUP >= 100, f"{label}: only {n} outputs captured"
        r = rtl[WARMUP:n]
        m = ref[WARMUP - OUT_SHIFT:n - OUT_SHIFT]
        bad = np.nonzero(r != m)[0]
        if len(bad):
            k = int(bad[0]) + WARMUP
            raise AssertionError(
                f"{label} stream {names[s]}: {len(bad)}/{len(r)} mismatches, first at "
                f"output {k}: rtl={rtl[k]} model={ref[k - OUT_SHIFT]}; alignments that "
                f"WOULD match (lead_bits, out_shift): {_diagnose(rtl, ref_bits[s])}")
    return True


@cocotb.test()
async def test_bit_exact_tones_all_streams(dut):
    """8 distinct SD-modulated tones, RTL == model on every stream post-warm-up."""
    cocotb.start_soon(Clock(dut.clk_32m, CLK_NS, unit="ns").start())
    rng = np.random.default_rng(64)
    n_bits = N_OUT * R
    bits_i, bits_q = [], []
    for b in range(4):
        f = (11e3, -37e3, 83e3, 160e3)[b]          # within the 250 kHz passband
        amp = (0.30, 0.55, 0.70, 0.15)[b]
        bi, bq = _tone_bits(n_bits, f, amp, 0.7 * b, rng)
        bits_i.append(bi); bits_q.append(bq)
    rtl, _ = await _run(dut, bits_i, bits_q)
    _check_exact(rtl, bits_i + bits_q, "tones")
    peak = max(max(abs(v) for v in s[WARMUP:]) for s in rtl)
    assert peak > 60, f"stimulus too weak to exercise the MAC (peak |out|={peak})"


@cocotb.test()
async def test_bit_exact_saturation_and_dc(dut):
    """Full-scale DC (+/-) and a near-full-scale tone: exercises the CIC/HB1 int8 clips."""
    cocotb.start_soon(Clock(dut.clk_32m, CLK_NS, unit="ns").start())
    rng = np.random.default_rng(7)
    n_bits = N_OUT * R
    ones = np.ones(n_bits, np.uint8)
    zeros = np.zeros(n_bits, np.uint8)
    hi_i, hi_q = _tone_bits(n_bits, 23e3, 0.97, 0.0, rng)
    rnd = rng.integers(0, 2, n_bits).astype(np.uint8)
    bits_i = [ones, zeros, hi_i, rnd]
    bits_q = [zeros, ones, hi_q, ones]
    rtl, _ = await _run(dut, bits_i, bits_q)
    _check_exact(rtl, bits_i + bits_q, "saturation")
    # Full-scale DC clips to +127/-128 at the CIC (comb3=+/-4096 -> 128) and
    # again at HB1 (DC gain 1028/1024); HB2's DC gain is 998/1024, so the
    # settled output is (127*998+512)>>10 = 124 and (-128*998+512)>>10 = -125.
    assert all(v == 124 for v in rtl[0][WARMUP:]), \
        f"all-ones I0 settled at {sorted(set(rtl[0][WARMUP:]))}, expected 124"
    assert all(v == -125 for v in rtl[1][WARMUP:]), \
        f"all-zeros I1 settled at {sorted(set(rtl[1][WARMUP:]))}, expected -125"
    pk = max(abs(v) for v in rtl[2][WARMUP:])
    assert pk >= 110, f"near-full-scale tone peak |out|={pk}, expected >= 110"


@cocotb.test()
async def test_output_rate_r64(dut):
    """iq_valid: one single-cycle pulse per 64 clocks, all branches together."""
    cocotb.start_soon(Clock(dut.clk_32m, CLK_NS, unit="ns").start())
    rng = np.random.default_rng(1)
    n_bits = 40 * R
    bits = [rng.integers(0, 2, n_bits).astype(np.uint8) for _ in range(4)]
    _, cyc = await _run(dut, bits, bits)
    gaps = set(np.diff(cyc).tolist())
    assert gaps == {R}, f"iq_valid spacing {sorted(gaps)} != {{{R}}} (500 kS/s at 32 MHz)"
    assert len(cyc) >= 38, f"only {len(cyc)} output strobes in {n_bits} clocks"
