"""
test_capture_two_packet.py — sc_lock re-arm proven against a REAL capture.

The synthetic tb_trouper_two_packet.v (SGE job 3203) is the only place the
sc_lock re-arm fix (Open Risks #2/#3, TRPR-SCD-014, TRPR-IRQ-002/006) has ever
been verified — that testbench builds its own stimulus. This test drives the
same three checks (PK1-1 first lock, ARM-1 de-assert/re-arm, PK2-1 second
lock) from a real off-air capture containing two actual transmitted packets,
using the same capture_driver / iq_capture plumbing as test_capture_playback.py.

Capture choice: lora_20260619_144822_SF7-BW250-gain30.npy has 6 evenly spaced
bursts 2.02 s apart (668000, 4708000, 8748000, ... capture samples @2 MS/s).
Default clip spans burst 1 through burst 2 plus margin.

Environment (subset of test_capture_playback.py's, same meaning):
    CAPTURE_NPY    path to a .npy capture (required)
    CAPTURE_SF     spreading factor 7..12          (default 7)
    CAPTURE_BW     bandwidth kHz: 125 or 250       (default 250)
    CAPTURE_START  first capture sample to use     (default 600000)
    CAPTURE_NSAMP  capture samples to use          (default 4300000)
    CAPTURE_SNRDB / CAPTURE_SEED / CAPTURE_CHAN / CAPTURE_NTAPS / CAPTURE_DSPREAD
                   same as test_capture_playback.py (defaults: noiseless AWGN)

Cost note: ~4.3M capture samples x 16 (resample to 32 MS/s) x 31.25 ns ≈ 2.1e9
ns of simulated time. Measured Verilator throughput for this driver style
(job 3271, single-burst clip) was ~340,585 ns/s -> ~101 minutes real time.
Run in the background.
"""

import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer

from test_trouper_top import CLK_NS, spi_read, spi_write
from test_capture_playback import capture_driver, _env_int
import iq_capture


@cocotb.test()
async def test_capture_two_packet(dut):
    npy = os.environ.get("CAPTURE_NPY", "")
    assert npy, "set CAPTURE_NPY to a .npy capture path"

    sf      = _env_int("CAPTURE_SF", 7)
    bw_khz  = _env_int("CAPTURE_BW", 250)
    start   = _env_int("CAPTURE_START", 600000)
    nsamp   = _env_int("CAPTURE_NSAMP", 4300000)
    seed    = _env_int("CAPTURE_SEED", 0)
    snr_env = os.environ.get("CAPTURE_SNRDB", "").strip()
    snr_db  = float(snr_env) if snr_env else None

    chan    = os.environ.get("CAPTURE_CHAN", "awgn").strip() or "awgn"
    n_taps  = _env_int("CAPTURE_NTAPS", 3)
    dspread = float(os.environ.get("CAPTURE_DSPREAD", "300").strip() or 300)

    sample_shift = 1 if bw_khz == 250 else 2
    M          = 1 << (sf + sample_shift)
    clk_per_iq = 64
    tag        = f"CAP2PKT SF{sf}/BW{bw_khz}"

    # -- prepare stimulus (numpy, before any RTL time advances) --------------
    dut._log.info(f"{tag}: loading {npy} [{start}:{start + nsamp}] "
                  f"snr={snr_db} chan={chan}")
    bits_i, bits_q, meta, branch_power = iq_capture.prepare_stimulus(
        npy, start=start, nsamp=nsamp, n_branches=4, snr_db=snr_db, seed=seed,
        channel=chan, n_taps=n_taps, delay_spread_ns=dspread)
    n32 = bits_i.shape[1]
    dut._log.info(f"{tag}: {n32} chip samples @32MS/s ({n32 / 32e6:.3f} s), "
                  f"sr_in={meta.get('sample_rate_sps')}, "
                  f"branch power={[round(p, 5) for p in branch_power]}")

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

    # -- start capture playback ------------------------------------------------
    drv = cocotb.start_soon(capture_driver(dut, bits_i, bits_q))

    # -- SPI settle -------------------------------------------------------------
    await spi_read(dut, 0x00)
    await spi_read(dut, 0x09)

    # -- configure SF / BW ------------------------------------------------------
    await spi_write(dut, 0x09, sf & 0x0F)
    await spi_write(dut, 0x0A, 0 if bw_khz == 250 else 1)
    bw_rb = await spi_read(dut, 0x0A)
    assert (bw_rb & 0x01) == (0 if bw_khz == 250 else 1), \
        f"{tag}: BW_CFG readback 0x{bw_rb:02X}"

    # -- SC threshold (1 hit fires lock, matches test_capture_playback.py) -----
    await spi_write(dut, 0x0C, 0x01)
    await spi_write(dut, 0x0D, 0x00)
    await spi_write(dut, 0x0E, 0x00)

    # -- enable PSRAM + wait INIT_DONE ------------------------------------------
    await spi_write(dut, 0x70, 0x01)
    init_ok = False
    for _ in range(500):
        await Timer(8 * CLK_NS, unit="ns")
        if (await spi_read(dut, 0x71)) & 0x08:
            init_ok = True
            break
    assert init_ok, f"{tag}: PSRAM INIT_DONE never set"

    sym_ns    = M * clk_per_iq * CLK_NS
    total_ns  = n32 * CLK_NS
    max_polls = max(4, int(total_ns / sym_ns))

    # -- PK1-1: first sc_lock (IRQ_STATUS[0]) -----------------------------------
    lock1_ok = False
    for poll_i in range(max_polls):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x01:
            lock1_ok = True
            dut._log.info(f"{tag}: PK1-1 first sc_lock at poll {poll_i} "
                          f"(~{poll_i * sym_ns / 1e6:.2f} ms)")
            break
    assert lock1_ok, f"{tag}: PK1-1 first sc_lock never fired in {max_polls} polls"

    # -- ARM-1: internal sc_lock de-asserts (packet FSM returns to IDLE) --------
    # Poll the SC detector's internal sc_lock directly (same signal
    # tb_trouper_two_packet.v checks: dut.u_sc.sc_lock there vs
    # dut.u_dut.u_sc.sc_lock here, production hierarchy).
    rearm_ok = False
    remaining = max(8, max_polls - poll_i)
    for poll_j in range(remaining):
        await Timer(sym_ns, unit="ns")
        if int(dut.u_dut.u_sc.sc_lock.value) == 0:
            rearm_ok = True
            dut._log.info(f"{tag}: ARM-1 sc_lock de-asserted at poll {poll_j} "
                          f"(~{poll_j * sym_ns / 1e6:.2f} ms after first lock)")
            break
    assert rearm_ok, f"{tag}: ARM-1 sc_lock never de-asserted (one-shot regression?)"

    # -- PK2-1: second sc_lock fires (proves re-arm, not just de-assert) --------
    await spi_write(dut, 0x03, 0xFF)   # clear IRQ_STATUS before watching for #2
    lock2_ok = False
    remaining2 = max(8, remaining - poll_j)
    for poll_k in range(remaining2):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x01:
            lock2_ok = True
            dut._log.info(f"{tag}: PK2-1 second sc_lock at poll {poll_k} "
                          f"(~{poll_k * sym_ns / 1e6:.2f} ms after re-arm)")
            break
    assert lock2_ok, \
        f"{tag}: PK2-1 second sc_lock never fired (receiver stuck one-shot on real data?)"

    dut._log.info(f"{tag}: PASS — PK1-1 + ARM-1 + PK2-1 all confirmed on real capture")
    drv.cancel()
