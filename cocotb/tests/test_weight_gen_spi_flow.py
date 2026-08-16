"""
test_weight_gen_spi_flow.py -- end-to-end firmware weight-computation flow,
entirely over the real SPI register interface, verified against an oracle.

This is the "off-chip MCU" loop: IRQ_STATUS[TRAINING_DONE] -> read Z_kl/ZDIAG
over SPI -> compute MRC weights the way real firmware does (the bit-accurate
eigenvector model in sim/models/eigvec_fw.py) -> write W shadow bank over SPI
-> pulse W_COMMIT -> confirm the combiner actually uses these specific
weights, not just that some non-zero output appears.

Existing tests (test_trouper_top.py, test_capture_playback.py) only ever
commit hardcoded EGC weights (0x4000 real, all antennas) -- they check the
write->commit->combine PLUMBING works, not that a real firmware-computed
weight vector is numerically correct when it reaches the combiner.

Oracle strategy: rather than re-deriving the whole DSP chain (SDM -> decimate
-> DC-removal) in Python to predict the combiner's *inputs*, this records the
RTL's own actual pre-combiner samples (comb_xi/comb_xq -- the real decimated
+ DC-removed int8 stream, trouper_top.v:464-470) during the payload window,
then feeds those exact samples through nonfft_combine_rtl_int8w() (explicitly
documented as matching mrc_combiner.v) using the exact weight bytes this test
wrote over SPI, and compares against the RTL's own comb_y_i/comb_y_q. That
directly validates the combiner's hardware arithmetic against the reference
model given identical inputs and identical weights -- it does not depend on
modelling the decimator/DC-removal stages at all.

Weight-precision note (found while designing this test): trouper_top.v wires
only the HIGH byte of each 16-bit W shadow entry to the combiner
(`rb_w_shadow[127:120]` etc, trouper_top.v:497-500) -- the LOW bytes
(W_x_RE_LO/IM_LO) are write-only placeholders never read by hardware. The
combiner only ever sees 8-bit (Q0.7) weight precision regardless of what's
written to the 16-bit shadow registers. This matches nonfft_combine_rtl_int8w
convention (mrc_combiner.v commit cf65892): peak weight component -> +-120.
Not documented anywhere in planning/Register Map.md currently.

Real capture data is used (not synthetic CW) so the four antennas have
genuine, distinct complex channel gains -- a real eigenvector direction to
verify, not a degenerate equal-gain case.
"""

import os
import sys
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
import numpy as np

# sim/ (bit-true reference models) lives at the repo root, not on the
# cocotb PYTHONPATH (which only points at rtl-test/tb) -- add DESIGN_ROOT
# so `import sim.models...` resolves inside the container too.
_design_root = os.environ.get("DESIGN_ROOT", "")
if _design_root and _design_root not in sys.path:
    sys.path.insert(0, _design_root)

from test_trouper_top import (CLK_NS, spi_read, spi_write, spi_burst_write,
                              release_rx_hold)
from test_capture_playback import capture_driver, _env_int
import iq_capture

from sim.models.eigvec_fw import (compute_eigvec_fw, compute_eigvec_nw_fw,
                                  compute_eigvec_snrw_fw)
from sim.models.receiver import nonfft_combine_rtl_int8w
from sim.models.weight_generation import NoiseFloorEstimator


ZDIAG_ADDR = {0: (0x64, 0x65, 0x66), 1: (0x67, 0x68, 0x69),
              2: (0x6A, 0x6B, 0x6C), 3: (0x6D, 0x6E, 0x6F)}
# (I_hi, I_mid, I_lo, Q_hi, Q_mid, Q_lo) per pair, base address of the pair
ZKL_PAIRS = {(0, 1): 0x40, (0, 2): 0x46, (0, 3): 0x4C,
             (1, 2): 0x52, (1, 3): 0x58, (2, 3): 0x5E}


def _s24(hi, mid, lo):
    """Sign-extend a 24-bit big-endian register readback to a Python int."""
    v = (hi << 16) | (mid << 8) | lo
    if v & 0x800000:
        v -= 1 << 24
    return v


async def _read_z_matrix(dut):
    """Read Z_kl (0x40-0x63) + ZDIAG (0x64-0x6F) and build the 4x4 Hermitian
    matrix at the FULL accumulator scale compute_eigvec_fw() expects.

    CORRECTED 2026-07-05 (was <<8 on the diagonal before passing in -- WRONG,
    found via a genuine RTL run: with real gains 0/-3/-6/-9 dB, the computed
    weight direction came out as [0.9999, 0.0038, 0.0019, 0.0010] instead of
    the physically-expected ~amplitude-ratio direction [1, 0.71, 0.51, 0.36].
    Verified offline against the same observed ZDIAG values that both diag
    and off-diagonal registers must be passed to compute_eigvec_fw() AS-IS,
    with no scale adjustment -- doing so reproduces the expected ratio to
    3 decimal places. The function's own internal diagonal >>8 comment
    describes matching hardware's ZDIAG truncation for a FULL-precision
    (untruncated, e.g. float-model) Z_matrix input; since real SPI register
    reads are already truncated by hardware for BOTH Z_kl and ZDIAG (documented
    as "same scale" in Register Map.md), re-shifting one of them here was
    double-counting the truncation and threw off the diagonal-to-off-diagonal
    balance the eigenvector solve depends on.
    """
    Z = np.zeros((4, 4), dtype=complex)

    for (k, l), base in ZKL_PAIRS.items():
        i_hi, i_mid, i_lo, q_hi, q_mid, q_lo = [
            await spi_read(dut, base + off) for off in range(6)
        ]
        zi = _s24(i_hi, i_mid, i_lo)
        zq = _s24(q_hi, q_mid, q_lo)
        Z[k, l] = complex(zi, zq)
        Z[l, k] = complex(zi, -zq)   # Hermitian conjugate

    for k in range(4):
        hi, mid, lo = ZDIAG_ADDR[k]
        d_hi = await spi_read(dut, hi)
        d_mid = await spi_read(dut, mid)
        d_lo = await spi_read(dut, lo)
        zdiag_reg = (d_hi << 16) | (d_mid << 8) | d_lo   # unsigned, real & >=0
        Z[k, k] = complex(zdiag_reg, 0.0)

    return Z


async def _read_n_acc(dut):
    hi = await spi_read(dut, 0x21)
    mid = await spi_read(dut, 0x22)
    lo = await spi_read(dut, 0x23)
    return ((hi & 0x03) << 16) | (mid << 8) | lo


def _encode_w_shadow_bytes(w):
    """Quantize eigvec_fw's Q1.15 output to what actually reaches hardware:
    peak component -> +-120 in the HIGH byte (matching
    nonfft_combine_rtl_int8w's convention and mrc_combiner.v's 8-bit input),
    LOW byte fixed at 0 (write-only, never read by the combiner).
    Returns (spi_burst_bytes[16], w_hw[4] complex int8 actually used)."""
    peak = max(1e-9, np.max(np.abs(np.concatenate([w.real, w.imag]))))
    scale = 120.0 / peak
    w_re8 = np.clip(np.round(w.real * scale), -127, 127).astype(int)
    w_im8 = np.clip(np.round(w.imag * scale), -127, 127).astype(int)

    burst = []
    for k in range(4):
        # int(...) required: numpy.int64 & 0xFF is still numpy.int64, which
        # cocotb's value assignment rejects (TypeError: Unsupported type).
        burst += [int(w_re8[k]) & 0xFF, 0x00, int(w_im8[k]) & 0xFF, 0x00]
    w_hw = np.array([complex(int(w_re8[k]), int(w_im8[k])) for k in range(4)])
    return burst, w_hw


async def _read_zdiag_regs(dut):
    """Per-branch ZDIAG_k (0x64-0x6F) as raw unsigned 24-bit register values.

    These are ALREADY bits [31:8] of the accumulator -- hardware truncated
    them. Do not apply a further >>8 (e.g. sim.models.weight_generation's
    zdiag_from_energy(), which is for full-scale energy sums): that is exactly
    the double-shift bug fixed in _read_z_matrix on 2026-07-05.
    """
    out = []
    for k in range(4):
        hi, mid, lo = ZDIAG_ADDR[k]
        d_hi = await spi_read(dut, hi)
        d_mid = await spi_read(dut, mid)
        d_lo = await spi_read(dut, lo)
        out.append((d_hi << 16) | (d_mid << 8) | d_lo)
    return out


async def _verify_combiner_against_oracle(dut, w_hw, tag, clk_per_iq=64):
    """Record the RTL's own pre-combiner samples and combiner output over the
    payload window, then check the hardware arithmetic against
    nonfft_combine_rtl_int8w() given identical inputs and identical weights.

    Extracted verbatim from test_weight_gen_spi_flow so both the plain and the
    noise-whitened flows verify the combiner the same way.
    """
    # Settle delay: W_ACTIVE only updates at the packet FSM's next
    # safe_switch boundary (Register Map.md), not instantly at W_COMMIT --
    # recording immediately risked capturing samples still combined under
    # the pre-commit (default/zero) weight. A few decimated-sample periods
    # of margin (clk_per_iq=64 each) comfortably clears any such boundary.
    for _ in range(4 * clk_per_iq):
        await RisingEdge(dut.IQ_CLK)

    xi_rec = [[], [], [], []]
    xq_rec = [[], [], [], []]
    y_i_rec, y_q_rec = [], []
    # comb_xvalid/comb_y_valid pulse at the 500 kS/s decimated rate -- once
    # per clk_per_iq=64 IQ_CLK cycles -- so reaching 500 samples needs at
    # least 500*64=32000 IQ_CLK cycles. The original 6000-cycle budget only
    # ever collected ~94 samples (found via a genuine RTL run, job 3280).
    for _ in range(35000):
        await RisingEdge(dut.IQ_CLK)
        if int(dut.u_dut.comb_xvalid.value):
            for b in range(4):
                xi_rec[b].append(int(dut.u_dut.comb_xi[b].value.signed_integer))
                xq_rec[b].append(int(dut.u_dut.comb_xq[b].value.signed_integer))
        yv = dut.u_dut.comb_y_valid.value
        if yv.is_resolvable and int(yv):
            y_i_rec.append(int(dut.u_dut.comb_y_i.value.signed_integer))
            y_q_rec.append(int(dut.u_dut.comb_y_q.value.signed_integer))
        if len(y_i_rec) >= 500:
            break

    assert len(y_i_rec) >= 100, \
        f"{tag}: only {len(y_i_rec)} combiner output samples captured, too few to compare"
    n_common = min(len(y_i_rec), *[len(xi_rec[b]) for b in range(4)])
    assert n_common >= 100, f"{tag}: only {n_common} aligned input/output samples"

    y_rtl_full = np.array(y_i_rec) + 1j * np.array(y_q_rec)
    post_gain_shift = (await spi_read(dut, 0x0F)) & 0x07

    def _align(lag):
        if lag >= 0:
            xi_al = [xi_rec[b][lag:] for b in range(4)]
            xq_al = [xq_rec[b][lag:] for b in range(4)]
            y_al = y_rtl_full
        else:
            xi_al = [xi_rec[b][:lag] for b in range(4)]
            xq_al = [xq_rec[b][:lag] for b in range(4)]
            y_al = y_rtl_full[-lag:]
        return xi_al, xq_al, y_al

    # Lag search: comb_xi/comb_xq (input) and comb_y_i/comb_y_q (output) were
    # recorded via two independent valid strobes in the same loop, with no
    # guarantee they line up index-for-index -- mrc_combiner.v is a multi-
    # state serial MAC pipeline (state 0 catches x_valid, several more clk_16m
    # states before y_valid), so a genuine per-sample lag between the two
    # streams is expected. Rather than assume a specific lag, search a small
    # window and report whichever alignment the data itself supports -- this
    # also self-diagnoses whether a real mismatch (bad at every lag) vs. a
    # pure alignment issue (good at exactly one lag) is going on.
    best_lag, best_err, best_n = None, None, 0
    for lag in range(-5, 6):
        xi_al, xq_al, y_al = _align(lag)
        n = min(len(y_al), *[len(xi_al[b]) for b in range(4)])
        if n < 100:
            continue
        rx_payload = np.array([
            np.array(xi_al[b][:n]) + 1j * np.array(xq_al[b][:n]) for b in range(4)
        ])
        y_oracle = nonfft_combine_rtl_int8w(rx_payload, w_hw, post_gain_shift=post_gain_shift)
        max_err = np.max(np.abs(y_oracle - y_al[:n]))
        if best_err is None or max_err < best_err:
            best_lag, best_err, best_n = lag, max_err, n

    assert best_lag is not None, f"{tag}: no lag in [-5,5] gave >=100 aligned samples"
    dut._log.info(f"{tag}: best lag={best_lag} max_err={best_err:.2f} over {best_n} samples "
                  f"(searched lags -5..5)")

    # Per-sample error at the best lag -- locate WHERE the mismatch is
    # concentrated (all samples vs. a late-window subset, e.g. past the
    # capture clip's end where capture_driver holds the last bit frozen).
    xi_al, xq_al, y_al = _align(best_lag)
    n = best_n
    rx_payload = np.array([
        np.array(xi_al[b][:n]) + 1j * np.array(xq_al[b][:n]) for b in range(4)
    ])
    y_oracle_full = nonfft_combine_rtl_int8w(rx_payload, w_hw, post_gain_shift=post_gain_shift)
    err_full = np.abs(y_oracle_full - y_al[:n])
    bad_idx = np.where(err_full > 2)[0]
    if len(bad_idx):
        i0 = bad_idx[0]
        dut._log.info(f"{tag}: {len(bad_idx)}/{n} samples exceed 2 LSB at lag={best_lag}; "
                      f"first bad idx={i0} x={[rx_payload[b][i0] for b in range(4)]} "
                      f"y_rtl={y_al[i0]} y_oracle={y_oracle_full[i0]}")

    # int8 domain: allow +-2 LSB residual after finding the true pipeline lag.
    assert best_err <= 2, \
        f"{tag}: even at the best-fit lag ({best_lag}), oracle/RTL combiner " \
        f"mismatch max_err={best_err:.2f} (expected <=2 LSB) -- weights were " \
        f"not applied as computed (not just a sample-alignment artifact)"


@cocotb.test()
async def test_weight_gen_spi_flow(dut):
    # Default resolves against the hlab-sge shared_data_dir mount, which is
    # present read-only in every job. The previous default pointed into the
    # design tree at a capture that no longer exists there, so an unset
    # CAPTURE_NPY failed on a missing file rather than running.
    _shared = os.environ.get("SHARED_DIR", "").strip() or "/foss/shared"
    # `or default`, NOT os.environ.get(name, default): the Makefile exports
    # CAPTURE_NPY, so when the caller does not set it the variable exists but
    # is EMPTY, and .get() returns "" rather than falling back to the default.
    npy = os.environ.get("CAPTURE_NPY", "").strip() or (
        f"{_shared}/lora-mimo-captures/captures/lora_20260621_092907_SF7-BW250-Pre8.npy"
    )
    sf, bw_khz = 7, 250
    # Burst in this file starts at capture sample 564185 (located by
    # cocotb/tests/sweep_captures.py); the stock 0/60000 window misses it.
    #
    # This window deliberately starts ~24000 samples EARLIER than the planner's
    # `burst - 2000`, because the noise-weighted flows measure sigma2 on a
    # pre-packet quiet window: n_acc=2048 output samples at 500 kS/s is 4.096 ms
    # = 8192 capture samples at 2 MS/s. With only 2000 samples of lead-in ~75%
    # of the "noise" window was actually the packet, so sigma2 measured
    # signal+noise and the de-bias pedestal came out at 99% of ZDIAG. Measured
    # lead-in power here is -0.06 dB vs a known-quiet reference stretch, and the
    # burst is +40.0 dB, so 24000 samples is comfortably clean.
    start = _env_int("CAPTURE_START", 540185)
    nsamp = _env_int("CAPTURE_NSAMP", 84000)
    sample_shift = 1
    M = 1 << (sf + sample_shift)
    clk_per_iq = 64
    tag = "WGEN-SPI-FLOW"

    # Distinct per-antenna gains -> a real (non-degenerate) eigenvector
    # direction to verify, not an equal-gain case.
    gains_db = [0.0, -3.0, -6.0, -9.0]

    dut._log.info(f"{tag}: loading {npy} [{start}:{start+nsamp}] gains={gains_db}")
    bits_i, bits_q, meta, branch_power = iq_capture.prepare_stimulus(
        npy, start=start, nsamp=nsamp, n_branches=4, snr_db=None, seed=0,
        channel="awgn", gains_db=gains_db)
    n32 = bits_i.shape[1]
    dut._log.info(f"{tag}: {n32} chip samples, branch power={[round(p,5) for p in branch_power]}")

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

    drv = cocotb.start_soon(capture_driver(dut, bits_i, bits_q))

    await spi_read(dut, 0x00)
    await spi_read(dut, 0x09)
    await spi_write(dut, 0x09, sf & 0x0F)
    await spi_write(dut, 0x0A, 0 if bw_khz == 250 else 1)
    await spi_write(dut, 0x0C, 0x01)
    await spi_write(dut, 0x0D, 0x00)
    await spi_write(dut, 0x0E, 0x00)
    # RX_HOLD (0x1A) is SET out of reset and level-gates sc_clr, so the
    # detector can never lock until firmware releases it. The locked config
    # registers above (0x09/0x0A/0x0E) are only writable while it is held,
    # so this must come after them -- see planning/mcp-config-settle-gate-design.md.
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

    # -- IRQ high: wait for sc_lock, then training_done ------------------------
    lock_ok = False
    for _ in range(max_polls):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x01:
            lock_ok = True
            break
    assert lock_ok, f"{tag}: sc_lock never fired"
    dut._log.info(f"{tag}: sc_lock OK")

    await spi_write(dut, 0x03, 0xFF)   # clear IRQ
    train_ok = False
    for _ in range(max_polls):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x02:
            train_ok = True
            break
    assert train_ok, f"{tag}: training_done (IRQ_STATUS[1]) never fired"
    dut._log.info(f"{tag}: training_done (IRQ high) OK")

    # -- Z read over SPI --------------------------------------------------------
    Z = await _read_z_matrix(dut)
    n_acc = await _read_n_acc(dut)
    dut._log.info(f"{tag}: n_acc={n_acc}, ZDIAG={[round(Z[k,k].real) for k in range(4)]}")
    assert n_acc > 0, f"{tag}: n_acc=0, training accumulator never armed"

    # -- firmware-accurate weight computation (host/MCU side) -------------------
    w = compute_eigvec_fw(Z, n_acc)
    assert np.any(np.abs(w) > 0), f"{tag}: compute_eigvec_fw returned all-zero weights"
    dut._log.info(f"{tag}: computed weights (Q1.15 direction) = {w}")

    # -- encode + write W shadow bank, commit -----------------------------------
    burst, w_hw = _encode_w_shadow_bytes(w)
    await spi_burst_write(dut, 0x30, burst)
    await spi_write(dut, 0x1E, 0x01)   # W_COMMIT

    wgt = await spi_read(dut, 0x1E)
    assert (wgt >> 1) & 1, f"{tag}: W_VALID never latched after W_COMMIT (WGT_CTRL=0x{wgt:02X})"
    dut._log.info(f"{tag}: W_COMMIT -> W_VALID OK, w_hw (int8, as hardware sees it) = {w_hw}")

    # -- record real combiner inputs/outputs, verify against the oracle --------
    await _verify_combiner_against_oracle(dut, w_hw, tag, clk_per_iq=clk_per_iq)

    dut._log.info(f"{tag}: PASS -- IRQ->Z read->firmware weight compute->SPI write->"
                  f"W_COMMIT->combiner output all verified against oracle")
    drv.cancel()


@cocotb.test()
async def test_weight_gen_spi_flow_nw(dut):
    """Commits the DE-BIASED weights (compute_eigvec_nw_fw)."""
    await _noise_weighted_flow(dut, "WGEN-SPI-NW", mode="nw")


@cocotb.test()
async def test_weight_gen_spi_flow_snrw(dut):
    """Commits the fully SNR-WEIGHTED weights (compute_eigvec_snrw_fw).

    Prediction for this stimulus: gains_db scales the captured signal AND its
    noise floor together, so every branch has the same SNR. The unequal-noise
    optimum conj(D^-1 h) then goes as 1/g -- the exact MIRROR of the de-biased
    answer conj(h), which goes as g. Whether the measured sigma2 actually
    tracks g^2 is the open question: at this signal scale the noise window may
    be quantisation-limited rather than gain-proportional.
    """
    await _noise_weighted_flow(dut, "WGEN-SPI-SNRW", mode="snrw")


async def _noise_weighted_flow(dut, tag, mode):
    """
    Shared body for the noise-whitened flows. `mode` selects which weight
    vector is committed to hardware:

        "nw"   -> compute_eigvec_nw_fw    (pedestal subtraction; conj(h),
                                           the EQUAL-noise optimum)
        "snrw" -> compute_eigvec_snrw_fw  (pedestal + D^-1/2 transform;
                                           conj(D^-1 h), the UNEQUAL-noise optimum)

    Exercises the whole path end to end over SPI:

        TACC_NOISE_TRIG (0x1F) -> NOISE_READY (IRQ_STATUS[4])
          -> read ZDIAG/N_ACC   -> NoiseFloorEstimator (integer EMA, ZDIAG units)
          -> packet: sc_lock -> training_done -> read Z_kl/ZDIAG
          -> compute_eigvec_nw_fw(Z, n_acc, sigma2)
          -> W shadow write -> W_COMMIT -> combiner output vs oracle

    Scope note: this verifies the FLOW and the combiner ARITHMETIC, not that
    whitening improves BER. The BER question is answered by the Python sweep in
    sim/notebooks/05_sw_vs_hw_weight_gen.ipynb section 5, which can average
    thousands of channel realisations; a single RTL packet cannot.

    What it does assert beyond the plain flow:
      - a noise window completes and NOISE_READY fires with PSRAM disabled
        (no delay line -> the SC detector cannot lock and contaminate it)
      - the measured per-branch noise floor ranks in the same order as the
        applied per-antenna gains (they scale the captured noise floor too)
      - whitening actually CHANGES the weight vector -- a whitened path that
        silently degenerates to the unwhitened one would otherwise pass
      - the whitened weights are applied bit-exactly by the combiner
    """
    # Default resolves against the hlab-sge shared_data_dir mount, which is
    # present read-only in every job. The previous default pointed into the
    # design tree at a capture that no longer exists there, so an unset
    # CAPTURE_NPY failed on a missing file rather than running.
    _shared = os.environ.get("SHARED_DIR", "").strip() or "/foss/shared"
    # `or default`, NOT os.environ.get(name, default): the Makefile exports
    # CAPTURE_NPY, so when the caller does not set it the variable exists but
    # is EMPTY, and .get() returns "" rather than falling back to the default.
    npy = os.environ.get("CAPTURE_NPY", "").strip() or (
        f"{_shared}/lora-mimo-captures/captures/lora_20260621_092907_SF7-BW250-Pre8.npy"
    )
    sf, bw_khz = 7, 250
    # Burst in this file starts at capture sample 564185 (located by
    # cocotb/tests/sweep_captures.py); the stock 0/60000 window misses it.
    #
    # This window deliberately starts ~24000 samples EARLIER than the planner's
    # `burst - 2000`, because the noise-weighted flows measure sigma2 on a
    # pre-packet quiet window: n_acc=2048 output samples at 500 kS/s is 4.096 ms
    # = 8192 capture samples at 2 MS/s. With only 2000 samples of lead-in ~75%
    # of the "noise" window was actually the packet, so sigma2 measured
    # signal+noise and the de-bias pedestal came out at 99% of ZDIAG. Measured
    # lead-in power here is -0.06 dB vs a known-quiet reference stretch, and the
    # burst is +40.0 dB, so 24000 samples is comfortably clean.
    start = _env_int("CAPTURE_START", 540185)
    nsamp = _env_int("CAPTURE_NSAMP", 84000)
    sample_shift = 1
    M = 1 << (sf + sample_shift)
    clk_per_iq = 64

    gains_db = [0.0, -3.0, -6.0, -9.0]

    dut._log.info(f"{tag}: loading {npy} [{start}:{start+nsamp}] gains={gains_db}")
    bits_i, bits_q, meta, branch_power = iq_capture.prepare_stimulus(
        npy, start=start, nsamp=nsamp, n_branches=4, snr_db=None, seed=0,
        channel="awgn", gains_db=gains_db)
    n32 = bits_i.shape[1]
    dut._log.info(f"{tag}: {n32} chip samples, branch power={[round(p,5) for p in branch_power]}")

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

    drv = cocotb.start_soon(capture_driver(dut, bits_i, bits_q))

    await spi_read(dut, 0x00)
    await spi_read(dut, 0x09)
    await spi_write(dut, 0x09, sf & 0x0F)
    await spi_write(dut, 0x0A, 0 if bw_khz == 250 else 1)
    await spi_write(dut, 0x0C, 0x01)
    await spi_write(dut, 0x0D, 0x00)
    await spi_write(dut, 0x0E, 0x00)

    sym_ns = M * clk_per_iq * CLK_NS
    max_polls = max(4, int(n32 * CLK_NS / sym_ns))

    # =====================================================================
    # Phase 1 -- noise window, PSRAM still DISABLED.
    # With PSRAM off the SC detector has no delay line, so it cannot lock
    # and contaminate the window by construction (same argument as
    # cocotb/tests/test_noise_trig.py phase A). This runs on the leading,
    # pre-preamble part of the capture, so it measures the recording's real
    # per-antenna noise floor with gains_db applied.
    # =====================================================================
    await Timer(4 * sym_ns, unit="ns")     # let the decimator/DCR transient die

    ts = await spi_read(dut, 0x20)
    assert ts == 0x00, f"{tag}: TRAINING_STATUS=0x{ts:02X} before any trigger"

    await spi_write(dut, 0x1F, 0x01)       # TACC_NOISE_TRIG (W1P)

    noise_ready = False
    for _ in range(20):
        await Timer(sym_ns, unit="ns")
        irq = await spi_read(dut, 0x02)
        if irq & 0x10:                     # NOISE_READY
            noise_ready = True
            break
    assert noise_ready, \
        f"{tag}: NOISE_READY (IRQ_STATUS[4]) never fired for the noise window"
    assert not (irq & 0x01), \
        f"{tag}: sc_lock IRQ set during the noise window with PSRAM disabled (0x{irq:02X})"

    n_acc_noise = await _read_n_acc(dut)
    zdiag_noise = await _read_zdiag_regs(dut)
    assert n_acc_noise > 0, f"{tag}: noise-window n_acc=0"
    assert all(z > 0 for z in zdiag_noise), \
        f"{tag}: a branch accumulated no noise energy: {zdiag_noise}"
    dut._log.info(f"{tag}: noise window n_acc={n_acc_noise} ZDIAG={zdiag_noise}")

    # Feed the firmware-side estimator. ZDIAG over SPI is already bits [31:8];
    # NoiseFloorEstimator works in exactly those units, so no conversion here
    # (see _read_zdiag_regs docstring on the 2026-07-05 double-shift bug).
    nfe = NoiseFloorEstimator(NR=4, alpha_shift=4)
    assert nfe.update(np.array(zdiag_noise, dtype=np.int64), n_acc_noise), \
        f"{tag}: NoiseFloorEstimator rejected the noise window"
    sigma2 = nfe.estimate
    dut._log.info(f"{tag}: sigma2 (ZDIAG units/sample) = {[round(s, 6) for s in sigma2]}")
    dut._log.info(f"{tag}: underflow_mask={list(nfe.underflow_mask)} valid={nfe.valid}")

    # Fixed-point resolution gate. sigma2 is the ratio ZDIAG_k/n_acc, and on a
    # live capture the sigma-delta full scale is set by the packet peak, so a
    # quiet noise floor lands very close to the estimator's representable floor.
    # At Q8 this exact window underflowed 3 of 4 branches (job 3593); Q16 is the
    # default precisely because of that. A partially underflowed estimate must
    # never be whitened with -- it fabricates an imbalance that was not measured.
    assert nfe.valid, (
        f"{tag}: noise estimate unusable (underflow={list(nfe.underflow_mask)}, "
        f"sigma2={list(sigma2)}) -- firmware must skip whitening here, not "
        f"fabricate a per-branch imbalance")

    # The applied gains scale the captured noise floor as well as the signal,
    # so the measured noise floor must rank in the same order as gains_db.
    assert sigma2[0] >= sigma2[3], (
        f"{tag}: noise floor does not track applied gains "
        f"(ant0 {sigma2[0]:.3f} < ant3 {sigma2[3]:.3f}, gains={gains_db}) -- "
        f"the noise window probably overlapped the packet; adjust CAPTURE_START")

    await spi_write(dut, 0x03, 0xFF)       # clear IRQ before the packet phase

    # =====================================================================
    # Phase 2 -- enable PSRAM, acquire the packet, read the signal Z.
    # =====================================================================
    # RX_HOLD is deliberately left SET through Phase 1: it level-gates sc_clr,
    # so it is a second, independent guarantee that the detector cannot lock
    # and contaminate the noise window -- stronger than the PSRAM-off argument
    # alone, which relies on the delay line being unavailable. Release it only
    # now, together with the PSRAM enable, so acquisition can start.
    await release_rx_hold(dut)
    await spi_write(dut, 0x70, 0x01)
    init_ok = False
    for _ in range(500):
        await Timer(8 * CLK_NS, unit="ns")
        if (await spi_read(dut, 0x71)) & 0x08:
            init_ok = True
            break
    assert init_ok, f"{tag}: PSRAM INIT_DONE never set"

    lock_ok = False
    for _ in range(max_polls):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x01:
            lock_ok = True
            break
    assert lock_ok, f"{tag}: sc_lock never fired"
    dut._log.info(f"{tag}: sc_lock OK")

    await spi_write(dut, 0x03, 0xFF)
    train_ok = False
    for _ in range(max_polls):
        await Timer(sym_ns, unit="ns")
        if (await spi_read(dut, 0x02)) & 0x02:
            train_ok = True
            break
    assert train_ok, f"{tag}: training_done (IRQ_STATUS[1]) never fired"

    Z = await _read_z_matrix(dut)
    n_acc = await _read_n_acc(dut)
    assert n_acc > 0, f"{tag}: n_acc=0, training accumulator never armed"
    dut._log.info(f"{tag}: signal window n_acc={n_acc} "
                  f"ZDIAG={[round(Z[k,k].real) for k in range(4)]}")

    # Sanity: the signal window must sit above the noise window on at least
    # the strongest branch, otherwise the 'noise' window caught the packet.
    # A bare `>` here is not a guard: it passed at 60.60 vs 59.97 (a 1% margin)
    # on a capture whose burst is 40 dB above its own noise floor, because the
    # noise window overlapped the packet and sigma2 measured signal+noise. Any
    # genuinely quiet noise window must sit far below the signal window, so
    # require a real margin -- 6 dB is loose against the ~40 dB this capture
    # actually offers, but tight enough that window overlap fails loudly here
    # instead of silently poisoning sigma2 and everything derived from it.
    MIN_SIG_NOISE_RATIO = 4.0        # 6 dB
    sig_per_sample = Z[0, 0].real / max(n_acc, 1)
    ratio_db = 10.0 * np.log10(max(sig_per_sample, 1e-9) / max(sigma2[0], 1e-9))
    ped_frac = [float(sigma2[k] * n_acc / max(Z[k, k].real, 1.0)) for k in range(4)]
    dut._log.info(f"{tag}: signal/noise window ratio = {ratio_db:.2f} dB "
                  f"(sig/sample={sig_per_sample:.1f}, sigma2_0={sigma2[0]:.1f}); "
                  f"pedestal fraction of ZDIAG = {[round(p, 3) for p in ped_frac]}")
    assert sig_per_sample > MIN_SIG_NOISE_RATIO * sigma2[0], (
        f"{tag}: ant0 signal-window power/sample ({sig_per_sample:.1f}) is only "
        f"{ratio_db:.2f} dB above the measured noise floor ({sigma2[0]:.1f}), "
        f"below the {10 * np.log10(MIN_SIG_NOISE_RATIO):.0f} dB minimum -- the noise "
        f"window almost certainly overlaps the packet, so sigma2 is measuring "
        f"signal+noise. Move CAPTURE_START earlier so the full noise window "
        f"(n_acc={n_acc} samples at 500 kS/s) lands before the burst. "
        f"Pedestal fraction of ZDIAG = {[round(p, 3) for p in ped_frac]}")

    # =====================================================================
    # Phase 3 -- whitened weight computation, commit, verify.
    # =====================================================================
    w_plain = compute_eigvec_fw(Z, n_acc)
    w_nw = compute_eigvec_nw_fw(Z, n_acc, sigma2)
    w_snrw = compute_eigvec_snrw_fw(Z, n_acc, sigma2)
    dut._log.info(f"{tag}: w_plain={w_plain}")
    dut._log.info(f"{tag}: w_nw   ={w_nw}")
    dut._log.info(f"{tag}: w_snrw ={w_snrw}")

    def _angle_deg(a, b):
        a = a / np.linalg.norm(a); b = b / np.linalg.norm(b)
        return float(np.degrees(np.arccos(np.clip(abs(np.dot(np.conj(a), b)), 0.0, 1.0))))

    def _rel(w):
        return np.abs(w) / np.abs(w).max()

    w_commit = w_nw if mode == "nw" else w_snrw
    assert np.any(np.abs(w_commit) > 0), f"{tag}: weight computation returned all zeros"

    if mode == "nw":
        # Uniform-pedestal property: subtracting sigma2*n_acc from the diagonal
        # when every sigma2 entry is EQUAL is subtracting a multiple of I. That
        # shifts all eigenvalues equally and cannot rotate the eigenvector, so
        # de-biasing must be a no-op here. Catches an over-subtracting or
        # mis-scaled implementation.
        #
        # This feeds a synthetic UNIFORM sigma2 rather than the measured one,
        # deliberately. The measured sigma2 is NOT uniform: gains_db scales the
        # captured signal and its noise floor together, so the real pedestal is
        # graded ~3 dB per branch and legitimately does rotate the eigenvector.
        # An earlier version asserted no-op against the measured sigma2 and so
        # depended on the recording being strong enough that the pedestal was
        # negligible -- it passed on a high-gain capture and failed on a weaker
        # one (12.4 deg) where the pedestal was 99% of the diagonal. The
        # property under test is arithmetic, so pin it to a uniform vector and
        # keep the real measured Z / n_acc from the chip.
        sigma2_uniform = np.full(4, float(np.min(sigma2)))
        w_uniform = compute_eigvec_nw_fw(Z, n_acc, sigma2_uniform)
        ang = _angle_deg(w_uniform, w_plain)
        dut._log.info(f"{tag}: uniform-pedestal angle(w_nw_uniform, w_plain) = "
                      f"{ang:.3f} deg (sigma2_uniform={sigma2_uniform[0]:.3f})")
        assert ang < 5.0, (
            f"{tag}: a UNIFORM pedestal rotated the weight vector by {ang:.2f} deg "
            f"where it must be a no-op -- sigma2 pedestal mis-scaled "
            f"(sigma2_uniform={sigma2_uniform[0]}, n_acc={n_acc})")

        # The measured (graded) pedestal is reported, not asserted: with a
        # near-marginal capture the de-biased matrix is ill-conditioned (the
        # pedestal can be most of the diagonal while the off-diagonals are
        # untouched), so its eigenvector is not a meaningful reference.
        ang_measured = _angle_deg(w_nw, w_plain)
        ped_frac = [float(sigma2[k] * n_acc / max(Z[k, k].real, 1.0)) for k in range(4)]
        dut._log.info(f"{tag}: measured graded pedestal is "
                      f"{[round(p, 3) for p in ped_frac]} of ZDIAG; "
                      f"angle(w_nw, w_plain) = {ang_measured:.3f} deg (informational)")

        # Directed imbalance: the whitening arithmetic must actually bite.
        sigma2_imb = sigma2.copy()
        sigma2_imb[0] = 0.5 * Z[0, 0].real / n_acc
        w_imb = compute_eigvec_nw_fw(Z, n_acc, sigma2_imb)
        assert not np.array_equal(w_imb, w_plain), (
            f"{tag}: a pedestal of half of ZDIAG_0 left the weights unchanged")
        # Normalise by the VECTOR NORM, not the max component: ant0 is the
        # largest entry in both vectors, so a max-normalised ant0 is 1.0 by
        # construction and the comparison below would be vacuous.
        rel_plain = abs(w_plain[0]) / np.linalg.norm(w_plain)
        rel_imb = abs(w_imb[0]) / np.linalg.norm(w_imb)
        dut._log.info(f"{tag}: directed imbalance -- ant0 relative weight "
                      f"{rel_plain:.4f} -> {rel_imb:.4f}")
        assert rel_imb < rel_plain, (
            f"{tag}: declaring ant0 noisiest did not down-weight it "
            f"({rel_plain:.4f} -> {rel_imb:.4f}) -- whitening has the wrong sign")
    else:
        # SNR weighting must reorder the branches relative to de-biasing.
        # conj(h) ranks by |h_k| (loudest first); conj(D^-1 h) divides that by
        # sigma2_k. With gains scaling signal and noise together the ranking
        # should invert outright.
        ang = _angle_deg(w_snrw, w_nw)
        dut._log.info(f"{tag}: angle(w_snrw, w_nw) = {ang:.3f} deg")
        dut._log.info(f"{tag}: rel |w_nw|   = {np.round(_rel(w_nw), 4)}")
        dut._log.info(f"{tag}: rel |w_snrw| = {np.round(_rel(w_snrw), 4)}")

        ratio_nw = _rel(w_nw)[0] / max(_rel(w_nw)[3], 1e-9)
        ratio_snrw = _rel(w_snrw)[0] / max(_rel(w_snrw)[3], 1e-9)
        dut._log.info(f"{tag}: ant0/ant3 weight ratio  nw={ratio_nw:.3f}  "
                      f"snrw={ratio_snrw:.3f}")
        assert ratio_snrw < ratio_nw, (
            f"{tag}: SNR weighting did not shift weight away from the branch "
            f"with the higher noise floor (nw ratio {ratio_nw:.3f} -> "
            f"snrw {ratio_snrw:.3f}, sigma2={list(sigma2)})")

    burst, w_hw = _encode_w_shadow_bytes(w_commit)
    await spi_burst_write(dut, 0x30, burst)
    await spi_write(dut, 0x1E, 0x01)       # W_COMMIT

    wgt = await spi_read(dut, 0x1E)
    assert (wgt >> 1) & 1, f"{tag}: W_VALID never latched after W_COMMIT (WGT_CTRL=0x{wgt:02X})"
    dut._log.info(f"{tag}: W_COMMIT -> W_VALID OK, w_hw (int8) = {w_hw}")

    await _verify_combiner_against_oracle(dut, w_hw, tag, clk_per_iq=clk_per_iq)

    dut._log.info(f"{tag}: PASS -- noise window->sigma2->whitened weight compute->"
                  f"SPI write->W_COMMIT->combiner output all verified against oracle")
    drv.cancel()
