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

from test_trouper_top import CLK_NS, spi_read, spi_write, spi_burst_write
from test_capture_playback import capture_driver, _env_int
import iq_capture

from sim.models.eigvec_fw import compute_eigvec_fw
from sim.models.receiver import nonfft_combine_rtl_int8w


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


@cocotb.test()
async def test_weight_gen_spi_flow(dut):
    npy = os.environ.get(
        "CAPTURE_NPY",
        "/foss/designs/lora-mimo/lora-capture/captures/lora_20260619_144822_SF7-BW250-gain30.npy",
    )
    sf, bw_khz = 7, 250
    start = _env_int("CAPTURE_START", 668000)
    nsamp = _env_int("CAPTURE_NSAMP", 60000)
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

    # Settle delay: W_ACTIVE only updates at the packet FSM's next
    # safe_switch boundary (Register Map.md), not instantly at W_COMMIT --
    # recording immediately risked capturing samples still combined under
    # the pre-commit (default/zero) weight. A few decimated-sample periods
    # of margin (clk_per_iq=64 each) comfortably clears any such boundary.
    for _ in range(4 * clk_per_iq):
        await RisingEdge(dut.IQ_CLK)

    # -- record real combiner inputs/outputs over the payload window ------------
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
        if lag >= 0:
            xi_al = [xi_rec[b][lag:] for b in range(4)]
            xq_al = [xq_rec[b][lag:] for b in range(4)]
            y_al = y_rtl_full
        else:
            xi_al = [xi_rec[b][:lag] for b in range(4)]
            xq_al = [xq_rec[b][:lag] for b in range(4)]
            y_al = y_rtl_full[-lag:]
        n = min(len(y_al), *[len(xi_al[b]) for b in range(4)])
        if n < 100:
            continue
        rx_payload = np.array([
            np.array(xi_al[b][:n]) + 1j * np.array(xq_al[b][:n]) for b in range(4)
        ])
        y_oracle = nonfft_combine_rtl_int8w(rx_payload, w_hw, post_gain_shift=post_gain_shift)
        err = np.abs(y_oracle - y_al[:n])
        max_err = np.max(err)
        if best_err is None or max_err < best_err:
            best_lag, best_err, best_n = lag, max_err, n

    assert best_lag is not None, f"{tag}: no lag in [-5,5] gave >=100 aligned samples"
    dut._log.info(f"{tag}: best lag={best_lag} max_err={best_err:.2f} over {best_n} samples "
                  f"(searched lags -5..5)")

    # Per-sample error at the best lag -- locate WHERE the mismatch is
    # concentrated (all samples vs. a late-window subset, e.g. past the
    # capture clip's end where capture_driver holds the last bit frozen).
    lag = best_lag
    if lag >= 0:
        xi_al = [xi_rec[b][lag:] for b in range(4)]
        xq_al = [xq_rec[b][lag:] for b in range(4)]
        y_al = y_rtl_full
    else:
        xi_al = [xi_rec[b][:lag] for b in range(4)]
        xq_al = [xq_rec[b][:lag] for b in range(4)]
        y_al = y_rtl_full[-lag:]
    n = best_n
    rx_payload = np.array([
        np.array(xi_al[b][:n]) + 1j * np.array(xq_al[b][:n]) for b in range(4)
    ])
    y_oracle_full = nonfft_combine_rtl_int8w(rx_payload, w_hw, post_gain_shift=post_gain_shift)
    err_full = np.abs(y_oracle_full - y_al[:n])
    bad_idx = np.where(err_full > 2)[0]
    if len(bad_idx):
        i0 = bad_idx[0]
        dut._log.info(f"{tag}: {len(bad_idx)}/{n} samples exceed 2 LSB at lag={lag}; "
                      f"first bad idx={i0} x={[rx_payload[b][i0] for b in range(4)]} "
                      f"y_rtl={y_al[i0]} y_oracle={y_oracle_full[i0]}")

    # int8 domain: allow +-2 LSB residual after finding the true pipeline lag.
    assert best_err <= 2, \
        f"{tag}: even at the best-fit lag ({best_lag}), oracle/RTL combiner " \
        f"mismatch max_err={best_err:.2f} (expected <=2 LSB) -- weights were " \
        f"not applied as computed (not just a sample-alignment artifact)"

    dut._log.info(f"{tag}: PASS -- IRQ->Z read->firmware weight compute->SPI write->"
                  f"W_COMMIT->combiner output all verified against oracle")
    drv.cancel()
