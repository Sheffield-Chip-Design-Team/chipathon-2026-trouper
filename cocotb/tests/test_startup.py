"""
test_startup.py -- cocotb power-on / startup-ordering tests for trouper_top.

Covers Open Risks item 27 (planning/Open Risks.md): unknowns around chip
power-up sequencing that the normal SF/BW sweep (test_trouper_top.py) never
exercises, because those tests all reset from an already-quiescent bench and
never race firmware writes against reset release.

Four things are checked here:

  1. The very first SPI transaction after RESETB release must be parsed
     correctly regardless of the clock-phase alignment of the reset release
     (regression coverage for Open Risks item 26, closed 2026-07-02).
  2. There is no on-chip wait enforcing the APS6404L's tPU (>=150 us) between
     power-up and the first RSTEN command -- `init_start` is a register-bit
     level, not a firmware-timed pulse. This test demonstrates the gap
     numerically rather than assuming it.
  3. The RST(0x99) -> Enter-QPI(0x35) gap inside QE_INIT must clear the
     APS6404L's tRST (>=50 ns); this measures the real margin instead of
     hand-counting states.
  4. The SC-detector correlator (TDM engine) must stay completely idle until
     `del_rdy` fires (Gate 9 hold-off) -- verifies there is no possibility of
     a stale/zero delayed sample producing a false lock during the warm-up
     window, and reports the measured warm-up latency.

Reuses the SPI helpers and SDM stimulus from test_trouper_top so the two
files behave identically as far as the DUT is concerned.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, Timer
from cocotb.utils import get_sim_time

from test_trouper_top import spi_write, spi_read, sdm_driver, CLK_NS, release_rx_hold

TPU_NS = 150_000.0   # APS6404L datasheet minimum power-up time before RSTEN
TRST_NS = 50.0        # APS6404L datasheet minimum RST->next-command gap


async def _start_clock(dut):
    cocotb.start_soon(Clock(dut.IQ_CLK, CLK_NS, unit="ns").start())


async def _idle_inputs(dut):
    dut.HOST_CS.value   = 1
    dut.SPI_MOSI.value  = 0
    dut.SPI_SCK.value   = 0
    dut.IQ_DATA_I.value = 0
    dut.IQ_DATA_Q.value = 0


# ---------------------------------------------------------------------------
# 1. First SPI transaction after power-on, at several reset/clock phases
# ---------------------------------------------------------------------------

async def _first_transaction_at_phase(dut, phase_ns):
    await _start_clock(dut)
    await _idle_inputs(dut)
    dut.RESETB.value = 0
    await Timer(4 * CLK_NS, unit="ns")
    if phase_ns:
        await Timer(phase_ns, unit="ns")   # release mid-cycle, not on an edge
    dut.RESETB.value = 1

    # No warm-up/discard read -- the very first transaction must be correct.
    chip_id = await spi_read(dut, 0x00)
    assert chip_id == 0xA7, (
        f"phase={phase_ns}ns: first post-reset SPI transaction returned "
        f"CHIP_ID=0x{chip_id:02X} (expected 0xA7) -- regression of Open "
        f"Risks item 26"
    )


@cocotb.test()
async def test_first_transaction_reset_on_edge(dut):
    """Reset released exactly on a clock edge (phase=0)."""
    await _first_transaction_at_phase(dut, 0)


@cocotb.test()
async def test_first_transaction_reset_mid_cycle(dut):
    """Reset released partway into a clock period (not phase-aligned)."""
    await _first_transaction_at_phase(dut, 10)


@cocotb.test()
async def test_first_transaction_reset_late_cycle(dut):
    """Reset released late in a clock period (not phase-aligned)."""
    await _first_transaction_at_phase(dut, 20)


# ---------------------------------------------------------------------------
# 2. PSRAM init_start has no hardware tPU gate
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_psram_init_has_no_tpu_wait(dut):
    """
    Characterizes Open Risks item 27.1: `init_start` (trouper_top.v) is
    `PSRAM_CTRL[0] & ~QSPI_OWNER`, a register level with no on-chip timer.
    Firmware writes PSRAM_CTRL[0]=1 as its very first action after reset
    (the worst case a real bring-up sequence could hit if the host does not
    itself wait out tPU). This test measures how long after RESETB release
    the controller actually asserts PSRAM CE# for the first RSTEN command.

    The assertion documents the *absence* of a guard: elapsed time is only a
    couple of SPI-transaction widths, several orders of magnitude below the
    APS6404L's 150 us tPU. If a future revision adds an on-chip tPU timer,
    this assertion will start failing right at the point where it should --
    that is the intended regression signal.
    """
    await _start_clock(dut)
    await _idle_inputs(dut)
    dut.RESETB.value = 0
    await Timer(4 * CLK_NS, unit="ns")
    dut.RESETB.value = 1
    reset_release_ns = get_sim_time(unit="ns")

    # Fire the PSRAM-enable write immediately -- no host-side tPU wait.
    # init_start only takes effect once reg_bank captures the write (i.e.
    # after the SPI transaction completes), so the CE# falling edge cannot
    # occur until after spi_write() returns -- no need to race it.
    await spi_write(dut, 0x70, 0x01)

    await FallingEdge(dut.u_dut.u_psram.ce_n)
    ce_fall_ns = get_sim_time(unit="ns")
    elapsed_ns = ce_fall_ns - reset_release_ns

    dut._log.info(
        f"RESETB release -> first PSRAM CE# low: {elapsed_ns:.1f} ns "
        f"(tPU minimum is {TPU_NS:.0f} ns)"
    )
    assert elapsed_ns < TPU_NS, (
        f"first PSRAM command issued {elapsed_ns:.1f} ns after reset "
        f"release -- expected it to race ahead of tPU ({TPU_NS:.0f} ns) "
        f"since no on-chip wait exists; if this now holds off past tPU, "
        f"item 27.1 in Open Risks.md has been fixed and this test (and the "
        f"risk writeup) should be updated to assert the wait instead"
    )


# ---------------------------------------------------------------------------
# 3. QE_INIT: RST(0x99) -> Enter-QPI(0x35) gap vs tRST
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_qe_init_trst_margin(dut):
    """
    Measures the real RST->Enter-QPI CE# high duration inside psram_buf_ctrl's
    QE_INIT sequence and checks it against the APS6404L's tRST >= 50 ns.
    QE_INIT issues three back-to-back SPI-mode commands (RSTEN, RST, Enter
    QPI) as three CE#-low pulses; the gap that matters for tRST is the CE#
    -high dwell between the *second* pulse (RST, 0x99) and the *third*
    (Enter QPI, 0x35).
    """
    await _start_clock(dut)
    await _idle_inputs(dut)
    dut.RESETB.value = 0
    await Timer(4 * CLK_NS, unit="ns")
    dut.RESETB.value = 1

    ce_n = dut.u_dut.u_psram.ce_n

    # Wait for reset of QE_INIT logic to settle, then trigger init.
    await Timer(2 * CLK_NS, unit="ns")
    await spi_write(dut, 0x70, 0x01)

    # Collect CE# edge timestamps until we have seen 3 low pulses (6 edges:
    # fall,rise,fall,rise,fall,rise).
    edges = []
    prev = int(ce_n.value)
    for _ in range(20000):
        await RisingEdge(dut.IQ_CLK)
        cur = int(ce_n.value)
        if cur != prev:
            edges.append((get_sim_time(unit="ns"), cur))
            prev = cur
        if len(edges) >= 6:
            break

    assert len(edges) >= 6, (
        f"only saw {len(edges)} PSRAM CE# edges during QE_INIT -- expected "
        f"3 full command pulses (RSTEN, RST, Enter QPI)"
    )

    # edges: [fall,rise](RSTEN) [fall,rise](RST) [fall,rise](Enter QPI)
    # edges[3] = rising edge ending the RST pulse (2nd low pulse)
    # edges[4] = falling edge starting the Enter-QPI pulse (3rd low pulse)
    rst_end_ns      = edges[3][0]
    enterqpi_start_ns = edges[4][0]
    gap_ns = enterqpi_start_ns - rst_end_ns

    dut._log.info(
        f"RST(0x99) end -> Enter-QPI(0x35) start: {gap_ns:.2f} ns "
        f"(tRST minimum is {TRST_NS:.0f} ns, margin {gap_ns - TRST_NS:.2f} ns)"
    )
    assert gap_ns >= TRST_NS, (
        f"RST->Enter-QPI gap is {gap_ns:.2f} ns, below the APS6404L's "
        f"tRST minimum of {TRST_NS:.0f} ns"
    )


# ---------------------------------------------------------------------------
# 4. SC-detector correlator stays idle until del_rdy (Gate 9 hold-off)
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_sc_correlator_idle_until_del_rdy(dut):
    """
    SF9/BW125 (M=2048, ~4.1 ms warm-up) chosen to bound simulation time while
    still exercising a multi-thousand-sample hold-off. Confirms the TDM
    correlator (`sc_detector.tdm_busy`) never activates before `del_rdy`
    (psram_buf_ctrl) is set, and reports the measured warm-up latency against
    the predicted N = 2^(SF+sample_shift) samples at 500 kS/s. Worst case in
    silicon is SF12/BW125 (~32.8 ms) -- not run here for sim-time reasons,
    but scales as 2^(SF+sample_shift).
    """
    sf = 9
    bw_khz = 125
    sample_shift = 2
    M = 1 << (sf + sample_shift)
    clk_per_iq = 64
    predicted_warmup_ns = M * clk_per_iq * CLK_NS

    await _start_clock(dut)
    await _idle_inputs(dut)
    dut.RESETB.value = 0
    await Timer(4 * CLK_NS, unit="ns")
    dut.RESETB.value = 1
    await Timer(8 * CLK_NS, unit="ns")

    cocotb.start_soon(sdm_driver(dut, sf, bw_khz))

    await spi_read(dut, 0x00)  # SPI settle, matches test_trouper_top pattern
    await spi_write(dut, 0x09, sf & 0x0F)
    await spi_write(dut, 0x0A, 1)   # BW_CFG bw_sel=1 -> 125 kHz
    await spi_write(dut, 0x0C, 0x01)
    await spi_write(dut, 0x0D, 0x00)
    await spi_write(dut, 0x0E, 0x00)
    await release_rx_hold(dut)
    await spi_write(dut, 0x70, 0x01)  # PSRAM_EN

    init_ok = False
    for _ in range(500):
        await Timer(8 * CLK_NS, unit="ns")
        if (await spi_read(dut, 0x71)) & 0x08:
            init_ok = True
            break
    assert init_ok, "PSRAM INIT_DONE never set"

    t_init_done_ns = get_sim_time(unit="ns")

    # Watch every cycle from here on: tdm_busy must not go high before
    # del_rdy does.
    del_rdy_seen_ns = None
    watch_cycles = int(predicted_warmup_ns / CLK_NS) + 2000
    for _ in range(watch_cycles):
        await RisingEdge(dut.IQ_CLK)
        del_rdy = int(dut.u_dut.u_psram.del_rdy.value)
        tdm_busy = int(dut.u_dut.u_sc.tdm_busy.value)
        if del_rdy and del_rdy_seen_ns is None:
            del_rdy_seen_ns = get_sim_time(unit="ns")
        assert not (tdm_busy and del_rdy_seen_ns is None), (
            "sc_detector TDM correlator went active before del_rdy -- SC "
            "lock could fire on a stale/zero delayed sample during warm-up"
        )
        if del_rdy_seen_ns is not None:
            break

    assert del_rdy_seen_ns is not None, (
        f"del_rdy never asserted within {watch_cycles} cycles after "
        f"PSRAM INIT_DONE"
    )

    measured_warmup_ns = del_rdy_seen_ns - t_init_done_ns
    dut._log.info(
        f"SF{sf}/BW{bw_khz}: measured del_rdy warm-up = "
        f"{measured_warmup_ns:.0f} ns (predicted {predicted_warmup_ns:.0f} ns)"
    )
    # Loose tolerance: pipeline/init latency, not sample-accurate here.
    assert abs(measured_warmup_ns - predicted_warmup_ns) < 0.05 * predicted_warmup_ns, (
        f"measured warm-up {measured_warmup_ns:.0f} ns deviates >5% from "
        f"predicted {predicted_warmup_ns:.0f} ns"
    )

    # Finally confirm the receiver actually locks shortly after warm-up ends.
    lock_ok = False
    for _ in range(20):
        await Timer(predicted_warmup_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x01:
            lock_ok = True
            break
    assert lock_ok, "sc_lock never fired after del_rdy warm-up completed"
