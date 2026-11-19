"""Padring integration smoke + one full packet, all through A40_ACV_padring.v
and the real gf180mcu_fd_io cell models (icarus).

The DUT here is `tb_trouper_padring` -- same trouper_top / psram_model
instances and the same top-level driving-side port names as
`tb_trouper_cocotb`, so the `test_trouper_top` helpers work unchanged.  What
differs is the path: every signal now goes through its real pad cell.

  1. reset + CHIP_ID/CHIP_REV readback   -- in_s SPI in -> core -> bi_t MISO out
  2. PSRAM QPI init                       -- 4x bi_t SIO turnaround + IE!=OE guard
  3. sc_lock on the CW stimulus           -- 9x in_c IQ path -> decimator -> SC
  4. one full end-to-end packet           -- sc_lock -> training -> weights ->
                                             MRC -> REMOD toggling through bi_t
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer

from test_trouper_top import CLK_NS, spi_read, spi_write, release_rx_hold, run_scenario


async def _reset(dut):
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


@cocotb.test()
async def test_padring_reset_and_id(dut):
    """SPI round-trips N09/N10/N11 (in_s) -> core -> N12 (bi_t) through the padring."""
    await _reset(dut)
    await spi_read(dut, 0x00)          # prime (first read may be stale)
    chip_id = await spi_read(dut, 0x00)
    chip_rev = await spi_read(dut, 0x01)
    assert chip_id == 0xA7, f"CHIP_ID=0x{chip_id:02X} through the padring (expected 0xA7)"
    assert chip_rev == 0x01, f"CHIP_REV=0x{chip_rev:02X} through the padring (expected 0x01)"


@cocotb.test()
async def test_padring_psram_qpi_init(dut):
    """PSRAM QE init completes with read data returning through the 4 bi_t SIO pads."""
    await _reset(dut)
    await spi_read(dut, 0x00)
    await spi_write(dut, 0x09, 7)      # SF7
    await spi_write(dut, 0x0A, 0)      # BW 250 kHz
    await release_rx_hold(dut)
    await spi_write(dut, 0x70, 0x01)   # PSRAM_EN

    init_ok = False
    for _ in range(500):
        await Timer(8 * CLK_NS, unit="ns")
        if (await spi_read(dut, 0x71)) & 0x08:
            init_ok = True
            break
    assert init_ok, "PSRAM INIT_DONE never set through the padring"
    # SAMPLE_SKIP sticky must be clean straight out of init.
    assert not ((await spi_read(dut, 0x71)) & 0x04), "PSRAM SAMPLE_SKIP set after init"


@cocotb.test()
async def test_padring_sc_lock_cw(dut):
    """IQ path W13..W21 (in_c) -> decimator -> SC detector locks on the CW stimulus."""
    await run_scenario(dut, sf=7, bw_khz=250, full=False)


@cocotb.test()
async def test_padring_one_packet(dut):
    """Full chain through the padring: sc_lock + training + n_acc + EGC weights +
    REMOD_A_{I,Q} toggling + register spot-checks."""
    await run_scenario(dut, sf=7, bw_khz=250, full=True)
