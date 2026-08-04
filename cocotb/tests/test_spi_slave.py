"""Standalone spi_slave.v protocol regression.

Instantiates ``spi_slave.v`` directly (not ``trouper_top.v``/
``tb_trouper_cocotb.v``) and services its register-bank ports with a small,
independent Python stub -- a plain dict-backed memory that answers the
asynchronous peek port (``reg_rd_addr`` -> ``reg_rdata``) and the
synchronized write mailbox (``reg_we``/``reg_wr_addr``/``reg_wdata``). The
stub is not derived from ``reg_bank.v``; this suite is purely about
``spi_slave``'s own transport, per its verification plan's boundary note
("Register contents ... belong to the separate reg-bank-verification-plan").

Verification-plan rows closed/extended here
(``planning/verification-plan/spi-slave-verification-plan.md``):

* #11 -- read-byte atomicity: the MISO shifter snapshots ``reg_rdata`` once
  per data byte (at the falling edge that precedes it), so a live register
  change mid-byte must never appear in that byte's shifted-out bits, but
  must be visible on the very next, independent read.
* #12 -- SCK toggling while ``HOST_CS`` is high must produce no reg_we/
  reg_re events, and a command-only frame (CS asserted, one command byte,
  CS deasserted with no data byte) must leave the SPI-domain frame state
  clean for the next transaction.
* #14 -- ``SpiSlaveModel`` (``spi_slave_model.py``) is an independent,
  from-spec protocol oracle (command decode, 7-bit address progression
  including modulo-128 wrap and the 0x76 no-increment exception, and
  read/write event generation) that does not reuse any of spi_slave.v's
  internal shift-register/CDC logic. Legal frames and constrained aborts are
  driven bit-by-bit and checked against it byte-wise.

Row #13 (formal/analysis -- legal byte spacing vs. synchronizer latency) is
out of scope for this cocotb suite; see the plan doc.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Edge, RisingEdge, Timer

from spi_slave_model import SpiSlaveModel

CLK_NS = 31.25  # 32 MHz clk_32m


def _ps(ns_value):
    """Round an ns float to an exact integer count of picoseconds -- the
    simulator's 1e-12s time precision can't represent an arbitrary float ns
    value, so randomized/half-cycle delays must be quantized before Timer()
    sees them."""
    return round(ns_value * 1000)


# ---------------------------------------------------------------------------
# Standalone reg_bank stub. Independent dict-backed memory, not reg_bank.v.
# ---------------------------------------------------------------------------

def _push_rdata(dut, mem):
    addr = int(dut.reg_rd_addr.value) & 0x7F
    dut.reg_rdata.value = mem.get(addr, 0) & 0xFF


async def _addr_tap_service(dut, mem):
    """Emulates reg_bank's combinational peek port: reg_rdata must track
    reg_rd_addr (and any content change at that address) with no clock
    involved -- exactly what lets a mid-byte register update reach the SPI
    domain in real hardware, which is the scenario row #11 depends on."""
    _push_rdata(dut, mem)
    while True:
        await Edge(dut.reg_rd_addr)
        _push_rdata(dut, mem)


async def _mem_write_service(dut, mem):
    while True:
        await RisingEdge(dut.clk_32m)
        if int(dut.reg_we.value):
            addr = int(dut.reg_wr_addr.value) & 0x7F
            mem[addr] = int(dut.reg_wdata.value) & 0xFF
            _push_rdata(dut, mem)


class EventScoreboard:
    """Records DUT-side reg_we/reg_re rising edges as (addr, data)/addr."""

    def __init__(self):
        self.writes = []  # (addr, data)
        self.reads = []   # addr

    def clear(self):
        self.__init__()


async def _event_monitor(dut, sb):
    prev_we, prev_re = 0, 0
    while True:
        await RisingEdge(dut.clk_32m)
        we = int(dut.reg_we.value)
        re = int(dut.reg_re.value)
        if we and not prev_we:
            sb.writes.append((int(dut.reg_wr_addr.value) & 0x7F,
                               int(dut.reg_wdata.value) & 0xFF))
        if re and not prev_re:
            sb.reads.append(int(dut.reg_re_addr.value) & 0x7F)
        prev_we, prev_re = we, re


async def _bringup(dut, mem):
    cocotb.start_soon(Clock(dut.clk_32m, CLK_NS, unit="ns").start())
    dut.rst_n.value = 0
    dut.HOST_CS.value = 1
    dut.SPI_SCK.value = 0
    dut.SPI_MOSI.value = 0
    dut.reg_rdata.value = 0
    await Timer(4 * CLK_NS, unit="ns")
    dut.rst_n.value = 1
    await Timer(4 * CLK_NS, unit="ns")

    cocotb.start_soon(_addr_tap_service(dut, mem))
    cocotb.start_soon(_mem_write_service(dut, mem))
    sb = EventScoreboard()
    cocotb.start_soon(_event_monitor(dut, sb))
    return sb


async def _settle(dut, cycles=16):
    for _ in range(cycles):
        await RisingEdge(dut.clk_32m)


# ---------------------------------------------------------------------------
# Bit-level frame driver
# ---------------------------------------------------------------------------

async def spi_frame(dut, tx_bytes, half_ns, cs_lead_ns=None, cs_trail_ns=None,
                     abort_after_bits=None, mid_bit_hook=None):
    """Drive HOST_CS low, clock out tx_bytes MSB-first at the given SCK
    half-period, sampling MISO each bit.

    abort_after_bits: raise CS after exactly this many total bits (< 8*len
    for a genuine mid-byte/mid-frame abort).
    mid_bit_hook(dut, bit_idx): called, if given, after each bit's negedge
    has fully settled (bit_idx counts total completed bits across the whole
    frame) -- used by the byte-atomicity test to mutate the backing register
    at a chosen point mid-byte, strictly after that bit's own MISO shift has
    already happened, so the hook can never race the RTL event it is
    supposed to happen after.

    Returns (rx_bytes, bits_clocked); rx_bytes has one entry per completed
    DATA byte only (tx_bytes[1:]) -- the command byte (tx_bytes[0]) shifts
    out whatever was left in the MISO shift register from before the frame
    (TRPR-SPS-009: read data is only valid once the address tap has settled,
    which is not until the data byte), so it carries no meaningful bits and
    is intentionally excluded here to match SpiSlaveModel.run_frame's return.
    """
    dut.HOST_CS.value = 0
    lead = half_ns if cs_lead_ns is None else cs_lead_ns
    await Timer(_ps(lead), unit="ps")

    total_bits = len(tx_bytes) * 8
    limit = total_bits if abort_after_bits is None else min(abort_after_bits, total_bits)
    half_ps = _ps(half_ns)

    rx_bytes = []
    bit_idx = 0
    for byte_num, tx in enumerate(tx_bytes):
        rx = 0
        byte_done = True
        for bit in range(7, -1, -1):
            if bit_idx >= limit:
                byte_done = False
                break
            dut.SPI_MOSI.value = (tx >> bit) & 1
            await Timer(half_ps, unit="ps")
            dut.SPI_SCK.value = 1
            await Timer(half_ps, unit="ps")
            rx = (rx << 1) | int(dut.SPI_MISO.value)
            dut.SPI_SCK.value = 0
            await Timer(1, unit="ps")  # let the negedge-triggered MISO load settle
            bit_idx += 1
            if mid_bit_hook is not None:
                mid_bit_hook(dut, bit_idx)
        if byte_done and byte_num > 0:
            rx_bytes.append(rx)
        if bit_idx >= limit:
            break

    trail = half_ns if cs_trail_ns is None else cs_trail_ns
    trail_ps = _ps(trail)
    await Timer(trail_ps, unit="ps")
    dut.HOST_CS.value = 1
    await Timer(trail_ps, unit="ps")
    return rx_bytes, bit_idx


async def spi_write(dut, addr, val, half_ns=50.0):
    await spi_frame(dut, [addr & 0x7F, val & 0xFF], half_ns,
                     cs_lead_ns=half_ns, cs_trail_ns=half_ns)


async def spi_read(dut, addr, half_ns=50.0):
    rx, bits = await spi_frame(dut, [0x80 | (addr & 0x7F), 0xFF], half_ns,
                                cs_lead_ns=half_ns, cs_trail_ns=half_ns)
    assert bits == 16, f"spi_read(0x{addr:02X}): frame truncated ({bits} bits)"
    return rx[0]


def _data_pattern(rnd, idx):
    """Zero, all-ones, walking-one/zero, and non-symmetric random bytes, per
    the plan's sec 1a coverage list."""
    fixed = (0x00, 0xFF, 1 << (idx % 8), (~(1 << (idx % 8))) & 0xFF)
    if rnd.random() < 0.5:
        return rnd.choice(fixed)
    return rnd.randrange(256)


# ---------------------------------------------------------------------------
# Row #14 -- address progression (ordinary increment, modulo-128 wrap, and
# the 0x76 no-increment exception) checked explicitly against the model.
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_address_progression_wrap_and_no_inc_vs_model(dut):
    tag = "address_progression_vs_model"
    mem = {}
    sb = await _bringup(dut, mem)
    model = SpiSlaveModel()
    half_ns = 50.0  # 10 MHz

    # Ordinary burst write across the 0x7E -> 0x7F -> 0x00 wrap boundary.
    pattern = [0x11 + i for i in range(6)]
    tx = [0x7D] + pattern  # 0x7D,0x7E,0x7F,0x00,0x01,0x02
    rx, bits = await spi_frame(dut, tx, half_ns, cs_lead_ns=half_ns, cs_trail_ns=half_ns)
    assert bits == 8 * len(tx), f"{tag}: wrap write frame truncated ({bits} bits)"
    exp_rx = model.run_frame(tx)
    assert rx == exp_rx, f"{tag}: wrap write MISO mismatch: dut={rx} model={exp_rx}"

    # Verification reads must also be run through the model (not the
    # untracked spi_read() helper) so the read-event stream stays comparable
    # to the DUT's below -- every SPI transaction the test drives on the DUT
    # must have a matching model.run_frame() call.
    for i, val in enumerate(pattern):
        addr = (0x7D + i) & 0x7F
        cmd = [0x80 | addr, 0xFF]
        rx_v, bits_v = await spi_frame(dut, cmd, half_ns, cs_lead_ns=half_ns, cs_trail_ns=half_ns)
        assert bits_v == 16
        exp_v = model.run_frame(cmd)
        assert rx_v == exp_v, (
            f"{tag}: wrap write landed wrong -- addr=0x{addr:02X} expected {exp_v} got {rx_v}")
        assert rx_v[0] == val, (
            f"{tag}: wrap write landed wrong -- addr=0x{addr:02X} expected 0x{val:02X} "
            f"got 0x{rx_v[0]:02X}")

    # 0x76 (PSRAM_DBG_DATA) no-increment: repeated bytes re-hit the same port.
    burst = [0xA1, 0xA2, 0xA3, 0xA4]
    tx76 = [0x76] + burst
    rx76, bits76 = await spi_frame(dut, tx76, half_ns, cs_lead_ns=half_ns, cs_trail_ns=half_ns)
    assert bits76 == 8 * len(tx76), f"{tag}: 0x76 burst frame truncated ({bits76} bits)"
    exp_rx76 = model.run_frame(tx76)
    assert rx76 == exp_rx76, f"{tag}: 0x76 burst MISO mismatch: dut={rx76} model={exp_rx76}"

    cmd76 = [0x80 | 0x76, 0xFF]
    rx76b, bits76b = await spi_frame(dut, cmd76, half_ns, cs_lead_ns=half_ns, cs_trail_ns=half_ns)
    assert bits76b == 16
    exp76b = model.run_frame(cmd76)
    assert rx76b == exp76b
    assert rx76b[0] == burst[-1], (
        f"{tag}: 0x76 no-inc final value mismatch: got 0x{rx76b[0]:02X} expected 0x{burst[-1]:02X}")

    await _settle(dut)
    assert sb.writes == model.write_events, (
        f"{tag}: write event stream mismatch: dut={sb.writes} model={model.write_events}")
    assert sb.reads == model.read_events, (
        f"{tag}: read event stream mismatch: dut={sb.reads} model={model.read_events}")


# ---------------------------------------------------------------------------
# Row #14 -- randomized legal-frame regression vs. the independent model.
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_randomized_protocol_model_regression(dut):
    tag = "randomized_protocol_model"
    mem = {}
    sb = await _bringup(dut, mem)
    model = SpiSlaveModel()
    rnd = random.Random(0x5117)
    half_ns = 50.0  # 10 MHz

    n_frames = 150
    for i in range(n_frames):
        addr = rnd.choice([0x00, 0x01, 0x3F, 0x40, 0x76, 0x7D, 0x7E, 0x7F,
                            rnd.randrange(0x80)])
        is_read = rnd.random() < 0.5
        length = rnd.choice([1, 1, 2, 3, 8])
        cmd = (0x80 if is_read else 0x00) | (addr & 0x7F)
        data_bytes = ([0xFF] * length if is_read
                       else [_data_pattern(rnd, j) for j in range(length)])
        tx_bytes = [cmd] + data_bytes

        rx, bits = await spi_frame(dut, tx_bytes, half_ns,
                                    cs_lead_ns=half_ns, cs_trail_ns=half_ns)
        assert bits == 8 * len(tx_bytes), f"{tag}: frame {i} truncated ({bits} bits)"

        exp_rx = model.run_frame(tx_bytes)
        assert rx == exp_rx, (
            f"{tag}: frame {i} (addr=0x{addr:02X} read={is_read} len={length}) "
            f"MISO mismatch: dut={[hex(b) for b in rx]} model={[hex(b) for b in exp_rx]}")

    await _settle(dut)
    assert sb.writes == model.write_events, (
        f"{tag}: write event stream mismatch over {n_frames} frames: "
        f"dut has {len(sb.writes)}, model has {len(model.write_events)}")
    assert sb.reads == model.read_events, (
        f"{tag}: read event stream mismatch over {n_frames} frames: "
        f"dut has {len(sb.reads)}, model has {len(model.read_events)}")


# ---------------------------------------------------------------------------
# Row #14 -- constrained aborts vs. the model. A write only ever produces an
# event on its own completed 8th bit; a read's event fires as soon as its
# own first bit starts (see SpiSlaveModel.run_frame's docstring), so an
# aborted read data byte can still register exactly one read event even
# though it never produces a MISO byte.
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_randomized_aborted_frames_vs_model(dut):
    tag = "randomized_aborted_frames"
    mem = {}
    sb = await _bringup(dut, mem)
    model = SpiSlaveModel()
    rnd = random.Random(0x0AB0)
    half_ns = 50.0  # 10 MHz

    n_iters = 80
    for i in range(n_iters):
        addr = rnd.randrange(0x80)
        is_read = rnd.random() < 0.5
        length = rnd.randrange(1, 4)
        cmd = (0x80 if is_read else 0x00) | (addr & 0x7F)
        data_bytes = ([0xFF] * length if is_read
                       else [rnd.randrange(256) for _ in range(length)])
        tx_bytes = [cmd] + data_bytes
        total_bits = 8 * len(tx_bytes)
        abort_bits = rnd.randrange(1, total_bits)  # always a genuine mid-frame abort

        sb.clear()
        writes_before = len(model.write_events)
        reads_before = len(model.read_events)

        rx, bits = await spi_frame(dut, tx_bytes, half_ns, abort_after_bits=abort_bits)
        assert bits == abort_bits, f"{tag}: iter {i} abort did not land at the requested bit"

        completed_bytes = bits // 8
        exp_rx = model.run_frame(tx_bytes, total_bits=bits)
        assert rx == exp_rx, (
            f"{tag}: iter {i} (abort_bits={abort_bits}, completed_bytes={completed_bytes}) "
            f"MISO mismatch: dut={rx} model={exp_rx}")
        assert sb.writes == model.write_events[writes_before:], (
            f"{tag}: iter {i}: write events beyond completed bytes: "
            f"dut={sb.writes} model={model.write_events[writes_before:]}")
        assert sb.reads == model.read_events[reads_before:], (
            f"{tag}: iter {i}: read events beyond completed bytes: "
            f"dut={sb.reads} model={model.read_events[reads_before:]}")

        await _settle(dut, 8)

    # Confirm the slave still works normally after the abort sweep.
    await spi_write(dut, 0x22, 0x99, half_ns)
    got = await spi_read(dut, 0x22, half_ns)
    assert got == 0x99, f"{tag}: slave did not recover after abort sweep"


# ---------------------------------------------------------------------------
# Row #11 -- MISO byte-atomicity: a live register change mid-byte must never
# appear in the byte already being shifted out, but must be visible on the
# very next, independent frame.
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_byte_atomicity_live_status_change(dut):
    tag = "byte_atomicity"
    mem = {}
    sb = await _bringup(dut, mem)
    half_ns = 50.0  # 10 MHz
    ADDR = 0x20

    # inject_bit_idx == 8 is the earliest point after the command byte
    # completes (the falling edge right before the data byte's first bit is
    # shifted out, i.e. exactly the load instant). 9..16 mutate mid-shift,
    # one bit position at a time through the whole data byte.
    for inject_bit_idx in range(8, 17):
        V0, V1 = 0x55, 0xAA
        mem[ADDR] = V0
        _push_rdata(dut, mem)

        state = {"fired": False}

        def hook(dut_, bit_idx, _target=inject_bit_idx, _state=state):
            if bit_idx == _target and not _state["fired"]:
                mem[ADDR] = V1
                _push_rdata(dut, mem)
                _state["fired"] = True

        rx, bits = await spi_frame(dut, [0x80 | ADDR, 0xFF], half_ns,
                                    cs_lead_ns=half_ns, cs_trail_ns=half_ns,
                                    mid_bit_hook=hook)
        assert bits == 16, f"{tag}: inject@{inject_bit_idx} frame truncated ({bits} bits)"
        assert state["fired"], f"{tag}: inject@{inject_bit_idx} hook never fired"
        assert rx[0] == V0, (
            f"{tag}: inject@bit {inject_bit_idx}: MISO byte torn -- got 0x{rx[0]:02X}, "
            f"expected the byte-start snapshot 0x{V0:02X} (live register changed to "
            f"0x{V1:02X} mid-byte)")

        # The live update must reach the very next, independent frame --
        # only the in-flight byte is protected, not the register itself.
        rx2, bits2 = await spi_frame(dut, [0x80 | ADDR, 0xFF], half_ns,
                                      cs_lead_ns=half_ns, cs_trail_ns=half_ns)
        assert bits2 == 16
        assert rx2[0] == V1, (
            f"{tag}: inject@bit {inject_bit_idx}: follow-up frame did not observe "
            f"the live update -- got 0x{rx2[0]:02X}, expected 0x{V1:02X}")

    sb  # scoreboard kept attached for symmetry with the other tests; unused here


# ---------------------------------------------------------------------------
# Row #12 -- SCK toggling while deselected, and command-only-frame recovery.
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_deselected_clock_no_effect(dut):
    tag = "deselected_clock"
    mem = {}
    sb = await _bringup(dut, mem)
    half_ns = 50.0  # 10 MHz

    dut.HOST_CS.value = 1
    dut.SPI_MOSI.value = 1
    for _ in range(64):
        dut.SPI_SCK.value = 1
        await Timer(_ps(half_ns), unit="ps")
        dut.SPI_SCK.value = 0
        await Timer(_ps(half_ns), unit="ps")
    await _settle(dut)

    assert not sb.writes, (
        f"{tag}: SCK toggling while HOST_CS was high produced reg_we events: {sb.writes}")
    assert not sb.reads, (
        f"{tag}: SCK toggling while HOST_CS was high produced reg_re events: {sb.reads}")

    # Confirm normal operation afterward.
    await spi_write(dut, 0x15, 0x63, half_ns)
    got = await spi_read(dut, 0x15, half_ns)
    assert got == 0x63, f"{tag}: slave did not operate normally after deselected clocking"


@cocotb.test()
async def test_command_only_frame_recovery(dut):
    tag = "command_only_recovery"
    mem = {}
    sb = await _bringup(dut, mem)
    half_ns = 50.0  # 10 MHz
    ADDR = 0x10

    for label, cmd in (("write_cmd_only", ADDR & 0x7F), ("read_cmd_only", 0x80 | (ADDR & 0x7F))):
        sb.clear()
        rx, bits = await spi_frame(dut, [cmd], half_ns,
                                    cs_lead_ns=half_ns, cs_trail_ns=half_ns)
        assert bits == 8, f"{tag}/{label}: command-only frame truncated ({bits} bits)"
        assert not sb.writes, (
            f"{tag}/{label}: command-only frame produced a reg_we event: {sb.writes}")
        assert not sb.reads, (
            f"{tag}/{label}: command-only frame produced a reg_re event: {sb.reads}")

        # A fresh, complete transaction right afterward must behave normally
        # -- HOST_CS rising must have reset have_cmd/cur_addr cleanly, with
        # no residual state leaking from the command-only frame.
        await spi_write(dut, ADDR, 0x37, half_ns)
        got = await spi_read(dut, ADDR, half_ns)
        assert got == 0x37, (
            f"{tag}/{label}: fresh transaction after a command-only frame failed: "
            f"wrote 0x37 got 0x{got:02X}")

    # Repeated command-only frames back to back, no data byte ever sent.
    sb.clear()
    for _ in range(20):
        rx, bits = await spi_frame(dut, [ADDR & 0x7F], half_ns,
                                    cs_lead_ns=half_ns, cs_trail_ns=half_ns)
        assert bits == 8
    assert not sb.writes and not sb.reads, (
        f"{tag}: repeated command-only frames produced events: "
        f"writes={sb.writes} reads={sb.reads}")

    await spi_write(dut, ADDR, 0x5E, half_ns)
    got = await spi_read(dut, ADDR, half_ns)
    assert got == 0x5E, f"{tag}: slave did not recover after repeated command-only frames"
