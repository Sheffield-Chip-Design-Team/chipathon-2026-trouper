"""
test_mrc_absent_branch.py -- full end-to-end MRC with 1 or 2 antenna branches
absent (no signal reaching them).

Motivation: every existing top-level MRC test drives all four IQ input
streams with real signal. test_bypass_antenna only exercises the bypass_ant
mux for reduced ANTENNA_EN masks; tb_mrc_combiner Test 7 zeroes branches at
the combiner port directly. Neither runs the whole firmware loop
(capture -> decimate -> DC-removal -> SC lock -> training_acc -> Z read over
SPI -> firmware eigenvector -> W shadow write -> W_COMMIT -> combiner) with a
branch that genuinely carries nothing.

Stimulus: the same capture-playback path as test_weight_gen_spi_flow, but one
or two entries of gains_db set to -90 dB (amplitude ~3e-5). After the shared
sigma-delta scale that branch's decimated stream is ~0 -- an antenna that is
physically connected and clocked but receiving no energy (disconnected feed,
dead front-end). ant0 is always kept at full gain: the SC detector keys on
antenna 0 (planning/Open Risks.md #9, memory project_sc_detector_ant0_fade),
so an absent ant0 would just block sc_lock and is a different test.

What this asserts on top of the plain flow:
  - sc_lock and training_done still fire with the dead branch(es) present
  - ZDIAG for each absent branch collapses to a small fraction of the loudest
    live branch (the accumulator sees no energy there)
  - the firmware eigenvector assigns near-zero relative weight to each absent
    branch (compute_eigvec_fw handles the rank-deficient Z)
  - the combiner output is still bit-exact against nonfft_combine_rtl_int8w
    given the recorded RTL inputs and the committed weights (the MAC over a
    zero-weighted zero-input branch must not perturb the result)

Runs under Verilator (see cocotb/mrc_absent_branch/Makefile); imports the
bit-true reference models from sim/, so DESIGN_ROOT must point at a tree with
BOTH src/ and sim/ synced.
"""

import os
import sys
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer
import numpy as np

_design_root = os.environ.get("DESIGN_ROOT", "")
if _design_root and _design_root not in sys.path:
    sys.path.insert(0, _design_root)

from test_trouper_top import (CLK_NS, spi_read, spi_write, spi_burst_write,
                              release_rx_hold)
from test_capture_playback import capture_driver, _env_int
from test_weight_gen_spi_flow import (_read_z_matrix, _read_n_acc,
                                      _encode_w_shadow_bytes,
                                      _verify_combiner_against_oracle)
import iq_capture

from sim.models.eigvec_fw import compute_eigvec_fw


# -90 dB -> amplitude 10**(-90/20) ~ 3.16e-5; after the common full-scale
# sigma-delta normalisation this branch's baseband is far below 1 LSB, so its
# decimated int8 stream is 0 for the whole packet. Not -inf so make_channels'
# amp math and the global-peak scan stay well-conditioned.
ABSENT_DB = -90.0


async def _absent_branch_flow(dut, tag, gains_db):
    """Plain firmware eigenvector flow (cf. test_weight_gen_spi_flow) with a
    parameterised per-antenna gain vector, plus absent-branch assertions."""
    absent = [k for k, g in enumerate(gains_db) if g <= ABSENT_DB]
    live = [k for k in range(4) if k not in absent]
    assert 0 in live, f"{tag}: ant0 must stay live (SC detector keys on it)"

    _shared = os.environ.get("SHARED_DIR", "").strip() or "/foss/shared"
    npy = os.environ.get("CAPTURE_NPY", "").strip() or (
        f"{_shared}/lora-mimo-captures/captures/"
        f"lora_20260621_092907_SF7-BW250-Pre8.npy"
    )
    sf, bw_khz = 7, 250
    start = _env_int("CAPTURE_START", 540185)
    nsamp = _env_int("CAPTURE_NSAMP", 84000)
    sample_shift = 1
    M = 1 << (sf + sample_shift)
    clk_per_iq = 64

    dut._log.info(f"{tag}: loading {npy} [{start}:{start + nsamp}] "
                  f"gains={gains_db} absent={absent}")
    bits_i, bits_q, meta, branch_power = iq_capture.prepare_stimulus(
        npy, start=start, nsamp=nsamp, n_branches=4, snr_db=None, seed=0,
        channel="awgn", gains_db=gains_db)
    n32 = bits_i.shape[1]
    dut._log.info(f"{tag}: {n32} chip samples, "
                  f"branch power={[round(p, 6) for p in branch_power]}")
    # The stimulus itself must actually have a dead branch -- otherwise the
    # test would silently degrade to a plain four-branch run.
    for k in absent:
        assert branch_power[k] < branch_power[0] * 1e-4, (
            f"{tag}: branch {k} power {branch_power[k]:.3e} is not << ant0 "
            f"{branch_power[0]:.3e}; gains_db did not null it")

    # -- reset --------------------------------------------------------------
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

    drv = cocotb.start_soon(capture_driver(dut, bits_i, bits_q))

    await spi_read(dut, 0x00)
    await spi_read(dut, 0x09)
    await spi_write(dut, 0x09, sf & 0x0F)
    await spi_write(dut, 0x0A, 0 if bw_khz == 250 else 1)
    await spi_write(dut, 0x0C, 0x01)
    await spi_write(dut, 0x0D, 0x00)
    await spi_write(dut, 0x0E, 0x00)
    await release_rx_hold(dut)
    await spi_write(dut, 0x70, 0x01)

    init_ok = False
    for _ in range(500):
        await Timer(8 * CLK_NS, unit="ns")
        if (await spi_read(dut, 0x71)) & 0x08:
            init_ok = True
            break
    assert init_ok, f"{tag}: PSRAM INIT_DONE never set"

    sym_ns = M * clk_per_iq * CLK_NS
    max_polls = max(4, int(n32 * CLK_NS / sym_ns))

    lock_ok = False
    for _ in range(max_polls):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x01:
            lock_ok = True
            break
    assert lock_ok, (
        f"{tag}: sc_lock never fired with branch(es) {absent} absent "
        f"(SC keys on ant0, which is live -- a real regression if this trips)")
    dut._log.info(f"{tag}: sc_lock OK")

    await spi_write(dut, 0x03, 0xFF)
    train_ok = False
    for _ in range(max_polls):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x02:
            train_ok = True
            break
    assert train_ok, f"{tag}: training_done (IRQ_STATUS[1]) never fired"
    dut._log.info(f"{tag}: training_done OK")

    # -- Z read + absent-branch checks on the accumulator ------------------
    Z = await _read_z_matrix(dut)
    n_acc = await _read_n_acc(dut)
    assert n_acc > 0, f"{tag}: n_acc=0, training accumulator never armed"
    zdiag = [Z[k, k].real for k in range(4)]
    dut._log.info(f"{tag}: n_acc={n_acc} ZDIAG={[round(z) for z in zdiag]}")

    loud = max(zdiag[k] for k in live)
    for k in absent:
        assert zdiag[k] < 0.01 * loud, (
            f"{tag}: ZDIAG[{k}]={zdiag[k]:.1f} for an ABSENT branch is not "
            f"<< the loudest live branch ({loud:.1f}) -- training_acc is "
            f"picking up energy on a dead input")

    # -- firmware weight compute + absent-branch weight check --------------
    w = compute_eigvec_fw(Z, n_acc)
    assert np.any(np.abs(w) > 0), f"{tag}: compute_eigvec_fw returned all zeros"
    w_rel = np.abs(w) / np.max(np.abs(w))
    dut._log.info(f"{tag}: weight direction |w|={np.round(w_rel, 4)}")
    for k in absent:
        assert w_rel[k] < 0.10, (
            f"{tag}: eigenvector puts relative weight {w_rel[k]:.3f} on absent "
            f"branch {k} -- expected ~0 for a branch with no signal/correlation")

    # -- encode, write, commit -------------------------------------------------
    burst, w_hw = _encode_w_shadow_bytes(w)
    await spi_burst_write(dut, 0x30, burst)
    await spi_write(dut, 0x1E, 0x01)   # W_COMMIT
    wgt = await spi_read(dut, 0x1E)
    assert (wgt >> 1) & 1, \
        f"{tag}: W_VALID never latched after W_COMMIT (WGT_CTRL=0x{wgt:02X})"
    dut._log.info(f"{tag}: W_COMMIT -> W_VALID OK, w_hw(int8)={w_hw}")
    for k in absent:
        assert w_hw[k] == 0, (
            f"{tag}: quantised hardware weight for absent branch {k} is "
            f"{w_hw[k]}, expected 0")

    # -- combiner arithmetic vs oracle, with the dead branch in the MAC ---
    await _verify_combiner_against_oracle(dut, w_hw, tag, clk_per_iq=clk_per_iq)

    dut._log.info(f"{tag}: PASS -- full MRC flow with branch(es) {absent} "
                  f"absent verified end to end")
    drv.cancel()


@cocotb.test()
async def test_mrc_one_branch_absent(dut):
    """ant3 carries no signal; ants 0-2 graded 0 / -3 / -6 dB."""
    await _absent_branch_flow(dut, "MRC-ABSENT-1",
                              gains_db=[0.0, -3.0, -6.0, ABSENT_DB])


@cocotb.test()
async def test_mrc_two_branches_absent(dut):
    """ant2 and ant3 carry no signal; ants 0-1 graded 0 / -3 dB."""
    await _absent_branch_flow(dut, "MRC-ABSENT-2",
                              gains_db=[0.0, -3.0, ABSENT_DB, ABSENT_DB])
