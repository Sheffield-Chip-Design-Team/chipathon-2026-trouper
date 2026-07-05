"""
test_bypass_antenna.py -- Open Risks #4 regression: bypass_ant must select
the LOWEST enabled antenna, not skip bit0.

trouper_top.v's bypass_ant mux originally tested active_antenna_en[1..3] and
fell back to 0, never actually testing bit0 first -- so with all antennas
enabled it selected antenna 1 instead of antenna 0. Fixed 2026-07-05.

active_antenna_en is latched from the ANTENNA_EN shadow register (MIMO_CTRL
0x08[7:4]) only on the sc_lock rising edge while the packet FSM is IDLE
(packet_ctrl_fsm.v ST_IDLE case) -- so each mask under test needs its own
full reset + drive-to-sc_lock cycle; writing ANTENNA_EN alone does not take
effect until the next lock. PSRAM is not required: the latch has no PSRAM
dependency (packet_ctrl_fsm.v is independent of psram_buf_ctrl.v).

bypass_ant is read directly off the internal wire (dut.u_dut.bypass_ant) --
it's a plain combinational assignment, computed regardless of MIMO_CTRL.MODE,
so this checks the mux logic itself without needing bypass mode's downstream
routing to be exercised.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer

from test_trouper_top import CLK_NS, spi_read, spi_write, sdm_driver


async def _check_bypass_ant(dut, antenna_en_mask, expected_bypass_ant):
    tag = f"ANTENNA_EN=0x{antenna_en_mask:X}"
    sf, bw_khz = 7, 250
    sample_shift = 1
    M = 1 << (sf + sample_shift)
    clk_per_iq = 64

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

    cocotb.start_soon(sdm_driver(dut, sf, bw_khz))

    # -- SPI settle -------------------------------------------------------
    await spi_read(dut, 0x00)
    await spi_read(dut, 0x09)

    # -- configure SF/BW, SC threshold (1 hit fires lock) -------------------
    await spi_write(dut, 0x09, sf & 0x0F)
    await spi_write(dut, 0x0A, 0)   # 250 kHz
    await spi_write(dut, 0x0C, 0x01)
    await spi_write(dut, 0x0D, 0x00)
    await spi_write(dut, 0x0E, 0x00)

    # -- write ANTENNA_EN shadow BEFORE lock so it latches on this packet ---
    await spi_write(dut, 0x08, (antenna_en_mask & 0x0F) << 4)
    mimo_rb = await spi_read(dut, 0x08)
    assert (mimo_rb >> 4) == antenna_en_mask, \
        f"{tag}: MIMO_CTRL readback ANTENNA_EN=0x{mimo_rb >> 4:X}"

    # -- enable PSRAM + wait INIT_DONE ---------------------------------------
    # Required: psram_buf_ctrl.v is the SC detector's delay line (replaces
    # frontend_buf_ctrl/on-chip SRAM) -- sc_lock can never fire without it,
    # since the correlator has no delayed sample to compare against until
    # qe_init_done. Omitting this was the bug in the first version of this
    # test (job 3275: "sc_lock never fired" on all 4 cases).
    await spi_write(dut, 0x70, 0x01)
    init_ok = False
    for _ in range(500):
        await Timer(8 * CLK_NS, unit="ns")
        if (await spi_read(dut, 0x71)) & 0x08:
            init_ok = True
            break
    assert init_ok, f"{tag}: PSRAM INIT_DONE never set"

    # -- poll sc_lock (IRQ_STATUS[0] at 0x02), triggers the FSM's IDLE->armed
    # latch of active_antenna_en <= antenna_en_shadow ----------------------
    sym_ns = M * clk_per_iq * CLK_NS
    lock_ok = False
    for _ in range(20):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x01:
            lock_ok = True
            break
    assert lock_ok, f"{tag}: sc_lock never fired"

    active_en = int(dut.u_dut.active_antenna_en.value)
    bypass_ant = int(dut.u_dut.bypass_ant.value)
    dut._log.info(f"{tag}: active_antenna_en=0x{active_en:X} "
                  f"bypass_ant={bypass_ant} (expected {expected_bypass_ant})")
    assert active_en == antenna_en_mask, \
        f"{tag}: active_antenna_en=0x{active_en:X} did not latch the shadow mask"
    assert bypass_ant == expected_bypass_ant, \
        f"{tag}: bypass_ant={bypass_ant}, expected lowest-enabled={expected_bypass_ant}"
    dut._log.info(f"{tag}: PASS")


@cocotb.test()
async def test_bypass_ant_all_enabled(dut):
    """All antennas enabled (reset-default shadow, 0xF) -> lowest enabled = 0.
    This is the exact case Open Risks #4 got wrong (returned 1)."""
    await _check_bypass_ant(dut, 0xF, 0)

@cocotb.test()
async def test_bypass_ant_skip_0(dut):
    """Antenna 0 disabled -> lowest enabled = 1."""
    await _check_bypass_ant(dut, 0xE, 1)

@cocotb.test()
async def test_bypass_ant_skip_01(dut):
    """Antennas 0,1 disabled -> lowest enabled = 2."""
    await _check_bypass_ant(dut, 0xC, 2)

@cocotb.test()
async def test_bypass_ant_only_3(dut):
    """Only antenna 3 enabled -> lowest (and only) enabled = 3."""
    await _check_bypass_ant(dut, 0x8, 3)
