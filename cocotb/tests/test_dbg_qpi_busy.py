"""
test_dbg_qpi_busy.py -- Open Risk #67.

debug_probe_mux group 101 (G_PSRAM), selector 0, presents
{d0=psram_init_done, d1=qpi_busy}. trouper_top.v:1201 wires that qpi_busy input
to `|psram_state_dbg`. Once PSRAM init completes the FSM sits in S_WRITE (state
2) / S_REPLAY (state 3), both nonzero, so the probe reads busy continuously and
cannot show individual QPI transactions -- a first-silicon observability
failure. psram_buf_ctrl.v has the real per-transaction `qpi_busy` register
(line 231) but never exports it.

Bench: point the shared IRQ_OUT/DBG1 pad (DBG_CTRL1) at group 101 / sel 0, run
the decimator so psram_buf_ctrl issues S_WRITE capture transactions, and sample
the pad against the internal qpi_busy read hierarchically. The internal signal
must go low between bursts; the probe should track it. EXPECTED TO FAIL: the
probe is stuck at 1.

Top-level bench, TOPLEVEL = tb_trouper_cocotb.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from test_trouper_top import CLK_NS, spi_read, spi_write, release_rx_hold, sdm_driver

REG_DBG_CTRL1  = 0x06
REG_PSRAM_CTRL = 0x70
REG_PSRAM_STAT = 0x71

EN = 0x80
G_PSRAM = 5


def ctrl(group, ant=0, sel=0, en=True):
    return (EN if en else 0) | ((group & 0x7) << 4) | ((ant & 0x3) << 2) | (sel & 0x3)


@cocotb.test()
async def test_qpi_busy_probe_stuck_after_init(dut):
    tag = "dbg_qpi_busy"

    cocotb.start_soon(Clock(dut.IQ_CLK, CLK_NS, unit="ns").start())
    dut.HOST_CS.value   = 1
    dut.SPI_SCK.value   = 0
    dut.SPI_MOSI.value  = 0
    dut.IQ_DATA_I.value = 0
    dut.IQ_DATA_Q.value = 0
    dut.RESETB.value    = 0
    await Timer(4 * CLK_NS, unit="ns")
    dut.RESETB.value = 1
    await Timer(8 * CLK_NS, unit="ns")

    await spi_read(dut, 0x00)
    await spi_write(dut, 0x09, 7)
    await spi_write(dut, 0x0A, 0)
    await spi_write(dut, 0x0C, 0x01)
    await spi_write(dut, 0x0D, 0x00)
    await spi_write(dut, 0x0E, 0x00)

    # shared IRQ_OUT/DBG1 pad -> PSRAM group, selector 0 (d1 = qpi_busy). Write
    # while idle (DBG_CTRL is idle-only gated).
    await spi_write(dut, REG_DBG_CTRL1, ctrl(G_PSRAM, sel=0, en=True))
    assert (await spi_read(dut, REG_DBG_CTRL1)) == ctrl(G_PSRAM, sel=0, en=True), \
        f"{tag}: DBG_CTRL1 not stored"

    await release_rx_hold(dut)

    # bring PSRAM up
    await spi_write(dut, REG_PSRAM_CTRL, 0x01)
    for _ in range(500):
        await Timer(8 * CLK_NS, unit="ns")
        if (await spi_read(dut, REG_PSRAM_STAT)) & 0x08:
            break
    assert (await spi_read(dut, REG_PSRAM_STAT)) & 0x08, f"{tag}: PSRAM INIT_DONE never set"

    # run the decimator so psram_buf_ctrl issues S_WRITE capture transactions
    cocotb.start_soon(sdm_driver(dut, 7, 250))
    await Timer(30 * 64 * CLK_NS, unit="ns")     # let iq_valid start pulsing

    # -- sample the probe pad vs the real internal transaction-busy level ---
    probe_low = 0
    internal_low = 0
    both = mismatch = 0
    N = 40_000
    for _ in range(N):
        await RisingEdge(dut.IQ_CLK)
        probe = int(dut.IRQ_OUT.value) & 1
        real = int(dut.u_dut.u_psram.qpi_busy.value) & 1
        state = int(dut.u_dut.psram_state_dbg.value)
        probe_low += (probe == 0)
        internal_low += (real == 0)
        if state != 0 and probe == real:
            both += 1
        elif state != 0:
            mismatch += 1

    dut._log.info(f"{tag}: over {N} cycles -- internal qpi_busy low on {internal_low}, "
                  f"probe pad low on {probe_low}; probe==internal on {both}, differs on {mismatch}")

    assert internal_low > 0, (
        f"{tag}: the internal psram_buf_ctrl.qpi_busy never went low over {N} cycles -- "
        f"expected bursty QPI transactions in S_WRITE; the stimulus is not exercising the bus")

    assert probe_low > 0, (
        f"{tag}: the debug probe (group 101 / sel 0, IRQ_OUT/DBG1 pad) never read 0 over "
        f"{N} cycles while the real qpi_busy was low on {internal_low} of them -- it is wired "
        f"to `|psram_state_dbg` and stuck busy for every post-init state (Open Risk #67)")

    # tighter: the probe should mostly agree with the real level
    assert mismatch < both, (
        f"{tag}: debug probe disagrees with the real qpi_busy on {mismatch} of "
        f"{mismatch + both} post-init cycles -- not a usable transaction-activity probe "
        f"(Open Risk #67)")
