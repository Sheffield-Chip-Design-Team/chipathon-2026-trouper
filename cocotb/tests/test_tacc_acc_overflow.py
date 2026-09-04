"""
test_tacc_acc_overflow.py -- Open Risk #63.

training_acc.v accumulates:
  * the six complex cross-pairs Zpair_i/q0..5 into signed [31:0] (line 55-60);
  * the four diagonals Zdiag_0..3 into unsigned [31:0] (line 62).

TACC_WINDOW_SYMS is a 4-bit register clamped to 8..15, and M = 2^(sf+sample_shift)
reaches 16384, so the largest legal accumulation window is 15 * 16384 = 245760
samples (line 248-249, and packet_ctrl_fsm span bounds).

At int8 full scale two correlated branches add I_a*I_b + Q_a*Q_b = 127*127*2 =
32258 to a real cross-pair every sample, so the signed-int32 maximum
(2147483647) is passed after ceil(2147483648 / 32258) = 66573 samples -- roughly
a quarter of the legal window. The accumulator then wraps negative and the
firmware weight computation (MRC row-sum / power-iteration eigenvector) reads a
sign-inverted Z. The unsigned diagonals (127^2 * 2 per sample for the k==k term)
wrap past 2^32 after ~133147 samples.

Bench: TOPLEVEL = training_acc in noise mode (fully-forward window from the
trigger instant), branches 0 and 1 held at (127, 127) so Zpair_i0 (= Z_01)
accumulates the worst-case correlated term; branches 2, 3 held at zero.
Regresses the #63 fix (saturating sadd32/uadd32 on every Z accumulate;
branch rtl/open-risk-fixes): Zpair_i0 now clamps at INT32_MAX and Zdiag_0
stays monotonic instead of wrapping. PASS once the fix is in.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

CLK_NS = 31.25

# int8 full scale on the two correlated branches
A = 127
ZPAIR_ADD_PER_SAMPLE = A * A + A * A          # 32258  -> Zpair_i0
ZDIAG_ADD_PER_SAMPLE = A * A + A * A          # 32258  -> Zdiag_0
INT32_MAX = (1 << 31) - 1
UINT32_MAX = (1 << 32) - 1
ZPAIR_OVERFLOW_SAMPLE = INT32_MAX // ZPAIR_ADD_PER_SAMPLE + 1     # ~66573
ZDIAG_OVERFLOW_SAMPLE = UINT32_MAX // ZDIAG_ADD_PER_SAMPLE + 1    # ~133147


async def _reset(dut, sf, shift):
    dut.rst_n.value = 0
    dut.iq_valid.value = 0
    dut.sc_lock.value = 0
    dut.noise_trig.value = 0
    dut.timing_ref.value = 0
    dut.sf.value = sf
    dut.sample_shift.value = shift
    dut.tacc_window_syms.value = 15                # legal maximum
    # branches 0 and 1 identical -> perfectly correlated cross-pair Z_01
    dut.raw_i0.value = A & 0xFF
    dut.raw_q0.value = A & 0xFF
    dut.raw_i1.value = A & 0xFF
    dut.raw_q1.value = A & 0xFF
    dut.raw_i2.value = 0
    dut.raw_q2.value = 0
    dut.raw_i3.value = 0
    dut.raw_q3.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 3)


async def _arm_noise(dut):
    dut.noise_trig.value = 1
    await RisingEdge(dut.clk)
    dut.noise_trig.value = 0
    await ClockCycles(dut.clk, 3)
    assert int(dut.training_armed.value) == 1, "noise_trig did not arm the accumulator"


async def _wait_pipe_idle(dut, guard=400):
    for _ in range(guard):
        await RisingEdge(dut.clk)
        if int(dut.tdm_active.value) == 0 and int(dut.acc_active.value) == 0:
            return
    raise TimeoutError("TDM pipeline never drained between samples")


async def _accumulate(dut, sf, shift, max_samples, probe):
    """Arm a noise-mode window and feed identical correlated samples one at a
    time, waiting for the paced TDM/acc pipeline to drain between each so every
    sample is accumulated. `probe(n)` is called after sample n with the DUT; it
    returns a string on the first violation, else None."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await _reset(dut, sf, shift)
    await _arm_noise(dut)

    n = 0
    while n < max_samples:
        dut.iq_valid.value = 1
        await RisingEdge(dut.clk)
        dut.iq_valid.value = 0
        await _wait_pipe_idle(dut)
        n += 1
        if int(dut.training_done.value) == 1:
            raise AssertionError(
                f"window closed after only {n} samples (n_acc={int(dut.n_acc.value)}) "
                f"-- expected the legal 15*M window to be far longer")
        msg = probe(dut, n)
        if msg:
            return n, msg
    return n, None


@cocotb.test()
async def test_zpair_i_overflows_within_legal_window(dut):
    """Zpair_i0 is signed [31:0]; with Z_01 accumulating 32258/sample it reaches
    2^31 around sample 66573 -- well inside the 245760-sample legal window.
    Pre-fix it wrapped negative there. With the #63 saturating add it must clamp
    at INT32_MAX and never go negative."""
    def probe(d, n):
        v = d.Zpair_i0.value.signed_integer
        if v < 0:
            return f"Zpair_i0 wrapped to {v} at sample {n} (expected clamp at 2^31-1)"
        return None

    n, msg = await _accumulate(dut, sf=12, shift=2, max_samples=70_000, probe=probe)
    final = dut.Zpair_i0.value.signed_integer
    dut._log.info(f"stopped at sample {n}, Zpair_i0={final}")
    assert msg is None, (
        f"{msg} -- signed int32 cross-pair accumulator wrapped instead of clamping; "
        f"the #63 saturating add regressed (firmware would read a sign-inverted Z)")
    assert final == INT32_MAX, (
        f"Zpair_i0={final} did not clamp at INT32_MAX ({INT32_MAX}) after {n} samples "
        f"-- expected saturation by ~sample {ZPAIR_OVERFLOW_SAMPLE} (Open Risk #63 fix)")


@cocotb.test()
async def test_zdiag_overflows_within_legal_window(dut):
    """Zdiag_0 is unsigned [31:0] and accumulates a non-negative term every
    sample, so it must be monotonically non-decreasing for the whole window.
    Pre-fix it wrapped past 2^32 around sample 133147. With the #63 saturating
    add it must clamp at UINT32_MAX and stay monotonic."""
    state = {"prev": 0}

    def probe(d, n):
        v = int(d.Zdiag_0.value)
        if v < state["prev"]:
            return (f"Zdiag_0 decreased {state['prev']} -> {v} at sample {n} "
                    f"(expected clamp at 2^32-1)")
        state["prev"] = v
        return None

    n, msg = await _accumulate(dut, sf=12, shift=2, max_samples=140_000, probe=probe)
    final = int(dut.Zdiag_0.value)
    dut._log.info(f"stopped at sample {n}, Zdiag_0={final}")
    assert msg is None, (
        f"{msg} -- unsigned int32 diagonal accumulator wrapped instead of clamping; "
        f"the #63 saturating add regressed")
    assert final == UINT32_MAX, (
        f"Zdiag_0={final} did not clamp at UINT32_MAX ({UINT32_MAX}) after {n} samples "
        f"-- expected saturation by ~sample {ZDIAG_OVERFLOW_SAMPLE} (Open Risk #63 fix)")
