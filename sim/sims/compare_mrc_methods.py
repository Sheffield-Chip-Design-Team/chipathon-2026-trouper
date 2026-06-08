"""
Compare MRC combining methods: W_k row-sum (HW path) vs eigenvector variants (FW path).

Curves:
  oracle_float  — ideal MRC, perfect h, float weights (absolute ceiling)
  oracle_q15    — ideal MRC, perfect h, Q1.15 weights (quantization-only loss)
  eigvec_float  — eigenvec of Z, preamble-only, float weights (estimation-only loss)
  eigvec_q15    — eigenvec of Z, preamble-only, Q1.15 weights (estimation + quantization)
  eigvec_psram  — eigenvec of Z, preamble+payload, Q1.15 (PSRAM replay path)
  eigvec_nw     — noise-whitened eigvec, oracle σ², PSRAM acc, Q1.15 (upper bound for NW)
  wk_mrc        — W_k row-sum → WeightGenerator shift-normalise (current HW path, Q1.15)

The float vs Q1.15 split isolates quantization loss from estimation loss.

Run from repo root:
    python3 -m sim.sims.compare_mrc_methods
    python3 -m sim.sims.compare_mrc_methods -n 2000 --sf 7
"""

import argparse
import os
import time
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

from sim.models.lora import modulate, demodulate
from sim.models.channel import rayleigh_coefficients
from sim.models.training_accumulator import (
    training_accumulate_allpairs,
    compute_eigvec_weights,
    compute_weights as tacc_compute_weights,
)
from sim.models.receiver import nonfft_combine, quantize_q1_15


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


def _eigvec_weights(Z_mat: np.ndarray, q15: bool = True) -> np.ndarray:
    v = np.linalg.eigh(Z_mat)[1][:, -1]
    return _normalise(np.conj(v), q15)


def _eigvec_nw(Z_mat: np.ndarray, N0: float, n_acc: int, q15: bool = True) -> np.ndarray:
    """Noise-whitened eigvec: eig(Z − σ²·n_acc·I). Falls back to plain eigvec if all-negative."""
    NR = Z_mat.shape[0]
    Z_w = Z_mat - N0 * n_acc * np.eye(NR)
    eigvals, eigvecs = np.linalg.eigh(Z_w)
    v = eigvecs[:, -1] if eigvals[-1] > 0 else np.linalg.eigh(Z_mat)[1][:, -1]
    return _normalise(np.conj(v), q15)


def simulate_one(SF: int, NR: int, N0: float,
                 preamble_len: int = 8, payload_symbols: int = 1):
    """
    One packet. Returns dict of {label: b_rx} plus b_tx.

    payload_symbols controls how many symbols the full packet has. The last
    symbol is decoded; all symbols are used for PSRAM accumulation. Preamble-only
    accumulation uses only the preamble (preamble_len * M samples), regardless
    of payload length.
    """
    M = 2 ** SF
    h = rayleigh_coefficients(NR)

    noise = lambda n: np.sqrt(N0 / 2) * (
        np.random.randn(NR, n) + 1j * np.random.randn(NR, n))

    rx_preamble = h[:, None] * np.tile(modulate(0, M), preamble_len)[None, :] + noise(preamble_len * M)

    # Generate payload_symbols symbols; decode the last one
    payload_bits = [np.random.randint(0, M) for _ in range(payload_symbols)]
    rx_payload_all = np.concatenate(
        [h[:, None] * modulate(b, M)[None, :] + noise(M) for b in payload_bits], axis=1)
    b_tx = payload_bits[-1]
    rx_decode = rx_payload_all[:, -M:]   # last symbol to decode

    # Preamble-only accumulator (baseline — ignores payload)
    W_k, Z_pre, _, n_pre = training_accumulate_allpairs(
        rx_preamble, sc_lock_sample=0, timing_ref=0, M=M,
        preamble_len=preamble_len, return_matrix=True)

    # PSRAM: preamble + full payload
    rx_full = np.concatenate([rx_preamble, rx_payload_all], axis=1)
    _, Z_psram, _, n_psram = training_accumulate_allpairs(
        rx_full, sc_lock_sample=0, timing_ref=0, M=M,
        packet_end=rx_full.shape[1] - 1, return_matrix=True)

    dec = lambda w: demodulate(nonfft_combine(rx_decode, w))

    results = {
        "oracle_float": dec(_oracle_weights(h,       q15=False)),
        "oracle_q15":   dec(_oracle_weights(h,       q15=True)),
        "eigvec_pre":   dec(_eigvec_weights(Z_pre,   q15=True)),
        "eigvec_psram": dec(_eigvec_weights(Z_psram, q15=True)),
        "eigvec_nw":    dec(_eigvec_nw(Z_psram, N0, n_psram, q15=True)),
        "wk":           dec(tacc_compute_weights(W_k, mode="mrc", sf=SF)),
    }
    return b_tx, results


KEYS = ("oracle_float", "oracle_q15", "eigvec_pre", "eigvec_psram", "eigvec_nw", "wk")


def run_sweep(SF: int, NR: int, snr_list: list[float],
              n_packets: int, preamble_len: int = 8,
              payload_symbols: int = 1) -> dict:
    results = {k: [] for k in KEYS}
    for snr_db in snr_list:
        N0 = 10 ** (-snr_db / 10)
        errs = {k: 0 for k in KEYS}
        t0 = time.time()
        for _ in range(n_packets):
            b_tx, res = simulate_one(SF, NR, N0, preamble_len, payload_symbols)
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
              f"oracle={ser['oracle_float']:.4f}  "
              f"pre={ser['eigvec_pre']:.4f}  "
              f"psram={ser['eigvec_psram']:.4f}  "
              f"nw={ser['eigvec_nw']:.4f}  "
              f"wk={ser['wk']:.4f}  "
              f"psram_vs_pre={gap(ser['eigvec_psram'], ser['eigvec_pre']):+.2f} dB  "
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
    print(f"Accumulation: preamble-only={n_acc_pre} samples, PSRAM={n_acc_psram} samples ({n_acc_psram/n_acc_pre:.1f}×)")
    print(f"SNR range: {snr_list[0]:+.0f} to {snr_list[-1]:+.0f} dB")
    print()

    t0 = time.time()
    res = run_sweep(args.sf, args.nr, snr_list, args.n_packets, args.preamble, args.payload)
    print(f"\nTotal: {time.time()-t0:.1f}s")

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    snr_arr = np.array(snr_list)
    fig, ax = plt.subplots(figsize=(10, 5))
    ax.semilogy(snr_arr, np.clip(res["oracle_float"], 1e-4, 1), "k-",
                label="Oracle MRC (perfect h, float)")
    ax.semilogy(snr_arr, np.clip(res["oracle_q15"],   1e-4, 1), "k--",
                label="Oracle MRC (perfect h, Q1.15)")
    ax.semilogy(snr_arr, np.clip(res["eigvec_nw"],    1e-4, 1), "^-",  color="tab:green",
                label=f"Eigvec NW, Q1.15 (oracle σ², PSRAM {args.preamble}+{args.payload} sym)")
    ax.semilogy(snr_arr, np.clip(res["eigvec_psram"], 1e-4, 1), "s-",  color="tab:blue",
                label=f"Eigvec PSRAM, Q1.15 ({args.preamble}+{args.payload} sym acc)")
    ax.semilogy(snr_arr, np.clip(res["eigvec_pre"],   1e-4, 1), "o--", color="tab:cyan",
                label=f"Eigvec preamble-only, Q1.15 ({args.preamble} sym acc)")
    ax.semilogy(snr_arr, np.clip(res["wk"],           1e-4, 1), "s--", color="tab:orange",
                label="W_k row-sum (HW path, Q1.15)")
    ax.set_xlabel("Per-antenna SNR (dB)")
    ax.set_ylabel("Symbol Error Rate")
    ax.set_title(f"MRC Method Comparison  SF={args.sf}  NR={args.nr}  preamble={args.preamble}×M")
    ax.grid(True, which="both", ls="--", alpha=0.4)
    ax.set_ylim(5e-4, 1.05)
    ax.legend(fontsize=8)
    fig.savefig(args.out, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"Plot: {args.out}")


if __name__ == "__main__":
    main()
