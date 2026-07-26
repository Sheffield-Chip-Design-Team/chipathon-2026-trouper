"""
test_dbg_amask_wrap.py -- debug-fetch address wraparound at the 8 MB AMASK
boundary.

Traceability: verification-plan row #21
(planning/verification-plan/psram-buf-ctrl-verification-plan.md), which
cites "Open Risks #25 (same bug class)". Checked against
planning/Open Risks.md: item #25 (~857-897, "trouper_top dead logic + minor
RTL hygiene") is unrelated -- packet_ctrl_fsm dead-signal cleanup and the
psram_abort reachability proof, nothing about addressing or the 8 MB
boundary. The actual 2^23/AMASK wraparound material -- "the replay backlog
would need to land within 8 bytes of a 2^23 wraparound... still holding
unchanged" -- lives under Open Risks item #32's formal-verification-effort
note (~1069-1143). This is very likely a stale/mistyped cross-reference in
the plan row rather than a real #25 connection; noted here (and will be
flagged back to the plan doc) so a future reader isn't sent to the wrong
section. The test itself is unaffected either way -- it exercises the RTL
directly, not the citation.

psram_buf_ctrl.v's debug-fetch address register (`dbg_addr_cur`, 23 bits,
PSRAM_DBG_ADDR_LO/MID/HI at 0x72-0x74) is masked with `& AMASK`
(23'h7FFFFF, 8 MB) on every AUTO_INC advance (~378: `dbg_addr_cur <=
(dbg_addr_cur + 23'd8) & AMASK`). This test drives a debug fetch to the
very last 8-byte-aligned sample below the 8 MB boundary (0x7FFFF8), lets
AUTO_INC step past it, and confirms:
  (a) the address genuinely wraps to 0x000000, not a corrupted/truncated
      value (e.g. stuck at the unrepresentable 0x800000, or silently not
      advancing at all);
  (b) `dbg_addr_cur` -- the register that directly drives the QPI address
      nibbles during the burst (psram_buf_ctrl.v sub 2-7:
      `sio_out<=dbg_addr_cur[22:20]` etc.) -- holds the correctly-wrapped
      value STABLY for the whole burst, not just transiently;
  (c) both fetches (pre-wrap and post-wrap) return bit-exact PSRAM content,
      with distinct known patterns pre-loaded into the model at BOTH
      addresses so a wrong-address read is guaranteed to mismatch rather
      than accidentally "passing" against a shared default value;
  (d) both fetches take the same fixed 31-sub-cycle QPI burst length as any
      other debug fetch (cf. test_dbg_write_collision.py) -- no bogus
      extra/short burst around the wrap.

PSRAM_EN is turned off immediately after INIT_DONE. Debug reads are NOT
gated on PSRAM_EN (only on qspi_owner / packet_active / dbg_fetch_busy /
!qe_init_done -- psram_buf_ctrl.v ~218/390), so this freezes the circular
capture (wr_ptr parked) without blocking debug reads -- otherwise live
capture writes would clobber the byte-0 sample this test depends on (wr_ptr
starts at 0 on reset), and honestly reaching the real 0x7FFFF8 region
through actual capture traffic would take ~1M samples (>2 s of simulated
time) to arrive there. The psram_model's own memory (`dut.u_psram.mem[]`,
the environment model, NOT the DUT under test) is then pre-loaded directly
with the two known patterns. The model itself only backs 64 KB
(ADDR_BITS=16 in tb_trouper_cocotb.v) and masks every address to its own
low 16 bits internally -- patterns are pre-loaded at those SAME
model-masked addresses. That is a memory-footprint convenience of the test
environment, unrelated to the DUT's own 23-bit AMASK logic under test here
(0x7FFFF8 and 0x000000 mask to distinct model addresses, 0xFFF8 and
0x0000, so the compare stays meaningful).
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from test_trouper_top import CLK_NS, spi_read, spi_write

MODEL_ADDR_BITS = 16
MODEL_MASK = (1 << MODEL_ADDR_BITS) - 1
FETCH_SUBCYCLES = 31

ADDR_PRE_WRAP = 0x7FFFF8    # last 8-byte-aligned sample below the 8 MB boundary
ADDR_POST_WRAP = 0x000000   # AUTO_INC target: (ADDR_PRE_WRAP + 8) & AMASK

PATTERN_PRE = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]
PATTERN_POST = [0x91, 0xA2, 0xB3, 0xC4, 0xD5, 0xE6, 0xF7, 0x08]


async def _poke_model(dut, raw_addr, data_bytes):
    """Write known bytes directly into the psram_model's memory (test
    environment, not the DUT) at the address it will actually use."""
    masked = raw_addr & MODEL_MASK
    for i, b in enumerate(data_bytes):
        idx = 2 * (masked + i)
        dut.u_psram.mem[idx].value = (b >> 4) & 0xF
        dut.u_psram.mem[idx + 1].value = b & 0xF
    await Timer(1, unit="ns")


async def _burst_monitor(dut, bursts, max_cycles):
    """Background task: records every dbg_mode&&qpi_busy burst's start
    cycle, length, and the set of dbg_addr_cur values observed while it was
    active (a singleton set means the address register was stable
    throughout -- a set with >1 or a wrong value is a real finding)."""
    prev_active = 0
    cur_start = None
    cur_addr_samples = None
    for n in range(max_cycles):
        await RisingEdge(dut.IQ_CLK)
        dbg_mode = int(dut.u_dut.u_psram.dbg_mode.value)
        qpi_busy = int(dut.u_dut.u_psram.qpi_busy.value)
        active = dbg_mode & qpi_busy
        if prev_active == 0 and active == 1:
            cur_start = n
            cur_addr_samples = set()
        if active == 1:
            cur_addr_samples.add(int(dut.u_dut.u_psram.dbg_addr_cur.value))
        if prev_active == 1 and active == 0 and cur_start is not None:
            bursts.append({"start": cur_start, "len": n - cur_start,
                            "addr_samples": cur_addr_samples})
            cur_start = None
        prev_active = active


@cocotb.test()
async def test_dbg_addr_amask_wrap(dut):
    tag = "amask_wrap"

    cocotb.start_soon(Clock(dut.IQ_CLK, CLK_NS, unit="ns").start())
    dut.HOST_CS.value   = 1
    dut.SPI_MOSI.value  = 0
    dut.SPI_SCK.value   = 0
    dut.IQ_DATA_I.value = 0
    dut.IQ_DATA_Q.value = 0
    dut.RESETB.value    = 0
    await Timer(4 * CLK_NS, unit="ns")
    dut.RESETB.value = 1
    await Timer(8 * CLK_NS, unit="ns")

    await spi_read(dut, 0x00)
    await spi_read(dut, 0x09)
    await spi_write(dut, 0x09, 7)
    await spi_write(dut, 0x0A, 0)

    await spi_write(dut, 0x70, 0x01)   # PSRAM_EN -> triggers init
    init_ok = False
    for _ in range(500):
        await Timer(8 * CLK_NS, unit="ns")
        if (await spi_read(dut, 0x71)) & 0x08:
            init_ok = True
            break
    assert init_ok, f"{tag}: PSRAM INIT_DONE never set"

    # Freeze the circular capture (see module docstring); debug reads stay
    # usable throughout since they are not gated on PSRAM_EN.
    await spi_write(dut, 0x70, 0x00)
    assert int(dut.u_dut.u_psram.packet_active.value) == 0, \
        f"{tag}: packet_active unexpectedly asserted -- debug reads would be blocked"

    await _poke_model(dut, ADDR_PRE_WRAP, PATTERN_PRE)
    await _poke_model(dut, ADDR_POST_WRAP, PATTERN_POST)
    # Sanity: the two addresses really are distinguishable in the model's
    # masked footprint, and the patterns differ -- otherwise a wrong-address
    # read could accidentally read back as "correct".
    assert (ADDR_PRE_WRAP & MODEL_MASK) != (ADDR_POST_WRAP & MODEL_MASK)
    assert PATTERN_PRE != PATTERN_POST

    # -- program the pre-wrap debug address (0x72-0x74) ----------------------
    await spi_write(dut, 0x72, ADDR_PRE_WRAP & 0xFF)
    await spi_write(dut, 0x73, (ADDR_PRE_WRAP >> 8) & 0xFF)
    await spi_write(dut, 0x74, (ADDR_PRE_WRAP >> 16) & 0x7F)
    addr_rb = (((await spi_read(dut, 0x74)) & 0x7F) << 16) | \
              ((await spi_read(dut, 0x73)) << 8) | (await spi_read(dut, 0x72))
    assert addr_rb == ADDR_PRE_WRAP, \
        f"{tag}: PSRAM_DBG_ADDR readback 0x{addr_rb:06X} != 0x{ADDR_PRE_WRAP:06X}"
    assert int(dut.u_dut.u_psram.dbg_mode.value) == 0, \
        f"{tag}: dbg_mode already 1 before RD_TRIG was ever issued -- monitor baseline invalid"

    # -- background cycle-accurate burst monitor, running for the rest of
    # the test (both the pre-wrap RD_TRIG fetch and the AUTO_INC-triggered
    # post-wrap refetch, which only launches once we pop the 8th byte below)
    bursts = []
    cocotb.start_soon(_burst_monitor(dut, bursts, max_cycles=20000))

    await spi_write(dut, 0x75, 0x03)   # RD_TRIG | AUTO_INC

    for _ in range(100):
        if not ((await spi_read(dut, 0x75)) & 0x80):
            break
    else:
        assert False, f"{tag}: DBG_BUSY never cleared after the pre-wrap RD_TRIG"

    got_pre = [await spi_read(dut, 0x76) for _ in range(8)]
    assert got_pre == PATTERN_PRE, \
        f"{tag}: pre-wrap sample @0x{ADDR_PRE_WRAP:06X}: read {got_pre} != {PATTERN_PRE}"

    # 8th pop above re-arms the AUTO_INC fetch at (ADDR_PRE_WRAP+8)&AMASK
    for _ in range(100):
        if not ((await spi_read(dut, 0x75)) & 0x80):
            break
    else:
        assert False, f"{tag}: DBG_BUSY never cleared after the AUTO_INC (wrapped) fetch"

    got_post = [await spi_read(dut, 0x76) for _ in range(8)]
    assert got_post == PATTERN_POST, \
        f"{tag}: post-wrap sample @0x{ADDR_POST_WRAP:06X}: read {got_post} != {PATTERN_POST} " \
        f"-- AUTO_INC wraparound returned wrong/corrupted content"

    # -- now inspect the burst monitor's record of both QPI transactions.
    # AUTO_INC is still set, so draining got_post's 8th byte above also
    # re-arms a THIRD fetch (at ADDR_POST_WRAP+8) that the monitor may catch
    # before this coroutine gets scheduled again -- expected background
    # noise, not part of what this test checks, so >=2 (not ==2) is right. --
    assert len(bursts) >= 2, \
        f"{tag}: expected at least 2 debug-fetch bursts (pre-wrap RD_TRIG + AUTO_INC " \
        f"post-wrap refetch), got {len(bursts)}: {bursts}"
    b0, b1 = bursts[0], bursts[1]

    assert b0["len"] == FETCH_SUBCYCLES, \
        f"{tag}: pre-wrap burst took {b0['len']} sub-cycles, expected fixed " \
        f"{FETCH_SUBCYCLES} -- bogus/truncated QSPI burst"
    assert b1["len"] == FETCH_SUBCYCLES, \
        f"{tag}: post-wrap burst took {b1['len']} sub-cycles, expected fixed " \
        f"{FETCH_SUBCYCLES} -- bogus/truncated QSPI burst"

    assert b0["addr_samples"] == {ADDR_PRE_WRAP}, \
        f"{tag}: pre-wrap burst's dbg_addr_cur samples were {b0['addr_samples']}, " \
        f"expected a stable single value 0x{ADDR_PRE_WRAP:06X} for the whole burst"
    assert b1["addr_samples"] == {ADDR_POST_WRAP}, \
        f"{tag}: post-wrap burst's dbg_addr_cur samples were {b1['addr_samples']}, " \
        f"expected a stable single value 0x{ADDR_POST_WRAP:06X} -- the AUTO_INC step " \
        f"(dbg_addr_cur+8)&AMASK from 0x{ADDR_PRE_WRAP:06X} did not wrap correctly"

    dut._log.info(f"{tag}: PASS -- debug-fetch AUTO_INC wraps 0x{ADDR_PRE_WRAP:06X} -> "
                  f"0x{ADDR_POST_WRAP:06X} cleanly: correct masked address (register stable "
                  f"across each fixed {FETCH_SUBCYCLES}-sub-cycle burst, no bogus/short/extra "
                  f"burst), bit-exact content on both sides of the 8 MB boundary")
