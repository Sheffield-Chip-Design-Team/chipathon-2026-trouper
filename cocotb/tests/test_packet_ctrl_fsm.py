"""Standalone packet-control FSM tests.

Verification-plan rows:

* #1 — reset values and IDLE quiescence;
* #2 — lock edge, packet-parameter latch, and exactly one cycle in
  ``ST_ACQ_SETUP`` before ``ST_PREAMBLE_ACQ``.

Every sampled clock is compared against ``PacketCtrlFsmModel``.  The tests also make
focused assertions at the requirement boundaries so a failure reports the intended
contract rather than only a generic model mismatch.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge, Timer

from packet_ctrl_fsm_model import (
    PacketCtrlFsmModel,
    ST_ACQ_SETUP,
    ST_IDLE,
    ST_PREAMBLE_ACQ,
)


CLK_NS = 31.25

INPUT_NAMES = (
    "rst_n",
    "sample_count",
    "iq_tick",
    "sf",
    "sample_shift",
    "sc_lock",
    "timing_ref",
    "training_done",
    "W_commit",
    "mode_shadow",
    "antenna_en_shadow",
    "pkt_timeout_syms",
    "tacc_window_syms",
)


def _drive_defaults(dut) -> None:
    dut.rst_n.value = 0
    dut.sample_count.value = 0
    dut.iq_tick.value = 0
    dut.sf.value = 7
    dut.sample_shift.value = 1
    dut.sc_lock.value = 0
    dut.timing_ref.value = 0
    dut.training_done.value = 0
    dut.W_commit.value = 0
    dut.mode_shadow.value = 0
    dut.antenna_en_shadow.value = 1
    dut.pkt_timeout_syms.value = 64
    dut.tacc_window_syms.value = 8


def _inputs(dut) -> dict[str, int]:
    return {name: int(getattr(dut, name).value) for name in INPUT_NAMES}


def _check_model(dut, model: PacketCtrlFsmModel, tag: str) -> None:
    mismatches = []
    for name, expected in model.snapshot().items():
        actual = int(getattr(dut, name).value)
        if actual != expected:
            mismatches.append(f"{name}: rtl={actual} model={expected}")
    assert not mismatches, f"{tag}: " + ", ".join(mismatches)


async def _cycle(dut, model: PacketCtrlFsmModel, tag: str) -> None:
    """Advance one edge, then compare settled RTL state with the model."""
    # A cocotb deposit is not guaranteed to be visible through a handle read in
    # the same scheduler phase. Let newly-driven inputs settle before capturing
    # the model's pre-edge input vector.
    await Timer(1, unit="ps")
    model.step(_inputs(dut))
    await RisingEdge(dut.clk)
    await ReadOnly()
    _check_model(dut, model, tag)
    # Leave the read-only scheduler phase before the caller drives new inputs.
    await Timer(1, unit="ns")


async def _initial_reset(dut, model: PacketCtrlFsmModel) -> None:
    _drive_defaults(dut)
    for cycle in range(3):
        await _cycle(dut, model, f"initial reset cycle {cycle}")
    dut.rst_n.value = 1
    for cycle in range(2):
        await _cycle(dut, model, f"post-reset idle cycle {cycle}")


@cocotb.test()
async def test_reset_values_and_idle_quiescence(dut):
    """Plan row #1: reset contract and an event-free IDLE."""
    _drive_defaults(dut)
    model = PacketCtrlFsmModel()
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await _initial_reset(dut, model)

    assert model.state == ST_IDLE
    assert int(dut.packet_phase.value) == 0
    assert int(dut.packet_active.value) == 0
    assert int(dut.packet_active_ps.value) == 0
    assert int(dut.W_valid_set.value) == 0
    assert int(dut.W_missed_packet.value) == 0
    assert int(dut.W_missed_q.value) == 0
    assert int(dut.active_mode.value) == 0
    assert int(dut.active_antenna_en.value) == 1

    # sample_count/iq_tick and unrelated event levels must not disturb IDLE.
    # W_commit and sc_lock remain low because they intentionally leave quiescence.
    dut.training_done.value = 1
    for cycle in range(6):
        dut.iq_tick.value = cycle & 1
        if cycle & 1:
            dut.sample_count.value = int(dut.sample_count.value) + 1
        await _cycle(dut, model, f"idle quiescence cycle {cycle}")
        assert int(dut.state.value) == ST_IDLE
        assert int(dut.packet_phase.value) == 0
        assert int(dut.packet_active.value) == 0

    # Assert reset asynchronously with every functional event high. Outputs and
    # internal state must take reset values without waiting for another clock.
    dut.sc_lock.value = 1
    dut.training_done.value = 1
    dut.W_commit.value = 1
    dut.rst_n.value = 0
    model.reset()
    await Timer(2, unit="ns")
    await ReadOnly()
    _check_model(dut, model, "asynchronous reset")
    await Timer(1, unit="ps")


@cocotb.test()
async def test_lock_setup_and_parameter_latching(dut):
    """Plan row #2: IDLE lock edge and the dedicated setup cycle."""
    _drive_defaults(dut)
    model = PacketCtrlFsmModel()
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await _initial_reset(dut, model)

    # Non-default values make every latch independently observable.
    locked_timing_ref = 0x0012_3450
    locked_mode = 2
    locked_antennas = 0xA
    dut.sample_count.value = locked_timing_ref + 37
    dut.timing_ref.value = locked_timing_ref
    dut.mode_shadow.value = locked_mode
    dut.antenna_en_shadow.value = locked_antennas
    dut.sc_lock.value = 1

    await _cycle(dut, model, "lock edge enters setup")
    assert int(dut.state.value) == ST_ACQ_SETUP, \
        "sc_lock rising edge did not enter ST_ACQ_SETUP"
    assert int(dut.packet_phase.value) == 1
    assert int(dut.packet_active.value) == 1
    assert int(dut.packet_active_ps.value) == 1
    assert int(dut.lat_timing_ref.value) == locked_timing_ref
    assert int(dut.active_mode.value) == locked_mode
    assert int(dut.active_antenna_en.value) == locked_antennas

    # Change every live source during setup. Counter loads must use the registered
    # timing reference, while the packet controls must retain their at-lock values.
    dut.timing_ref.value = 0x00FE_DCBA
    dut.mode_shadow.value = 1
    dut.antenna_en_shadow.value = 0x3
    dut.sample_count.value = locked_timing_ref + 38
    dut.iq_tick.value = 1

    await _cycle(dut, model, "setup loads counters")
    assert int(dut.state.value) == ST_PREAMBLE_ACQ, \
        "ST_ACQ_SETUP did not last exactly one clock"
    assert int(dut.packet_phase.value) == 1
    assert int(dut.lat_timing_ref.value) == locked_timing_ref, \
        "live timing_ref was re-latched during ST_ACQ_SETUP"
    assert int(dut.active_mode.value) == locked_mode
    assert int(dut.active_antenna_en.value) == locked_antennas
    assert int(dut.acq_cnt.value) == model.acq_cnt
    assert int(dut.wpend_cnt.value) == model.wpend_cnt
    assert int(dut.pkt_cnt.value) == model.pkt_cnt

    # A later sc_lock rising edge while active is not a packet-start edge and must
    # not re-latch timing_ref/mode/mask or re-enter setup.
    dut.iq_tick.value = 0
    dut.sc_lock.value = 0
    await _cycle(dut, model, "active lock deassert")
    dut.sc_lock.value = 1
    await _cycle(dut, model, "active lock re-edge ignored")
    assert int(dut.state.value) == ST_PREAMBLE_ACQ
    assert int(dut.lat_timing_ref.value) == locked_timing_ref
    assert int(dut.active_mode.value) == locked_mode
    assert int(dut.active_antenna_en.value) == locked_antennas
