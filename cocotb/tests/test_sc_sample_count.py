"""
test_sc_sample_count.py -- sc_detector's free-running sample_count must stay
locked to the number of iq_valid samples across sc_clr re-arms.

Why: timing_ref is computed in sc_detector's own sample_count domain, but it is
consumed against OTHER counters that count the same dcr_valid samples --
training_acc.sample_count (acc_start), trouper_top.iq_samp_cnt (packet FSM
deadlines, psram buf_base). Any sample sc_detector fails to count shifts every
later timing_ref one sample early relative to those consumers, and the error
accumulates per event for the life of the chip (sample_count is deliberately
never reset by sc_clr).

Suspected mechanism (review 2026-11-21): the per-sample TDM burst starts on
delayed_valid (~44 clocks after iq_valid) and runs 24 clocks, so it overlaps
the NEXT iq_valid; that sample's increment is parked in iq_inc_pending. sc_clr
clears iq_inc_pending, so an sc_clr landing in that window drops a count. In
trouper_top sc_clr (= packet_done_pulse) lands ~3 clocks after a dcr_valid,
i.e. inside the window, on every packet end.

Tests (standalone sc_detector, production cadence: iq_valid every 64 clocks,
delayed_valid DEL_LAG=44 clocks later, as in test_sc_timing_golden):
  test_sample_count_sc_clr_phase_sweep
      sc_clr pulsed at every clock phase 0..63 of the sample frame; after each,
      sample_count must equal the number of iq_valid pulses driven.
  test_timing_ref_multi_packet_no_reset
      several packets back to back WITHOUT reset, sc_clr between them at the
      trouper_top phase; each packet's timing_ref must equal (global index of
      the first post-clr sample) + the sim/models/sc_rtl.py result for the
      post-clr segment. A dropped count shows up as -1, -2, ... per packet.
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
# trouper_top: dcr_valid sampled by u_sc at edge E, packet_done_pulse sampled
# as sc_clr at E+3 (pkt_cnt==0 -> packet_active fall -> packet_active_r ->
# packet_done_pulse register chain).
TOP_CLR_PHASE = 3


async def _reset(dut, sf, sample_shift, sc_thr=0x1CC, sc_hits_req=2):
    for s in ("iq_valid", "delayed_valid", "sc_clr", "sc_lock_force", "sc_lock_sync",
              "cur_i0", "cur_q0", "del_i0", "del_q0"):
        getattr(dut, s).value = 0
    dut.sf.value = sf
    dut.sample_shift.value = sample_shift
    dut.sc_thr.value = sc_thr
    dut.sc_hits_req.value = sc_hits_req
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 4)


async def _frame(dut, cur=(0, 0), dl=(0, 0), clr_at=None):
    """One 64-clock sample frame. Signals set before an edge are sampled at it."""
    events = {0: "iq", DEL_LAG: "del"}
    if clr_at is not None:
        events[clr_at] = events.get(clr_at, "") + "clr"
    c = 0
    for t in sorted(events):
        if t > c:
            await ClockCycles(dut.clk, t - c)
            c = t
        ev = events[t]
        dut.iq_valid.value = 1 if "iq" in ev else 0
        dut.delayed_valid.value = 1 if "del" in ev else 0
        dut.sc_clr.value = 1 if "clr" in ev else 0
        if "del" in ev:
            dut.cur_i0.value = int(cur[0]) & 0xFF
            dut.cur_q0.value = int(cur[1]) & 0xFF
            dut.del_i0.value = int(dl[0]) & 0xFF
            dut.del_q0.value = int(dl[1]) & 0xFF
        await RisingEdge(dut.clk)
        c += 1
        dut.iq_valid.value = 0
        dut.delayed_valid.value = 0
        dut.sc_clr.value = 0
    if SAMPLE_CLKS > c:
        await ClockCycles(dut.clk, SAMPLE_CLKS - c)


@cocotb.test()
async def test_sample_count_sc_clr_phase_sweep(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await _reset(dut, 7, 1)
    n_iq = 0
    lost = []
    for phase in range(SAMPLE_CLKS):
        before = int(dut.sample_count.value)
        for _ in range(3):
            await _frame(dut); n_iq += 1
        await _frame(dut, clr_at=phase); n_iq += 1
        for _ in range(3):
            await _frame(dut); n_iq += 1
        got = int(dut.sample_count.value)
        if got - before != 7:
            lost.append((phase, 7 - (got - before)))
    dut._log.info(f"iq_valid driven={n_iq} sample_count={int(dut.sample_count.value)}")
    dut._log.info(f"sc_clr phases that dropped counts (phase, n_lost): {lost}")
    assert not lost, (f"sample_count lost {sum(n for _, n in lost)} counts; sc_clr phases "
                      f"{[p for p, _ in lost]} (trouper_top lands at phase {TOP_CLR_PHASE})")


def _packet(rng, M, snr_db):
    g = int(rng.integers(2 * M, 4 * M))
    up = np.exp(1j * np.pi * np.arange(M) ** 2 / M)
    fr = np.concatenate([np.zeros(g, complex), np.tile(up, 8),
                         modulate(int(rng.integers(0, M)), M), np.zeros(2 * M, complex)])
    n0 = 10 ** (-snr_db / 10)
    rx = fr + np.sqrt(n0 / 2) * (rng.standard_normal(len(fr)) + 1j * rng.standard_normal(len(fr)))
    sc = 40 / np.sqrt(1 + n0)
    return (np.clip(np.round(rx.real * sc), -128, 127)
            + 1j * np.clip(np.round(rx.imag * sc), -128, 127))


@cocotb.test()
async def test_timing_ref_multi_packet_no_reset(dut):
    sf, shift, n_pkts = 6, 0, 5
    M = 1 << (sf + shift)
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await _reset(dut, sf, shift)
    rng = np.random.default_rng(7)

    # Build the whole stream up front: [packet, M zeros, CLR-sample, M zeros] x n.
    # Each sc_clr sits in a zero region at least M samples after the packet tail
    # and is followed by >= M zeros, so the post-clr segment's `del` history is
    # all zeros -- exactly the sc_rtl.py model's zero padding.
    segs, clr_idx = [], []
    pos = 0
    for _ in range(n_pkts):
        p = _packet(rng, M, 20)
        seg = np.concatenate([p, np.zeros(2 * M, complex)])
        segs.append(seg)
        pos += len(seg)
        clr_idx.append(pos - M)          # sc_clr in the frame of this sample
    x = np.concatenate(segs)
    xi = np.real(x).astype(int); xq = np.imag(x).astype(int)

    seg_start = 0
    results = []
    lock_seen = None
    for n in range(len(x)):
        dl = (xi[n - M], xq[n - M]) if n >= M else (0, 0)
        clr = TOP_CLR_PHASE if n in clr_idx else None
        if clr is not None and lock_seen is None:
            raise AssertionError(f"packet ending at sample {n} never locked")
        await _frame(dut, (xi[n], xq[n]), dl, clr_at=clr)
        if lock_seen is None and int(dut.sc_lock.value):
            lock_seen = int(dut.timing_ref.value)
        if clr is not None:
            mdl = sc_rtl_detect(x[seg_start:n], sf, shift)
            assert mdl[0], f"model did not lock on segment {seg_start}..{n}"
            exp = seg_start + mdl[1]
            results.append((seg_start, lock_seen, exp, lock_seen - exp))
            dut._log.info(f"packet {len(results)}: segment start={seg_start} "
                          f"timing_ref rtl={lock_seen} expected={exp} err={lock_seen - exp:+d}")
            # sc_clr kills the burst of sample n-1 and resets the symbol grid, so the
            # next segment's first evaluated sample is n (its delayed_valid follows
            # the clr in the same frame).
            seg_start = n
            lock_seen = None
    errs = [r[3] for r in results]
    assert all(e == 0 for e in errs), (
        f"timing_ref drifts across sc_clr re-arms: per-packet error {errs} samples "
        f"(packet 1 follows reset, later ones follow an sc_clr)")
