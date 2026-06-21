"""
test_capture_playback.py — drive trouper_top with a *measured* IQ capture.

Instead of the synthetic CW source in test_trouper_top_hb.py, this reads a
real baseband capture (lora-capture/captures/*.npy), resamples it to 32 MS/s,
fans it out to NR=4 branches with independent AWGN, ΣΔ-modulates to 1-bit, and
plays the bitstream onto IQ_DATA_I/Q one bit per IQ_CLK. SF/BW are set over the
same SPI register interface (helpers imported from test_trouper_top_hb).

Run on Verilator for speed (cocotb_trouper_capture/Makefile sets SIM=verilator).
Driving millions of clocks bit-by-bit under Icarus is impractical, so clip the
capture with CAPTURE_START / CAPTURE_NSAMP (sample counts at the *capture* rate).

Environment:
    CAPTURE_NPY    path to a .npy capture (required)
    CAPTURE_SF     spreading factor 7..12          (default 7)
    CAPTURE_BW     bandwidth kHz: 125 or 250       (default 250)
    CAPTURE_STAGE  lock | train | full             (default full)
                   lock = stop at sc_lock (fast, for high SF); train adds
                   training_done + ZDIAG; full adds weight commit + combine + remod
    CAPTURE_START  first capture sample to use     (default 0)
    CAPTURE_NSAMP  capture samples to use          (default 60000 = 30 ms @2MS/s)
    CAPTURE_SNRDB  AWGN SNR in dB (shared floor)    (default "" = noiseless)
    CAPTURE_SEED   RNG seed for channel + AWGN      (default 0)
    CAPTURE_CHAN   "awgn" (flat) or "rayleigh"      (default awgn)
    CAPTURE_NTAPS  multipath taps per antenna       (default 3, rayleigh only)
    CAPTURE_DSPREAD delay spread in ns              (default 300, rayleigh only)
    CAPTURE_PHASES comma per-antenna phase in deg   (default "" = 0,0,0,0)
    CAPTURE_GAINS  comma per-antenna gain in dB      (default "" = 0,0,0,0)
                   distinct values -> the test asserts ZDIAG (per-branch
                   Σ|raw|²) ranks the branches in the same order, i.e. the
                   chip's training measured the stronger antennas as stronger.
"""

import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from test_trouper_top_hb import (
    CLK_NS, spi_read, spi_write, spi_burst_write,
)
import iq_capture


# ---------------------------------------------------------------------------
# Stimulus driver: play prepared 1-bit branches onto the IQ pads
# ---------------------------------------------------------------------------

async def capture_driver(dut, bits_i, bits_q):
    """Drive IQ_DATA_I/Q[3:0] from per-branch 0/1 bitstreams, one column per
    IQ_CLK. bits_* are shape (4, N). Holds the last sample after the clip ends.
    """
    n = bits_i.shape[1]
    for k in range(n):
        await RisingEdge(dut.IQ_CLK)
        ci = bits_i[:, k]
        cq = bits_q[:, k]
        nib_i = (int(ci[3]) << 3) | (int(ci[2]) << 2) | (int(ci[1]) << 1) | int(ci[0])
        nib_q = (int(cq[3]) << 3) | (int(cq[2]) << 2) | (int(cq[1]) << 1) | int(cq[0])
        dut.IQ_DATA_I.value = nib_i
        dut.IQ_DATA_Q.value = nib_q
    # leave the pads at the final value; caller decides when to stop polling


def _env_int(name, default):
    v = os.environ.get(name, "")
    return int(v) if v.strip() else default


# ZDIAG_k = Σ|raw_k|² top 16 bits [31:16], big-endian (HI,LO) per branch.
ZDIAG_ADDR = {0: (0x64, 0x65), 1: (0x66, 0x67), 2: (0x68, 0x69), 3: (0x6A, 0x6B)}


async def read_zdiag(dut):
    """Read the four per-branch diagonal energies as 16-bit ints."""
    z = []
    for b in range(4):
        hi = await spi_read(dut, ZDIAG_ADDR[b][0])
        lo = await spi_read(dut, ZDIAG_ADDR[b][1])
        z.append((hi << 8) | lo)
    return z


# ---------------------------------------------------------------------------
# Test
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_capture_playback(dut):
    npy = os.environ.get("CAPTURE_NPY", "")
    assert npy, "set CAPTURE_NPY to a .npy capture path"

    sf      = _env_int("CAPTURE_SF", 7)
    bw_khz  = _env_int("CAPTURE_BW", 250)
    start   = _env_int("CAPTURE_START", 0)
    nsamp   = _env_int("CAPTURE_NSAMP", 60000)
    seed    = _env_int("CAPTURE_SEED", 0)
    snr_env = os.environ.get("CAPTURE_SNRDB", "").strip()
    snr_db  = float(snr_env) if snr_env else None

    chan    = os.environ.get("CAPTURE_CHAN", "awgn").strip() or "awgn"
    n_taps  = _env_int("CAPTURE_NTAPS", 3)
    dspread = float(os.environ.get("CAPTURE_DSPREAD", "300").strip() or 300)
    ph_env  = os.environ.get("CAPTURE_PHASES", "").strip()
    import math as _math
    phases  = ([_math.radians(float(p)) for p in ph_env.split(",")]
               if ph_env else None)
    gn_env  = os.environ.get("CAPTURE_GAINS", "").strip()
    gains_db = ([float(g) for g in gn_env.split(",")] if gn_env else None)

    sample_shift = 1 if bw_khz == 250 else 2
    M          = 1 << (sf + sample_shift)
    clk_per_iq = 64
    tag        = f"CAP SF{sf}/BW{bw_khz}"

    # -- prepare stimulus (numpy, before any RTL time advances) --------------
    dut._log.info(f"{tag}: loading {npy} [{start}:{start + nsamp}] "
                  f"snr={snr_db} chan={chan} ntaps={n_taps} dspread={dspread}ns")
    bits_i, bits_q, meta, branch_power = iq_capture.prepare_stimulus(
        npy, start=start, nsamp=nsamp, n_branches=4, snr_db=snr_db, seed=seed,
        channel=chan, n_taps=n_taps, delay_spread_ns=dspread, phases=phases,
        gains_db=gains_db)
    n32 = bits_i.shape[1]
    dut._log.info(f"{tag}: {n32} chip samples @32MS/s "
                  f"({n32 / 32e6 * 1e3:.2f} ms), sr_in={meta.get('sample_rate_sps')}")
    dut._log.info(f"{tag}: realised branch power = "
                  f"{[round(p, 5) for p in branch_power]}")

    # -- reset ---------------------------------------------------------------
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

    # -- start capture playback ----------------------------------------------
    drv = cocotb.start_soon(capture_driver(dut, bits_i, bits_q))

    # -- SPI settle ----------------------------------------------------------
    await spi_read(dut, 0x00)
    await spi_read(dut, 0x09)

    # -- configure SF / BW ---------------------------------------------------
    await spi_write(dut, 0x09, sf & 0x0F)
    await spi_write(dut, 0x0A, 0 if bw_khz == 250 else 1)
    bw_rb = await spi_read(dut, 0x0A)
    assert (bw_rb & 0x01) == (0 if bw_khz == 250 else 1), \
        f"{tag}: BW_CFG readback 0x{bw_rb:02X}"

    # -- SC threshold (1 hit fires lock) -------------------------------------
    await spi_write(dut, 0x0C, 0x01)
    await spi_write(dut, 0x0D, 0x00)
    await spi_write(dut, 0x0E, 0x00)

    # -- enable PSRAM + wait INIT_DONE ---------------------------------------
    await spi_write(dut, 0x70, 0x01)
    init_ok = False
    for _ in range(500):
        await Timer(8 * CLK_NS, unit="ns")
        if (await spi_read(dut, 0x71)) & 0x08:
            init_ok = True
            break
    assert init_ok, f"{tag}: PSRAM INIT_DONE never set"

    # -- poll sc_lock over the playback window -------------------------------
    sym_ns = M * clk_per_iq * CLK_NS
    budget_ns = n32 * CLK_NS          # total playback duration
    max_polls = max(4, int(budget_ns / sym_ns))

    lock_ok = False
    for poll_i in range(max_polls):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x01:
            lock_ok = True
            dut._log.info(f"{tag}: sc_lock at poll {poll_i} "
                          f"(~{poll_i * M * clk_per_iq / 32e6 * 1e3:.2f} ms)")
            break

    # sc_lock is the headline result; report rather than hard-fail so a clip
    # that happens to miss a preamble still surfaces useful diagnostics.
    if not lock_ok:
        sc_stat = dut.u_dut.u_sc.sc_stat.value
        dut._log.warning(f"{tag}: no sc_lock in {max_polls} polls "
                         f"(sc_stat={sc_stat}); try a different "
                         f"CAPTURE_START/NSAMP window or check SF/BW")
    assert lock_ok, f"{tag}: sc_lock never fired over the capture window"

    # Stage gate: "lock" stops here (fast for high SF), "train" adds training +
    # ZDIAG, "full" (default) adds weight commit + combine + remod.
    stage = os.environ.get("CAPTURE_STAGE", "full").strip() or "full"
    if stage == "lock":
        drv.cancel()
        return

    # -- training: clear IRQ then poll training_done (IRQ_STATUS[1]) ----------
    await spi_write(dut, 0x03, 0xFF)
    train_ok = False
    remaining = max(8, max_polls - poll_i)
    for _ in range(remaining):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x02:
            train_ok = True
            break
    assert train_ok, f"{tag}: training_done never fired within the window"
    dut._log.info(f"{tag}: training_done OK")

    # -- per-branch energy: ZDIAG_k = Σ|raw_k|² ------------------------------
    zdiag = await read_zdiag(dut)
    dut._log.info(f"{tag}: ZDIAG = {zdiag}")

    # Every branch should have accumulated real signal energy.
    assert all(z > 0 for z in zdiag), f"{tag}: a branch has ZDIAG=0: {zdiag}"

    # The chip's per-branch energy must rank the antennas the same way as the
    # power we actually fed in (branch_power) — strongest received -> largest
    # ZDIAG, weakest -> smallest. This is the "MRC sees the stronger branches"
    # check (HW MRC weights themselves are not register-exposed). Reference is
    # the realised power, not nominal gains: under frequency-selective fading
    # the two differ, and the chip must track what it actually received.
    #
    # Only assert when there is a clear spread (>3 dB strongest/weakest) so the
    # shared AWGN floor can't flip two near-equal branches.
    if max(branch_power) > 2.0 * min(branch_power):
        p_strong = max(range(4), key=lambda b: branch_power[b])
        p_weak   = min(range(4), key=lambda b: branch_power[b])
        z_strong = max(range(4), key=lambda b: zdiag[b])
        z_weak   = min(range(4), key=lambda b: zdiag[b])
        import math as _m
        spread_db = 10 * _m.log10(max(branch_power) / min(branch_power))
        dut._log.info(f"{tag}: power spread {spread_db:.1f} dB -> strongest "
                      f"ant{p_strong}, weakest ant{p_weak}; ZDIAG argmax "
                      f"ant{z_strong}, argmin ant{z_weak}")
        assert z_strong == p_strong, \
            f"{tag}: strongest branch ant{p_strong} (pwr={branch_power}) " \
            f"but ZDIAG max is ant{z_strong} ({zdiag})"
        assert z_weak == p_weak, \
            f"{tag}: weakest branch ant{p_weak} (pwr={branch_power}) " \
            f"but ZDIAG min is ant{z_weak} ({zdiag})"
        dut._log.info(f"{tag}: ZDIAG ranking matches received branch power PASS")
    else:
        dut._log.info(f"{tag}: branch power spread <3 dB; skipping ZDIAG rank "
                      f"assertion (set CAPTURE_GAINS for a deliberate ordering)")

    # -- full chain: weights -> MRC combine -> sd_remod ----------------------
    # trouper_top has no weight_gen; the combiner reads the firmware shadow bank
    # (0x30-0x3F) gated by W_COMMIT. True MRC weight derivation (eigenvector from
    # the Z pairs) is firmware — out of scope here. This checks the *datapath*:
    # commit EGC weights and confirm real decimated signal flows combine->remod.
    if stage == "full":
        # clear IRQ then commit equal-gain weights (Q1.15: 0x4000 = 0.5 real)
        await spi_write(dut, 0x03, 0xFF)
        await spi_burst_write(dut, 0x30, [
            0x40, 0x00, 0x00, 0x00,   # ant0  re=0x4000, im=0
            0x40, 0x00, 0x00, 0x00,   # ant1
            0x40, 0x00, 0x00, 0x00,   # ant2
            0x40, 0x00, 0x00, 0x00,   # ant3
        ])
        await spi_write(dut, 0x1E, 0x01)        # W_COMMIT (W1P)

        # W_VALID should latch (WGT_CTRL[1] / PACKET_STATUS[6])
        wgt = await spi_read(dut, 0x1E)
        dut._log.info(f"{tag}: WGT_CTRL after commit = 0x{wgt:02X} "
                      f"(W_VALID={ (wgt>>1)&1 })")

        # Watch the combiner output and the remod pads together: confirm the
        # combiner produces non-trivial output AND both remod bits toggle.
        seen_i = {0: False, 1: False}
        seen_q = {0: False, 1: False}
        comb_nonzero = False
        comb_active  = False
        for _ in range(4000):
            await RisingEdge(dut.IQ_CLK)
            seen_i[int(dut.REMOD_A_I.value) & 1] = True
            seen_q[int(dut.REMOD_A_Q.value) & 1] = True
            vv = dut.u_dut.comb_y_valid.value
            if vv.is_resolvable and int(vv):
                comb_active = True
                yi, yq = dut.u_dut.comb_y_i.value, dut.u_dut.comb_y_q.value
                if yi.is_resolvable and yq.is_resolvable and (int(yi) or int(yq)):
                    comb_nonzero = True
            if all(seen_i.values()) and all(seen_q.values()) and comb_nonzero:
                break

        assert comb_active, f"{tag}: combiner never asserted y_valid (no MRC output)"
        assert comb_nonzero, f"{tag}: combiner output stuck at 0 (signal not reaching combine)"
        assert all(seen_i.values()), f"{tag}: REMOD_A_I stuck (sd_remod not modulating)"
        assert all(seen_q.values()), f"{tag}: REMOD_A_Q stuck"
        dut._log.info(f"{tag}: full chain OK — combine active + non-zero, "
                      f"REMOD_A_I/Q both toggling")

    drv.cancel()
