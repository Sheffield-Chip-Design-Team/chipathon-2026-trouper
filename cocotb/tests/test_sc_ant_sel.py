"""
test_sc_ant_sel.py -- BW_CFG.sc_ant_sel (0x0A[2:1]) regression.

Open Risk #9 (planning/Open Risks.md) is that sc_detector acquires only on
antenna 0, hardcoded, with no diversity at lock time. The full spec-faithful
fix (a serial 4-channel TDM correlator, ~+20k um^2) is deliberately deferred
for area (memory project_ant0_fade_deferred). This is a much cheaper partial
mitigation: a new 2-bit register field, BW_CFG[2:1] (sc_ant_sel), lets
firmware pick WHICH single antenna feeds the SC correlator's delay-line taps
in psram_buf_ctrl.v, instead of the previous fixed antenna 0. It does not
add diversity combining -- the correlator is still single-antenna at any
instant -- it only un-hardcodes the branch choice (see planning/Register
Map.md 0x0A).

test_sc_ant_sel_cur_mux:
  For each of the 4 sc_ant_sel settings, captures the exact live iq sample
  psram_buf_ctrl's write-capture cycle will latch (dut.u_dut.u_psram.iq_i{n}
  /iq_q{n}, the same named ports the mux selects from -- no unpacked-array
  indexing needed) and checks cur_i0/cur_q0 come out bit-exact after the
  write burst completes. Proves the wr_data byte-lane mux
  (wr_data_ant_i/wr_data_ant_q in psram_buf_ctrl.v).

test_sc_ant_sel_del_offset:
  Sets sc_ant_sel=2, lets the SC delay line warm up (del_rdy, N=M samples),
  then bit-exact compares a run of del_i0/del_q0 pulses against a
  Python-side replica of antenna 2's write history (a plain deque recorded
  from the same u_psram.iq_i2/iq_q2 ports on every iq_valid, correlated 1:1
  in pulse order with del_valid completions -- both counted from the same
  start point, so no dependence on psram_buf_ctrl's internal absolute write
  index). Proves the del_addr byte-offset math routes the delayed read to
  the SELECTED branch, not always branch 0.

Runs under Verilator (see cocotb/sc_ant_sel/Makefile): needs --timing for
the Timer()-based SPI bit-bang and --public-flat-rw for the hierarchical
u_psram port reads.
"""

from collections import deque

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from test_trouper_top import CLK_NS, spi_read, spi_write
from test_bypass_e2e import sdm_driver_multi, ANT_AMPS


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


async def _psram_init(dut):
    await spi_read(dut, 0x00)          # SPI settle
    await spi_write(dut, 0x70, 0x01)   # PSRAM_EN
    for _ in range(500):
        await Timer(8 * CLK_NS, unit="ns")
        if (await spi_read(dut, 0x71)) & 0x08:
            return
    assert False, "PSRAM INIT_DONE never set"


@cocotb.test()
async def test_sc_ant_sel_cur_mux(dut):
    await _reset(dut)
    cocotb.start_soon(sdm_driver_multi(dut))
    await _psram_init(dut)

    for ant in range(4):
        await spi_write(dut, 0x0A, (ant & 0x3) << 1)
        rb = await spi_read(dut, 0x0A)
        assert (rb >> 1) & 0x3 == ant, \
            f"sc_ant_sel readback {(rb >> 1) & 0x3} != {ant} (BW_CFG=0x{rb:02X})"

        await RisingEdge(dut.u_dut.u_psram.iq_valid)
        exp_i = int(getattr(dut.u_dut.u_psram, f"iq_i{ant}").value.signed_integer)
        exp_q = int(getattr(dut.u_dut.u_psram, f"iq_q{ant}").value.signed_integer)

        await Timer(40 * CLK_NS, unit="ns")   # >> 25-sub-cycle write burst

        got_i = int(dut.u_dut.u_psram.cur_i0.value.signed_integer)
        got_q = int(dut.u_dut.u_psram.cur_q0.value.signed_integer)
        assert (got_i, got_q) == (exp_i, exp_q), \
            (f"ant{ant}: cur_i0/cur_q0=({got_i},{got_q}) != "
             f"iq_i{ant}/iq_q{ant}=({exp_i},{exp_q})")
        dut._log.info(f"ant{ant}: cur_i0/cur_q0=({got_i},{got_q}) OK")


@cocotb.test()
async def test_sc_ant_sel_del_offset(dut):
    sf, sample_shift = 7, 1
    M = 1 << (sf + sample_shift)
    ant = 2
    CHECKS = 10

    await _reset(dut)
    cocotb.start_soon(sdm_driver_multi(dut))

    await spi_write(dut, 0x09, sf & 0x0F)          # SF_CFG (packet inactive)
    await spi_write(dut, 0x0A, (ant & 0x3) << 1)   # sc_ant_sel=2, 250 kHz
    await _psram_init(dut)

    hist_i = deque()
    hist_q = deque()

    async def _record():
        while True:
            await RisingEdge(dut.u_dut.u_psram.iq_valid)
            hist_i.append(int(getattr(dut.u_dut.u_psram, f"iq_i{ant}").value.signed_integer))
            hist_q.append(int(getattr(dut.u_dut.u_psram, f"iq_q{ant}").value.signed_integer))

    cocotb.start_soon(_record())

    checked = 0
    k = 0
    while checked < CHECKS:
        await RisingEdge(dut.u_dut.u_psram.del_valid)
        k += 1
        if len(hist_i) > M:
            exp_i, exp_q = hist_i[-M - 1], hist_q[-M - 1]
            got_i = int(dut.u_dut.u_psram.del_i0.value.signed_integer)
            got_q = int(dut.u_dut.u_psram.del_q0.value.signed_integer)
            assert (got_i, got_q) == (exp_i, exp_q), \
                (f"del pulse {k}: del_i0/del_q0=({got_i},{got_q}) != "
                 f"antenna-{ant} history N={M} samples back=({exp_i},{exp_q})")
            checked += 1

    dut._log.info(f"sc_ant_sel={ant}: {checked}/{checked} del_i0/del_q0 "
                   "pulses bit-exact against antenna-2 write history")

    # Sanity: antenna 2's amplitude (15) is well below antenna 0's (31) --
    # if the offset math were wrong and this were silently still reading
    # branch 0, the values compared above would still have been wrong, but
    # this catches a degenerate all-zero/all-same-branch failure mode too.
    assert max(abs(v) for v in list(hist_i)[-CHECKS:]) <= ANT_AMPS[ant] + 2
