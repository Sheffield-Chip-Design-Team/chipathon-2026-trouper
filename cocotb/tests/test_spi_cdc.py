"""
test_spi_cdc.py -- SPI slave CDC/timing regression suite.

Traceability: planning/spi-slave-cdc-and-10mhz-timing-plan.md, Open Risk #38.
Targets spi_slave.v's SPI-domain -> clk_32m (IQ_CLK) crossing: the toggle
synchroniser + bundled-data mailbox (spi_we_toggle/spi_re_toggle ->
reg_we/reg_re), and the CE-gated capture into reg_bank one stage further
downstream (trouper_top's rb_we/rb_addr/rb_wdata, ce_16m-latched).

Three-level scoreboard (per scenario, matches the equality chain this suite
is built to prove):

    completed source SPI bytes  ==  destination reg_we/reg_re edges
                                 ==  accepted register-bank writes

  - "source" events: spi_we_toggle / spi_re_toggle flips in the SPI clock
    domain (dut.u_dut.u_spi), sampled with the bundled address/data latch
    that changed alongside the toggle.
  - "destination" events: rising edges of u_spi.reg_we / u_spi.reg_re in the
    clk_32m domain -- the synchronised, CDC-safe strobes.
  - "accepted" events: rising edges of trouper_top's CE-gated rb_we (one
    more clk_32m stage downstream, ce_16m-latched into reg_bank) -- the
    actual register-bank write, address/data compared in order.

Scenario -> test function map:
    1. Randomized clock-phase sweep         -> test_randomized_clock_phase
    2. Back-to-back minimum-CS writes       -> test_back_to_back_min_cs
    3. Continuous burst writes               -> test_continuous_burst
    4. Read-side-effect verification         -> test_read_side_effect
    5. Reset interruption tests              -> test_reset_interruption
    6. Aborted-frame tests                   -> test_aborted_frame
    7. Clock-limit sweep                     -> test_clock_limit_sweep
    8. W1P exactly-once sweep                -> test_w1p_exactly_once

Safe (no-side-effect, plain-storage) registers used as CDC test payloads:
0x0B (PKT_TIMEOUT_SYMS), 0x30-0x3F (W shadow bank) -- none of these gate on
packet_active or trigger a downstream FSM, so repeated/aborted/reset-interrupted
writes to them can't be confused with a real functional failure elsewhere in
the chip.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Edge, RisingEdge, Timer

from test_trouper_top import CLK_NS, spi_read, spi_write, spi_burst_write

def _ps(ns_value):
    """Round an ns float to an exact integer count of picoseconds -- the
    simulator's 1e-12s time precision can't represent an arbitrary float ns
    value, so randomized delays must be quantized before Timer() sees them."""
    return round(ns_value * 1000)


SAFE_ADDR = 0x0B          # PKT_TIMEOUT_SYMS: plain RW byte, no side effects
BURST_BASE = 0x30         # W shadow bank: 16 plain RW bytes, 0x30-0x3F
BURST_LEN = 16
W1P_REGS = [0x1E, 0x1F]   # WGT_CTRL.W_COMMIT, TACC_NOISE_TRIG (bit[0], W1P)


# ---------------------------------------------------------------------------
# Bring-up helpers
# ---------------------------------------------------------------------------

async def _start_clock(dut):
    cocotb.start_soon(Clock(dut.IQ_CLK, CLK_NS, unit="ns").start())


def _idle_inputs(dut):
    dut.HOST_CS.value = 1
    dut.SPI_MOSI.value = 0
    dut.SPI_SCK.value = 0
    dut.IQ_DATA_I.value = 0
    dut.IQ_DATA_Q.value = 0


async def _reset(dut, cycles=4):
    dut.RESETB.value = 0
    await Timer(cycles * CLK_NS, unit="ns")
    dut.RESETB.value = 1
    await Timer(cycles * CLK_NS, unit="ns")


async def _bringup(dut):
    await _start_clock(dut)
    _idle_inputs(dut)
    await _reset(dut)


# ---------------------------------------------------------------------------
# Low-level, phase/abort/reset-controllable SPI frame driver
# (spi_write/spi_read from test_trouper_top are used only where the CDC
# behaviour itself isn't under test -- e.g. bring-up writes, verification
# reads.)
# ---------------------------------------------------------------------------

async def spi_frame(dut, tx_bytes, half_ns, cs_lead_ns=None, cs_trail_ns=None,
                     abort_after_bits=None, reset_at_bit=None):
    """Drive HOST_CS low, clock out tx_bytes MSB-first at the given SCK
    half-period, sampling MISO each bit.

    abort_after_bits: raise CS after exactly this many total bits (< 8*len
    for a genuine mid-byte/mid-frame abort).
    reset_at_bit: assert RESETB low as soon as this many total bits have
    been clocked (caller is responsible for releasing it afterwards).

    Returns (rx_bytes, bits_clocked).
    """
    dut.HOST_CS.value = 0
    lead = half_ns if cs_lead_ns is None else cs_lead_ns
    await Timer(_ps(lead), unit="ps")

    total_bits = len(tx_bytes) * 8
    limit = total_bits if abort_after_bits is None else min(abort_after_bits, total_bits)
    half_ps = _ps(half_ns)

    rx_bytes = []
    bit_idx = 0
    for tx in tx_bytes:
        rx = 0
        byte_done = True
        for bit in range(7, -1, -1):
            if bit_idx >= limit:
                byte_done = False
                break
            dut.SPI_MOSI.value = (tx >> bit) & 1
            await Timer(half_ps, unit="ps")
            if reset_at_bit is not None and bit_idx == reset_at_bit:
                dut.RESETB.value = 0
            dut.SPI_SCK.value = 1
            await Timer(half_ps, unit="ps")
            rx = (rx << 1) | int(dut.SPI_MISO.value)
            dut.SPI_SCK.value = 0
            bit_idx += 1
        if byte_done:
            rx_bytes.append(rx)
        if bit_idx >= limit:
            break

    trail = half_ns if cs_trail_ns is None else cs_trail_ns
    trail_ps = _ps(trail)
    await Timer(trail_ps, unit="ps")
    dut.HOST_CS.value = 1
    await Timer(trail_ps, unit="ps")
    return rx_bytes, bit_idx


# ---------------------------------------------------------------------------
# Three-level scoreboard
# ---------------------------------------------------------------------------

class Scoreboard:
    def __init__(self):
        self.src_writes = []       # (addr, data) from spi_we_toggle (SPI domain)
        self.src_reads = []        # addr from spi_re_toggle (SPI domain)
        self.dst_we = []           # (addr, data) from u_spi.reg_we rising edge
        self.dst_re = []           # addr from u_spi.reg_re rising edge
        self.accepted_writes = []  # (addr, data) from top-level rb_we rising edge (CE-gated)

    def clear(self):
        self.__init__()

    def check_write_chain(self, tag):
        assert len(self.src_writes) == len(self.dst_we), (
            f"{tag}: source write bytes ({len(self.src_writes)}) != "
            f"dst reg_we edges ({len(self.dst_we)})")
        assert len(self.dst_we) == len(self.accepted_writes), (
            f"{tag}: dst reg_we edges ({len(self.dst_we)}) != "
            f"accepted reg_bank writes ({len(self.accepted_writes)})")
        for i, (src, dst, acc) in enumerate(
                zip(self.src_writes, self.dst_we, self.accepted_writes)):
            assert src == dst == acc, (
                f"{tag}: write #{i} mismatched across CDC stages: "
                f"src={src} dst={dst} accepted={acc}")

    def check_read_chain(self, tag):
        assert len(self.src_reads) == len(self.dst_re), (
            f"{tag}: source read bytes ({len(self.src_reads)}) != "
            f"dst reg_re edges ({len(self.dst_re)})")
        for i, (src, dst) in enumerate(zip(self.src_reads, self.dst_re)):
            assert src == dst, (
                f"{tag}: read #{i} address mismatch: src=0x{src:02X} dst=0x{dst:02X}")


async def _src_we_monitor(dut, sb):
    sig = dut.u_dut.u_spi.spi_we_toggle
    while True:
        await Edge(sig)
        sb.src_writes.append((int(dut.u_dut.u_spi.spi_wr_addr_lat.value),
                               int(dut.u_dut.u_spi.spi_wdata_lat.value)))


async def _src_re_monitor(dut, sb):
    sig = dut.u_dut.u_spi.spi_re_toggle
    while True:
        await Edge(sig)
        sb.src_reads.append(int(dut.u_dut.u_spi.spi_re_addr_lat.value))


async def _dst_monitor(dut, sb):
    prev_we, prev_re, prev_rbwe = 0, 0, 0
    while True:
        await RisingEdge(dut.IQ_CLK)
        we = int(dut.u_dut.u_spi.reg_we.value)
        re = int(dut.u_dut.u_spi.reg_re.value)
        rbwe = int(dut.u_dut.rb_we.value)
        if we and not prev_we:
            sb.dst_we.append((int(dut.u_dut.u_spi.reg_wr_addr.value),
                               int(dut.u_dut.u_spi.reg_wdata.value)))
        if re and not prev_re:
            sb.dst_re.append(int(dut.u_dut.u_spi.reg_re_addr.value))
        if rbwe and not prev_rbwe:
            sb.accepted_writes.append((int(dut.u_dut.rb_addr.value),
                                        int(dut.u_dut.rb_wdata.value)))
        prev_we, prev_re, prev_rbwe = we, re, rbwe


def _attach_scoreboard(dut):
    sb = Scoreboard()
    cocotb.start_soon(_src_we_monitor(dut, sb))
    cocotb.start_soon(_src_re_monitor(dut, sb))
    cocotb.start_soon(_dst_monitor(dut, sb))
    return sb


async def _settle(dut, cycles=32):
    """Give the 3-stage toggle synchroniser + CE-gated capture time to drain."""
    for _ in range(cycles):
        await RisingEdge(dut.IQ_CLK)


# ---------------------------------------------------------------------------
# 1. Randomized clock-phase sweep
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_randomized_clock_phase(dut):
    """Randomize SCLK-vs-IQ_CLK phase across many transactions (10 MHz SPI,
    32 MHz IQ_CLK, free-running relative to each other -- the SPI driver
    uses independent Timer() delays, so nothing here locks phase)."""
    tag = "randomized_clock_phase"
    await _bringup(dut)
    sb = _attach_scoreboard(dut)
    rnd = random.Random(0xC1D5)

    n_iters = 200
    for i in range(n_iters):
        # Random sub-cycle phase offset relative to IQ_CLK before CS falls.
        phase_ns = rnd.uniform(0, CLK_NS)
        await Timer(_ps(phase_ns), unit="ps")

        half_ns = 50.0  # 10 MHz SCLK (the formally-required rate)
        addr = SAFE_ADDR
        data = rnd.randrange(256)
        lead = rnd.uniform(half_ns * 0.5, half_ns * 2.0)
        trail = rnd.uniform(half_ns * 0.5, half_ns * 2.0)

        await spi_frame(dut, [addr & 0x7F, data], half_ns,
                         cs_lead_ns=lead, cs_trail_ns=trail)
        await _settle(dut)

        assert len(sb.src_writes) == i + 1, f"{tag}: source write dropped at iter {i}"
        got = await spi_read(dut, addr)
        assert got == data, f"{tag}: readback mismatch at iter {i}: wrote 0x{data:02X} got 0x{got:02X}"

    sb.check_write_chain(tag)


# ---------------------------------------------------------------------------
# 2. Back-to-back minimum-CS writes
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_back_to_back_min_cs(dut):
    """Hundreds of two-byte writes with minimum CS-high spacing (a single
    SCK half-period, matching a real RPi's tight gap between SPI0
    transfers). Every completed byte must produce exactly one reg_we."""
    tag = "back_to_back_min_cs"
    await _bringup(dut)
    sb = _attach_scoreboard(dut)

    half_ns = 50.0  # 10 MHz
    n_writes = 300
    for i in range(n_writes):
        data = i & 0xFF
        await spi_frame(dut, [SAFE_ADDR & 0x7F, data], half_ns,
                         cs_lead_ns=half_ns, cs_trail_ns=half_ns)
    await _settle(dut, 64)

    assert len(sb.src_writes) == n_writes, (
        f"{tag}: expected {n_writes} source writes, saw {len(sb.src_writes)}")
    sb.check_write_chain(tag)
    for i, (addr, data) in enumerate(sb.accepted_writes):
        assert addr == SAFE_ADDR and data == (i & 0xFF), (
            f"{tag}: write #{i} corrupted: addr=0x{addr:02X} data=0x{data:02X}")


# ---------------------------------------------------------------------------
# 3. Continuous burst writes
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_continuous_burst(dut):
    """One CS-low frame, all consecutive addresses (0x30-0x3F), no
    inter-byte gaps. Count source bytes vs destination events, and verify
    address/data ordering end to end."""
    tag = "continuous_burst"
    await _bringup(dut)
    sb = _attach_scoreboard(dut)

    half_ns = 50.0  # 10 MHz
    pattern = [0xA0 + i for i in range(BURST_LEN)]
    await spi_frame(dut, [BURST_BASE & 0x7F] + pattern, half_ns,
                     cs_lead_ns=half_ns, cs_trail_ns=half_ns)
    await _settle(dut, 64)

    assert len(sb.src_writes) == BURST_LEN, (
        f"{tag}: expected {BURST_LEN} source writes, saw {len(sb.src_writes)}")
    sb.check_write_chain(tag)
    for i, (addr, data) in enumerate(sb.accepted_writes):
        exp_addr = (BURST_BASE + i) & 0x7F
        assert addr == exp_addr and data == pattern[i], (
            f"{tag}: burst byte #{i}: expected addr=0x{exp_addr:02X} data=0x{pattern[i]:02X}, "
            f"got addr=0x{addr:02X} data=0x{data:02X}")

    # Cross-check against readback too.
    for i in range(BURST_LEN):
        got = await spi_read(dut, BURST_BASE + i)
        assert got == pattern[i], f"{tag}: readback mismatch at 0x{BURST_BASE + i:02X}"


# ---------------------------------------------------------------------------
# 4. Read-side-effect verification (PSRAM_DBG_DATA, 0x76)
# ---------------------------------------------------------------------------

async def _enable_psram_dbg(dut, timeout_polls=2000):
    await spi_write(dut, 0x70, 0x01)          # PSRAM_EN
    await spi_write(dut, 0x72, 0x00)          # DBG_ADDR[7:0]
    await spi_write(dut, 0x73, 0x00)          # DBG_ADDR[15:8]
    await spi_write(dut, 0x74, 0x00)          # DBG_ADDR[22:16]
    await spi_write(dut, 0x75, 0x03)          # RD_TRIG | AUTO_INC
    for _ in range(timeout_polls):
        if not ((await spi_read(dut, 0x75)) & 0x80):
            return
        await Timer(CLK_NS, unit="ns")
    raise AssertionError("PSRAM debug fetch never cleared DBG_BUSY")


@cocotb.test()
async def test_read_side_effect(dut):
    """Repeatedly read PSRAM_DBG_DATA (0x76). One reg_re per returned byte,
    address stays 0x76, no event lost when CS rises immediately after the
    byte, no duplicate debug FIFO pop (dbg_data_pop is combinationally
    spi_reg_re && addr==0x76, so the reg_re scoreboard chain covers it)."""
    tag = "read_side_effect"
    await _bringup(dut)
    # Scoreboard is attached AFTER setup: _enable_psram_dbg's own busy-poll
    # reads register 0x75 over SPI, which legitimately produces its own
    # source/dst read events -- those must not be counted against the 32
    # dedicated 0x76 reads under test below.
    await _enable_psram_dbg(dut)
    sb = _attach_scoreboard(dut)

    half_ns = 50.0  # 10 MHz
    n_reads = 32
    for i in range(n_reads):
        # CS raised immediately (minimum trail) after the last data bit.
        rx, bits = await spi_frame(dut, [0x80 | (0x76 & 0x7F), 0xFF], half_ns,
                                    cs_lead_ns=half_ns, cs_trail_ns=1.0)
        assert bits == 16, f"{tag}: read #{i} frame truncated ({bits} bits)"

    await _settle(dut, 64)

    assert len(sb.src_reads) == n_reads, (
        f"{tag}: expected {n_reads} source read bytes, saw {len(sb.src_reads)}")
    sb.check_read_chain(tag)
    for i, addr in enumerate(sb.dst_re):
        assert addr == 0x76, f"{tag}: dst reg_re #{i} address drifted to 0x{addr:02X}"


@cocotb.test()
async def test_read_side_effect_continuous_burst(dut):
    """Continuous CS-low read burst at PSRAM_DBG_DATA (0x76): a single command
    byte followed directly by many data bytes under one HOST_CS assertion --
    unlike test_read_side_effect above, which re-asserts CS for every byte
    pair. NO_INC_ADDR must hold cur_addr at 0x76 for every byte of the burst
    (the burst auto-increment path is never taken), and each data byte must
    still produce exactly one reg_re event even though the burst runs past
    the 8-byte debug buffer boundary where AUTO_INC (DBG_CTRL bit 1, set by
    _enable_psram_dbg) kicks off a refetch and dbg_busy stalls the PSRAM-side
    data (that stall is a psram_buf_ctrl content concern, not a transport
    one -- reg_re/cur_addr must not glitch because of it)."""
    tag = "read_side_effect_continuous_burst"
    await _bringup(dut)
    # Scoreboard attached after setup for the same reason as test_read_side_effect.
    await _enable_psram_dbg(dut)
    sb = _attach_scoreboard(dut)

    half_ns = 50.0  # 10 MHz
    n_reads = 16    # spans the 8-byte dbg_buf boundary (dbg_idx wraps once)
    tx_bytes = [0x80 | (0x76 & 0x7F)] + [0xFF] * n_reads
    rx, bits = await spi_frame(dut, tx_bytes, half_ns,
                                cs_lead_ns=half_ns, cs_trail_ns=half_ns)
    assert bits == 8 * (1 + n_reads), f"{tag}: frame truncated ({bits} bits)"

    await _settle(dut, 64)

    assert len(sb.src_reads) == n_reads, (
        f"{tag}: expected {n_reads} source read events from one continuous "
        f"burst, saw {len(sb.src_reads)}")
    for i, addr in enumerate(sb.src_reads):
        assert addr == 0x76, (
            f"{tag}: source read #{i} address drifted to 0x{addr:02X} -- "
            f"NO_INC_ADDR must hold for the whole burst, not just across "
            f"separate frames")
    sb.check_read_chain(tag)
    for i, addr in enumerate(sb.dst_re):
        assert addr == 0x76, f"{tag}: dst reg_re #{i} address drifted to 0x{addr:02X}"

    # Slave must still work normally afterward.
    await spi_write(dut, SAFE_ADDR, 0x5C)
    got = await spi_read(dut, SAFE_ADDR)
    assert got == 0x5C, f"{tag}: slave did not recover after continuous burst"


# ---------------------------------------------------------------------------
# 5. Reset interruption tests
# ---------------------------------------------------------------------------

async def _release_reset(dut, cycles=4):
    await Timer(cycles * CLK_NS, unit="ns")
    dut.RESETB.value = 1
    await Timer(cycles * CLK_NS, unit="ns")


@cocotb.test()
async def test_reset_interruption(dut):
    """Assert RESETB mid-command-byte, mid-write-data-byte, mid-toggle-sync,
    and mid-extended-reg_we. After release, no phantom write must have
    landed in reg_bank, and the first new transaction must succeed clean."""
    tag = "reset_interruption"
    await _bringup(dut)
    sb = _attach_scoreboard(dut)
    half_ns = 50.0  # 10 MHz

    cases = [
        ("command_byte", dict(reset_at_bit=3)),   # mid command byte
        ("write_data_byte", dict(reset_at_bit=11)),  # mid data byte (8..15)
    ]

    for case_tag, kwargs in cases:
        sb.clear()
        dut.RESETB.value = 1
        _idle_inputs(dut)
        await Timer(4 * CLK_NS, unit="ns")

        await spi_frame(dut, [SAFE_ADDR & 0x7F, 0x5A], half_ns, **kwargs)
        # RESETB was pulled low mid-frame above; hold it, then release.
        await _release_reset(dut)
        await _settle(dut, 32)

        assert not sb.accepted_writes, (
            f"{tag}/{case_tag}: phantom accepted write after reset interruption: "
            f"{sb.accepted_writes}")

        # First clean transaction post-reset must succeed.
        await spi_write(dut, SAFE_ADDR, 0x77)
        got = await spi_read(dut, SAFE_ADDR)
        assert got == 0x77, (
            f"{tag}/{case_tag}: first post-reset transaction failed: got 0x{got:02X}")

    # Pending-toggle-synchronization / extended-reg_we windows: complete a
    # full write byte pair, then assert reset at increasing delays through
    # the toggle synchroniser + 2-cycle-wide reg_we window (0..8 clk_32m
    # cycles after the 8th SCK edge).
    for delay_cycles in range(0, 9):
        sb.clear()
        dut.RESETB.value = 1
        _idle_inputs(dut)
        await Timer(4 * CLK_NS, unit="ns")

        dut.HOST_CS.value = 0
        await Timer(half_ns, unit="ns")
        for tx in (SAFE_ADDR & 0x7F, 0x99):
            for bit in range(7, -1, -1):
                dut.SPI_MOSI.value = (tx >> bit) & 1
                await Timer(half_ns, unit="ns")
                dut.SPI_SCK.value = 1
                await Timer(half_ns, unit="ns")
                dut.SPI_SCK.value = 0
        dut.HOST_CS.value = 1

        for _ in range(delay_cycles):
            await RisingEdge(dut.IQ_CLK)
        dut.RESETB.value = 0
        await _release_reset(dut)
        await _settle(dut, 32)

        # Either the write landed cleanly (reset came after capture) or it
        # didn't land at all -- never a corrupted address/data pair.
        for addr, data in sb.accepted_writes:
            assert addr == SAFE_ADDR and data == 0x99, (
                f"{tag}/pending_sync(delay={delay_cycles}): corrupted accepted write "
                f"addr=0x{addr:02X} data=0x{data:02X}")

        await spi_write(dut, SAFE_ADDR, 0x77)
        got = await spi_read(dut, SAFE_ADDR)
        assert got == 0x77, (
            f"{tag}/pending_sync(delay={delay_cycles}): first post-reset transaction failed")


# ---------------------------------------------------------------------------
# 6. Aborted-frame tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_aborted_frame(dut):
    """Raise CS after every bit position 0-15 of a two-byte write frame.
    A partial command or data byte must not produce a write or read-side-
    effect event (the RTL only latches on the 8th rising SCK edge of each
    byte, so no abort inside bits 0-15 can complete the data byte)."""
    tag = "aborted_frame"
    await _bringup(dut)
    sb = _attach_scoreboard(dut)
    half_ns = 50.0  # 10 MHz

    for bit_pos in range(0, 16):
        sb.clear()
        await spi_frame(dut, [SAFE_ADDR & 0x7F, 0xE5], half_ns,
                         abort_after_bits=bit_pos)
        await _settle(dut, 32)
        assert not sb.src_writes, (
            f"{tag}: bit_pos={bit_pos} produced a source write event ({sb.src_writes})")
        assert not sb.dst_we, (
            f"{tag}: bit_pos={bit_pos} produced a dst reg_we event ({sb.dst_we})")
        assert not sb.accepted_writes, (
            f"{tag}: bit_pos={bit_pos} produced an accepted reg_bank write ({sb.accepted_writes})")

    # Confirm the slave still works normally afterward (no latent corruption).
    await spi_write(dut, SAFE_ADDR, 0x42)
    got = await spi_read(dut, SAFE_ADDR)
    assert got == 0x42, f"{tag}: slave did not recover after abort sweep"


# ---------------------------------------------------------------------------
# 7. Clock-limit sweep
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_clock_limit_sweep(dut):
    """Run at several SCLK rates. Only <=10 MHz is required to pass; the
    above-spec rate is exercised for diagnostic margin only and its result
    is logged, not asserted."""
    tag = "clock_limit_sweep"
    await _bringup(dut)

    # (label, half-period ns, must_pass)
    rates = [
        ("100kHz", 5000.0, True),
        ("1MHz", 500.0, True),
        ("8MHz", 62.5, True),
        ("10MHz", 50.0, True),
        ("12MHz_diagnostic", 41.7, False),
    ]

    for label, half_ns, must_pass in rates:
        data = 0xB6
        rx, bits = await spi_frame(dut, [SAFE_ADDR & 0x7F, data], half_ns,
                                    cs_lead_ns=half_ns, cs_trail_ns=half_ns)
        await _settle(dut, 32)
        got = await spi_read(dut, SAFE_ADDR)
        ok = (bits == 16) and (got == data)
        if must_pass:
            assert ok, f"{tag}: {label} failed (bits={bits}, got=0x{got:02X})"
        else:
            dut._log.info(f"{tag}: {label} (above 10 MHz spec) result={'OK' if ok else 'FAIL'} "
                           f"-- diagnostic only, not asserted")


# ---------------------------------------------------------------------------
# 8. W1P exactly-once sweep
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_w1p_exactly_once(dut):
    """Exercise every write-one-pulse register with minimum CS hold.
    Duplicate destination strobes show up far more clearly on a W1P bit
    than on an ordinary storage register (a double-pulse re-arms an FSM
    instead of silently overwriting the same value)."""
    tag = "w1p_exactly_once"
    await _bringup(dut)
    sb = _attach_scoreboard(dut)
    half_ns = 50.0  # 10 MHz

    for reg_addr in W1P_REGS:
        for i in range(20):
            sb.clear()
            await spi_frame(dut, [reg_addr & 0x7F, 0x01], half_ns,
                             cs_lead_ns=half_ns, cs_trail_ns=half_ns)
            await _settle(dut, 32)
            assert len(sb.src_writes) == 1, (
                f"{tag}: 0x{reg_addr:02X} iter {i}: {len(sb.src_writes)} source writes, expected 1")
            sb.check_write_chain(tag)
            assert sb.accepted_writes[0] == (reg_addr, 0x01), (
                f"{tag}: 0x{reg_addr:02X} iter {i}: unexpected accepted write {sb.accepted_writes[0]}")
