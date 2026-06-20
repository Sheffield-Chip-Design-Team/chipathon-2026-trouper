"""
test_trouper_top.py — cocotb integration tests for trouper_top.

Sweeps SF7–SF12 × BW 250 kHz / 125 kHz.

Full scenario (sc_lock + training_done + remod + register checks) runs only
for SF7, where training completes in ~130 K cycles.  For SF8–SF12 the
training window scales as 8×M samples and becomes impractical, so those
tests assert sc_lock only — still exercising the decimator, PSRAM delay
buffer, and SC detector for every SF/BW combination.

Run via the cocotb_trouper_top/Makefile or via `make sim_trouper_cocotb`
from rtl-test/.  Select a subset with TESTCASE=test_sf7_bw250,test_sf7_bw125.
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
    frequency the dc_removal highpass (corner ≈ 0.01) attenuates by <3%
    for all SF values, so effective CIC amplitude ≈ A for every SF.

    Amplitude A=31 chosen so the sc_detector e_slice guard (requires
    eval_e_acc[25:13]>0 ↔ A_eff²×M/1024 ≥ 91) is satisfied for SF7
    (A²×128/1024 = 119 → 119²=14161 >> 8192 ✓) and the 24-bit accumulator
    and 13-bit eval_ci0 do not overflow for SF12
    (A²×4096/1024 = 3844 < 4095 ✓, A²×4096 = 3.84M < 8.39M ✓).

    clk_per_iq is always 128: sd_decimator_cic_tdm8 has no decim_ratio port
    so iq_valid fires every 128 clocks regardless of the decim_ratio register.
    """
    clk_per_iq = 128   # iq_valid every 128 clocks; decim_ratio reg has no effect
    P = 8              # CW period in iq_valid samples (well above dc_removal corner)
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
    full=True  — SF7: sc_lock + training_done + REMOD toggles + reg checks.
    full=False — SF8–12: sc_lock only (training takes 8×M²×clk cycles).
    """
    M          = 1 << sf
    clk_per_iq = 128  # always 128: sd_decimator_cic_tdm8 ignores decim_ratio register
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
    await spi_write(dut, 0x0A, 1 if bw_khz == 125 else 0)  # decim_ratio

    # -- SC threshold: sc_thr=0x0100 (sc_thr[11:0]=256, positive 13-bit) -----
    # sc_hits_req=0 → 1 hit fires lock (avoids 2× symbol wait at high SF).
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
    # sc_lock fires within ~3 evaluations (1 X-flush + 2 valid); 20 gives margin.
    sym_ns   = M * clk_per_iq * CLK_NS
    max_polls = 20

    lock_ok = False
    for poll_i in range(max_polls):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x01:
            lock_ok = True
            break
        if poll_i < 5 or poll_i % (max(1, max_polls // 10)) == 0:
            del_rdy  = int(dut.u_dut.u_psram.del_rdy.value)
            sym_cnt  = int(dut.u_dut.u_sc.sym_cnt.value)
            acc_ci0  = dut.u_dut.u_sc.acc_ci0.value
            sc_stat  = dut.u_dut.u_sc.sc_stat.value
            dut._log.info(f"{tag} poll[{poll_i}] del_rdy={del_rdy} sym_cnt={sym_cnt} acc_ci0={acc_ci0} sc_stat={sc_stat}")
    assert lock_ok, f"{tag}: sc_lock never fired after {max_polls} polls"
    dut._log.info(f"{tag}: sc_lock OK")

    if not full:
        return

    # -- clear IRQ ------------------------------------------------------------
    await spi_write(dut, 0x03, 0xFF)

    # -- poll training_done (IRQ_STATUS[1]) -----------------------------------
    # Training window = 8×M samples; poll every symbol, budget 40×M symbols.
    train_budget = int(40 * M * sym_ns / sym_ns) + 10
    train_ok = False
    for _ in range(train_budget):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x02:
            train_ok = True
            break
    assert train_ok, f"{tag}: training_done never fired"
    dut._log.info(f"{tag}: training_done OK")

    # -- write EGC weights (W_re=0x40, W_im=0x00 for all 4 antennas) ---------
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

    # -- register spot-checks -------------------------------------------------
    chip_id = await spi_read(dut, 0x00)
    assert chip_id == 0xA7, f"{tag}: CHIP_ID=0x{chip_id:02X} (expected 0xA7)"
    w0_re = await spi_read(dut, 0x30)
    assert w0_re != 0, f"{tag}: W0_re=0x00 (weight not committed)"
    dut._log.info(f"{tag}: PASS (CHIP_ID=0x{chip_id:02X} W0_re=0x{w0_re:02X})")


# ---------------------------------------------------------------------------
# Test declarations — SF7 full, SF8-SF12 sc_lock only
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_sf7_bw250(dut):
    """SF7 / 250 kHz — full chain: sc_lock + training + remod + registers."""
    await run_scenario(dut, sf=7, bw_khz=250, full=True)

@cocotb.test()
async def test_sf7_bw125(dut):
    """SF7 / 125 kHz — full chain."""
    await run_scenario(dut, sf=7, bw_khz=125, full=True)

@cocotb.test()
async def test_sf8_bw250(dut):
    """SF8 / 250 kHz — sc_lock only."""
    await run_scenario(dut, sf=8, bw_khz=250, full=False)

@cocotb.test()
async def test_sf8_bw125(dut):
    """SF8 / 125 kHz — sc_lock only."""
    await run_scenario(dut, sf=8, bw_khz=125, full=False)

@cocotb.test()
async def test_sf9_bw250(dut):
    """SF9 / 250 kHz — sc_lock only."""
    await run_scenario(dut, sf=9, bw_khz=250, full=False)

@cocotb.test()
async def test_sf9_bw125(dut):
    """SF9 / 125 kHz — sc_lock only."""
    await run_scenario(dut, sf=9, bw_khz=125, full=False)

@cocotb.test()
async def test_sf10_bw250(dut):
    """SF10 / 250 kHz — sc_lock only."""
    await run_scenario(dut, sf=10, bw_khz=250, full=False)

@cocotb.test()
async def test_sf10_bw125(dut):
    """SF10 / 125 kHz — sc_lock only."""
    await run_scenario(dut, sf=10, bw_khz=125, full=False)

@cocotb.test()
async def test_sf11_bw250(dut):
    """SF11 / 250 kHz — sc_lock only."""
    await run_scenario(dut, sf=11, bw_khz=250, full=False)

@cocotb.test()
async def test_sf11_bw125(dut):
    """SF11 / 125 kHz — sc_lock only."""
    await run_scenario(dut, sf=11, bw_khz=125, full=False)

@cocotb.test()
async def test_sf12_bw250(dut):
    """SF12 / 250 kHz — sc_lock only."""
    await run_scenario(dut, sf=12, bw_khz=250, full=False)

@cocotb.test()
async def test_sf12_bw125(dut):
    """SF12 / 125 kHz — sc_lock only."""
    await run_scenario(dut, sf=12, bw_khz=125, full=False)
