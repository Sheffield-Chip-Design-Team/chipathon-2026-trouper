"""A40 padframe pad-control tie-off contract (TRPR-PHY-004, TRPR-SPS-008).

The A40 (ACV) workshop padring has no output-only cell: every functional output
sits on a bidirectional pad whose full control interface (`_OE/_IE/_CS/_SL/
_PU/_PD/_PDRV0/_PDRV1`) is driven from `trouper_top` itself.  That is 96
constant tie-offs plus 4 dynamic `PSRAM_SIO_n_IE` lanes.

Until this test none of them were read by any simulation: an inverted `_IE`
polarity, a swapped `_PU`/`_PD`, or a wrong `_PDRV` code would pass every
existing suite and only show up in silicon.  The expected values below are
transcribed **from `planning/Pinout.md` "A40 pad-control tie-offs"**, not from
the RTL, so this is a check against documented intent rather than a mirror of
the implementation.

Covered here:
  * every constant tie-off holds its documented value out of reset;
  * it is genuinely constant -- re-checked on every clock through PSRAM QPI
    init and sustained circular-capture traffic, so a tie-off accidentally
    wired to a real signal is caught;
  * `PSRAM_SIO_n_IE == ~PSRAM_SIO_n_OE` per clock, and the GF180-disallowed
    `IE=OE=1` state never occurs on any lane.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from test_trouper_top import CLK_NS, spi_read, spi_write, release_rx_hold
from test_noise_trig import _StimMode, _noise_or_cw_driver


# --- Expected tie-off values, transcribed from planning/Pinout.md -----------
# 13 input pads: on-chip pulls off, board supplies the pull-ups.
_INPUT_PADS = (
    ["IQ_CLK", "RESETB", "HOST_CS", "SPI_SCK", "SPI_MOSI"]
    + [f"IQ_DATA_I_{n}" for n in range(4)]
    + [f"IQ_DATA_Q_{n}" for n in range(4)]
)

# Output-on-bidir pads: (OE, IE, CS, SL, PU, PD, PDRV0, PDRV1).
# Drive code {PDRV1,PDRV0}: 00=4mA, 01=8mA, 10=12mA, 11=16mA.
# PSRAM lanes, CE_N and REMOD are all 16 mA (PDRV0=1, PDRV1=1) with fast slew.
# MISO/IRQ are 8 mA + slow slew (SL=1): 2 MHz, ~50x timing margin.
_OUTPUT_PADS = {
    "PSRAM_CE_N": dict(OE=1, IE=0, CS=0, SL=0, PU=0, PD=0, PDRV0=1, PDRV1=1),
    # REMOD raised 8 -> 16 mA 2026-08-30: 32 MHz into an SX1302 whose input
    # capacitance is unpublished, and under-drive cannot be fixed post-silicon.
    "REMOD_A_I":  dict(OE=1, IE=0, CS=0, SL=0, PU=0, PD=0, PDRV0=1, PDRV1=1),
    "REMOD_A_Q":  dict(OE=1, IE=0, CS=0, SL=0, PU=0, PD=0, PDRV0=1, PDRV1=1),
    "SPI_MISO":   dict(OE=1, IE=0, CS=0, SL=1, PU=0, PD=0, PDRV0=1, PDRV1=0),
    "IRQ_OUT":    dict(OE=1, IE=0, CS=0, SL=1, PU=0, PD=0, PDRV0=1, PDRV1=0),
    # PSRAM_SCK sits on a fixed-drive bi_24t cell: no PDRV select exists.
    "PSRAM_SCK":  dict(OE=1, IE=0, CS=0, SL=0, PU=0, PD=0),
}

# PSRAM_SIO_0..3 are true bidirectional: _IE tracks ~_OE and is checked
# dynamically, so only the constant members appear here.
_SIO_CONST = dict(CS=0, SL=0, PU=0, PD=0, PDRV0=1, PDRV1=1)


def _expected_table():
    """Flatten the documented groups into {port_name: expected_value}."""
    exp = {}
    for pad in _INPUT_PADS:
        exp[f"{pad}_PU"] = 0
        exp[f"{pad}_PD"] = 0
    for pad, ctrls in _OUTPUT_PADS.items():
        for ctrl, val in ctrls.items():
            exp[f"{pad}_{ctrl}"] = val
    for n in range(4):
        for ctrl, val in _SIO_CONST.items():
            exp[f"PSRAM_SIO_{n}_{ctrl}"] = val
    return exp


EXPECTED = _expected_table()


def _check_constants(dut, where):
    """Assert every constant tie-off against the Pinout.md table."""
    bad = []
    for port, want in EXPECTED.items():
        got = int(getattr(dut, port).value)
        if got != want:
            bad.append(f"{port}={got} (want {want})")
    assert not bad, f"{where}: pad tie-off mismatch: " + ", ".join(bad)


def _check_sio_ie(dut, where):
    """PSRAM_SIO_n_IE must be the exact complement of _OE on every lane.

    These two are the only pad-control ports the wrapper already consumes
    (they drive the PSRAM model / optional bi_t pad cells), so they are read
    from the wrapper's internal vectors rather than from pass-through ports.
    """
    oe_vec = int(dut.psram_sio_oe.value)
    ie_vec = int(dut.psram_sio_ie.value)
    for n in range(4):
        oe = (oe_vec >> n) & 1
        ie = (ie_vec >> n) & 1
        assert ie == (oe ^ 1), \
            f"{where}: PSRAM_SIO_{n} IE={ie} OE={oe} -- IE must equal ~OE"
        # The IE=OE=1 control state is uncharacterized for gf180mcu_fd_io__bi_t.
        assert not (ie and oe), \
            f"{where}: PSRAM_SIO_{n} in disallowed IE=OE=1 state"


@cocotb.test()
async def test_pad_tieoffs_match_pinout(dut):
    """All 96 constant tie-offs hold their documented value out of reset."""
    tag = "pad_tieoffs"
    cocotb.start_soon(Clock(dut.IQ_CLK, CLK_NS, unit="ns").start())
    dut.HOST_CS.value   = 1
    dut.SPI_MOSI.value  = 0
    dut.SPI_SCK.value   = 0
    dut.IQ_DATA_I.value = 0
    dut.IQ_DATA_Q.value = 0
    dut.RESETB.value    = 0
    await Timer(4 * CLK_NS, unit="ns")

    # Tie-offs are combinational constants: they must already be correct while
    # reset is still asserted, before any register is writable.
    _check_constants(dut, f"{tag}: in reset")
    _check_sio_ie(dut, f"{tag}: in reset")

    dut.RESETB.value = 1
    await Timer(8 * CLK_NS, unit="ns")
    _check_constants(dut, f"{tag}: out of reset")
    _check_sio_ie(dut, f"{tag}: out of reset")

    # Guard against the table silently drifting out of sync with the RTL port
    # list: Pinout.md documents exactly 96 constant tie-offs.
    assert len(EXPECTED) == 96, \
        f"{tag}: expected-value table has {len(EXPECTED)} entries, want 96"


@cocotb.test()
async def test_pad_tieoffs_stable_under_qpi_traffic(dut):
    """Tie-offs stay constant, and SIO IE tracks ~OE, through live QPI bursts.

    Checks every clock rather than sampling: a tie-off accidentally driven by
    a real signal, or an IE/OE overlap of even one cycle at a burst boundary,
    would otherwise slip between polls.
    """
    tag = "pad_qpi"
    sf = 7
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

    # Low-amplitude independent noise: nonzero stored samples, no SC hits.
    mode = _StimMode()
    cocotb.start_soon(_noise_or_cw_driver(dut, mode, sigma=8.0))

    await spi_read(dut, 0x00)
    await spi_write(dut, 0x09, sf & 0x0F)
    await spi_write(dut, 0x0A, 0)
    await release_rx_hold(dut)

    # Watch the pads continuously from before PSRAM_EN, so QE_INIT's very first
    # bus turnaround is covered too.
    stop = False
    checked = {"clocks": 0, "oe_high": 0, "ie_high": 0}

    async def _watcher():
        while not stop:
            await RisingEdge(dut.IQ_CLK)
            _check_constants(dut, f"{tag}: clk {checked['clocks']}")
            _check_sio_ie(dut, f"{tag}: clk {checked['clocks']}")
            checked["clocks"] += 1
            if int(dut.psram_sio_oe.value) & 1:
                checked["oe_high"] += 1
            if int(dut.psram_sio_ie.value) & 1:
                checked["ie_high"] += 1

    watcher = cocotb.start_soon(_watcher())

    await spi_write(dut, 0x70, 0x01)
    init_ok = False
    for _ in range(500):
        await Timer(8 * CLK_NS, unit="ns")
        if (await spi_read(dut, 0x71)) & 0x08:
            init_ok = True
            break
    assert init_ok, f"{tag}: PSRAM INIT_DONE never set"

    # Sustained circular capture: many write bursts, so the SIO lanes turn
    # around repeatedly under the watcher.
    await Timer(200 * clk_per_iq * CLK_NS, unit="ns")

    stop = True
    await RisingEdge(dut.IQ_CLK)
    watcher.cancel()

    # The watcher only proves a contract; confirm it actually saw the lanes
    # driven AND released, otherwise a permanently-stuck OE would pass.
    assert checked["clocks"] > 10000, \
        f"{tag}: watcher only ran {checked['clocks']} clocks"
    assert checked["oe_high"] > 0, f"{tag}: PSRAM_SIO_0_OE never asserted"
    assert checked["ie_high"] > 0, f"{tag}: PSRAM_SIO_0_IE never asserted"
    dut._log.info(
        "%s: %d clocks checked; SIO_0 driven %d, released %d",
        tag, checked["clocks"], checked["oe_high"], checked["ie_high"])
