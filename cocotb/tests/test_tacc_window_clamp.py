"""
test_tacc_window_clamp.py -- training_acc window clamp (R3,
planning/dsp-block-review-changes-2026-07.md).

Hazard: in live mode acc_start = timing_ref, which lies (sc_hits_req+1) <= 4
symbols in the past at arm time. With tacc_window_syms <= that lock latency,
acc_end = timing_ref + window*M - 1 lands BEFORE the lock instant, the
accumulate condition (acc_start <= sample_count <= acc_end) is false forever,
and training_done never fires -- the packet dies on PKT_TIMEOUT. reg_bank
clamps 0x27 writes to >= 8, but the module-level guard only mapped 0 -> 1
(itself a dead value); direct-drive integrations (unit TBs, FPGA wrapper,
formal) had no protection. The fix clamps < 8 -> 8 inside training_acc,
matching reg_bank.

Unit-level bench: TOPLEVEL = training_acc, sc_lock/timing_ref driven directly
to emulate a worst-case 4-symbol-late lock. SF=6/shift=0 (M=64) keeps sims
short; training_acc uses sf as a bare shift amount so any value is legal here.

  test_window_clamp_live   -- windows {0, 2, 8, 9} with a 4-symbol-late lock:
                              done must fire with n_acc exactly matching the
                              *clamped* window (0 and 2 deadlock pre-fix).
  test_window_clamp_noise  -- noise mode with window 3: n_acc == 8*M (clamped;
                              was 3*M pre-fix -- documents the intentional
                              semantic change for direct-driven sub-8 windows).

Zdiag_0 is checked bit-exactly (constant raw input -> Zdiag_0 = n_acc*(i^2+q^2)),
so a miscounted or partially-accumulated window cannot pass.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

CLK_NS = 31.25
SF = 6
SHIFT = 0
M = 1 << (SF + SHIFT)      # 64 samples/symbol
SAMPLE_CLKS = 64           # iq_valid spacing (matches the real 500 kS/s schedule)
RAW_I0, RAW_Q0 = 5, -3     # constant branch-0 sample -> Zdiag_0 = n_acc * 34


async def _reset(dut):
    dut.rst_n.value = 0
    dut.iq_valid.value = 0
    dut.sc_lock.value = 0
    dut.noise_trig.value = 0
    dut.timing_ref.value = 0
    dut.sf.value = SF
    dut.sample_shift.value = SHIFT
    dut.raw_i0.value = RAW_I0 & 0xFF
    dut.raw_q0.value = RAW_Q0 & 0xFF
    for k in range(1, 4):
        getattr(dut, f"raw_i{k}").value = (10 + k) & 0xFF
        getattr(dut, f"raw_q{k}").value = (-4 - k) & 0xFF
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


async def _pulse(dut):
    """One iq_valid sample, then the rest of the 64-clock sample period
    (the 16-step x MCP=3 TDM burst needs ~51 clocks to drain)."""
    dut.iq_valid.value = 1
    await RisingEdge(dut.clk)
    dut.iq_valid.value = 0
    await ClockCycles(dut.clk, SAMPLE_CLKS - 1)


async def _run_live_case(dut, window):
    """4-symbol-late lock (sc_hits_req=3 equivalent): sc_lock rises when
    sample_count is already timing_ref + 4*M - 1."""
    await _reset(dut)
    dut.tacc_window_syms.value = window
    tr = 1
    dut.timing_ref.value = tr
    lock_at = tr + 4 * M - 1                    # DUT sample_count at arm
    eff = 8 if window < 8 else window           # post-clamp window
    acc_end = tr + eff * M - 1
    expected_n = acc_end - lock_at + 1

    k = 0                                       # pulses issued == DUT sample_count
    max_pulses = acc_end + 3 * M                # deadlock guard
    while int(dut.training_done.value) == 0 and k < max_pulses:
        if k == lock_at:
            dut.sc_lock.value = 1
            await ClockCycles(dut.clk, 3)       # arm strictly before next sample
            assert int(dut.training_armed.value) == 1, \
                f"window={window}: not armed after sc_lock"
        await _pulse(dut)
        k += 1

    assert int(dut.training_done.value) == 1, \
        f"window={window}: training_done never fired within {max_pulses} samples " \
        "(pre-fix deadlock: acc_end before lock instant)"
    n = int(dut.n_acc.value)
    assert n == expected_n, \
        f"window={window}: n_acc={n}, expected {expected_n} (clamped window {eff} syms)"
    zd = int(dut.Zdiag_0.value)
    exp_zd = expected_n * (RAW_I0 * RAW_I0 + RAW_Q0 * RAW_Q0)
    assert zd == exp_zd, f"window={window}: Zdiag_0={zd}, expected {exp_zd}"
    dut.sc_lock.value = 0
    await ClockCycles(dut.clk, 8)


@cocotb.test()
async def test_window_clamp_live(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    for window in (0, 2, 8, 9):
        await _run_live_case(dut, window)


@cocotb.test()
async def test_window_clamp_noise(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await _reset(dut)
    dut.tacc_window_syms.value = 3              # would be 3*M pre-fix
    for _ in range(5):
        await _pulse(dut)

    dut.noise_trig.value = 1                    # W1P edge, away from any iq_valid
    await RisingEdge(dut.clk)
    dut.noise_trig.value = 0
    await ClockCycles(dut.clk, 3)
    assert int(dut.training_armed.value) == 1, "noise_trig did not arm"

    expected_n = 8 * M                          # clamped: fully-forward window
    k = 0
    while int(dut.training_done.value) == 0 and k < expected_n + 3 * M:
        await _pulse(dut)
        k += 1
    assert int(dut.training_done.value) == 1, "noise-mode training_done never fired"
    n = int(dut.n_acc.value)
    assert n == expected_n, f"noise mode: n_acc={n}, expected {expected_n} (8*M, clamped)"
    zd = int(dut.Zdiag_0.value)
    exp_zd = expected_n * (RAW_I0 * RAW_I0 + RAW_Q0 * RAW_Q0)
    assert zd == exp_zd, f"noise mode: Zdiag_0={zd}, expected {exp_zd}"
    assert int(dut.training_armed.value) == 0, "noise mode did not self-disarm at done"
