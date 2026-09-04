"""
test_noise_window_edge.py -- Open Risk #66 / #68.

Exercises the noise-window qualification block from src/top/trouper_top.v
(verbatim copy in cocotb/noise_window_edge/noise_window_qual.v) against the
timing hazards the earlier fix attempts missed.

Background
---------
sc_hit_dbg / sc_lock are REGISTERED sc_detector outputs; the serial metric
engine is ~57 cycles deep, and an evaluation only *launches* at a symbol
boundary. So on training_done the gate enters a DRAIN phase, keeps sampling
sc_hit_dbg/sc_lock, and renders the verdict only once ALL of:

  (1) a fixed NOISE_DRAIN_MIN (=72) count has elapsed;
  (2) sc_pipe_active is low (nothing currently in flight);
  (3) IF the SC detector ran at all this window (noise_sc_was_active): an
      evaluation that was *launched after* the drain began has completed
      (sc_eval_start_pulse -> noise_eval_armed -> sc_eval_done_pulse ->
      noise_eval_seen). An evaluation already in flight at training_done was
      fed the previous symbol and must NOT count. If the SC detector never ran
      (PSRAM / SC-delay disabled), (3) is skipped so NOISE_READY can't
      deadlock.

The wrapper models the registered detector outputs. The test drives:
  hit_ev        -- 1-cycle "an evaluation completed WITH a hit"
  eval_done_ev  -- 1-cycle "an evaluation completed (hit or not)"
  eval_start_ev -- 1-cycle "an evaluation launched (symbol boundary)"
  pipe_busy     -- TDM burst / serial metric engine in flight
and the wrapper produces sc_hit_dbg / sc_pipe_active / sc_eval_{start,done}_
pulse with the real 1-cycle latency.

Tests
-----
  test_clean_window_qualifies_detector_dark  -- no SC activity at all ->
                                                verdict on the fixed drain
                                                alone (PSRAM-disabled path)
  test_clean_window_qualifies_detector_live  -- SC evals running -> verdict
                                                only after a full post-drain
                                                evaluation, then qualifies
  test_verdict_waits_for_drain               -- pipe_busy held past the drain
  test_hit_offset_sweep                      -- contaminating hit at offsets
                                                -2..+8 vs training_done
  test_noise_abort_drops_window              -- training_acc pre-empt, no verdict
  test_lock_at_or_after_boundary             -- sc_lock at/after training_done
  test_retrigger_during_drain_not_lost       -- #66 P1: a fresh trigger on the
                                                verdict-render cycle is honored
  test_verdict_waits_for_eval                -- #66 P2: fixed drain + idle pipe
                                                alone does NOT release
  test_stale_inflight_eval_does_not_release  -- #66 P2: an eval already in
                                                flight at training_done does not
                                                satisfy the requirement
  test_late_hit_after_drain_rejected         -- #66 P2: a hit visible only at a
                                                post-drain eval boundary rejects
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, ReadOnly, Timer

CLK_NS = 31.25

# src/top/trouper_top.v localparam NOISE_DRAIN_MIN
DRAIN_MIN = 72
DRAIN_WAIT = DRAIN_MIN + 16


async def _settle():
    await Timer(1, unit="ns")


async def _reset(dut):
    dut.rst_n.value = 0
    dut.noise_trig_accept.value = 0
    dut.hit_ev.value = 0
    dut.pipe_busy.value = 0
    dut.eval_done_ev.value = 0
    dut.eval_start_ev.value = 0
    dut.sc_lock_in.value = 0
    dut.training_done.value = 0
    dut.noise_abort.value = 0
    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


async def _open_window(dut):
    dut.noise_trig_accept.value = 1
    await RisingEdge(dut.clk)
    dut.noise_trig_accept.value = 0
    await RisingEdge(dut.clk)
    await ReadOnly()
    assert int(dut.noise_window_active_o.value) == 1, "window did not open"
    await _settle()


async def _run_one_eval(dut, busy_cycles=18):
    """Model one SC metric evaluation: launch pulse + pipe_busy through the
    engine + completion pulse (no hit)."""
    dut.eval_start_ev.value = 1
    dut.pipe_busy.value = 1
    await RisingEdge(dut.clk)
    dut.eval_start_ev.value = 0
    for _ in range(busy_cycles):
        await RisingEdge(dut.clk)
    dut.pipe_busy.value = 0
    dut.eval_done_ev.value = 1
    await RisingEdge(dut.clk)
    dut.eval_done_ev.value = 0


class _EvalHeartbeat:
    """Free-running SC evaluations (one per ~`gap` idle cycles) -- models the
    detector emitting metric_valid_pulse every symbol. Off by default so a
    test can control exactly when the first post-drain evaluation lands."""
    def __init__(self, dut, gap=24):
        self.dut = dut
        self.gap = gap
        self._t = None

    def start(self):
        self._t = cocotb.start_soon(self._run())

    def stop(self):
        if self._t:
            self._t.kill()

    async def _run(self):
        while True:
            for _ in range(self.gap):
                await RisingEdge(self.dut.clk)
            await _run_one_eval(self.dut)


class _S2Monitor:
    """Latches whether sigma2_valid ever pulsed 1."""
    def __init__(self, dut):
        self.dut = dut
        self.pulsed = False
        self._t = None

    def start(self):
        self._t = cocotb.start_soon(self._run())

    def stop(self):
        if self._t:
            self._t.kill()

    async def _run(self):
        while True:
            await RisingEdge(self.dut.clk)
            await ReadOnly()
            if int(self.dut.sigma2_valid.value):
                self.pulsed = True


@cocotb.test()
async def test_clean_window_qualifies_detector_dark(dut):
    """No SC activity at all (PSRAM/SC-delay disabled): the eval requirement is
    skipped and the verdict renders on the fixed drain alone."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await _reset(dut)
    await _open_window(dut)
    mon = _S2Monitor(dut); mon.start()

    await ClockCycles(dut.clk, 10)
    dut.training_done.value = 1
    await ClockCycles(dut.clk, DRAIN_WAIT)
    mon.stop()
    assert mon.pulsed, "detector-dark clean window never asserted sigma2_valid"


@cocotb.test()
async def test_clean_window_qualifies_detector_live(dut):
    """SC evals running through the window and drain: verdict holds until a
    full post-drain evaluation completes, then qualifies clean."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await _reset(dut)
    await _open_window(dut)
    hb = _EvalHeartbeat(dut); hb.start()
    mon = _S2Monitor(dut); mon.start()

    await ClockCycles(dut.clk, 30)          # detector demonstrably live
    dut.training_done.value = 1
    await ClockCycles(dut.clk, DRAIN_WAIT + 80)
    hb.stop(); mon.stop()
    assert mon.pulsed, "detector-live clean window never asserted sigma2_valid"


@cocotb.test()
async def test_verdict_waits_for_drain(dut):
    """pipe_busy held high after training_done: no verdict until it falls."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await _reset(dut)
    await _open_window(dut)

    await ClockCycles(dut.clk, 5)
    dut.training_done.value = 1
    dut.pipe_busy.value = 1
    await RisingEdge(dut.clk)
    await ReadOnly()
    assert int(dut.noise_window_draining_o.value) == 1, "did not enter drain on training_done"
    await _settle()

    mon = _S2Monitor(dut); mon.start()
    await ClockCycles(dut.clk, DRAIN_MIN + 30)
    assert not mon.pulsed, "sigma2_valid fired while the SC pipeline was still busy"

    # release the pipe, then run a real post-drain evaluation -> clean verdict
    dut.pipe_busy.value = 0
    await _run_one_eval(dut)
    await ClockCycles(dut.clk, 8)
    mon.stop()
    assert mon.pulsed, "sigma2_valid never fired after the pipeline drained + evaluated"


@cocotb.test()
async def test_hit_offset_sweep(dut):
    """A non-locking hit whose sc_hit_dbg registers at offset -2..+8 relative to
    training_done, with an evaluation in flight bridging the boundary, must be
    rejected at EVERY offset."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())

    for offset in (-2, -1, 0, 1, 2, 4, 8):
        await _reset(dut)
        await _open_window(dut)
        mon = _S2Monitor(dut); mon.start()

        TD = 12
        hit_at = TD + offset
        lo = min(TD, hit_at) - 2
        hi = max(TD, hit_at) + 2
        for c in range(TD + DRAIN_WAIT + 80):
            dut.training_done.value = 1 if c >= TD else 0
            dut.hit_ev.value = 1 if c == hit_at else 0
            # boundary-bridging eval, then a free-running post-drain eval
            # heartbeat so the gate renders its rejection verdict instead of
            # stalling in drain
            d = c - (hi + 20)
            in_eval = d > 0 and (d % 40) < 20
            dut.pipe_busy.value = 1 if (lo <= c <= hi) or in_eval else 0
            dut.eval_start_ev.value = 1 if (d > 0 and d % 40 == 0) else 0
            dut.eval_done_ev.value = 1 if (d > 0 and d % 40 == 20) else 0
            await RisingEdge(dut.clk)
        await ClockCycles(dut.clk, 8)
        mon.stop()

        assert not mon.pulsed, (
            f"offset {offset:+d}: sigma2_valid qualified a window contaminated by a "
            f"non-locking hit {offset:+d} edges from training_done (Open Risk #66)")
        dut._log.info(f"offset {offset:+d}: rejected, OK")


@cocotb.test()
async def test_noise_abort_drops_window(dut):
    """training_acc cancels an in-flight noise window (Open Risk #68): the
    qualification block drops it with NO verdict and no hang."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await _reset(dut)
    await _open_window(dut)
    hb = _EvalHeartbeat(dut); hb.start()
    mon = _S2Monitor(dut); mon.start()

    await ClockCycles(dut.clk, 8)
    dut.noise_abort.value = 1
    await RisingEdge(dut.clk)
    dut.noise_abort.value = 0
    await ReadOnly()
    await _settle()
    assert int(dut.noise_window_active_o.value) == 0, "window not dropped on noise_abort"

    await ClockCycles(dut.clk, DRAIN_WAIT + 80)
    hb.stop(); mon.stop()
    assert not mon.pulsed, "noise_abort produced a spurious sigma2_valid"


@cocotb.test()
async def test_lock_at_or_after_boundary(dut):
    """sc_lock asserting at or just after training_done must reject."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    for offset in (0, 1, 2):
        await _reset(dut)
        await _open_window(dut)
        mon = _S2Monitor(dut); mon.start()
        TD = 10
        for c in range(TD + DRAIN_WAIT + 80):
            dut.training_done.value = 1 if c >= TD else 0
            dut.sc_lock_in.value = 1 if c >= TD + offset else 0
            base = TD + offset + 4
            dut.pipe_busy.value = 1 if (c == TD + offset) or \
                (c > base and (c - base) % 40 < 18) else 0
            dut.eval_start_ev.value = 1 if (c > base and (c - base) % 40 == 0) else 0
            dut.eval_done_ev.value = 1 if (c > base and (c - base) % 40 == 18) else 0
            await RisingEdge(dut.clk)
        await ClockCycles(dut.clk, 6)
        mon.stop()
        assert not mon.pulsed, (
            f"offset {offset:+d}: sigma2_valid qualified a window with sc_lock "
            f"asserting {offset:+d} edges from training_done (Open Risk #66)")


@cocotb.test()
async def test_retrigger_during_drain_not_lost(dut):
    """Open Risk #66 P1 (two-chain race): a fresh noise_trig_accept while the
    previous window is draining must start a clean window and NOT be lost to the
    old window's verdict. Swept so the retrigger lands on the exact cycle the
    old verdict would otherwise render."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())

    for extra in (0, 1, 2, 5, 20):
        await _reset(dut)
        await _open_window(dut)
        mon = _S2Monitor(dut); mon.start()

        await ClockCycles(dut.clk, 4)
        dut.training_done.value = 1
        await ClockCycles(dut.clk, DRAIN_MIN + extra)
        # retrigger on this edge (collides with any pending verdict). Detector
        # was dark this window (no pipe_busy), so the old verdict was armed.
        dut.noise_trig_accept.value = 1
        await RisingEdge(dut.clk)
        dut.noise_trig_accept.value = 0
        dut.training_done.value = 0
        await ReadOnly()
        assert int(dut.noise_window_active_o.value) == 1, \
            f"extra={extra}: fresh trigger lost -- window not active after retrigger"
        assert int(dut.noise_window_draining_o.value) == 0, \
            f"extra={extra}: fresh window came up already draining (stale state)"
        await _settle()
        # For larger `extra` the old window legitimately finished its full drain
        # and rendered a verdict BEFORE the retrigger -- that is not a leak. The
        # hazard is the *pre-empted* window emitting a verdict *after* the
        # retrigger, so clear the latch and watch the next cycles.
        mon.pulsed = False
        await ClockCycles(dut.clk, 6)
        assert not mon.pulsed, \
            f"extra={extra}: stale verdict from the pre-empted window leaked out"

        # fresh window completes cleanly (detector dark) -> its own verdict
        dut.training_done.value = 1
        await ClockCycles(dut.clk, DRAIN_WAIT)
        mon.stop()
        assert mon.pulsed, f"extra={extra}: fresh window never produced a verdict"


@cocotb.test()
async def test_verdict_waits_for_eval(dut):
    """Open Risk #66 P2: detector live, the fixed drain elapsed and the pipe
    idle -- the verdict must still NOT render until a post-drain evaluation
    completes. A later clean evaluation then qualifies."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await _reset(dut)
    await _open_window(dut)
    mon = _S2Monitor(dut); mon.start()

    # one evaluation during the window so noise_sc_was_active latches
    await _run_one_eval(dut)
    await ClockCycles(dut.clk, 5)
    dut.training_done.value = 1

    # drain count elapses, pipe idle, but NO post-drain eval boundary
    await ClockCycles(dut.clk, DRAIN_MIN + 200)
    await ReadOnly()
    assert int(dut.noise_window_draining_o.value) == 1, \
        "window left drain before any post-drain eval -- P2 gap not closed"
    await _settle()
    assert not mon.pulsed, (
        "sigma2_valid rendered on the fixed drain alone, before the symbol that "
        "was accumulating at training_done was evaluated (Open Risk #66 P2)")

    await _run_one_eval(dut)                 # clean post-drain evaluation
    await ClockCycles(dut.clk, 8)
    mon.stop()
    assert mon.pulsed, "clean post-drain evaluation did not release the verdict"


@cocotb.test()
async def test_stale_inflight_eval_does_not_release(dut):
    """Open Risk #66 P2 (refinement): an evaluation already in flight at
    training_done -- its completion pulse arrives during the drain but it has NO
    post-drain launch pulse -- must NOT satisfy the requirement. Only a
    subsequently *launched* evaluation releases the gate."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await _reset(dut)
    await _open_window(dut)
    mon = _S2Monitor(dut); mon.start()

    # an evaluation is in flight (pipe_busy, launched) as training_done lands
    dut.eval_start_ev.value = 1
    dut.pipe_busy.value = 1
    await RisingEdge(dut.clk)
    dut.eval_start_ev.value = 0
    await ClockCycles(dut.clk, 3)
    dut.training_done.value = 1              # drain starts while this eval flies
    await ClockCycles(dut.clk, 10)
    dut.pipe_busy.value = 0
    dut.eval_done_ev.value = 1               # the in-flight (pre-drain) eval completes
    await RisingEdge(dut.clk)
    dut.eval_done_ev.value = 0

    await ClockCycles(dut.clk, DRAIN_MIN + 60)
    await ReadOnly()
    assert not mon.pulsed, (
        "sigma2_valid released on an evaluation that was already in flight at "
        "training_done (fed the previous symbol) -- Open Risk #66 P2")
    await _settle()

    await _run_one_eval(dut)                 # a genuinely post-drain evaluation
    await ClockCycles(dut.clk, 8)
    mon.stop()
    assert mon.pulsed, "a post-drain evaluation did not release the verdict"


@cocotb.test()
async def test_late_hit_after_drain_rejected(dut):
    """Open Risk #66 P2: a packet that started late in the noise window is not
    visible as sc_hit_dbg until its symbol-boundary evaluation, which lands far
    past the 72-cycle fixed drain. The window must still be REJECTED."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await _reset(dut)
    await _open_window(dut)
    mon = _S2Monitor(dut); mon.start()

    await _run_one_eval(dut)                 # detector live this window
    await ClockCycles(dut.clk, 5)
    dut.training_done.value = 1

    await ClockCycles(dut.clk, DRAIN_MIN + 300)
    await ReadOnly()
    assert not mon.pulsed, "verdict rendered before the late eval boundary (P2)"
    await _settle()

    # the delayed boundary evaluation launches and completes WITH a hit
    dut.eval_start_ev.value = 1
    dut.pipe_busy.value = 1
    await RisingEdge(dut.clk)
    dut.eval_start_ev.value = 0
    await ClockCycles(dut.clk, 10)
    dut.pipe_busy.value = 0
    dut.hit_ev.value = 1                     # eval completed, found the late packet
    await RisingEdge(dut.clk)
    dut.hit_ev.value = 0
    await ClockCycles(dut.clk, 12)
    mon.stop()
    assert not mon.pulsed, (
        "sigma2_valid qualified a window whose contaminating hit only became "
        "visible at a post-drain eval boundary (Open Risk #66 P2)")
