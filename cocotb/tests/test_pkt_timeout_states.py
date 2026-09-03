"""
test_pkt_timeout_states.py -- Open Risk #64.

packet_ctrl_fsm.v decrements the packet-deadline down-counter pkt_cnt in
ST_PREAMBLE_ACQ, ST_W_PENDING and ST_PAYLOAD_ACTIVE (line 164-170), but only
ST_PAYLOAD_ACTIVE acts on pkt_cnt == 0 (line 290-297). TRPR-PCF-007 requires
PKT_TIMEOUT_SYMS to bound packet_active. When PKT_TIMEOUT_SYMS is configured
shorter than the acquisition deadline (acq_span = tacc_window_span + 2M) or the
weight-pending deadline (wpend_span = tacc_window_span + 5M), pkt_cnt reaches
zero while the FSM is still in ST_PREAMBLE_ACQ / ST_W_PENDING, nothing forces
IDLE, and packet_active stays high until the *acquisition* deadline instead --
several symbols past the configured packet timeout.

SF7 / sample_shift=1 -> M = 256. tacc_window_syms = 8 -> acq_span = 2048 + 512 =
2560, wpend_span = 2048 + 1280 = 3328. pkt_timeout_syms = 4 -> pkt_span = 1024.

  test_payload_timeout_forces_idle          -- CONTROL, must PASS: in
      ST_PAYLOAD_ACTIVE the same pkt_cnt == 0 does force IDLE, so the mechanism
      itself works.
  test_preamble_acq_timeout_is_ignored      -- EXPECTED FAIL: packet_active
      should drop ~pkt_span ticks after lock; it survives to ~acq_span.
  test_wpending_timeout_is_ignored          -- EXPECTED FAIL: same in
      ST_W_PENDING (training_done fired, W_COMMIT withheld).
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

CLK_NS = 31.25

SF = 7
SAMPLE_SHIFT = 1
M = 1 << (SF + SAMPLE_SHIFT)          # 256
TACC_WINDOW_SYMS = 8
PKT_TIMEOUT_SYMS = 4

ACQ_SPAN = TACC_WINDOW_SYMS * M + 2 * M      # 2560
WPEND_SPAN = TACC_WINDOW_SYMS * M + 5 * M    # 3328
PKT_SPAN = PKT_TIMEOUT_SYMS * M              # 1024

ST_IDLE, ST_PREAMBLE_ACQ, ST_W_PENDING, ST_PAYLOAD_ACTIVE, ST_ACQ_SETUP = range(5)


def _defaults(dut):
    dut.rst_n.value = 0
    dut.sample_count.value = 0
    dut.iq_tick.value = 0
    dut.sf.value = SF
    dut.sample_shift.value = SAMPLE_SHIFT
    dut.sc_lock.value = 0
    dut.timing_ref.value = 0
    dut.training_done.value = 0
    dut.W_commit.value = 0
    dut.mode_shadow.value = 0
    dut.antenna_en_shadow.value = 1
    dut.pkt_timeout_syms.value = PKT_TIMEOUT_SYMS
    dut.tacc_window_syms.value = TACC_WINDOW_SYMS


async def _edge(dut):
    """One clock edge, with a settle before it so freshly-deposited inputs are
    visible at the edge (the test_packet_ctrl_fsm pattern)."""
    await Timer(1, unit="ps")
    await RisingEdge(dut.clk)


async def _reset(dut):
    _defaults(dut)
    for _ in range(4):
        await _edge(dut)
    dut.rst_n.value = 1
    for _ in range(2):
        await _edge(dut)


async def _state(dut):
    await Timer(1, unit="ps")
    return int(dut.state.value)


async def _lock_to_preamble_acq(dut):
    """Take the sc_lock edge and the 4-cycle ST_ACQ_SETUP dwell (iq_tick held
    low so elapsed==0 and the loads are span+1)."""
    dut.sc_lock.value = 1
    await _edge(dut)
    assert await _state(dut) == ST_ACQ_SETUP, "no ST_ACQ_SETUP after lock"
    dut.sc_lock.value = 0
    for _ in range(6):
        await _edge(dut)
        if await _state(dut) == ST_PREAMBLE_ACQ:
            break
    assert await _state(dut) == ST_PREAMBLE_ACQ, "never reached ST_PREAMBLE_ACQ"


async def _tick(dut, n=1):
    """Advance n captured samples: pulse iq_tick and increment the sample_count
    input in lock-step, exactly as trouper_top wires iq_samp_cnt/dcr_valid."""
    for _ in range(n):
        cnt = int(dut.sample_count.value)
        dut.sample_count.value = cnt + 1
        dut.iq_tick.value = 1
        await _edge(dut)
        dut.iq_tick.value = 0
        await _edge(dut)                   # one idle clock between ticks


async def _ticks_until_idle(dut, limit):
    """Tick until packet_active deasserts; return the tick count, or None."""
    for i in range(1, limit + 1):
        await _tick(dut)
        if int(dut.packet_active.value) == 0:
            return i
    return None


@cocotb.test()
async def test_payload_timeout_forces_idle(dut):
    """CONTROL (must PASS): reach ST_PAYLOAD_ACTIVE via training_done + W_COMMIT,
    then let pkt_cnt expire. The FSM does force IDLE here."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await _reset(dut)
    await _lock_to_preamble_acq(dut)

    dut.training_done.value = 1
    await _edge(dut)
    dut.training_done.value = 0
    assert await _state(dut) == ST_W_PENDING, "training_done did not advance to ST_W_PENDING"

    dut.W_commit.value = 1              # sets W_commit_pending
    await _edge(dut)
    dut.W_commit.value = 0
    await _edge(dut)                    # ST_W_PENDING consumes the pending commit
    assert await _state(dut) == ST_PAYLOAD_ACTIVE, "W_COMMIT did not advance to ST_PAYLOAD_ACTIVE"
    assert int(dut.packet_active.value) == 1

    fell_at = await _ticks_until_idle(dut, PKT_SPAN + 4 * M)
    assert fell_at is not None, "packet_active never dropped in ST_PAYLOAD_ACTIVE"
    # generous bound: pkt_cnt already spent ~ (setup + W_PENDING) ticks == 0 here,
    # so it should fire within ~PKT_SPAN of entering PREAMBLE_ACQ.
    assert fell_at <= PKT_SPAN + 2 * M, (
        f"packet_active dropped after {fell_at} ticks, expected <= {PKT_SPAN + 2*M}")
    dut._log.info(f"control OK: ST_PAYLOAD_ACTIVE honored pkt timeout at tick {fell_at}")


@cocotb.test()
async def test_preamble_acq_timeout_is_ignored(dut):
    """EXPECTED FAIL: training_done withheld, so the FSM stays in
    ST_PREAMBLE_ACQ. pkt_cnt hits 0 at ~PKT_SPAN ticks but is never checked
    there; packet_active survives to the acquisition deadline (~ACQ_SPAN)."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await _reset(dut)
    await _lock_to_preamble_acq(dut)
    assert int(dut.pkt_cnt.value) == PKT_SPAN + 1, \
        f"pkt_cnt loaded {int(dut.pkt_cnt.value)}, expected {PKT_SPAN + 1}"

    fell_at = await _ticks_until_idle(dut, ACQ_SPAN + 4 * M)
    dut._log.info(f"packet_active dropped at tick {fell_at} "
                  f"(pkt_span={PKT_SPAN}, acq_span={ACQ_SPAN})")
    assert fell_at is not None, "packet_active never dropped at all"
    assert fell_at <= PKT_SPAN + M, (
        f"packet_active stayed asserted for {fell_at} ticks after lock -- "
        f"PKT_TIMEOUT_SYMS bounds it to ~{PKT_SPAN} (TRPR-PCF-007), but pkt_cnt==0 "
        f"is not acted on in ST_PREAMBLE_ACQ, so it survives to the acquisition "
        f"deadline ~{ACQ_SPAN} (Open Risk #64)")


@cocotb.test()
async def test_wpending_timeout_is_ignored(dut):
    """EXPECTED FAIL: training_done fires (-> ST_W_PENDING) but W_COMMIT is
    withheld. pkt_cnt expires in ST_W_PENDING and is not acted on; packet_active
    survives to the weight-pending deadline (~WPEND_SPAN)."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await _reset(dut)
    await _lock_to_preamble_acq(dut)

    dut.training_done.value = 1
    await _edge(dut)
    dut.training_done.value = 0
    assert await _state(dut) == ST_W_PENDING

    fell_at = await _ticks_until_idle(dut, WPEND_SPAN + 4 * M)
    dut._log.info(f"packet_active dropped at tick {fell_at} "
                  f"(pkt_span={PKT_SPAN}, wpend_span={WPEND_SPAN})")
    assert fell_at is not None, "packet_active never dropped at all"
    assert fell_at <= PKT_SPAN + M, (
        f"packet_active stayed asserted for {fell_at} ticks -- PKT_TIMEOUT_SYMS "
        f"bounds it to ~{PKT_SPAN}, but pkt_cnt==0 is ignored in ST_W_PENDING so it "
        f"survives to ~{WPEND_SPAN} (Open Risk #64)")
