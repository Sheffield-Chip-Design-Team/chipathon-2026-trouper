"""
test_trouper_top.py -- cocotb integration tests for production trouper_top.

Sweeps SF7-SF12 x BW 250 kHz / 125 kHz using the production half-band decimator chain:
  32 MS/s -> CIC-3/R=16 -> HB1/2 -> HB2/2 -> 500 kS/s int8 IQ

Production timing assumptions:
  - clk_per_iq = 64 (iq_valid every 64 clocks; decimator fixed R=64)
  - sample_shift = 1 (250 kHz BW, 2x oversampled) or 2 (125 kHz BW, 4x oversampled)
  - M = 1 << (SF + sample_shift)  -- symbol period in output samples
  - Register 0x0A = BW_CFG: bit[0] bw_sel (0=250kHz, 1=125kHz); write-gated during packet
  - n_acc readback: 3 bytes at 0x21[1:0]/0x22/0x23 (18-bit)

Full scenario (sc_lock + training_done + n_acc + remod + registers) runs for
every SF7-SF12 x BW250/125 combination. Run under Verilator (SIM=verilator,
cocotb_trouper_top/Makefile) -- ~7.7x faster than Icarus (job 3218 vs 3268),
which is what makes full-depth coverage at every SF affordable; under Icarus
this previously ran sc_lock-only for SF8-12 to keep sim time bounded.
"""

import math
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

CLK_NS   = 31.25    # 32 MHz
SCK_HALF = 62.5     # 8 MHz SPI half-period (ns)


# ---------------------------------------------------------------------------
# SPI helpers
# ---------------------------------------------------------------------------

async def _spi_byte(dut, tx):
    rx = 0
    for bit in range(7, -1, -1):
        dut.SPI_MOSI.value = (tx >> bit) & 1
        await Timer(SCK_HALF, unit="ns")
        dut.SPI_SCK.value = 1
        await Timer(SCK_HALF, unit="ns")
        rx = (rx << 1) | int(dut.SPI_MISO.value)
        dut.SPI_SCK.value = 0
    return rx


async def spi_write(dut, addr, data):
    dut.HOST_CS.value = 0
    await Timer(SCK_HALF, unit="ns")
    await _spi_byte(dut, addr & 0x7F)          # R/W=0
    await _spi_byte(dut, data & 0xFF)
    await Timer(SCK_HALF, unit="ns")
    dut.HOST_CS.value = 1
    await Timer(500, unit="ns")


async def spi_read(dut, addr):
    dut.HOST_CS.value = 0
    await Timer(SCK_HALF, unit="ns")
    await _spi_byte(dut, 0x80 | (addr & 0x7F))  # R/W=1
    data = await _spi_byte(dut, 0xFF)
    await Timer(SCK_HALF, unit="ns")
    dut.HOST_CS.value = 1
    await Timer(500, unit="ns")
    return data


async def spi_burst_write(dut, addr, data_bytes):
    dut.HOST_CS.value = 0
    await Timer(SCK_HALF, unit="ns")
    await _spi_byte(dut, addr & 0x7F)
    for b in data_bytes:
        await _spi_byte(dut, b & 0xFF)
    await Timer(SCK_HALF, unit="ns")
    dut.HOST_CS.value = 1
    await Timer(500, unit="ns")


# ---------------------------------------------------------------------------
# SDM stimulus (background task)
# ---------------------------------------------------------------------------

async def sdm_driver(dut, sf, bw_khz):
    """
    First-order SDM driving all four IQ_DATA_I/Q inputs identically (NT=1).

    CW period P=8 iq_valid samples regardless of SF.  At 1/8 normalised
    frequency the dc_removal highpass (corner ~ 1/32) attenuates by <3%
    for all SF values, so effective CIC amplitude ~ A for every SF.

    Amplitude A=31 chosen so the sc_detector e_slice guard is satisfied for
    SF7/BW250 (A^2x256/1024 = 240 >> 91) and accumulator headroom holds
    to SF12/BW125 (A^2x16384/1024 = 15376 < 16384 = 2^14 OK for 24-bit acc).

    clk_per_iq = 64: sd_decimator_poly has fixed R=64 (CIC-16 x HB1 x HB2).
    """
    clk_per_iq = 64    # iq_valid every 64 clocks
    P = 8              # CW period in iq_valid samples
    A = 31

    stim_i = [round(A * math.cos(2 * math.pi * k / P)) for k in range(P)]
    stim_q = [round(A * math.sin(2 * math.pi * k / P)) for k in range(P)]

    acc_i = acc_q = 0
    sine_ptr = 0
    bit_cnt  = 0

    while True:
        await RisingEdge(dut.IQ_CLK)

        xi, xq = stim_i[sine_ptr], stim_q[sine_ptr]

        if acc_i >= 0:
            bit_i = 1; acc_i += xi - 127
        else:
            bit_i = 0; acc_i += xi + 127

        if acc_q >= 0:
            bit_q = 1; acc_q += xq - 127
        else:
            bit_q = 0; acc_q += xq + 127

        bits_i = (bit_i << 3) | (bit_i << 2) | (bit_i << 1) | bit_i
        bits_q = (bit_q << 3) | (bit_q << 2) | (bit_q << 1) | bit_q
        dut.IQ_DATA_I.value = bits_i
        dut.IQ_DATA_Q.value = bits_q

        bit_cnt += 1
        if bit_cnt >= clk_per_iq:
            bit_cnt  = 0
            sine_ptr = (sine_ptr + 1) % P


# ---------------------------------------------------------------------------
# Core scenario
# ---------------------------------------------------------------------------

async def run_scenario(dut, sf, bw_khz, *, full):
    """
    full=True  -- SF7: sc_lock + training_done + REMOD toggles + registers.
    full=False -- SF8-12: sc_lock only (training takes 8*M^2 clk cycles).
    """
    sample_shift = 1 if bw_khz == 250 else 2
    M          = 1 << (sf + sample_shift)   # output samples per symbol
    clk_per_iq = 64
    tag        = f"SF{sf}/BW{bw_khz}"

    # -- reset ----------------------------------------------------------------
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

    # -- start SDM -----------------------------------------------------------
    cocotb.start_soon(sdm_driver(dut, sf, bw_khz))

    # -- SPI settle: prime the interface (first read may return stale) --------
    await spi_read(dut, 0x00)   # CHIP_ID (discard)
    await spi_read(dut, 0x09)   # SF_CFG  (discard)

    # -- configure SF and BW before enabling PSRAM ---------------------------
    await spi_write(dut, 0x09, sf & 0x0F)
    # BW_CFG[0] bw_sel: 0=250kHz (sample_shift=1), 1=125kHz (sample_shift=2)
    await spi_write(dut, 0x0A, 0 if bw_khz == 250 else 1)

    # -- verify BW_CFG readback ----------------------------------------------
    bw_rb = await spi_read(dut, 0x0A)
    expected_bw = 0 if bw_khz == 250 else 1
    assert (bw_rb & 0x01) == expected_bw, \
        f"{tag}: BW_CFG readback 0x{bw_rb:02X} expected bit0={expected_bw}"

    # -- SC threshold: sc_thr=0x0100 (1 hit fires lock) ----------------------
    await spi_write(dut, 0x0C, 0x01)   # sc_thr[15:8]
    await spi_write(dut, 0x0D, 0x00)   # sc_thr[7:0]
    await spi_write(dut, 0x0E, 0x00)   # sc_hits_req = 0

    # -- enable PSRAM ---------------------------------------------------------
    await spi_write(dut, 0x70, 0x01)

    # -- poll PSRAM INIT_DONE (0x71[3]) --------------------------------------
    init_ok = False
    for _ in range(500):
        await Timer(8 * CLK_NS, unit="ns")
        if (await spi_read(dut, 0x71)) & 0x08:
            init_ok = True
            break
    assert init_ok, f"{tag}: PSRAM INIT_DONE never set"
    dut._log.info(f"{tag}: PSRAM init OK")

    # -- poll sc_lock (IRQ_STATUS[0] at 0x02) --------------------------------
    # del_rdy requires del_n = M samples (warm-up) before sc_lock can fire.
    # Budget 20 symbol periods beyond the warm-up.
    sym_ns    = M * clk_per_iq * CLK_NS
    max_polls = 20

    lock_ok = False
    for poll_i in range(max_polls):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x01:
            lock_ok = True
            break
        if poll_i < 5 or poll_i % max(1, max_polls // 10) == 0:
            del_rdy  = int(dut.u_dut.u_psram.del_rdy.value)
            sym_cnt  = int(dut.u_dut.u_sc.sym_cnt.value)
            acc_ci0  = dut.u_dut.u_sc.acc_ci0.value
            sc_stat  = dut.u_dut.u_sc.sc_stat.value
            dut._log.info(
                f"{tag} poll[{poll_i}] del_rdy={del_rdy} sym_cnt={sym_cnt} "
                f"acc_ci0={acc_ci0} sc_stat={sc_stat}"
            )
    assert lock_ok, f"{tag}: sc_lock never fired after {max_polls} polls"
    dut._log.info(f"{tag}: sc_lock OK")

    if not full:
        return

    # -- clear IRQ ------------------------------------------------------------
    await spi_write(dut, 0x03, 0xFF)

    # -- poll training_done (IRQ_STATUS[1]) -----------------------------------
    # Training window = 8*M samples at 500 kS/s; budget 40 polls each M samples.
    train_ok = False
    for _ in range(40):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x02:
            train_ok = True
            break
    assert train_ok, f"{tag}: training_done never fired"
    dut._log.info(f"{tag}: training_done OK")

    # -- verify n_acc readback (18-bit across 3 bytes at 0x21/0x22/0x23) -----
    n_hi  = await spi_read(dut, 0x21)   # [17:16] in bits [1:0]
    n_mid = await spi_read(dut, 0x22)   # [15:8]
    n_lo  = await spi_read(dut, 0x23)   # [7:0]
    n_acc_rb = ((n_hi & 0x03) << 16) | (n_mid << 8) | n_lo
    # Training window spans [timing_ref, timing_ref + 8*M), but training_acc
    # accumulates FORWARD from arming at sc_lock -- and with SC_HITS_REQ=0 the
    # lock fires at the END of the window's first symbol (timing_ref points at
    # that symbol's start: lock_mark - 1*M + 1). The first symbol is therefore
    # already in the past at arming and never accumulated: n_acc = 7*M - 1.
    # (Until the 2026-07-06 sc_detector sample_count double-count fix,
    # timing_ref was inflated by ~2 symbols, which pushed the window entirely
    # after the lock and made n_acc read exactly 8*M -- that value encoded the
    # counter bug, not the design intent. Z is normalized by the n_acc
    # readback, so the partial window is functionally correct.)
    expected_n = 7 * M - 1
    # Allow a few samples for arming/pipeline latency
    assert abs(n_acc_rb - expected_n) <= 4, \
        f"{tag}: n_acc={n_acc_rb} expected~{expected_n}"
    dut._log.info(f"{tag}: n_acc={n_acc_rb} (expected {expected_n})")

    # -- write EGC weights ----------------------------------------------------
    await spi_burst_write(dut, 0x30, [
        0x40, 0x00, 0x00, 0x00,   # ant 0
        0x40, 0x00, 0x00, 0x00,   # ant 1
        0x40, 0x00, 0x00, 0x00,   # ant 2
        0x40, 0x00, 0x00, 0x00,   # ant 3
    ])

    # -- commit weights -------------------------------------------------------
    await spi_write(dut, 0x1E, 0x01)   # W_COMMIT (WP1)

    # -- verify REMOD_A_I / REMOD_A_Q both toggle ----------------------------
    seen_i = {0: False, 1: False}
    seen_q = {0: False, 1: False}
    for _ in range(2000):
        await RisingEdge(dut.IQ_CLK)
        seen_i[int(dut.REMOD_A_I.value) & 1] = True
        seen_q[int(dut.REMOD_A_Q.value) & 1] = True
        if all(seen_i.values()) and all(seen_q.values()):
            break
    assert all(seen_i.values()), f"{tag}: REMOD_A_I stuck"
    assert all(seen_q.values()), f"{tag}: REMOD_A_Q stuck"

    # -- BW_CFG write-gated during packet: verify register stays locked -------
    orig_bw = await spi_read(dut, 0x0A)
    await spi_write(dut, 0x0A, orig_bw ^ 0x01)   # attempt flip during active packet
    locked_bw = await spi_read(dut, 0x0A)
    assert (locked_bw & 0x01) == (orig_bw & 0x01), \
        f"{tag}: BW_CFG changed during packet (was 0x{orig_bw:02X}, now 0x{locked_bw:02X})"
    dut._log.info(f"{tag}: BW_CFG write-lock during packet OK")

    # -- SF_CFG write-gated during packet: verify register stays locked -------
    # Regression for Open Risks #30: SF_CFG (0x09) had no packet_active gate
    # (unlike BW_CFG), so a mid-packet SF write would desynchronize sc_detector
    # and training_acc symbol-length arithmetic with no re-arm to recover.
    orig_sf = await spi_read(dut, 0x09)
    await spi_write(dut, 0x09, (orig_sf & 0xF0) | ((orig_sf & 0x0F) ^ 0x0F))
    locked_sf = await spi_read(dut, 0x09)
    assert (locked_sf & 0x0F) == (orig_sf & 0x0F), \
        f"{tag}: SF_CFG changed during packet (was 0x{orig_sf:02X}, now 0x{locked_sf:02X})"
    dut._log.info(f"{tag}: SF_CFG write-lock during packet OK")

    # -- TRPR-PSR-020: sticky SAMPLE_SKIP must stay 0 across a full packet of
    # sustained iq_valid (the directed check the spec text claims exists --
    # this makes the claim true). A nonzero read here means the QPI engine
    # missed a capture window (see Open Risks #30, stale R=128 budget).
    psram_status = await spi_read(dut, 0x71)
    assert not (psram_status & 0x04), \
        f"{tag}: PSRAM SAMPLE_SKIP sticky flag set (PSRAM_STATUS=0x{psram_status:02X})"
    dut._log.info(f"{tag}: SAMPLE_SKIP clean (PSRAM_STATUS=0x{psram_status:02X})")

    # -- register spot-checks -------------------------------------------------
    chip_id = await spi_read(dut, 0x00)
    assert chip_id == 0xA7, f"{tag}: CHIP_ID=0x{chip_id:02X} (expected 0xA7)"
    w0_re = await spi_read(dut, 0x30)
    assert w0_re != 0, f"{tag}: W0_re=0x00 (weight not committed)"
    dut._log.info(f"{tag}: PASS (CHIP_ID=0x{chip_id:02X} W0_re=0x{w0_re:02X})")


# ---------------------------------------------------------------------------
# Test declarations -- full chain (sc_lock + training + n_acc + remod +
# registers) for all SF7-SF12 x BW250/125. Previously SF8-12 ran sc_lock-only
# to keep sim time bounded under Icarus; now run under Verilator (~7.7x
# faster, confirmed job 3268/3269), full-depth coverage at every SF is
# affordable -- see run_scenario, which is fully SF-generic (expected_n=8*M
# scales automatically, nothing hardcoded to SF7).
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_sf7_bw250(dut):
    """SF7 / 250 kHz -- full chain: sc_lock + training + n_acc + remod + registers."""
    await run_scenario(dut, sf=7, bw_khz=250, full=True)

@cocotb.test()
async def test_sf7_bw125(dut):
    """SF7 / 125 kHz -- full chain."""
    await run_scenario(dut, sf=7, bw_khz=125, full=True)

@cocotb.test()
async def test_sf8_bw250(dut):
    """SF8 / 250 kHz -- full chain."""
    await run_scenario(dut, sf=8, bw_khz=250, full=True)

@cocotb.test()
async def test_sf8_bw125(dut):
    """SF8 / 125 kHz -- full chain."""
    await run_scenario(dut, sf=8, bw_khz=125, full=True)

@cocotb.test()
async def test_sf9_bw250(dut):
    """SF9 / 250 kHz -- full chain."""
    await run_scenario(dut, sf=9, bw_khz=250, full=True)

@cocotb.test()
async def test_sf9_bw125(dut):
    """SF9 / 125 kHz -- full chain."""
    await run_scenario(dut, sf=9, bw_khz=125, full=True)

@cocotb.test()
async def test_sf10_bw250(dut):
    """SF10 / 250 kHz -- full chain."""
    await run_scenario(dut, sf=10, bw_khz=250, full=True)

@cocotb.test()
async def test_sf10_bw125(dut):
    """SF10 / 125 kHz -- full chain."""
    await run_scenario(dut, sf=10, bw_khz=125, full=True)

@cocotb.test()
async def test_sf11_bw250(dut):
    """SF11 / 250 kHz -- full chain."""
    await run_scenario(dut, sf=11, bw_khz=250, full=True)

@cocotb.test()
async def test_sf11_bw125(dut):
    """SF11 / 125 kHz -- full chain."""
    await run_scenario(dut, sf=11, bw_khz=125, full=True)

@cocotb.test()
async def test_sf12_bw250(dut):
    """SF12 / 250 kHz -- full chain."""
    await run_scenario(dut, sf=12, bw_khz=250, full=True)

@cocotb.test()
async def test_sf12_bw125(dut):
    """SF12 / 125 kHz -- full chain."""
    await run_scenario(dut, sf=12, bw_khz=125, full=True)
