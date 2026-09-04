"""
test_w_valid_split.py -- Open Risk #62.

There are two W_valid state elements for one logical flag:

  * packet_ctrl_fsm.v `W_valid` (reg, line 124): set in ST_IDLE when a
    W_commit_pending is consumed (line 180-184), and NOT cleared on IDLE entry
    -- only at the ST_PAYLOAD_ACTIVE packet timeout (line 292).
  * trouper_top.v `W_valid` (line 756-760): set by the one-cycle W_valid_set
    pulse, cleared on every `!packet_active`.

Commit a weight vector while the FSM is in IDLE and let it sit: the FSM copy
goes (and stays) high, the top copy is high for a single cycle then cleared by
`!packet_active`. On the next packet, with no fresh W_COMMIT:

  * ST_W_PENDING's `wpend_cnt==0 -> if (!W_valid)` sees the stale FSM copy == 1,
    so W_MISSED_PACKET is NOT raised;
  * the combiner (`use_mrc_r = W_valid && !mode`, driven by the TOP copy == 0)
    stays in bypass;
  * reg_bank's 0x30-0x3F write-lock (`w_valid_rb` == the top copy == 0) is open.

So the packet neither combines with the committed weights nor reports a miss.
A single authoritative W_valid would do exactly one of those.

Top-level bench, TOPLEVEL = tb_trouper_cocotb. Regresses the #62 fix (single
authoritative W_valid exported from packet_ctrl_fsm; branch rtl/open-risk-fixes):
FSM and top-level W_valid now agree, and the packet either combines or reports
the miss. PASS once the fix is in.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from test_trouper_top import (CLK_NS, spi_read, spi_write, spi_burst_write,
                              sdm_driver, release_rx_hold)

SF, BW_KHZ = 7, 250
SAMPLE_SHIFT = 1
M = 1 << (SF + SAMPLE_SHIFT)
CLK_PER_IQ = 64
SYM_NS = M * CLK_PER_IQ * CLK_NS

IDLE_WEIGHTS = [0x40, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00]


@cocotb.test()
async def test_idle_commit_then_unrefreshed_packet(dut):
    tag = "w_valid_split"

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

    await spi_read(dut, 0x00)
    await spi_read(dut, 0x09)

    await spi_write(dut, 0x09, SF & 0x0F)
    await spi_write(dut, 0x0A, 0)            # 250 kHz
    await spi_write(dut, 0x0B, 30)           # PKT_TIMEOUT_SYMS: long enough to see wpend timeout
    await spi_write(dut, 0x0C, 0x01)         # SC threshold: 1 hit -> lock
    await spi_write(dut, 0x0D, 0x00)
    await spi_write(dut, 0x0E, 0x00)
    await release_rx_hold(dut)
    await spi_write(dut, 0x08, 0xF0)         # MIMO_CTRL: mode 0 (MRC), all antennas
    await spi_write(dut, 0x0F, 0x00)         # COMB_CFG: backoff shift 0
    await spi_write(dut, 0x77, 0xFF)         # hold the packet in modulated-silence
    await spi_write(dut, 0x78, 0xFF)

    # -- COMMIT IN IDLE: PSRAM is still down and no IQ stimulus is running, so
    # the FSM is unambiguously in ST_IDLE. --------------------------------------
    assert int(dut.u_dut.packet_active.value) == 0, f"{tag}: not idle before the commit"
    await spi_burst_write(dut, 0x30, IDLE_WEIGHTS)
    await spi_write(dut, 0x1E, 0x01)         # W_COMMIT (W1P)

    # let it settle for a few symbols of idle time
    await Timer(5 * SYM_NS, unit="ns")

    fsm_wv  = int(dut.u_dut.u_pcfsm.W_valid.value)
    top_wv  = int(dut.u_dut.W_valid.value)
    dut._log.info(f"{tag}: after IDLE commit + idle wait -- FSM W_valid={fsm_wv}, "
                  f"top W_valid={top_wv}")
    assert fsm_wv == 1, f"{tag}: FSM W_valid did not latch the IDLE commit ({fsm_wv})"

    # -- bring up PSRAM + start the preamble stimulus -------------------------
    await spi_write(dut, 0x70, 0x01)
    init_ok = False
    for _ in range(500):
        await Timer(8 * CLK_NS, unit="ns")
        if (await spi_read(dut, 0x71)) & 0x08:
            init_ok = True
            break
    assert init_ok, f"{tag}: PSRAM INIT_DONE never set"

    cocotb.start_soon(sdm_driver(dut, SF, BW_KHZ))

    lock_ok = False
    for _ in range(20):
        await Timer(SYM_NS, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x01:
            lock_ok = True
            break
    assert lock_ok, f"{tag}: sc_lock never fired"
    await spi_write(dut, 0x03, 0xFF)         # clear IRQs (keep the miss check clean)

    # -- training_done -> ST_W_PENDING, then withhold W_COMMIT --------------
    train_ok = False
    for _ in range(40):
        await Timer(SYM_NS, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x02:
            train_ok = True
            break
    assert train_ok, f"{tag}: training_done never fired"

    # -- let ST_W_PENDING time out with no commit this packet --------------
    for _ in range(15):
        await Timer(SYM_NS, unit="ns")
        irq = await spi_read(dut, 0x02)
        if (irq & 0x04) or ((await spi_read(dut, 0x1C)) >> 1 & 0x7) == 3:
            break

    irq        = await spi_read(dut, 0x02)
    pkt_status = await spi_read(dut, 0x1C)
    wgt        = await spi_read(dut, 0x1E)
    fsm_wv     = int(dut.u_dut.u_pcfsm.W_valid.value)
    top_wv     = int(dut.u_dut.W_valid.value)
    use_mrc    = int(dut.u_dut.u_comb.use_mrc_r.value)
    phase      = (pkt_status >> 1) & 0x7
    w_missed   = bool(irq & 0x04) or bool(pkt_status & 0x80)

    dut._log.info(
        f"{tag}: post-wpend-timeout -- phase={phase} IRQ=0x{irq:02X} "
        f"PACKET_STATUS=0x{pkt_status:02X} WGT_CTRL=0x{wgt:02X} "
        f"FSM W_valid={fsm_wv} top W_valid={top_wv} use_mrc_r={use_mrc} "
        f"w_missed={w_missed}")

    assert phase == 3, f"{tag}: did not reach ST_PAYLOAD_ACTIVE (phase={phase})"

    # The two copies of one logical flag must agree.
    assert fsm_wv == top_wv, (
        f"{tag}: packet_ctrl_fsm W_valid={fsm_wv} but trouper_top W_valid={top_wv} -- "
        f"an IDLE W_COMMIT was latched by the FSM copy and cleared from the top copy "
        f"(Open Risk #62)")

    # And with no fresh commit this packet, the outcome must be ONE of:
    #   (a) combine with the committed vector  -> use_mrc_r == 1, or
    #   (b) declare the weights missed         -> W_MISSED_PACKET set.
    assert use_mrc == 1 or w_missed, (
        f"{tag}: packet reached PAYLOAD_ACTIVE with use_mrc_r=0 AND no W_MISSED_PACKET -- "
        f"the committed-in-IDLE vector was neither applied nor reported missing, because "
        f"the FSM copy suppressed the miss while the combiner saw the cleared top copy "
        f"(Open Risk #62)")
