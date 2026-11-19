"""
test_tacc_golden.py -- bit-exact regression of src/combiner/training_acc.v
against sim/models/training_accumulator.py training_accumulate_allpairs(),
standalone (TOPLEVEL = training_acc).

The model returns Z[k,l] = sum_n raw_k[n] conj(raw_l[n]) over
[acc_start, timing_ref + W*M - 1]. The RTL accumulates the samples whose
pre-increment sample_count lies in [acc_start, acc_end], but can only take
samples that arrive after it has armed, so the model's acc_start
(`sc_lock_sample`) is max(first strobe index after arming, timing_ref). The
six cross-pairs map as 0=(0,1) 1=(0,2) 2=(0,3) 3=(1,2) 4=(1,3) 5=(2,3),
Zpair_i/q = Re/Im Z[a,b]; Zdiag_k = Z[k,k].

Windows are kept below the int32 saturation onset (tacc_acc_overflow owns the
clamp), so every compare is exact, not bounded.

Requirements: TRPR-TAC-001 (all-pairs + diagonal), TRPR-TAC-002 (W*M window
from timing_ref, >= 8 symbol clamp), TRPR-TAC-003 (training_done timing, n_acc),
TRPR-TAC-007 (noise mode: training_done but never training_done_pkt),
TRPR-TAC-009 (Z vs the Python reference, here exact rather than within Q1.15).
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

from sim.models.training_accumulator import training_accumulate_allpairs  # noqa: E402

CLK_NS = 31.25
SAMPLE_CLKS = 64
PAIRS = ((0, 1), (0, 2), (0, 3), (1, 2), (1, 3), (2, 3))


def _stimulus(rng, n, *, full_scale=False):
    """4-branch int8 stream: common chirp x per-branch complex gain + noise."""
    if full_scale:
        return rng.integers(-128, 128, (4, n)) + 1j * rng.integers(-128, 128, (4, n))
    t = np.arange(n)
    s = np.exp(1j * np.pi * (t % 256) ** 2 / 256)
    h = (rng.standard_normal(4) + 1j * rng.standard_normal(4)) / np.sqrt(2)
    x = 60 * h[:, None] * s[None, :] + 8 * (rng.standard_normal((4, n)) + 1j * rng.standard_normal((4, n)))
    return np.clip(np.round(x.real), -128, 127) + 1j * np.clip(np.round(x.imag), -128, 127)


async def _reset(dut, sf, shift, window):
    dut.rst_n.value = 0
    for s in ("iq_valid", "sc_lock", "noise_trig", "timing_ref"):
        getattr(dut, s).value = 0
    for k in range(4):
        getattr(dut, f"raw_i{k}").value = 0
        getattr(dut, f"raw_q{k}").value = 0
    dut.sf.value = sf
    dut.sample_shift.value = shift
    dut.tacc_window_syms.value = window
    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


class Driver:
    """Strobes iq_valid once per 64 clocks; tracks the RTL sample index."""

    def __init__(self, dut, x):
        self.dut, self.x, self.idx = dut, x, 0
        self.done_at = None        # sample index during which training_done rose
        self.pkt_seen = False

    async def strobe(self):
        d, n = self.dut, self.idx
        for k in range(4):
            getattr(d, f"raw_i{k}").value = int(self.x[k, n].real) & 0xFF
            getattr(d, f"raw_q{k}").value = int(self.x[k, n].imag) & 0xFF
        d.iq_valid.value = 1
        await RisingEdge(d.clk)
        await Timer(1, unit="ns")
        d.iq_valid.value = 0
        self.idx += 1
        for _ in range(SAMPLE_CLKS - 1):
            await RisingEdge(d.clk)
            await ReadOnly()
            if self.done_at is None and int(d.training_done.value):
                self.done_at = n
            self.pkt_seen |= bool(int(d.training_done_pkt.value))
            await Timer(1, unit="ns")


def _read_z(dut):
    zp = []
    for p in range(6):
        zp.append(complex(getattr(dut, f"Zpair_i{p}").value.to_signed(),
                          getattr(dut, f"Zpair_q{p}").value.to_signed()))
    zd = [int(getattr(dut, f"Zdiag_{k}").value) for k in range(4)]
    return zp, zd, int(dut.n_acc.value)


def _compare(dut, x, acc_start, timing_ref, M, w_eff, label):
    Z, Zdiag, n_acc = training_accumulate_allpairs(
        x, sc_lock_sample=acc_start, timing_ref=timing_ref, M=M, preamble_len=w_eff)
    zp, zd, n = _read_z(dut)
    assert n == n_acc, f"{label}: n_acc rtl={n} model={n_acc}"
    for p, (a, b) in enumerate(PAIRS):
        exp = complex(int(Z[a, b].real), int(Z[a, b].imag))
        assert zp[p] == exp, f"{label}: Z_{a}{b} rtl={zp[p]} model={exp}"
    for k in range(4):
        assert zd[k] == int(Zdiag[k]), f"{label}: Zdiag_{k} rtl={zd[k]} model={int(Zdiag[k])}"
    return n_acc


async def _packet_case(dut, rng, *, sf, shift, window, lock_at, tref, full_scale=False):
    M = 1 << (sf + shift)
    w_eff = max(window, 8)
    end = tref + w_eff * M - 1
    x = _stimulus(rng, end + 8, full_scale=full_scale)
    await _reset(dut, sf, shift, window)
    drv = Driver(dut, x)
    while drv.idx < lock_at:
        await drv.strobe()
    dut.timing_ref.value = tref
    dut.sc_lock.value = 1
    await ClockCycles(dut.clk, 2)  # `armed` is registered: lock between strobes, as sc_detector does
    while drv.idx <= end + 2:
        await drv.strobe()
    first = max(lock_at, tref)
    label = f"sf={sf} shift={shift} W={window} lock@{lock_at} tref={tref}"
    n = _compare(dut, x, first, tref, M, w_eff, label)
    assert n == end - first + 1, f"{label}: window length {n} != {end - first + 1}"
    assert drv.done_at == end, f"{label}: training_done rose during sample {drv.done_at}, expected {end}"
    assert drv.pkt_seen, f"{label}: packet window never pulsed training_done_pkt"
    dut.sc_lock.value = 0
    return x


@cocotb.test()
async def test_packet_timing_ref_in_past(dut):
    """Lock lands 3 symbols after timing_ref: window starts at the lock."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    rng = np.random.default_rng(10)
    M = 1 << 6
    await _packet_case(dut, rng, sf=5, shift=1, window=10, lock_at=40 + 3 * M, tref=40)


@cocotb.test()
async def test_packet_timing_ref_in_future(dut):
    """timing_ref ahead of the lock: window starts exactly at timing_ref."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    rng = np.random.default_rng(11)
    await _packet_case(dut, rng, sf=5, shift=2, window=8, lock_at=20, tref=57)


@cocotb.test()
async def test_packet_window_clamp_and_max(dut):
    """TACC_WINDOW_SYMS=3 behaves as 8; 15 is the largest legal window."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    rng = np.random.default_rng(12)
    await _packet_case(dut, rng, sf=4, shift=1, window=3, lock_at=5, tref=5)
    await _packet_case(dut, rng, sf=4, shift=1, window=15, lock_at=9, tref=7)


@cocotb.test()
async def test_packet_full_scale_int8(dut):
    """Uniform full-range int8 (incl. -128): multiplier/sign-extension corners."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    rng = np.random.default_rng(13)
    await _packet_case(dut, rng, sf=5, shift=1, window=8, lock_at=3, tref=3, full_scale=True)


@cocotb.test()
async def test_noise_mode_window(dut):
    """noise_trig (sc_lock low) accumulates W*M samples from the trigger;
    training_done asserts, training_done_pkt must not."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    rng = np.random.default_rng(14)
    sf, shift, window = 5, 1, 9
    M = 1 << (sf + shift)
    trig_at = 31
    end = trig_at + window * M - 1
    x = _stimulus(rng, end + 8, full_scale=True)
    await _reset(dut, sf, shift, window)
    drv = Driver(dut, x)
    while drv.idx < trig_at:
        await drv.strobe()
    dut.noise_trig.value = 1
    await ClockCycles(dut.clk, 2)
    dut.noise_trig.value = 0
    while drv.idx <= end + 2:
        await drv.strobe()
    _compare(dut, x, trig_at, trig_at, M, window, "noise")
    assert drv.done_at == end, f"noise: training_done rose during sample {drv.done_at}, expected {end}"
    assert not drv.pkt_seen, "noise window pulsed training_done_pkt (packet FSM would see it)"


@cocotb.test()
async def test_rearm_zeroes_previous_window(dut):
    """A second packet window must not inherit the first window's sums."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    rng = np.random.default_rng(15)
    sf, shift, window = 4, 1, 8
    M = 1 << (sf + shift)
    x = _stimulus(rng, 3 * window * M + 64, full_scale=True)
    await _reset(dut, sf, shift, window)
    drv = Driver(dut, x)
    for t0 in (4, window * M + 40):
        while drv.idx < t0:
            await drv.strobe()
        drv.done_at = None
        dut.timing_ref.value = t0
        dut.sc_lock.value = 1
        await ClockCycles(dut.clk, 2)
        end = t0 + window * M - 1
        while drv.idx <= end + 2:
            await drv.strobe()
        _compare(dut, x, t0, t0, M, window, f"window@{t0}")
        assert drv.done_at == end
        dut.sc_lock.value = 0
        await drv.strobe()
