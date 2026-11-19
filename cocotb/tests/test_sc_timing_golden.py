"""
test_sc_timing_golden.py -- diff src/frontend/sc_detector.v against the
integer decision-path model sim/models/sc_rtl.py: same lock decision and the
same timing_ref, packet by packet.

Stimulus: one antenna (the SC_ANT_SEL branch) carrying a guard of random
length (randomises the preamble start against the detector's free-running
symbol grid), 8 upchirps, one payload symbol and a tail, through a Rayleigh
tap plus AWGN, AGC'd to ~40 counts rms and rounded to int8. Driven at
production cadence: iq_valid once per 64 clocks, then cur/del + delayed_valid
44 clocks later (the psram_buf_ctrl delay-line latency), del = the same branch
M samples earlier (zero before the stream starts).
"""
import numpy as np
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

from sim.models.lora import modulate
from sim.models.sc_rtl import sc_rtl_detect

CLK_NS = 31.25
SAMPLE_CLKS = 64
DEL_LAG = 44


def _packet(rng, M, snr_db):
    g = int(rng.integers(2 * M, 4 * M))
    up = np.exp(1j * np.pi * np.arange(M) ** 2 / M)
    fr = np.concatenate([np.zeros(g, complex), np.tile(up, 8),
                         modulate(int(rng.integers(0, M)), M), np.zeros(2 * M, complex)])
    n0 = 10 ** (-snr_db / 10)
    h = (rng.standard_normal() + 1j * rng.standard_normal()) / np.sqrt(2)
    rx = h * fr + np.sqrt(n0 / 2) * (rng.standard_normal(len(fr)) + 1j * rng.standard_normal(len(fr)))
    sc = 40 / np.sqrt(abs(h) ** 2 + n0)
    x = (np.clip(np.round(rx.real * sc), -128, 127)
         + 1j * np.clip(np.round(rx.imag * sc), -128, 127))
    return x, g


async def _run_packet(dut, x, sf, sample_shift, sc_thr, sc_hits_req):
    M = 1 << (sf + sample_shift)
    dut.rst_n.value = 0
    for s in ("iq_valid", "delayed_valid", "sc_clr", "sc_lock_force", "sc_lock_sync",
              "cur_i0", "cur_q0", "del_i0", "del_q0"):
        getattr(dut, s).value = 0
    dut.sf.value = sf
    dut.sample_shift.value = sample_shift
    dut.sc_thr.value = sc_thr
    dut.sc_hits_req.value = sc_hits_req
    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 4)

    xi = np.real(x).astype(int); xq = np.imag(x).astype(int)
    for n in range(len(x)):
        dut.iq_valid.value = 1
        await RisingEdge(dut.clk)
        dut.iq_valid.value = 0
        await ClockCycles(dut.clk, DEL_LAG - 1)
        dut.cur_i0.value = int(xi[n]) & 0xFF
        dut.cur_q0.value = int(xq[n]) & 0xFF
        dut.del_i0.value = int(xi[n - M]) & 0xFF if n >= M else 0
        dut.del_q0.value = int(xq[n - M]) & 0xFF if n >= M else 0
        dut.delayed_valid.value = 1
        await RisingEdge(dut.clk)
        dut.delayed_valid.value = 0
        await ClockCycles(dut.clk, SAMPLE_CLKS - DEL_LAG - 1)
        if int(dut.sc_lock.value):
            return True, int(dut.timing_ref.value)
    await ClockCycles(dut.clk, 3 * SAMPLE_CLKS)      # let a final evaluation land
    if int(dut.sc_lock.value):
        return True, int(dut.timing_ref.value)
    return False, None


async def _sweep(dut, sf, sample_shift, sc_thr, sc_hits_req, snrs, per_snr, seed):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    rng = np.random.default_rng(seed)
    M = 1 << (sf + sample_shift)
    bad = []
    n_lock = 0
    for snr in snrs:
        for _ in range(per_snr):
            x, g = _packet(rng, M, snr)
            rtl = await _run_packet(dut, x, sf, sample_shift, sc_thr, sc_hits_req)
            mdl = sc_rtl_detect(x, sf, sample_shift, sc_thr, sc_hits_req)
            n_lock += rtl[0]
            err = (rtl[1] - 1 - g) if rtl[0] else None
            dut._log.info(f"sf={sf} shift={sample_shift} snr={snr:+d} guard={g}: rtl={rtl} model={mdl}"
                          + (f" timing_err={err:+d} samples ({err / M:+.2f} sym)" if err is not None else ""))
            if rtl != mdl:
                bad.append((snr, g, rtl, mdl))
    assert n_lock > 0, "no packet locked -- stimulus too weak to test timing_ref"
    assert not bad, f"{len(bad)} RTL/model mismatches: {bad[:5]}"


@cocotb.test()
async def test_sc_timing_sf6(dut):
    """M=64, reset SC_THR/SC_HITS_REQ, SNR -5..20 dB."""
    await _sweep(dut, 6, 0, 0x1CC, 2, (-5, 0, 5, 10, 20), 6, seed=1)


@cocotb.test()
async def test_sc_timing_sf7_bw125(dut):
    """M=512 (SF7, BW125 -> sample_shift=2), reset thresholds."""
    await _sweep(dut, 7, 2, 0x1CC, 2, (0, 10), 3, seed=2)


@cocotb.test()
async def test_sc_timing_other_cfg(dut):
    """Non-default SC_THR / SC_HITS_REQ, M=256 (SF7, BW250 -> sample_shift=1)."""
    await _sweep(dut, 7, 1, 0x300, 1, (0, 10), 3, seed=3)
