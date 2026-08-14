"""
test_reg_reset_sweep.py -- full register-map reset-value sweep for reg_bank.

Traceability (planning/Traceability.md): TRPR-REG-001 ("All registers per
map: reset values, R/W permissions") was previously only spot-checked
(tb_trouper_spi.v: SF/MIMO/COMB_CFG/TACC_WINDOW) rather than swept.
The 2026-07-06 ACTIVE_STATUS (0x1D) reset-value error -- Register Map.md said
0x0F, RTL reset was 0x10 -- was found by hand and shows a full sweep pays for
itself. Writing this sweep found a second one directly: PSRAM_DBG_CTRL
(0x75) documented reset 0x00, but DBG_BUSY (bit 7) is genuinely asserted at
power-on (held until qe_init_done, which nothing drives without firmware
enabling PSRAM) -- actual reset is 0x80. Both Register Map.md and the
expected table below have been corrected. This test asserts every one of
the 128 SPI-addressable registers (0x00-0x7F) against planning/Register
Map.md's Reset column, both:

  1. immediately after power-on reset (test_reset_sweep_poweron), and
  2. after every safely-writable data register has been dirtied to a
     non-default pattern and RESETB is pulsed again
     (test_reset_sweep_after_dirty) -- this is the stronger check, since a
     register whose reset net is wired wrong but happens to match the
     all-zero power-on state of its neighbours would pass check (1) but not
     (2).

Deliberately excluded from the "dirty" pass: W1P/enable bits that trigger
side-effecting FSMs if written (WGT_CTRL 0x1E, TACC_NOISE_TRIG 0x1F,
PSRAM_CTRL 0x70, PSRAM_DBG_CTRL 0x75) -- these are
covered by their own functional tests elsewhere and are not needed to prove
the reset sweep. 0x7F is never written (permanently reserved SPI escape
code) but is still read to confirm it returns 0x00 like any other
unimplemented address.

Excluded from the reset-*value* assertion entirely: the Z_kl/Zdiag readback
bank (0x40-0x6F). `training_acc.v`'s reset block explicitly does NOT reset
`Zpair_i*/q*`/`Zdiag_*` (comment there: "B2: ... intentionally NOT reset
here. They are zeroed at arm time below ... and never read before that
zeroing, so the reset was dead area -- proven by tb_tacc_resetless_equiv.v")
-- a deliberate area optimisation, not a bug. Register Map.md's "0x00" for
this range describes the value after the first training/noise window arms
and clears them, not the literal power-on value, which is don't-care.
Asserting a specific power-on value here would fail against the intended
design (and did, in Icarus, as `X`) without indicating any real defect.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer

from test_trouper_top import spi_read, spi_write, CLK_NS

# Expected reset value for every address 0x00-0x7F, per Register Map.md,
# excluding the resetless Z_kl/Zdiag bank (0x40-0x6F -- see module docstring).
REG_RESET = {addr: 0x00 for addr in range(0x80) if not (0x40 <= addr <= 0x6F)}
REG_RESET.update({
    0x00: 0xA7,  # CHIP_ID
    0x01: 0x01,  # CHIP_REV
    0x08: 0xF0,  # MIMO_CTRL
    0x09: 0x07,  # SF_CFG
    0x0B: 0x50,  # PKT_TIMEOUT_SYMS
    0x0C: 0x01,  # SC_THR_HI
    0x0D: 0xCC,  # SC_THR_LO
    0x0E: 0x02,  # SC_HITS_REQ
    0x0F: 0x10,  # COMB_CFG (REMOD_BACKOFF_SHIFT=1 at [5:4])
    0x1A: 0x01,  # RX_HOLD: SET out of reset -- the receiver comes up disabled
                 # and firmware must configure then release it. See
                 # planning/mcp-config-settle-gate-design.md §4a; the reset
                 # value is deliberate (fail-loud), not an oversight.
    0x1D: 0x10,  # ACTIVE_STATUS (mode=0, antenna_en=0x1)
    0x27: 0x08,  # TACC_WINDOW_SYMS
    0x75: 0x80,  # PSRAM_DBG_CTRL: DBG_BUSY held until qe_init_done, unset at reset
    0x77: 0xDC,  # REPLAY_DELAY_LO  (default 1500 = 0x05DC samples ≈ 3 ms)
    0x78: 0x05,  # REPLAY_DELAY_HI
})

# Safely-writable data registers to dirty in the second pass -- excludes
# W1P/enable control bits that would kick off side-effecting FSMs.
DIRTY_ADDRS = (
    [0x03]                       # IRQ_CLEAR (W1P, harmless with nothing set)
    + [0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F]
    + [0x27]
    + list(range(0x30, 0x40))     # W shadow bank
    + [0x72, 0x73, 0x74]          # PSRAM_DBG_ADDR_{LO,MID,HI}
    + [0x77, 0x78]                # REPLAY_DELAY_{LO,HI}
)


async def _start_clock(dut):
    cocotb.start_soon(Clock(dut.IQ_CLK, CLK_NS, unit="ns").start())


async def _idle_inputs(dut):
    dut.HOST_CS.value   = 1
    dut.SPI_MOSI.value  = 0
    dut.SPI_SCK.value   = 0
    dut.IQ_DATA_I.value = 0
    dut.IQ_DATA_Q.value = 0


async def _reset(dut):
    dut.RESETB.value = 0
    await Timer(4 * CLK_NS, unit="ns")
    dut.RESETB.value = 1
    await Timer(4 * CLK_NS, unit="ns")


async def _sweep_and_check(dut, label):
    mismatches = []
    for addr, expected in REG_RESET.items():
        got = await spi_read(dut, addr)
        if got != expected:
            mismatches.append(
                f"0x{addr:02X}: expected 0x{expected:02X}, got 0x{got:02X}"
            )
    assert not mismatches, (
        f"{label}: {len(mismatches)} register(s) mismatch Register Map.md "
        f"reset values:\n" + "\n".join(mismatches)
    )


@cocotb.test()
async def test_reset_sweep_poweron(dut):
    """Every one of the 128 registers reads its Register Map.md reset value
    immediately after power-on reset."""
    await _start_clock(dut)
    await _idle_inputs(dut)
    await _reset(dut)
    await _sweep_and_check(dut, "power-on")


@cocotb.test()
async def test_reset_sweep_after_dirty(dut):
    """Reset must restore every register to its default even after all
    safely-writable data registers have been driven to a non-default
    pattern -- catches a reset net wired to the wrong constant that would
    coincidentally match the all-zero power-on state."""
    await _start_clock(dut)
    await _idle_inputs(dut)
    await _reset(dut)

    for addr in DIRTY_ADDRS:
        await spi_write(dut, addr, 0xFF)

    # RX_HOLD (0x1A) is dirtied LAST and with 0x00, not 0xFF: its reset value is
    # 1, so 0xFF would leave it unchanged and prove nothing, and clearing it
    # earlier would make the gated config registers above (0x09/0x0A/0x0B/0x0E/
    # 0x27) reject their dirty writes and silently weaken this test. Clearing it
    # here checks the safety-relevant direction -- that reset re-asserts the
    # hold rather than leaving the receiver enabled with the config interlock
    # dropped.
    await spi_write(dut, 0x1A, 0x00)

    await _reset(dut)
    await _sweep_and_check(dut, "post-dirty reset")
