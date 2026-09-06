"""Pin-level sticky IRQ behavior.

The register bank tests prove IRQ_STATUS.  This test binds that state to the
physical output: IRQ_OUT must assert for either sticky source, remain asserted
while one source is uncleared, and return low only once the final sticky bit
is cleared.  (It also covered IRQ_GROUPER until that pin was removed with the
rest of the Grouper boundary on 2026-09-01.)
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from test_trouper_top import CLK_NS, spi_read, spi_write, release_rx_hold
from test_noise_trig import _StimMode, _noise_or_cw_driver


async def _assert_pins(dut, expected, where):
    irq_out = int(dut.IRQ_OUT.value)
    assert irq_out == expected, \
        f"{where}: IRQ_OUT={irq_out}, expected {expected}"


@cocotb.test()
async def test_irq_pins_sticky_clear(dut):
    """NOISE_READY and TRAINING_DONE prove pin OR/level/clear semantics."""
    tag = "irq_pins"
    sf = 7
    # SF7/BW250 -> M=256 output samples, 64 IQ clocks/sample.
    sym_ns = 256 * 64 * CLK_NS

    cocotb.start_soon(Clock(dut.IQ_CLK, CLK_NS, unit="ns").start())
    dut.HOST_CS.value = 1
    dut.SPI_MOSI.value = 0
    dut.SPI_SCK.value = 0
    dut.IQ_DATA_I.value = 0
    dut.IQ_DATA_Q.value = 0
    dut.RESETB.value = 0
    await Timer(4 * CLK_NS, unit="ns")
    await _assert_pins(dut, 0, f"{tag}: reset")
    dut.RESETB.value = 1
    await Timer(8 * CLK_NS, unit="ns")

    mode = _StimMode()                 # default = independent noise
    cocotb.start_soon(_noise_or_cw_driver(dut, mode))
    await spi_read(dut, 0x00)          # SPI-domain settle
    assert (await spi_read(dut, 0x02)) == 0, f"{tag}: IRQ_STATUS not reset"
    await spi_write(dut, 0x09, sf)
    await spi_write(dut, 0x0A, 0x00)   # BW250
    await release_rx_hold(dut)
    await Timer(4 * sym_ns, unit="ns")

    # PSRAM remains disabled: no SC lock can complicate this clean noise
    # window.  Completion sets both TRAINING_DONE[1] and NOISE_READY[4].
    await spi_write(dut, 0x1F, 0x01)
    status = 0
    for _ in range(20):
        await Timer(sym_ns, unit="ns")
        status = await spi_read(dut, 0x02)
        if (status & 0x12) == 0x12:
            break
    assert (status & 0x12) == 0x12, f"{tag}: expected DONE+NOISE_READY, got 0x{status:02X}"
    await _assert_pins(dut, 1, f"{tag}: both sticky sources set")

    # IRQ_OUT shares its pad with DBG1.  A real pending interrupt must remain
    # sticky while the debug selector owns the pad, then reappear as soon as
    # DBG_CTRL1.EN returns low.  GROUP=000 deliberately drives debug value 0,
    # making an accidentally unmuxed IRQ_OUT visible here.
    await spi_write(dut, 0x06, 0x80)    # DBG_CTRL1: EN=1, reserved/off group
    await Timer(4 * CLK_NS, unit="ns")
    assert (await spi_read(dut, 0x02)) & 0x12 == 0x12, \
        f"{tag}: debug override changed pending IRQ_STATUS"
    await _assert_pins(dut, 0, f"{tag}: DBG1 overrides asserted IRQ")

    await spi_write(dut, 0x06, 0x00)    # EN=0: hand shared pad back to IRQ
    await Timer(4 * CLK_NS, unit="ns")
    await _assert_pins(dut, 1, f"{tag}: pending IRQ returns after DBG1 release")

    # Clearing only one source must leave both pins asserted due to the other.
    await spi_write(dut, 0x03, 0x10)
    status = await spi_read(dut, 0x02)
    assert (status & 0x12) == 0x02, f"{tag}: selective clear lost/kept wrong bits 0x{status:02X}"
    await _assert_pins(dut, 1, f"{tag}: TRAINING_DONE still sticky")

    # Clear the final source: both output pins must deassert and must stay low
    # even though training_done itself remains a level until the next trigger.
    await spi_write(dut, 0x03, 0x02)
    assert (await spi_read(dut, 0x02)) == 0, f"{tag}: IRQ_STATUS did not clear"
    for _ in range(16):
        await RisingEdge(dut.IQ_CLK)
        await _assert_pins(dut, 0, f"{tag}: post-clear dwell")
