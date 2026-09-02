"""Host-only standalone Trouper end-to-end regression.

Traceability: TRPR-INT-004.

Every control transaction uses HOST_CS/SPI_SCK/SPI_MOSI.  Since the Grouper
bus was removed (2026-09-01) SPI is the only register master, so this is no
longer a fallback path -- it is the path.  It proves the complete operational
chain:

  host enables/initialises PSRAM -> configures RX -> observes TRAINING_DONE
  -> reads training status -> writes W shadow -> W_COMMIT -> same-packet MRC
  replay.
"""

import cocotb
from cocotb.triggers import Timer

from test_bypass_e2e import _reset_and_lock
from test_replay_delay import _wait_irq, _wait_replay_active, _watch_monotonic_replay
from test_trouper_top import CLK_NS, spi_burst_write, spi_read, spi_write


@cocotb.test()
async def test_host_spi_only_same_packet_mrc_replay(dut):
    """A no-Grouper board can receive, train, commit, and replay via SPI only."""
    tag = "host_only_e2e"

    # _reset_and_lock performs only SPI transactions: config, RX_HOLD release,
    # PSRAM_EN/init polling, then SC lock.  600 samples leaves enough time for
    # the host's 16-byte W shadow burst plus W_COMMIT before replay begins.
    sym_ns = await _reset_and_lock(dut, mode=0, ant_mask=0xF, tag=tag,
                                   pkt_timeout_syms=20, replay_delay=600)

    # TRAINING_DONE and its state are read on SPI; ZDIAG confirms that host
    # firmware has data from which it can derive its weights.
    await _wait_irq(dut, 0x02, 40, sym_ns, tag, "TRAINING_DONE")
    zdiag0 = [(await spi_read(dut, addr)) for addr in (0x64, 0x65, 0x66)]
    assert any(zdiag0), f"{tag}: ZDIAG0 remained zero after TRAINING_DONE"

    # Host-generated equal-gain weights are sufficient to prove the actual
    # host write -> live shadow -> W_COMMIT path.  Low bytes are retained as
    # zero because only the Q0.7 high byte reaches mrc_combiner.
    await spi_burst_write(dut, 0x30, [
        0x40, 0x00, 0x00, 0x00,
        0x40, 0x00, 0x00, 0x00,
        0x40, 0x00, 0x00, 0x00,
        0x40, 0x00, 0x00, 0x00,
    ])
    await spi_write(dut, 0x1E, 0x01)
    wgt = await spi_read(dut, 0x1E)
    assert wgt & 0x02, f"{tag}: host W_COMMIT did not set W_VALID (0x{wgt:02X})"
    assert not (wgt & 0x10), f"{tag}: host commit was unexpectedly late (0x{wgt:02X})"

    await _wait_replay_active(dut, 40, sym_ns, tag)
    assert int(dut.u_dut.u_comb.use_mrc_r.value) == 1, \
        f"{tag}: replay started but host-committed weights were not used"
    status = await spi_read(dut, 0x71)
    assert not (status & 0x20), f"{tag}: REPLAY_MISSED set (0x{status:02X})"
    await _watch_monotonic_replay(dut, 40, tag)

    await Timer(8 * CLK_NS, unit="ns")
    dut._log.info("host_only_e2e: PASS -- SPI-only PSRAM init, training, "
                  "weight commit, and same-packet MRC replay")
