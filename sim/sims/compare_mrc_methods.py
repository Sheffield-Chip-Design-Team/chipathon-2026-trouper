"""
Compare MRC combining methods: eigenvector variants (FW path) vs legacy W_k row-sum.

Curves:
  oracle_clean      — ideal MRC, perfect clean h, float weights (channel-only ceiling)
  oracle_q15        — ideal MRC, perfect clean h, Q1.15 weights (quantization-only loss)
  oracle_lin_imp    — best linear combiner for the actual impaired branch waveforms
  eigvec_pre        — eigenvec of Z via eigh, preamble-only, Q1.15
  eigvec_iter_float — eigenvec of Z via power iteration (float), preamble-only, float
                      Direct float analogue of the firmware algorithm; should match
                      eigvec_pre within iteration-count tolerance.
  eigvec_psram      — eigenvec of Z via eigh, preamble+payload, Q1.15 (PSRAM replay path)
  eigvec_nw         — noise-whitened eigvec, oracle σ², PSRAM acc, Q1.15 (upper bound for NW)
  eigvec_fw_pre     — compute_eigvec_fw fixed-point, preamble-only (chip-accurate firmware path)
  wk_mrc            — W_k row-sum → WeightGenerator shift-normalise (legacy reference, not in trouper_top)

The eigvec_pre vs eigvec_iter_float comparison isolates any accuracy loss from using
power iteration instead of exact eigendecomposition.

Run from repo root:
    python3 -m sim.sims.compare_mrc_methods
    python3 -m sim.sims.compare_mrc_methods -n 2000 --sf 7
    python3 -m sim.sims.compare_mrc_methods --iters 4   # test fewer iterations
"""

import argparse
import os
import time
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

from sim.models.lora import modulate, demodulate
from sim.models.channel import rayleigh_coefficients, apply_iq_imbalance
from sim.models.training_accumulator import (
    training_accumulate_allpairs,
    compute_eigvec_weights,
    compute_eigvec_nw_weights,
    compute_weights as tacc_compute_weights,
)
from sim.models.receiver import nonfft_combine, quantize_q1_15
from sim.models.eigvec import compute_eigvec_weights_float
from sim.models.eigvec_fw import compute_eigvec_fw


def _iq_imbalance_profile(nr: int, gain_db_step: float = 0.0, phase_deg_step: float = 0.0) -> tuple[np.ndarray, np.ndarray]:
    """Deterministic branch-to-branch IQ-imbalance profile centred around zero."""
    idx = np.arange(nr, dtype=float) - 0.5 * (nr - 1)
    return idx * gain_db_step, idx * phase_deg_step


def _normalise(v: np.ndarray, q15: bool) -> np.ndarray:
    """Normalise to unit peak, optionally quantize to Q1.15."""
    m = float(np.max(np.abs(v)))
    if m == 0.0:
        return np.zeros_like(v)
    w = v / m
    if q15:
        return quantize_q1_15(w.real) + 1j * quantize_q1_15(w.imag)
    return w


def _oracle_weights(h: np.ndarray, q15: bool = True) -> np.ndarray:
    return _normalise(np.conj(h), q15)


def _oracle_linear_impaired(rx_symbol_noiseless: np.ndarray, desired_symbol: np.ndarray) -> np.ndarray:
    """Best linear combiner for the impaired per-branch symbol templates.

    Solves the least-squares problem::

        min_w || R w - s ||_2

    where columns of ``R`` are the noiseless impaired branch waveforms for the
    symbol being decoded and ``s`` is the ideal desired symbol waveform.
    This is a genie-aided upper bound for the current linear combiner
    architecture under frontend IQ imbalance.
    """
    R = rx_symbol_noiseless.T  # (M, NR)
    w, *_ = np.linalg.lstsq(R, desired_symbol, rcond=None)
    return w.astype(np.complex128)


def _eigvec_weights(Z_mat: np.ndarray, q15: bool = True) -> np.ndarray:
    v = np.linalg.eigh(Z_mat)[1][:, -1]
    return _normalise(np.conj(v), q15)


def _eigvec_nw(Z_mat: np.ndarray, N0, n_acc: int, q15: bool = True) -> np.ndarray:
    """Noise-whitened eigvec, delegating to the models-level PER-BRANCH form.

    Was a local scalar implementation subtracting N0*n_acc*I. A scalar pedestal
    is a multiple of I and therefore cannot rotate an eigenvector at all, so it
    could only ever correct the low-SNR magnitude bias -- never branch-noise
    imbalance, which is the case whitening actually exists for. A scalar N0 is
    still accepted here (broadcast to all branches) so this sweep's existing
    equal-noise call sites keep working; pass an (NR,) array for the asymmetric
    case. See sim/models/training_accumulator.py::compute_eigvec_nw_weights.
    """
    NR = Z_mat.shape[0]
    sigma2 = np.broadcast_to(np.asarray(N0, dtype=float), (NR,))
    w = compute_eigvec_nw_weights(Z_mat, sigma2, n_acc)
    return w if q15 else _normalise(w, False)


def simulate_one(SF: int, NR: int, N0: float,
                 preamble_len: int = 8, payload_symbols: int = 1,
                 eigvec_iters: int = 8,
                 iq_gain_db_step: float = 0.0,
                 iq_phase_deg_step: float = 0.0):
    """
    One packet. Returns dict of {label: b_rx} plus b_tx.

    payload_symbols controls how many symbols the full packet has. The last
    symbol is decoded; all symbols are used for PSRAM accumulation. Preamble-only
    accumulation uses only the preamble (preamble_len * M samples), regardless
    of payload length.
    """
    M = 2 ** SF
    h = rayleigh_coefficients(NR)
    iq_gain_db, iq_phase_deg = _iq_imbalance_profile(
        NR, gain_db_step=iq_gain_db_step, phase_deg_step=iq_phase_deg_step)

    def impair_noiseless(rx: np.ndarray) -> np.ndarray:
        out = np.empty_like(rx)
        for j in range(NR):
            out[j] = apply_iq_imbalance(
                rx[j], gain_db=float(iq_gain_db[j]), phase_deg=float(iq_phase_deg[j]))
        return out

    def impair(rx: np.ndarray) -> np.ndarray:
        out = impair_noiseless(rx)
        for j in range(NR):
            out[j] = out[j] + np.sqrt(N0 / 2) * (
                np.random.randn(rx.shape[1]) + 1j * np.random.randn(rx.shape[1]))
        return out

    rx_preamble = impair(h[:, None] * np.tile(modulate(0, M), preamble_len)[None, :])

    # Generate payload_symbols symbols; decode the last one
    payload_bits = [np.random.randint(0, M) for _ in range(payload_symbols)]
    rx_payload_all = np.concatenate(
        [impair(h[:, None] * modulate(b, M)[None, :]) for b in payload_bits], axis=1)
    b_tx = payload_bits[-1]
    desired_symbol = modulate(b_tx, M)
    rx_decode = rx_payload_all[:, -M:]   # last symbol to decode
    rx_decode_noiseless = impair_noiseless(h[:, None] * desired_symbol[None, :])

    # Preamble-only accumulator (baseline — ignores payload)
    Z_pre, _, n_pre = training_accumulate_allpairs(
        rx_preamble, sc_lock_sample=0, timing_ref=0, M=M,
        preamble_len=preamble_len)

    # PSRAM: preamble + full payload
    rx_full = np.concatenate([rx_preamble, rx_payload_all], axis=1)
    Z_psram, _, n_psram = training_accumulate_allpairs(
        rx_full, sc_lock_sample=0, timing_ref=0, M=M,
        packet_end=rx_full.shape[1] - 1)

    dec = lambda w: demodulate(nonfft_combine(rx_decode, w))

    # Legacy W_k row-sum (removed from trouper_top hardware; kept for comparison)
    W_k_pre = np.sum(Z_pre, axis=1) - np.diag(Z_pre)

    results = {
        "oracle_clean":      dec(_oracle_weights(h,        q15=False)),
        "oracle_q15":        dec(_oracle_weights(h,        q15=True)),
        "oracle_lin_imp":    dec(_oracle_linear_impaired(rx_decode_noiseless, desired_symbol)),
        "eigvec_fw_pre":     dec(compute_eigvec_fw(Z_pre, n_pre)),
        "eigvec_pre":        dec(_eigvec_weights(Z_pre,    q15=True)),
        "eigvec_iter_float": dec(compute_eigvec_weights_float(Z_pre, iters=eigvec_iters)),
        "eigvec_psram":      dec(_eigvec_weights(Z_psram,  q15=True)),
        "eigvec_nw":         dec(_eigvec_nw(Z_psram, N0, n_psram, q15=True)),
        "wk":                dec(tacc_compute_weights(W_k_pre, mode="mrc", sf=SF)),
    }
    return b_tx, results


KEYS = ("oracle_clean", "oracle_q15", "oracle_lin_imp", "eigvec_fw_pre", "eigvec_pre",
        "eigvec_iter_float", "eigvec_psram", "eigvec_nw", "wk")


def run_sweep(SF: int, NR: int, snr_list: list[float],
              n_packets: int, preamble_len: int = 8,
              payload_symbols: int = 1, eigvec_iters: int = 8,
              iq_gain_db_step: float = 0.0,
              iq_phase_deg_step: float = 0.0) -> dict:
    results = {k: [] for k in KEYS}
    for snr_db in snr_list:
        N0 = 10 ** (-snr_db / 10)
        errs = {k: 0 for k in KEYS}
        t0 = time.time()
        for _ in range(n_packets):
            b_tx, res = simulate_one(SF, NR, N0, preamble_len, payload_symbols,
                                     eigvec_iters=eigvec_iters,
                                     iq_gain_db_step=iq_gain_db_step,
                                     iq_phase_deg_step=iq_phase_deg_step)
            for k in KEYS:
                errs[k] += (b_tx != res[k])
        ser = {k: errs[k] / n_packets for k in KEYS}
        for k in KEYS:
            results[k].append(ser[k])

        def gap(a, b):
            if b == 0 or a == 0:
                return float("nan")
            return 10 * np.log10(a / b)

        print(f"  SNR={snr_db:+6.1f} dB  "
              f"oracle={ser['oracle_clean']:.4f}  "
              f"oracle_imp={ser['oracle_lin_imp']:.4f}  "
              f"eigvec_fw={ser['eigvec_fw_pre']:.4f}  "
              f"pre={ser['eigvec_pre']:.4f}  "
              f"iter_float={ser['eigvec_iter_float']:.4f}  "
              f"psram={ser['eigvec_psram']:.4f}  "
              f"nw={ser['eigvec_nw']:.4f}  "
              f"wk={ser['wk']:.4f}  "
              f"fw_vs_eigh={gap(ser['eigvec_fw_pre'], ser['eigvec_pre']):+.2f} dB  "
              f"({time.time()-t0:.1f}s)")
    return results


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--sf",          type=int,   default=7)
    p.add_argument("--nr",          type=int,   default=4)
    p.add_argument("-n", "--n-packets", type=int, default=500)
    p.add_argument("--snr",         type=str,   default="")
    p.add_argument("--preamble",    type=int,   default=8)
    p.add_argument("--payload",     type=int,   default=1,
                   help="Payload symbols per packet (default 1; use 50 for full-packet PSRAM test)")
    p.add_argument("--iters",       type=int,   default=8,
                   help="Power-iteration steps for eigvec_iter_float (default 8)")
    p.add_argument("--iq-gain-db-step", type=float, default=0.0,
                   help="Per-branch IQ gain mismatch step in dB, centred across branches")
    p.add_argument("--iq-phase-deg-step", type=float, default=0.0,
                   help="Per-branch quadrature phase mismatch step in degrees, centred across branches")
    p.add_argument("--out",         type=str,   default="sim/plots/compare_mrc_methods.png")
    args = p.parse_args()

    if args.snr:
        snr_list = [float(s) for s in args.snr.split(",")]
    else:
        snr_list = list(np.arange(-18, 5, 2, dtype=float))

    n_acc_pre  = args.preamble * (2 ** args.sf)
    n_acc_psram = (args.preamble + args.payload) * (2 ** args.sf)
    print(f"MRC method comparison  SF={args.sf}  NR={args.nr}  "
          f"N_packets={args.n_packets}  preamble={args.preamble}  payload={args.payload} symbols")
    print(f"IQ imbalance profile: gain step={args.iq_gain_db_step:+.2f} dB/branch, "
          f"phase step={args.iq_phase_deg_step:+.2f} deg/branch")
    print(f"Accumulation: preamble-only={n_acc_pre} samples, PSRAM={n_acc_psram} samples ({n_acc_psram/n_acc_pre:.1f}×)")
    print(f"SNR range: {snr_list[0]:+.0f} to {snr_list[-1]:+.0f} dB")
    print()

    t0 = time.time()
    res = run_sweep(args.sf, args.nr, snr_list, args.n_packets, args.preamble,
                   args.payload, eigvec_iters=args.iters,
                   iq_gain_db_step=args.iq_gain_db_step,
                   iq_phase_deg_step=args.iq_phase_deg_step)
    print(f"\nTotal: {time.time()-t0:.1f}s")

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    snr_arr = np.array(snr_list)
    fig, ax = plt.subplots(figsize=(10, 5))
    ax.semilogy(snr_arr, np.clip(res["oracle_clean"],      1e-4, 1), "k-",
                label="Oracle MRC (perfect clean h, float)")
    ax.semilogy(snr_arr, np.clip(res["oracle_q15"],          1e-4, 1), "k--",
                label="Oracle MRC (perfect clean h, Q1.15)")
    ax.semilogy(snr_arr, np.clip(res["oracle_lin_imp"],      1e-4, 1), "k:",
                label="Oracle linear combiner (impaired branches)")
    ax.semilogy(snr_arr, np.clip(res["eigvec_nw"],         1e-4, 1), "^-",  color="tab:green",
                label=f"Eigvec NW, Q1.15 (oracle σ², PSRAM {args.preamble}+{args.payload} sym)")
    ax.semilogy(snr_arr, np.clip(res["eigvec_psram"],      1e-4, 1), "s-",  color="tab:blue",
                label=f"Eigvec PSRAM, Q1.15 ({args.preamble}+{args.payload} sym acc)")
    ax.semilogy(snr_arr, np.clip(res["eigvec_fw_pre"],     1e-4, 1), "P-",  color="tab:red",
                label=f"Eigvec FW int32 (chip path, preamble {args.preamble} sym)")
    ax.semilogy(snr_arr, np.clip(res["eigvec_pre"],        1e-4, 1), "o--", color="tab:cyan",
                label=f"Eigvec eigh, Q1.15 (preamble {args.preamble} sym)")
    ax.semilogy(snr_arr, np.clip(res["eigvec_iter_float"], 1e-4, 1), "D-",  color="tab:purple",
                label=f"Eigvec power iter ({args.iters} iters, float, preamble {args.preamble} sym)")
    ax.semilogy(snr_arr, np.clip(res["wk"],                1e-4, 1), "s--", color="tab:orange",
                label="W_k row-sum (legacy reference, not in trouper_top)")
    ax.set_xlabel("Per-antenna SNR (dB)")
    ax.set_ylabel("Symbol Error Rate")
    ax.set_title(f"MRC Method Comparison  SF={args.sf}  NR={args.nr}  preamble={args.preamble}×M\nIQ imbalance: Δg={args.iq_gain_db_step:+.2f} dB/branch, Δφ={args.iq_phase_deg_step:+.2f} deg/branch")
    ax.grid(True, which="both", ls="--", alpha=0.4)
    ax.set_ylim(5e-4, 1.05)
    ax.legend(fontsize=8)
    fig.savefig(args.out, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"Plot: {args.out}")


if __name__ == "__main__":
    main()
