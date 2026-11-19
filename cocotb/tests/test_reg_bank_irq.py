"""test_reg_bank_irq.py -- IRQ_STATUS (0x02) / IRQ_CLEAR (0x03) sticky behaviour
on the standalone reg_bank harness (``cocotb/reg_bank``, direct DUT).

Closes the open half of verification-plan row #13
(planning/verification-plan/reg-bank-verification-plan.md): independent bits
0..4, level-held source vs clear, reserved bits, no spontaneous clear, plus the
clk_en (ce_16m) sampling contract the 2-cycle irq_set stretch in trouper_top
exists for. Requirements: TRPR-REG-007, TRPR-IRQ-001/002/003/004.

reg_bank's irq_set port is LEVEL-sensitive by design: TRPR-IRQ-006 (edge-set,
no re-assert while the source is held) is implemented in trouper_top, which
edge-detects every source into a pulse before it reaches this port, and is
verified at that level (tb_trouper_two_packet / irq_pins). The level-held
case below pins the port contract that division of labour relies on.

Same-edge precedence (decided 2026-10-10): a set landing on the same clk_en
edge as an IRQ_CLEAR of that bit WINS -- a new event is never lost to a clear.
"""

import cocotb
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, Timer

from reg_bank_map_oracle import peek, write_reg
from test_reg_bank_rw_map import _bring_up

IRQ_STATUS, IRQ_CLEAR = 0x02, 0x03
LEGAL = 0x1F          # [4:0] CORR_LOCK, TRAINING_DONE, W_MISSED, PACKET_DONE, NOISE_READY


async def _pulse(dut, mask, cycles=1):
    dut.irq_set.value = mask
    await ClockCycles(dut.clk, cycles)
    await Timer(1, unit="ps")
    dut.irq_set.value = 0


async def _status(dut):
    v = await peek(dut, IRQ_STATUS)
    assert v == int(dut.irq_status_dbg.value), \
        f"0x02 read {v:#04x} != irq_status_dbg {int(dut.irq_status_dbg.value):#04x}"
    assert int(dut.irq_out.value) == (1 if v else 0), \
        f"irq_out={int(dut.irq_out.value)} with IRQ_STATUS={v:#04x}"
    return v


@cocotb.test()
async def test_irq_bits_independent(dut):
    """Each legal bit sets alone; one-hot W1C clears only that bit; irq_out is
    the OR and drops only with the last bit."""
    await _bring_up(dut)
    for b in range(5):
        await _pulse(dut, 1 << b)
        assert await _status(dut) == (1 << b), f"bit {b} set leaked into other bits"
        await write_reg(dut, IRQ_CLEAR, 1 << b)
        assert await _status(dut) == 0, f"bit {b} did not clear"
    await _pulse(dut, LEGAL)
    expect = LEGAL
    for b in (3, 0, 4, 2, 1):          # non-monotonic clear order
        await write_reg(dut, IRQ_CLEAR, 1 << b)
        expect &= ~(1 << b)
        assert await _status(dut) == expect, f"clearing bit {b}: wrong survivors"


@cocotb.test()
async def test_irq_no_spontaneous_clear(dut):
    """Sticky bits survive reads, W0 to IRQ_CLEAR, writes to RO 0x02 and to
    other registers, and long idle."""
    await _bring_up(dut)
    await _pulse(dut, 0b10101)
    await write_reg(dut, IRQ_CLEAR, 0x00)
    await write_reg(dut, IRQ_STATUS, 0xFF)            # RO: must be ignored
    for addr in (0x04, 0x09, 0x0A, 0x1E, 0x1F, 0x27, 0x30):
        await write_reg(dut, addr, 0xFF)
        await write_reg(dut, addr, 0x00)
    for _ in range(16):
        assert await _status(dut) == 0b10101
        assert await peek(dut, IRQ_CLEAR) == 0x00, "IRQ_CLEAR is write-only, reads 0"
    await ClockCycles(dut.clk, 500)
    assert await _status(dut) == 0b10101, "sticky bits decayed while idle"


@cocotb.test()
async def test_irq_level_held_source(dut):
    """Port contract: irq_set is level-sensitive, so a held input re-asserts
    its bit on the edge after a W1C (trouper_top's edge-detect is what makes
    TRPR-IRQ-006 hold); once the input drops, the clear sticks."""
    await _bring_up(dut)
    dut.irq_set.value = 0b00010
    await ClockCycles(dut.clk, 3)
    await write_reg(dut, IRQ_CLEAR, 0b00010)
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")
    assert await _status(dut) == 0b00010, "held source did not re-set after W1C"
    dut.irq_set.value = 0
    await RisingEdge(dut.clk)
    await write_reg(dut, IRQ_CLEAR, 0b00010)
    await ClockCycles(dut.clk, 4)
    assert await _status(dut) == 0, "bit came back with the source low"


@cocotb.test()
async def test_irq_reserved_bits(dut):
    """[7:5] read 0 with every legal source fired; W1C of reserved bits is a
    no-op on legal bits."""
    await _bring_up(dut)
    await _pulse(dut, LEGAL)
    await write_reg(dut, IRQ_CLEAR, 0xE0)
    v = await _status(dut)
    assert v == LEGAL and (v & 0xE0) == 0, f"IRQ_STATUS={v:#04x}"


@cocotb.test()
async def test_irq_clk_en_sampling(dut):
    """With clk_en at half rate (ce_16m), a 2-cycle irq_set stretch is caught in
    either phase; a 1-cycle pulse on the disabled phase is not (why trouper_top
    stretches every source)."""
    await _bring_up(dut)

    async def ce():
        while True:
            dut.clk_en.value = 1
            await RisingEdge(dut.clk)
            await Timer(1, unit="ps")
            dut.clk_en.value = 0
            await RisingEdge(dut.clk)
            await Timer(1, unit="ps")

    task = cocotb.start_soon(ce())
    await ClockCycles(dut.clk, 4)
    for phase in (0, 1):
        await FallingEdge(dut.clk)
        if phase:
            await ClockCycles(dut.clk, 1, rising=False)
        await _pulse(dut, 1 << (phase + 2), cycles=2)
        await ClockCycles(dut.clk, 2)
        assert (await _status(dut)) & (1 << (phase + 2)), f"2-cycle stretch missed in phase {phase}"
    # 1-cycle pulse aimed at a clk_en=0 edge
    while True:
        await FallingEdge(dut.clk)
        if int(dut.clk_en.value) == 0:
            break
    await _pulse(dut, 0b00001, cycles=1)
    await ClockCycles(dut.clk, 3)
    assert not ((await _status(dut)) & 1), "1-cycle pulse on a disabled edge was captured?"
    task.kill()
    dut.clk_en.value = 1


@cocotb.test()
async def test_irq_set_wins_over_same_edge_clear(dut):
    """A new event on the same edge as a W1C of its bit survives the clear;
    other bits in the same W1C still clear."""
    await _bring_up(dut)
    for b in range(5):
        other = (b + 1) % 5
        await _pulse(dut, (1 << b) | (1 << other))
        dut.irq_set.value = 1 << b                # re-fire bit b ...
        await write_reg(dut, IRQ_CLEAR, (1 << b) | (1 << other))   # ... on the clear edge
        dut.irq_set.value = 0
        v = await _status(dut)
        assert v == (1 << b), \
            f"bit {b}: same-edge set lost to IRQ_CLEAR or bit {other} not cleared (0x{v:02X})"
        await write_reg(dut, IRQ_CLEAR, 1 << b)
        assert await _status(dut) == 0, f"bit {b}: plain clear after the race failed"
