"""Standalone packet-control FSM tests.

Verification-plan rows:

* #1 — reset values and IDLE quiescence;
* #2 — lock edge, packet-parameter latch, and exactly one cycle in
  ``ST_ACQ_SETUP`` before ``ST_PREAMBLE_ACQ``.
* #9–#12 — deferred-commit handling and same-cycle deadline precedence;
* #18–#20 — counter load/tick behavior, configuration extremes, and wrap.

Every sampled clock is compared against ``PacketCtrlFsmModel``.  The tests also make
focused assertions at the requirement boundaries so a failure reports the intended
contract rather than only a generic model mismatch.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge, Timer

from packet_ctrl_fsm_model import (
    MASK20,
    PacketCtrlFsmModel,
    ST_ACQ_SETUP,
    ST_IDLE,
    ST_PAYLOAD_ACTIVE,
    ST_PREAMBLE_ACQ,
    ST_W_PENDING,
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


async def _reset_between_cases(dut, model: PacketCtrlFsmModel, tag: str) -> None:
    """Reset an already-running clock and return to a checked IDLE state."""
    dut.rst_n.value = 0
    await _cycle(dut, model, f"{tag}: reset")
    _drive_defaults(dut)
    dut.rst_n.value = 1
    await _cycle(dut, model, f"{tag}: idle")


# ST_ACQ_SETUP holds for SETUP_DWELL cycles and captures on the last one, so the
# counter-load cone's operands have been quiet for the 3 edges the scoped SDC's
# MCP=3 assumes (Open Risks #43, design doc S4d). Before that change the state
# lasted exactly one clock, which is what these tests used to assert.
SETUP_DWELL = 4


async def _run_setup_dwell(dut, model: PacketCtrlFsmModel, tag: str) -> None:
    """Advance through ST_ACQ_SETUP, checking it holds then loads."""
    for i in range(SETUP_DWELL - 1):
        await _cycle(dut, model, f"{tag}: setup dwell {i}")
        assert int(dut.state.value) == ST_ACQ_SETUP, \
            f"{tag}: left ST_ACQ_SETUP after {i + 1} cycle(s), expected a " \
            f"{SETUP_DWELL}-cycle dwell"
    await _cycle(dut, model, f"{tag}: setup load")


async def _lock_and_load(
    dut,
    model: PacketCtrlFsmModel,
    tag: str,
    *,
    timing_ref: int,
    sample_count: int,
    setup_iq_tick: int = 0,
) -> None:
    """Take one lock edge and the ST_ACQ_SETUP dwell up to the load edge."""
    dut.timing_ref.value = timing_ref
    dut.sample_count.value = sample_count
    dut.sc_lock.value = 1
    await _cycle(dut, model, f"{tag}: lock")
    assert int(dut.state.value) == ST_ACQ_SETUP

    dut.sc_lock.value = 0
    dut.iq_tick.value = setup_iq_tick
    await _run_setup_dwell(dut, model, tag)
    assert int(dut.state.value) == ST_PREAMBLE_ACQ


def _expected_loads(
    *,
    sf: int,
    sample_shift: int,
    tacc_window_syms: int,
    pkt_timeout_syms: int,
    elapsed: int,
    setup_iq_tick: int,
) -> tuple[int, int, int]:
    """Independent statement of the B6 counter-load equations."""
    m = 1 << (sf + sample_shift)
    tacc_span = (tacc_window_syms or 1) * m

    def remaining(span: int) -> int:
        return max(0, span + 1 - elapsed - setup_iq_tick)

    return (
        remaining(tacc_span + 2 * m),
        remaining(tacc_span + 5 * m),
        remaining(pkt_timeout_syms * m),
    )


def _assert_counter_loads(
    dut,
    *,
    sf: int,
    sample_shift: int,
    tacc_window_syms: int,
    pkt_timeout_syms: int,
    elapsed: int,
    setup_iq_tick: int,
    tag: str,
) -> tuple[int, int, int]:
    expected = _expected_loads(
        sf=sf,
        sample_shift=sample_shift,
        tacc_window_syms=tacc_window_syms,
        pkt_timeout_syms=pkt_timeout_syms,
        elapsed=elapsed,
        setup_iq_tick=setup_iq_tick,
    )
    actual = (
        int(dut.acq_cnt.value),
        int(dut.wpend_cnt.value),
        int(dut.pkt_cnt.value),
    )
    assert actual == expected, f"{tag}: counters rtl={actual} expected={expected}"
    return expected


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

    await _run_setup_dwell(dut, model, "setup loads counters")
    assert int(dut.state.value) == ST_PREAMBLE_ACQ, \
        f"ST_ACQ_SETUP did not last exactly {SETUP_DWELL} clocks"
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


@cocotb.test()
async def test_commit_before_packet_in_idle(dut):
    """Plan row #9: an IDLE commit is applied once and used by the next packet."""
    _drive_defaults(dut)
    model = PacketCtrlFsmModel()
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await _initial_reset(dut, model)

    dut.W_commit.value = 1
    await _cycle(dut, model, "idle commit captured")
    assert int(dut.W_commit_pending.value) == 1
    assert int(dut.W_valid_set.value) == 0

    dut.W_commit.value = 0
    await _cycle(dut, model, "idle commit consumed")
    assert int(dut.W_commit_pending.value) == 0
    assert int(dut.W_valid.value) == 1
    assert int(dut.W_valid_set.value) == 1

    await _cycle(dut, model, "idle commit pulse clears")
    assert int(dut.W_valid_set.value) == 0

    # Make all packet deadlines already expired. The pre-applied W must avoid a
    # miss at W_PENDING, then be cleared when the packet ends.
    dut.tacc_window_syms.value = 0
    dut.pkt_timeout_syms.value = 0
    await _lock_and_load(
        dut,
        model,
        "precommitted packet",
        timing_ref=0,
        sample_count=0x1000,
    )
    dut.training_done.value = 1
    await _cycle(dut, model, "precommitted packet: training done")
    assert int(dut.state.value) == ST_W_PENDING
    dut.training_done.value = 0
    await _cycle(dut, model, "precommitted packet: weight deadline")
    assert int(dut.state.value) == ST_PAYLOAD_ACTIVE
    assert int(dut.W_missed_packet.value) == 0
    assert int(dut.W_missed_q.value) == 0
    await _cycle(dut, model, "precommitted packet: packet end")
    assert int(dut.state.value) == ST_IDLE
    assert int(dut.W_valid.value) == 0


@cocotb.test()
async def test_commit_during_acquisition_is_deferred(dut):
    """Plan row #10: ACQ_SETUP/PREAMBLE commits wait for W_PENDING."""
    _drive_defaults(dut)
    model = PacketCtrlFsmModel()
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await _initial_reset(dut, model)

    for commit_state in ("setup", "preamble"):
        if commit_state == "setup":
            dut.timing_ref.value = 100
            dut.sample_count.value = 100
            dut.sc_lock.value = 1
            await _cycle(dut, model, "setup commit: lock")
            assert int(dut.state.value) == ST_ACQ_SETUP
            dut.sc_lock.value = 0
            dut.W_commit.value = 1
            await _run_setup_dwell(dut, model, "setup commit: capture and load")
        else:
            await _lock_and_load(
                dut,
                model,
                "preamble commit",
                timing_ref=100,
                sample_count=100,
            )
            dut.W_commit.value = 1
            await _cycle(dut, model, "preamble commit: capture")

        assert int(dut.state.value) == ST_PREAMBLE_ACQ
        assert int(dut.W_commit_pending.value) == 1
        assert int(dut.W_valid.value) == 0
        assert int(dut.W_valid_set.value) == 0

        dut.W_commit.value = 0
        dut.training_done.value = 1
        await _cycle(dut, model, f"{commit_state} commit: training done")
        assert int(dut.state.value) == ST_W_PENDING
        assert int(dut.W_commit_pending.value) == 1
        assert int(dut.W_valid_set.value) == 0

        dut.training_done.value = 0
        await _cycle(dut, model, f"{commit_state} commit: consume")
        assert int(dut.state.value) == ST_PAYLOAD_ACTIVE
        assert int(dut.W_commit_pending.value) == 0
        assert int(dut.W_valid.value) == 1
        assert int(dut.W_valid_set.value) == 1
        assert int(dut.W_missed_packet.value) == 0

        if commit_state == "setup":
            await _reset_between_cases(dut, model, "between commit-state cases")


@cocotb.test()
async def test_training_done_wins_at_acquisition_deadline(dut):
    """Plan row #11: training_done wins when acq_cnt is already zero."""
    _drive_defaults(dut)
    model = PacketCtrlFsmModel()
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await _initial_reset(dut, model)

    await _lock_and_load(
        dut,
        model,
        "acquisition precedence",
        timing_ref=0,
        sample_count=0x1000,
    )
    assert int(dut.acq_cnt.value) == 0

    dut.training_done.value = 1
    await _cycle(dut, model, "training_done at expired acquisition deadline")
    assert int(dut.state.value) == ST_W_PENDING
    assert int(dut.packet_phase.value) == 2
    assert int(dut.W_missed_packet.value) == 0
    assert int(dut.W_missed_q.value) == 0


@cocotb.test()
async def test_pending_commit_wins_at_weight_deadline(dut):
    """Plan row #12: an already-pending commit wins at wpend_cnt==0."""
    _drive_defaults(dut)
    model = PacketCtrlFsmModel()
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await _initial_reset(dut, model)

    await _lock_and_load(
        dut,
        model,
        "weight precedence",
        timing_ref=0,
        sample_count=0x1000,
    )
    assert int(dut.wpend_cnt.value) == 0

    # Capture the commit while leaving PREAMBLE_ACQ. It is therefore pending,
    # rather than merely arriving, on the W_PENDING deadline evaluation edge.
    dut.W_commit.value = 1
    dut.training_done.value = 1
    await _cycle(dut, model, "capture commit and enter W_PENDING")
    assert int(dut.state.value) == ST_W_PENDING
    assert int(dut.W_commit_pending.value) == 1

    dut.W_commit.value = 0
    dut.training_done.value = 0
    await _cycle(dut, model, "pending commit at expired weight deadline")
    assert int(dut.state.value) == ST_PAYLOAD_ACTIVE
    assert int(dut.W_valid.value) == 1
    assert int(dut.W_valid_set.value) == 1
    assert int(dut.W_commit_pending.value) == 0
    assert int(dut.W_missed_packet.value) == 0
    assert int(dut.W_missed_q.value) == 0


@cocotb.test()
async def test_counter_formula_tick_and_fire_edges(dut):
    """Plan row #18: exact loads, tick-only decrements, and zero fire edges."""
    _drive_defaults(dut)
    model = PacketCtrlFsmModel()
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await _initial_reset(dut, model)

    # Acquisition counter: setup tick is included in the load, non-ticks hold,
    # ticks decrement, and the zero test fires on the following evaluation edge.
    sf, shift, tacc, pkt = 7, 1, 8, 20
    m = 1 << (sf + shift)
    acq_span = (tacc + 2) * m
    elapsed = acq_span - 2
    dut.sf.value = sf
    dut.sample_shift.value = shift
    dut.tacc_window_syms.value = tacc
    dut.pkt_timeout_syms.value = pkt
    await _lock_and_load(
        dut,
        model,
        "acquisition counter",
        timing_ref=1000,
        sample_count=1000 + elapsed,
        setup_iq_tick=1,
    )
    expected = _assert_counter_loads(
        dut,
        sf=sf,
        sample_shift=shift,
        tacc_window_syms=tacc,
        pkt_timeout_syms=pkt,
        elapsed=elapsed,
        setup_iq_tick=1,
        tag="acquisition counter",
    )
    assert expected[0] == 2

    dut.iq_tick.value = 0
    for cycle in range(3):
        await _cycle(dut, model, f"acquisition no-tick hold {cycle}")
        assert int(dut.acq_cnt.value) == 2
    dut.iq_tick.value = 1
    await _cycle(dut, model, "acquisition tick 2 to 1")
    assert int(dut.acq_cnt.value) == 1
    await _cycle(dut, model, "acquisition tick 1 to 0")
    assert int(dut.acq_cnt.value) == 0
    assert int(dut.state.value) == ST_PREAMBLE_ACQ
    dut.iq_tick.value = 0
    await _cycle(dut, model, "acquisition zero fire")
    assert int(dut.state.value) == ST_PAYLOAD_ACTIVE
    assert int(dut.W_missed_packet.value) == 1

    # Weight counter at a second representative configuration.
    await _reset_between_cases(dut, model, "before weight counter")
    sf, shift, tacc, pkt = 9, 2, 9, 32
    m = 1 << (sf + shift)
    wpend_span = (tacc + 5) * m
    elapsed = wpend_span - 1
    dut.sf.value = sf
    dut.sample_shift.value = shift
    dut.tacc_window_syms.value = tacc
    dut.pkt_timeout_syms.value = pkt
    await _lock_and_load(
        dut,
        model,
        "weight counter",
        timing_ref=0x2000,
        sample_count=0x2000 + elapsed,
    )
    expected = _assert_counter_loads(
        dut,
        sf=sf,
        sample_shift=shift,
        tacc_window_syms=tacc,
        pkt_timeout_syms=pkt,
        elapsed=elapsed,
        setup_iq_tick=0,
        tag="weight counter",
    )
    assert expected[1] == 2
    dut.training_done.value = 1
    await _cycle(dut, model, "weight counter: enter pending")
    dut.training_done.value = 0
    dut.iq_tick.value = 1
    await _cycle(dut, model, "weight tick 2 to 1")
    await _cycle(dut, model, "weight tick 1 to 0")
    assert int(dut.wpend_cnt.value) == 0
    assert int(dut.state.value) == ST_W_PENDING
    dut.iq_tick.value = 0
    await _cycle(dut, model, "weight zero fire")
    assert int(dut.state.value) == ST_PAYLOAD_ACTIVE
    assert int(dut.W_missed_packet.value) == 1

    # Packet counter: enter payload with an already-valid W, then check its edge.
    await _reset_between_cases(dut, model, "before packet counter")
    sf, shift, tacc, pkt = 7, 1, 8, 14
    m = 1 << (sf + shift)
    elapsed = pkt * m - 1
    dut.sf.value = sf
    dut.sample_shift.value = shift
    dut.tacc_window_syms.value = tacc
    dut.pkt_timeout_syms.value = pkt
    dut.W_commit.value = 1
    await _cycle(dut, model, "packet counter: capture idle commit")
    dut.W_commit.value = 0
    await _cycle(dut, model, "packet counter: apply idle commit")
    await _lock_and_load(
        dut,
        model,
        "packet counter",
        timing_ref=0x4000,
        sample_count=0x4000 + elapsed,
    )
    expected = _assert_counter_loads(
        dut,
        sf=sf,
        sample_shift=shift,
        tacc_window_syms=tacc,
        pkt_timeout_syms=pkt,
        elapsed=elapsed,
        setup_iq_tick=0,
        tag="packet counter",
    )
    assert expected[2] == 2
    dut.training_done.value = 1
    await _cycle(dut, model, "packet counter: enter pending")
    dut.training_done.value = 0
    await _cycle(dut, model, "packet counter: enter payload")
    assert int(dut.state.value) == ST_PAYLOAD_ACTIVE
    dut.iq_tick.value = 1
    await _cycle(dut, model, "packet tick 2 to 1")
    await _cycle(dut, model, "packet tick 1 to 0")
    assert int(dut.pkt_cnt.value) == 0
    assert int(dut.state.value) == ST_PAYLOAD_ACTIVE
    dut.iq_tick.value = 0
    await _cycle(dut, model, "packet zero fire")
    assert int(dut.state.value) == ST_IDLE


@cocotb.test()
async def test_counter_configuration_extremes(dut):
    """Plan row #19: clamp/default rules and legal configuration extremes."""
    _drive_defaults(dut)
    model = PacketCtrlFsmModel()
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await _initial_reset(dut, model)

    cases = (
        # raw tacc=0 clamps to one symbol; pkt=0 still loads one evaluation.
        ("raw-zero minima", 7, 1, 0, 0, 0, 0),
        ("minimum legal tacc with setup tick", 7, 1, 8, 255, 0, 1),
        ("maximum spans", 12, 2, 15, 255, 0, 0),
        # All spans are already expired and must clamp, not wrap, to zero.
        ("already expired", 7, 1, 15, 0, 10000, 0),
    )

    for index, (tag, sf, shift, tacc, pkt, elapsed, setup_tick) in enumerate(cases):
        if index:
            await _reset_between_cases(dut, model, f"before {tag}")
        dut.sf.value = sf
        dut.sample_shift.value = shift
        dut.tacc_window_syms.value = tacc
        dut.pkt_timeout_syms.value = pkt
        timing_ref = 0x10000
        await _lock_and_load(
            dut,
            model,
            tag,
            timing_ref=timing_ref,
            sample_count=timing_ref + elapsed,
            setup_iq_tick=setup_tick,
        )
        expected = _assert_counter_loads(
            dut,
            sf=sf,
            sample_shift=shift,
            tacc_window_syms=tacc,
            pkt_timeout_syms=pkt,
            elapsed=elapsed,
            setup_iq_tick=setup_tick,
            tag=tag,
        )
        if tag == "raw-zero minima":
            m = 1 << (sf + shift)
            assert expected == (3 * m + 1, 6 * m + 1, 1)
        elif tag == "already expired":
            assert expected == (0, 0, 0)


@cocotb.test()
async def test_sample_count_and_elapsed_wrap(dut):
    """Plan row #20: loads remain exact across low-20 and full-32-bit wrap."""
    _drive_defaults(dut)
    model = PacketCtrlFsmModel()
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await _initial_reset(dut, model)

    cases = (
        ("low-20 wrap", 0x001F_FFF0, 0x0020_0010),
        ("full-32 wrap", 0xFFFF_FFF0, 0x0000_0010),
    )
    sf, shift, tacc, pkt = 7, 1, 8, 64

    for index, (tag, timing_ref, sample_count) in enumerate(cases):
        if index:
            await _reset_between_cases(dut, model, f"before {tag}")
        dut.sf.value = sf
        dut.sample_shift.value = shift
        dut.tacc_window_syms.value = tacc
        dut.pkt_timeout_syms.value = pkt
        elapsed = ((sample_count & MASK20) - (timing_ref & MASK20)) & MASK20
        assert elapsed == 32
        await _lock_and_load(
            dut,
            model,
            tag,
            timing_ref=timing_ref,
            sample_count=sample_count,
        )
        before = _assert_counter_loads(
            dut,
            sf=sf,
            sample_shift=shift,
            tacc_window_syms=tacc,
            pkt_timeout_syms=pkt,
            elapsed=elapsed,
            setup_iq_tick=0,
            tag=tag,
        )

        # Once loaded, the counters depend only on iq_tick, not on the wrapped
        # absolute sample_count value.
        dut.sample_count.value = (sample_count + 1) & 0xFFFF_FFFF
        dut.iq_tick.value = 1
        await _cycle(dut, model, f"{tag}: first post-wrap tick")
        after = (
            int(dut.acq_cnt.value),
            int(dut.wpend_cnt.value),
            int(dut.pkt_cnt.value),
        )
        assert after == tuple(value - 1 for value in before)
