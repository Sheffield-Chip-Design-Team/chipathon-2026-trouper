"""
test_mcp_tacc_settle.py -- Open Risks item 43, paced_dsp MCP settle proof,
training_acc leg.

Structural background (src/combiner/training_acc.v): the dual 8x8 multiply
(mul_out/mulB_out, opA_a*opA_b and opB_a*opB_b) cannot settle in one 31.25 ns
IQ_CLK cycle at the FD SS corner, so each TDM step is held for TDM_WAIT+1 = 3
cycles (tdm_wait counting 0..TDM_WAIT while pipe_active) before the settled
products are registered on `active_cycle = pipe_active && tdm_wait ==
TDM_WAIT`, and only then consumed by the Zpair_*/Zdiag_* accumulation (gated
by acc_active && active_cycle). This is exactly the
relaxation the SDC's scoped `set_multicycle_path 3 -setup -through
$paced_nets` (paced_dsp group, u_tacc.* in scope) grants.

NOTE on reset: mul_out/mulB_out live in a plain `always @(posedge clk)`
block with NO reset input at all (matching the file's documented pattern for
Zpair_*/Zdiag_* -- "B2: intentionally NOT reset... zeroed at arm time").
This is a deliberate, not accidental, resetless register -- consumption is
gated by acc_active/tdm_active, which DO reset, and by the arm-time zeroing
of every Z accumulator, so a stale mul_out can never reach a live register.
test_reset_mid_burst_rearm asserts exactly that contract: the *counters*
that gate consumption clear on reset, and the next training window still
starts and finishes correctly regardless of the stale mul_out left behind.

  test_mul_settle_gating     -- one full training window under normal
      sample/TDM activity; a background monitor asserts mul_out/mulB_out
      never change unless pipe_active && tdm_wait==TDM_WAIT held on the
      preceding edge. The same monitor directly checks every Zpair_*/Zdiag_*
      endpoint: it may change only on that paced accumulation edge, or on the
      explicit arm-time zero load.
  test_reset_mid_burst_rearm -- assert rst_n partway through a TDM step
      burst (tdm_active=1, tdm_wait < TDM_WAIT); confirms tdm_active/
      acc_active/tdm_pair/tdm_wait/armed all clear (mul_out deliberately
      does not), then a fresh sc_lock arm runs a full training window to
      completion with the same settle discipline and a bit-exact Zdiag_0.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

CLK_NS = 31.25
TDM_WAIT = 2       # localparam TDM_WAIT = 2'd2 in training_acc.v
SF = 6
SHIFT = 0
M = 1 << (SF + SHIFT)     # 64 samples/symbol
SAMPLE_CLKS = 64          # iq_valid spacing
WINDOW_SYMS = 8           # clamp floor
RAW_I0, RAW_Q0 = 5, -3    # constant branch-0 sample -> Zdiag_0 = n_acc * 34
Z_ENDPOINTS = (
    "Zpair_i0", "Zpair_q0", "Zpair_i1", "Zpair_q1",
    "Zpair_i2", "Zpair_q2", "Zpair_i3", "Zpair_q3",
    "Zpair_i4", "Zpair_q4", "Zpair_i5", "Zpair_q5",
    "Zdiag_0", "Zdiag_1", "Zdiag_2", "Zdiag_3",
)


async def _reset(dut):
    dut.rst_n.value = 0
    dut.iq_valid.value = 0
    dut.sc_lock.value = 0
    dut.noise_trig.value = 0
    dut.timing_ref.value = 0
    dut.sf.value = SF
    dut.sample_shift.value = SHIFT
    dut.tacc_window_syms.value = WINDOW_SYMS
    dut.raw_i0.value = RAW_I0 & 0xFF
    dut.raw_q0.value = RAW_Q0 & 0xFF
    for k in range(1, 4):
        getattr(dut, f"raw_i{k}").value = (10 + k) & 0xFF
        getattr(dut, f"raw_q{k}").value = (-4 - k) & 0xFF
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


async def _pulse(dut):
    dut.iq_valid.value = 1
    await RisingEdge(dut.clk)
    dut.iq_valid.value = 0
    await ClockCycles(dut.clk, SAMPLE_CLKS - 1)


def _snap(dut):
    return {
        "rst_n": int(dut.rst_n.value),
        "tdm_active": int(dut.tdm_active.value),
        "acc_active": int(dut.acc_active.value),
        "tdm_wait": int(dut.tdm_wait.value),
        "mul_out": int(dut.mul_out.value),
        "mulB_out": int(dut.mulB_out.value),
        "armed": int(dut.armed.value),
        "sc_lock": int(dut.sc_lock.value),
        "noise_trig": int(dut.noise_trig.value),
        "z": tuple(int(getattr(dut, name).value) for name in Z_ENDPOINTS),
    }


async def _settle_monitor(dut, violations, stats):
    prev = _snap(dut)
    stats.setdefault("z_acc_updates", 0)
    stats.setdefault("z_arm_loads", 0)
    stats.setdefault("z_touched", set())
    while True:
        await RisingEdge(dut.clk)
        await ReadOnly()
        cur = _snap(dut)
        # Reset is asynchronous and Z registers are intentionally resetless;
        # do not construe simulator initialization/reset transitions as a
        # paced datapath write. The re-arm test below covers the first real
        # post-reset window.
        if not cur["rst_n"] or not prev["rst_n"]:
            prev = cur
            continue
        pipe_active = prev["tdm_active"] or prev["acc_active"]
        active_cycle = pipe_active and prev["tdm_wait"] == TDM_WAIT
        if (cur["mul_out"] != prev["mul_out"] or cur["mulB_out"] != prev["mulB_out"]):
            if not active_cycle:
                violations.append(
                    f"mul_out/mulB_out changed with tdm_active={prev['tdm_active']} "
                    f"acc_active={prev['acc_active']} tdm_wait={prev['tdm_wait']} "
                    f"(need pipe_active=1 wait={TDM_WAIT})"
                )
        if cur["z"] != prev["z"]:
            stats["z_touched"].update(
                name for name, before, after in zip(Z_ENDPOINTS, prev["z"], cur["z"])
                if before != after
            )
            # Every Z endpoint is written in exactly two places in the RTL:
            # arm-time zeroing, or `if (acc_active && active_cycle)`.
            # Check the actual endpoints rather than inferring their pacing
            # transitively from mul_out/mulB_out.
            arm_load = ((cur["sc_lock"] or cur["noise_trig"]) and
                        not prev["armed"])
            if prev["acc_active"] and prev["tdm_wait"] == TDM_WAIT:
                stats["z_acc_updates"] += 1
            elif arm_load:
                stats["z_arm_loads"] += 1
            else:
                violations.append(
                    "Zpair/Zdiag endpoint changed outside an arm-time zero load "
                    f"or paced accumulate edge: prev(acc_active={prev['acc_active']}, "
                    f"tdm_wait={prev['tdm_wait']}, armed={prev['armed']}, "
                    f"sc_lock={prev['sc_lock']}, noise_trig={prev['noise_trig']})"
                )
        prev = cur


async def _wait_until(dut, pred, timeout_cycles=500):
    for _ in range(timeout_cycles):
        await ReadOnly()
        if pred():
            return
        await RisingEdge(dut.clk)
    raise TimeoutError("condition never became true")


async def _run_training_window(dut, tr_offset=1):
    """Arm via sc_lock at sample_count==tr_offset and pulse samples until
    training_done; returns n_acc, Zdiag_0."""
    dut.timing_ref.value = tr_offset
    dut.sc_lock.value = 1
    await ClockCycles(dut.clk, 3)
    assert int(dut.training_armed.value) == 1, "not armed after sc_lock"

    k = 0
    max_pulses = WINDOW_SYMS * M + 3 * M
    while int(dut.training_done.value) == 0 and k < max_pulses:
        await _pulse(dut)
        k += 1
    assert int(dut.training_done.value) == 1, "training_done never fired"
    dut.sc_lock.value = 0
    await ClockCycles(dut.clk, 4)
    return int(dut.n_acc.value), int(dut.Zdiag_0.value)


@cocotb.test()
async def test_mul_settle_gating(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await _reset(dut)

    violations = []
    stats = {}
    mon = cocotb.start_soon(_settle_monitor(dut, violations, stats))

    n_acc, zd = await _run_training_window(dut, tr_offset=1)
    exp_n = WINDOW_SYMS * M
    assert n_acc == exp_n, f"n_acc={n_acc}, expected {exp_n}"
    assert zd == n_acc * (RAW_I0 * RAW_I0 + RAW_Q0 * RAW_Q0), f"Zdiag_0={zd}"

    mon.kill()
    assert not violations, "settle violations:\n" + "\n".join(violations)
    assert stats["z_acc_updates"] > 0, "no paced Zpair/Zdiag update observed"
    assert set(Z_ENDPOINTS) <= stats["z_touched"], "not every Z endpoint changed"


@cocotb.test()
async def test_reset_mid_burst_rearm(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await _reset(dut)

    violations = []
    stats = {}
    mon = cocotb.start_soon(_settle_monitor(dut, violations, stats))

    # acc_start = timing_ref for a live-mode arm; use 0 so the very first
    # iq_valid pulse below satisfies sample_count(pre-increment)==0 >=
    # acc_start immediately (a single pulse is all this case sends -- a
    # nonzero timing_ref would need a second pulse to actually trigger the
    # TDM burst, since the trigger condition reads sample_count before its
    # same-cycle increment).
    dut.timing_ref.value = 0
    dut.sc_lock.value = 1
    await ClockCycles(dut.clk, 3)
    assert int(dut.training_armed.value) == 1, "not armed after sc_lock"

    # Trigger one TDM burst and catch it mid-step.
    dut.iq_valid.value = 1
    await RisingEdge(dut.clk)
    dut.iq_valid.value = 0
    await _wait_until(dut, lambda: int(dut.tdm_active.value) == 1)
    for _ in range(3):
        await RisingEdge(dut.clk)

    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 4)

    assert int(dut.tdm_active.value) == 0, "tdm_active not cleared by reset"
    assert int(dut.acc_active.value) == 0, "acc_active not cleared by reset"
    assert int(dut.tdm_wait.value) == 0, "tdm_wait not cleared by reset"
    assert int(dut.tdm_pair.value) == 0, "tdm_pair not cleared by reset"
    assert int(dut.armed.value) == 0, "armed not cleared by reset"
    assert int(dut.training_done.value) == 0, "training_done not cleared by reset"
    # mul_out/mulB_out are deliberately resetless (see module header note) --
    # documented here, not asserted to zero.

    dut.rst_n.value = 1
    dut.sc_lock.value = 0
    await ClockCycles(dut.clk, 2)

    # Clean re-arm from scratch: run a full training window and check
    # bit-exact accumulation (proves no stale mul_out/mulB_out leaked into a
    # live Z register across the reset).
    n_acc, zd = await _run_training_window(dut, tr_offset=1)
    exp_n = WINDOW_SYMS * M
    assert n_acc == exp_n, f"post-reset n_acc={n_acc}, expected {exp_n}"
    assert zd == n_acc * (RAW_I0 * RAW_I0 + RAW_Q0 * RAW_Q0), \
        f"post-reset Zdiag_0={zd} not bit-exact -- possible stale mul_out leak"

    mon.kill()
    assert not violations, "settle violations after reset re-arm:\n" + "\n".join(violations)
    assert stats["z_acc_updates"] > 0, "no paced Zpair/Zdiag update observed after reset"
    assert set(Z_ENDPOINTS) <= stats["z_touched"], "not every Z endpoint changed after reset"
