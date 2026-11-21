"""
test_sc_sample_count_top.py -- full-chip companion to test_sc_sample_count.py.

timing_ref is produced in u_sc.sample_count units and consumed against
iq_samp_cnt (packet FSM, psram buf_base) and u_tacc.sample_count (training
window). All three count the same dcr_valid samples, so their differences must
be constant for the life of the chip. This drives real packet ends through the
production sc_clr path (packet_ctrl_fsm timeout -> packet_done_pulse) and
checks the offsets after each one.

Packets are produced with SC_FORCE_LOCK (no RF stimulus needed); PSRAM is
enabled so psram_buf_ctrl's delay line feeds delayed_valid at its real latency,
which is what makes the sc_detector TDM burst overlap the next sample.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, FallingEdge, Timer

from test_trouper_top import CLK_NS, spi_read, spi_write, release_rx_hold

N_PKTS = 4


async def _offsets(dut):
    """Sample all counters 20 clocks after a dcr_valid, when every pending
    increment for that sample has landed."""
    top = dut.u_dut
    await RisingEdge(top.dcr_valid)
    await ClockCycles(dut.IQ_CLK, 20)
    iq = int(top.iq_samp_cnt.value)
    return (iq - int(top.u_sc.sample_count.value),
            iq - int(top.u_tacc.sample_count.value))


@cocotb.test()
async def test_sc_sample_count_tracks_iq_samp_cnt_across_packets(dut):
    cocotb.start_soon(Clock(dut.IQ_CLK, CLK_NS, unit="ns").start())
    dut.HOST_CS.value = 1
    dut.SPI_MOSI.value = 0
    dut.SPI_SCK.value = 0
    dut.IQ_DATA_I.value = 0
    dut.IQ_DATA_Q.value = 0
    dut.RESETB.value = 0
    await Timer(4 * CLK_NS, unit="ns")
    dut.RESETB.value = 1
    await Timer(8 * CLK_NS, unit="ns")
    top = dut.u_dut

    await spi_read(dut, 0x00)                 # prime SPI
    await spi_write(dut, 0x09, 7)             # SF7
    await spi_write(dut, 0x0A, 0)             # BW250 -> M = 256
    await spi_write(dut, 0x0B, 1)             # PKT_TIMEOUT_SYMS = 1 (short packets)
    await release_rx_hold(dut)
    await spi_write(dut, 0x70, 0x01)          # PSRAM_EN
    for _ in range(500):
        await Timer(8 * CLK_NS, unit="ns")
        if (await spi_read(dut, 0x71)) & 0x08:
            break
    else:
        raise AssertionError("PSRAM INIT_DONE never set")
    for _ in range(400):                      # del_rdy after M = 256 captures
        await ClockCycles(dut.IQ_CLK, 64 * 4)
        if int(top.u_psram.del_rdy.value):
            break
    else:
        raise AssertionError("psram del_rdy never set -- no delayed_valid stream")

    base = await _offsets(dut)
    dut._log.info(f"baseline offsets (iq_samp_cnt - u_sc, iq_samp_cnt - u_tacc) = {base}")
    seen = [base]
    for k in range(N_PKTS):
        await spi_write(dut, 0x19, 0x01)      # SC_FORCE_LOCK -> packet
        for _ in range(2000):
            await ClockCycles(dut.IQ_CLK, 64 * 16)
            if int(top.packet_active.value):
                break
        else:
            raise AssertionError(f"packet {k + 1}: forced lock did not start a packet")
        await FallingEdge(top.packet_active)
        await ClockCycles(dut.IQ_CLK, 64 * 4)
        assert not int(top.sc_lock.value), f"packet {k + 1}: sc_lock not re-armed"
        off = await _offsets(dut)
        seen.append(off)
        dut._log.info(f"after packet {k + 1}: offsets = {off}")

    sc_drift = [o[0] - base[0] for o in seen]
    tacc_drift = [o[1] - base[1] for o in seen]
    assert all(d == 0 for d in tacc_drift), f"training_acc counter drifted: {tacc_drift}"
    assert all(d == 0 for d in sc_drift), (
        f"u_sc.sample_count fell behind iq_samp_cnt by {sc_drift} samples after "
        f"packets 0..{N_PKTS} -- every later timing_ref is early by that much")
