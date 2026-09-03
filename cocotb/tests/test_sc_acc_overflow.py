"""
test_sc_acc_overflow.py -- Open Risk #61.

sc_detector.v's per-symbol accumulators are signed [23:0]
(acc_ci0/acc_cq0/acc_E0cur/acc_E0del, line 159-160) but the design now supports
M = 2^(SF+sample_shift) up to 16384. A full-scale complex sample contributes up
to 127^2 + 127^2 = 32258 energy counts; even at the documented ~90-count AGC
operating point that is 16200/sample, so a single M=1024 symbol accumulates
~16.6 M -- past 2^23. Two consequences:

  1. The symbol-boundary snapshot `eval_* <= acc_*[22:10]` (line 380-381) is a
     bare bit-slice that EXCLUDES the sign bit [23]. Once the accumulator
     exceeds 2^22 a large positive value is snapshotted as negative, and the
     Schmidl-Cox metric is then computed on sign-flipped garbage.

  2. At amplitudes where the accumulator lands on exactly 2^23 the [22:10]
     slice is 0, `eval_e_acc` degenerates to 0, `eval_hit` is forced false and
     sc_lock never fires for an otherwise clean, strong preamble.

Separately (line 365-381): at the final sample of a symbol `acc_E0del` is
incremented and snapshotted with non-blocking assignments on the SAME edge, so
`eval_E0del` receives the pre-update accumulator -- missing the last sample's
delayed-energy term. acc_E0cur (updated at TDM step 5) does not share this, so
with cur==del every sample the two snapshots must be equal and are not.

The accumulators are zeroed at the symbol boundary (line 395-396), so a
background monitor records their running peak/min *during* the symbol; the
persistent metric-engine snapshots (eval_E0cur/eval_E0del/eval_ci0) are read
after. SF7/M=256 must PASS; the SF9/SF10 cases are EXPECTED TO FAIL until #61
is fixed.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, ReadOnly

CLK_NS = 31.25
BURST_MARGIN = 45          # 8 TDM steps * (TDM_WAIT+1=3) = 24, plus slack
EVAL_MARGIN = 260          # 4 serial_mul13 products (~14 clk) + lock-check tail


def _s(handle):
    """signed int of a handle's current value (LogicArray)."""
    try:
        return handle.value.to_signed()
    except AttributeError:
        return handle.value.signed_integer


async def _reset(dut, sf, shift):
    dut.rst_n.value = 0
    dut.iq_valid.value = 0
    dut.delayed_valid.value = 0
    dut.cur_i0.value = 0
    dut.cur_q0.value = 0
    dut.del_i0.value = 0
    dut.del_q0.value = 0
    dut.sf.value = sf
    dut.sample_shift.value = shift
    dut.sc_thr.value = 1                # lowest useful threshold
    dut.sc_hits_req.value = 0           # 1 qualifying symbol -> lock
    dut.sc_clr.value = 0
    dut.sc_lock_force.value = 0
    dut.sc_lock_sync.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 3)


class _AccMon:
    """Background monitor of acc_E0cur across the whole run: records the running
    min (signed) and max (raw) before the symbol-boundary zeroing."""
    def __init__(self, dut):
        self.dut = dut
        self.min_signed = 0
        self.max_raw = 0
        self._task = None

    def start(self):
        self._task = cocotb.start_soon(self._run())

    def stop(self):
        if self._task:
            self._task.kill()

    async def _run(self):
        while True:
            await RisingEdge(self.dut.clk)
            await ReadOnly()
            raw = int(self.dut.acc_E0cur.value)
            sgn = _s(self.dut.acc_E0cur)
            if raw > self.max_raw:
                self.max_raw = raw
            if sgn < self.min_signed:
                self.min_signed = sgn


async def _pulse_sample(dut, ci, cq, di, dq):
    dut.cur_i0.value = ci & 0xFF
    dut.cur_q0.value = cq & 0xFF
    dut.del_i0.value = di & 0xFF
    dut.del_q0.value = dq & 0xFF
    dut.iq_valid.value = 1
    dut.delayed_valid.value = 1
    await RisingEdge(dut.clk)
    dut.iq_valid.value = 0
    dut.delayed_valid.value = 0
    await ClockCycles(dut.clk, BURST_MARGIN - 1)


async def _run_one_symbol(dut, sf, shift, amp):
    """Reset, drive exactly M correlated samples (cur==del==(amp,amp)), let the
    metric engine settle. Returns a dict of persistent snapshot state + the
    running accumulator extremes from the background monitor."""
    await _reset(dut, sf, shift)
    mon = _AccMon(dut)
    mon.start()
    M = 1 << (sf + shift)
    for _ in range(M):
        await _pulse_sample(dut, amp, amp, amp, amp)
    await ClockCycles(dut.clk, EVAL_MARGIN)
    await ReadOnly()
    out = {
        "M": M,
        "true_energy_sum": M * (amp * amp + amp * amp),
        "acc_min_signed": mon.min_signed,
        "acc_max_raw": mon.max_raw,
        "eval_E0cur": _s(dut.eval_E0cur),
        "eval_E0del": _s(dut.eval_E0del),
        "eval_ci0": _s(dut.eval_ci0),
        "sc_lock": int(dut.sc_lock.value),
    }
    mon.stop()
    return out


@cocotb.test()
async def test_baseline_sf7_no_overflow(dut):
    """M=256 at the ~90-count AGC point: no accumulator overflows, the snapshot
    stays positive and sc_lock fires. Proves the bench is sound."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    s = await _run_one_symbol(dut, sf=7, shift=1, amp=90)     # M = 256

    dut._log.info(f"baseline SF7/M=256: acc_max_raw={s['acc_max_raw']} "
                  f"acc_min_signed={s['acc_min_signed']} eval_E0cur={s['eval_E0cur']} "
                  f"sc_lock={s['sc_lock']}")
    assert s["acc_min_signed"] >= 0, \
        f"baseline acc_E0cur went negative ({s['acc_min_signed']}) at M=256"
    assert s["eval_E0cur"] > 0, \
        f"baseline eval_E0cur snapshot not positive ({s['eval_E0cur']}) at M=256"
    assert s["acc_max_raw"] == s["true_energy_sum"], \
        f"baseline acc_E0cur peak {s['acc_max_raw']} != true sum {s['true_energy_sum']}"
    assert s["sc_lock"] == 1, "baseline: sc_lock never fired for a clean strong preamble at SF7"


@cocotb.test()
async def test_sf9_energy_snapshot_sign_flip(dut):
    """M=1024 at the ~90-count AGC point. acc_E0cur reaches ~16.6 M with bit
    [23] set, so both the running signed accumulator and the acc_*[22:10]
    snapshot read NEGATIVE even though every sample contributed a non-negative
    squared magnitude. EXPECTED FAIL until #61 is fixed."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    s = await _run_one_symbol(dut, sf=9, shift=1, amp=90)     # M = 1024

    dut._log.info(f"SF9/M=1024 amp=90: true energy sum={s['true_energy_sum']} "
                  f"acc_min_signed={s['acc_min_signed']} acc_max_raw={s['acc_max_raw']} "
                  f"eval_E0cur={s['eval_E0cur']} eval_ci0={s['eval_ci0']} sc_lock={s['sc_lock']}")

    assert s["acc_min_signed"] >= 0, (
        f"acc_E0cur is signed [23:0] and dipped to {s['acc_min_signed']} during a symbol of "
        f"non-negative energy contributions (true peak +{s['true_energy_sum']}) -- bit [23] "
        f"overflow (Open Risk #61)")
    assert s["eval_E0cur"] > 0, (
        f"eval_E0cur snapshot = {s['eval_E0cur']} < 0 from acc_E0cur[22:10]; the slice drops "
        f"the sign bit so a large positive accumulator aliases negative -- the SC metric is "
        f"computed on sign-flipped data (Open Risk #61)")
    assert s["eval_ci0"] > 0, (
        f"eval_ci0 snapshot = {s['eval_ci0']} < 0 -- same acc_*[22:10] sign drop on the "
        f"correlation accumulator")


@cocotb.test()
async def test_sf9_amp64_lock_never_fires(dut):
    """M=1024, amp=64: acc_E0cur reaches exactly 2^23, so acc_E0cur[22:10] == 0,
    eval_e_acc degenerates to 0, eval_hit is forced false and sc_lock never
    asserts for a clean, strong, perfectly-correlated preamble. EXPECTED FAIL
    until #61 is fixed."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    s = await _run_one_symbol(dut, sf=9, shift=1, amp=64)     # M = 1024

    dut._log.info(f"SF9/M=1024 amp=64: acc_max_raw={s['acc_max_raw']} (2^23={1<<23}) "
                  f"eval_E0cur={s['eval_E0cur']} sc_lock={s['sc_lock']}")

    assert s["sc_lock"] == 1, (
        f"sc_lock never fired for a clean, strong (amp=64), perfectly-correlated preamble at "
        f"SF9/M=1024: acc_E0cur peaked at {s['acc_max_raw']} (== 2^23), the [22:10] snapshot "
        f"is {s['eval_E0cur']}, and the degenerate metric suppresses every hit (Open Risk #61)")


@cocotb.test()
async def test_e0del_drops_boundary_sample(dut):
    """cur == del on every sample, so the current-energy and delayed-energy
    snapshots MUST be identical. They are not: acc_E0del is updated at TDM
    step 7 with a non-blocking assignment on the same edge the symbol-boundary
    snapshot latches eval_E0del <= acc_E0del[22:10], so eval_E0del is missing
    the final sample's del_i0^2 + del_q0^2. M=64, amp=13 chosen so the missing
    term flips the >>10 slice by one. EXPECTED FAIL until #61 is fixed."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    s = await _run_one_symbol(dut, sf=6, shift=0, amp=13)     # M = 64

    dut._log.info(f"M=64 amp=13 cur==del: eval_E0cur={s['eval_E0cur']} eval_E0del={s['eval_E0del']}")

    assert s["eval_E0cur"] == s["eval_E0del"], (
        f"eval_E0cur ({s['eval_E0cur']}) != eval_E0del ({s['eval_E0del']}) even though cur==del "
        f"on every sample -- the step-7 same-edge NBA drops the last sample from the "
        f"delayed-energy snapshot (Open Risk #61)")


@cocotb.test()
async def test_sf10_accumulator_true_wrap(dut):
    """M=2048 at the ~90-count AGC point: the true energy sum (~33.2 M) exceeds
    2^24, so the raw 24-bit accumulator wraps and never actually reaches the
    true peak -- magnitude loss, not just sign interpretation. EXPECTED FAIL
    until #61 is fixed."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    s = await _run_one_symbol(dut, sf=9, shift=2, amp=90)     # M = 2048

    dut._log.info(f"M=2048 amp=90: true energy sum={s['true_energy_sum']} "
                  f"acc_max_raw={s['acc_max_raw']} (2^24={1<<24})")

    assert s["acc_max_raw"] >= s["true_energy_sum"], (
        f"acc_E0cur peaked at {s['acc_max_raw']} but the true accumulated energy is "
        f"{s['true_energy_sum']} -- the 24-bit accumulator wrapped past 2^24 (Open Risk #61)")
