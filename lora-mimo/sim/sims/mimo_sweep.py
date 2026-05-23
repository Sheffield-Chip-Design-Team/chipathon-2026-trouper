#!/usr/bin/env python3
"""
MIMO MRC sweep simulations.

Covers six experiments:
  1. BER vs SNR   — bypass / oracle / training / EGC / SC / post-detection (NR=4)
  2. NR scaling   — SER vs NR at fixed SNR for oracle and training
  3. Preamble len — oracle-training gap vs preamble_len at several SNRs
  4. Shift-MRC    — exact/oracle vs hardware shift-MRC under branch imbalance
  5. Doppler      — SER vs f_D for MRC oracle vs SC vs bypass
  6. Hierarchical — flat NR=8 vs two-stage 2×NR=4 for oracle and training

Run:
    cd /path/to/chipathon-2026/lora-mimo
    python3 -m sim.sims.mimo_sweep              # all sweeps
    python3 -m sim.sims.mimo_sweep --sweep ber
    python3 -m sim.sims.mimo_sweep --sweep nr
    python3 -m sim.sims.mimo_sweep --sweep preamble
    python3 -m sim.sims.mimo_sweep --sweep shiftmrc
    python3 -m sim.sims.mimo_sweep --sweep doppler
    python3 -m sim.sims.mimo_sweep --sweep hierarchical
    python3 -m sim.sims.mimo_sweep -n 2000      # more trials per point

Output:  sim/plots/sweep_*.png
"""

import argparse
import sys
import os
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from sim.models.lora               import modulate, demodulate
from sim.models.channel            import rayleigh_coefficients
from sim.models.receiver           import (
    nonfft_combine,
    nonfft_combine_rtl_int8,
    choose_comb_post_gain,
    _quantize_q15_int,
    _as_int8_pair,
)
from sim.models.training_accumulator import (
    training_accumulate,
    compute_weights,
)
from sim.models.weight_generation import compute_exact_mrc_weights

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _dechirp_fft(rx: np.ndarray) -> np.ndarray:
    """Return FFT magnitude spectrum of one de-chirped symbol."""
    M = len(rx)
    n = np.arange(M)
    return np.abs(np.fft.fft(rx * np.exp(-1j * np.pi * n ** 2 / M)))


def _jakes(N: int, f_D: float, f_s: float, N_osc: int = 12) -> np.ndarray:
    """Jakes fading: NR-independent complex envelope, length N."""
    t = np.arange(N) / f_s
    h = np.zeros(N, dtype=complex)
    for k in range(1, N_osc + 1):
        alpha = np.pi * k / (N_osc + 1)
        phase = np.random.uniform(0, 2 * np.pi)
        h += np.exp(1j * (2 * np.pi * f_D * np.cos(alpha) * t + phase))
    return h / np.sqrt(N_osc)


def _train_weights(rx_preamble: np.ndarray, M: int, preamble_len: int,
                   sc_hit_syms: int = 2, mode: str = "mrc") -> np.ndarray:
    """Run training_accumulate + compute_weights; SC fires after sc_hit_syms."""
    sc_lock  = sc_hit_syms * M
    timing   = 0
    Z, _, E  = training_accumulate(rx_preamble, sc_lock, timing, M,
                                   preamble_len=preamble_len)
    return compute_weights(Z, mode=mode, E_ref=E)


def _branch_ladder_gains(NR: int, step_db: float) -> np.ndarray:
    """
    Deterministic branch imbalance profile.

    branch 0 is strongest; each subsequent branch is attenuated by `step_db`.
    This stresses shared-shift MRC headroom without changing branch order.
    """
    idx = np.arange(NR, dtype=float)
    return 10.0 ** (-float(step_db) * idx / 20.0)


# ---------------------------------------------------------------------------
# Core packet simulation
# ---------------------------------------------------------------------------

def simulate_packet(
    SF: int,
    NR: int,
    N0: float,
    mode: str,
    preamble_len: int = 8,
    h_fixed: np.ndarray | None = None,
) -> tuple[int, int]:
    """
    Simulate one LoRa packet (preamble + 1 payload symbol) end-to-end.

    Parameters
    ----------
    SF          : spreading factor
    NR          : receive branches
    N0          : per-sample noise power (linear)
    mode        : oracle | training | egc | sc | bypass | postdet
    preamble_len: upchirp preamble length in symbols
    h_fixed     : (NR,) channel — drawn fresh if None

    Returns
    -------
    (b_tx, b_rx)
    """
    M = 2 ** SF
    h = rayleigh_coefficients(NR) if h_fixed is None else h_fixed

    noise = lambda n: np.sqrt(N0 / 2) * (
        np.random.randn(NR, n) + 1j * np.random.randn(NR, n)
    )

    # Preamble: preamble_len upchirps at symbol 0
    chirp0     = modulate(0, M)
    preamble   = np.tile(chirp0, preamble_len)            # (preamble_len*M,)
    rx_preamble = h[:, None] * preamble[None, :] + noise(preamble_len * M)

    # Payload: one random symbol
    b_tx      = np.random.randint(0, M)
    rx_payload = h[:, None] * modulate(b_tx, M)[None, :] + noise(M)

    if mode == "postdet":
        fft_sum = sum(_dechirp_fft(rx_payload[j]) for j in range(NR))
        return b_tx, int(np.argmax(fft_sum))

    if mode == "oracle":
        S = float(np.sum(np.abs(h) ** 2))
        w = np.conj(h) / S
    elif mode == "training":
        w = _train_weights(rx_preamble, M, preamble_len, mode="mrc")
    elif mode == "egc":
        Z, _, _ = training_accumulate(rx_preamble, 2 * M, 0, M,
                                      preamble_len=preamble_len)
        w = np.exp(-1j * np.angle(Z)) / NR
    elif mode == "sc":
        Z, _, _ = training_accumulate(rx_preamble, 2 * M, 0, M,
                                      preamble_len=preamble_len)
        best = int(np.argmax(np.abs(Z)))
        w = np.zeros(NR, dtype=complex)
        w[best] = np.exp(-1j * np.angle(Z[best]))
    elif mode == "bypass":
        w = np.zeros(NR, dtype=complex)
        w[0] = 1.0
    else:
        raise ValueError(f"Unknown mode: {mode}")

    y = nonfft_combine(rx_payload, w)
    return b_tx, demodulate(y)


def _compare_shift_mrc_packet(
    SF: int,
    NR: int,
    N0: float,
    preamble_len: int = 8,
    branch_step_db: float = 0.0,
    adc_scale: float = 64.0,
) -> dict[str, int | float | bool]:
    """
    One packet for the shift-MRC sweep.

    This isolates the normalization choice by feeding the same training
    estimate Z_j into both exact/oracle MRC and the hardware shift-MRC path.
    """
    M = 2 ** SF
    ladder = _branch_ladder_gains(NR, branch_step_db)
    h = rayleigh_coefficients(NR) * ladder

    noise = lambda n: np.sqrt(N0 / 2) * (
        np.random.randn(NR, n) + 1j * np.random.randn(NR, n)
    )

    chirp0 = modulate(0, M)
    preamble = np.tile(chirp0, preamble_len)
    rx_preamble = h[:, None] * preamble[None, :] + noise(preamble_len * M)

    b_tx = np.random.randint(0, M)
    rx_payload = h[:, None] * modulate(b_tx, M)[None, :] + noise(M)

    Z, _, E_ref = training_accumulate(
        rx_preamble,
        2 * M,
        0,
        M,
        preamble_len=preamble_len,
    )

    w_exact = compute_exact_mrc_weights(Z, E_ref=E_ref)
    w_shift = compute_weights(Z, mode="mrc", E_ref=E_ref)
    Z_z = Z.copy()
    best = int(np.argmax(np.abs(Z_z)))
    w_sc = np.zeros(NR, dtype=complex)
    w_sc[best] = np.exp(-1j * np.angle(Z_z[best]))
    w_bypass = np.zeros(NR, dtype=complex)
    w_bypass[0] = 1.0

    b_rx_exact = int(demodulate(nonfft_combine(rx_payload, w_exact)))
    b_rx_shift = int(demodulate(nonfft_combine(rx_payload, w_shift)))
    b_rx_sc = int(demodulate(nonfft_combine(rx_payload, w_sc)))
    b_rx_bypass = int(demodulate(nonfft_combine(rx_payload, w_bypass)))

    rx_payload_rtl = adc_scale * rx_payload
    y_rtl0 = nonfft_combine_rtl_int8(rx_payload_rtl, w_shift, post_gain_shift=0)
    comb_post_gain = choose_comb_post_gain(y_rtl0)

    # Pre-saturation headroom metric: compute the raw guarded accumulator,
    # then measure how many samples would exceed int8 before clipping.
    x_i, x_q = _as_int8_pair(rx_payload_rtl)
    w_re, w_im = _quantize_q15_int(w_shift)
    acc_i = np.sum(w_re[:, None] * x_i - w_im[:, None] * x_q, axis=0)
    acc_q = np.sum(w_re[:, None] * x_q + w_im[:, None] * x_i, axis=0)
    raw_i = (acc_i >> 1) << int(comb_post_gain)
    raw_q = (acc_q >> 1) << int(comb_post_gain)
    peak = float(max(np.max(np.abs(raw_i)), np.max(np.abs(raw_q))))
    sat = float(max(0.0, np.ceil(np.log2(max(peak / 127.0, 1.0)))))
    y_rtl = nonfft_combine_rtl_int8(
        rx_payload_rtl,
        w_shift,
        post_gain_shift=comb_post_gain,
    )

    return {
        "b_tx": b_tx,
        "exact": b_rx_exact,
        "shift": b_rx_shift,
        "sc": b_rx_sc,
        "bypass": b_rx_bypass,
        "comb_post_gain": comb_post_gain,
        "rtl_sat": sat,
    }


# ---------------------------------------------------------------------------
# Monte Carlo runner
# ---------------------------------------------------------------------------

def ser_at_snr(SF, NR, snr_db, mode, N_packets, preamble_len=8) -> float:
    N0 = 10 ** (-snr_db / 10)
    errs = sum(
        b_tx != b_rx
        for b_tx, b_rx in (
            simulate_packet(SF, NR, N0, mode, preamble_len)
            for _ in range(N_packets)
        )
    )
    return errs / N_packets


# ---------------------------------------------------------------------------
# Sweep 1 — BER vs SNR
# ---------------------------------------------------------------------------

def sweep_ber(SF=7, NR=4, N_packets=500, snr_range=None):
    if snr_range is None:
        snr_range = np.arange(-15, 6, 2, dtype=float)

    modes = ["bypass", "sc", "egc", "training", "oracle", "postdet"]
    labels = {
        "bypass":  "Bypass (NR=1)",
        "sc":      "SC",
        "egc":     "EGC",
        "training":"Training MRC",
        "oracle":  "Oracle MRC",
        "postdet": "Post-det (non-coh)",
    }
    colours = {
        "bypass":  "gray",
        "sc":      "tab:red",
        "egc":     "tab:orange",
        "training":"tab:blue",
        "oracle":  "tab:green",
        "postdet": "tab:purple",
    }

    results = {m: [] for m in modes}
    for snr_db in snr_range:
        print(f"  BER sweep SNR={snr_db:+.0f} dB", flush=True)
        for m in modes:
            results[m].append(ser_at_snr(SF, NR, snr_db, m, N_packets))

    fig, ax = plt.subplots(figsize=(8, 5))
    for m in modes:
        ser = np.array(results[m])
        ax.semilogy(snr_range, np.clip(ser, 1e-4, 1),
                    "o-", label=labels[m], color=colours[m])
    ax.set_xlabel("Per-antenna SNR (dB)")
    ax.set_ylabel("Symbol Error Rate")
    ax.set_title(f"MIMO MRC — BER vs SNR  SF={SF}  NR={NR}")
    ax.legend(fontsize=9)
    ax.grid(True, which="both", ls="--", alpha=0.4)
    ax.set_ylim(5e-4, 1.05)
    outpath = "sim/plots/sweep_ber.png"
    fig.savefig(outpath, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  → {outpath}")
    return results, snr_range


# ---------------------------------------------------------------------------
# Sweep 2 — NR scaling
# ---------------------------------------------------------------------------

def sweep_nr(SF=7, snr_db=0.0, N_packets=500, NR_list=None):
    if NR_list is None:
        NR_list = [1, 2, 4, 8]

    modes  = ["oracle", "training", "sc", "bypass"]
    labels = {"oracle": "Oracle MRC", "training": "Training MRC",
              "sc": "SC", "bypass": "Bypass (NR=1)"}
    colours = {"oracle": "tab:green", "training": "tab:blue",
               "sc": "tab:red", "bypass": "gray"}

    results = {m: [] for m in modes}
    for NR in NR_list:
        print(f"  NR scaling NR={NR}", flush=True)
        for m in modes:
            effective_NR = 1 if m == "bypass" else NR
            results[m].append(ser_at_snr(SF, effective_NR, snr_db, m, N_packets))

    fig, ax = plt.subplots(figsize=(7, 4))
    for m in modes:
        ax.semilogy(NR_list, np.clip(results[m], 1e-4, 1),
                    "o-", label=labels[m], color=colours[m])
    ax.set_xlabel("Number of RX branches (NR)")
    ax.set_ylabel("Symbol Error Rate")
    ax.set_title(f"MIMO MRC — NR scaling  SF={SF}  SNR={snr_db:+.0f} dB")
    ax.set_xticks(NR_list)
    ax.legend(fontsize=9)
    ax.grid(True, which="both", ls="--", alpha=0.4)
    outpath = "sim/plots/sweep_nr.png"
    fig.savefig(outpath, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  → {outpath}")
    return results


# ---------------------------------------------------------------------------
# Sweep 3 — Preamble length
# ---------------------------------------------------------------------------

def sweep_preamble(SF=7, NR=4, N_packets=600, preamble_lens=None, snr_dbs=None):
    if preamble_lens is None:
        preamble_lens = [4, 6, 8, 10, 12, 16]
    if snr_dbs is None:
        snr_dbs = [-5.0, 0.0, 5.0]

    fig, axes = plt.subplots(1, 2, figsize=(12, 4))

    # Left: absolute SER for oracle vs training at different preamble lengths
    ax = axes[0]
    cmap = plt.cm.viridis(np.linspace(0, 0.85, len(snr_dbs)))
    for i, snr_db in enumerate(snr_dbs):
        ser_oracle   = []
        ser_training = []
        for pl in preamble_lens:
            print(f"  Preamble sweep preamble_len={pl}  SNR={snr_db:+.0f} dB", flush=True)
            ser_oracle.append(ser_at_snr(SF, NR, snr_db, "oracle",   N_packets, pl))
            ser_training.append(ser_at_snr(SF, NR, snr_db, "training", N_packets, pl))
        c = cmap[i]
        ax.semilogy(preamble_lens, np.clip(ser_oracle,   1e-4, 1),
                    "o--", color=c, alpha=0.6, label=f"Oracle {snr_db:+.0f} dB")
        ax.semilogy(preamble_lens, np.clip(ser_training, 1e-4, 1),
                    "s-",  color=c, label=f"Training {snr_db:+.0f} dB")
    ax.set_xlabel("Preamble length (symbols)")
    ax.set_ylabel("SER")
    ax.set_title("SER vs Preamble length  (dashed=oracle)")
    ax.legend(fontsize=7, ncol=2)
    ax.grid(True, which="both", ls="--", alpha=0.4)

    # Right: oracle-training gap in dB at SNR=0 dB
    snr_db = 0.0
    gaps = []
    ser_o_list = []
    ser_t_list = []
    for pl in preamble_lens:
        print(f"  Gap sweep preamble_len={pl}", flush=True)
        so = ser_at_snr(SF, NR, snr_db, "oracle",   N_packets, pl)
        st = ser_at_snr(SF, NR, snr_db, "training", N_packets, pl)
        ser_o_list.append(so)
        ser_t_list.append(st)
        # gap in dB: how much extra SNR training needs to match oracle
        ratio = max(st, 1e-6) / max(so, 1e-6)
        gaps.append(10 * np.log10(max(ratio, 1.0)))

    ax2 = axes[1]
    ax2.plot(preamble_lens, gaps, "o-", color="tab:blue")
    ax2.set_xlabel("Preamble length (symbols)")
    ax2.set_ylabel("Training estimation loss (dB)")
    ax2.set_title(f"Oracle–Training gap vs Preamble length  SNR=0 dB")
    ax2.grid(True, ls="--", alpha=0.4)
    ax2.set_ylim(bottom=0)

    outpath = "sim/plots/sweep_preamble.png"
    fig.savefig(outpath, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  → {outpath}")


# ---------------------------------------------------------------------------
# Sweep 4 — Shift-MRC vs exact/oracle under branch imbalance
# ---------------------------------------------------------------------------

def sweep_shift_mrc(SF=7, NR=4, N_packets=500, snr_db=0.0,
                    branch_step_dbs=None, adc_scale: float = 64.0):
    if branch_step_dbs is None:
        branch_step_dbs = [0, 2, 4, 6, 8, 10, 12]

    exact_ser = []
    shift_ser = []
    sc_ser = []
    bypass_ser = []
    comb_gains = []
    rtl_sat_rates = []

    N0 = 10 ** (-snr_db / 10)
    for step_db in branch_step_dbs:
        print(f"  Shift-MRC branch step={step_db:+.0f} dB", flush=True)
        errs_exact = errs_shift = errs_sc = errs_bypass = 0
        gain_sum = 0
        sat_sum = 0
        for _ in range(N_packets):
            result = _compare_shift_mrc_packet(
                SF,
                NR,
                N0,
                branch_step_db=float(step_db),
                adc_scale=adc_scale,
            )
            b_tx = result["b_tx"]
            errs_exact += int(b_tx != result["exact"])
            errs_shift += int(b_tx != result["shift"])
            errs_sc += int(b_tx != result["sc"])
            errs_bypass += int(b_tx != result["bypass"])
            gain_sum += int(result["comb_post_gain"])
            sat_sum += float(result["rtl_sat"])

        exact_ser.append(errs_exact / N_packets)
        shift_ser.append(errs_shift / N_packets)
        sc_ser.append(errs_sc / N_packets)
        bypass_ser.append(errs_bypass / N_packets)
        comb_gains.append(gain_sum / N_packets)
        rtl_sat_rates.append(sat_sum / N_packets)

    fig, axes = plt.subplots(1, 2, figsize=(12, 4.5))

    ax = axes[0]
    ax.semilogy(branch_step_dbs, np.clip(exact_ser, 1e-4, 1),
                "o--", color="tab:green", linewidth=2.5, markersize=6,
                markerfacecolor="white", markeredgewidth=1.5,
                label="Exact/oracle MRC", zorder=4)
    ax.semilogy(branch_step_dbs, np.clip(shift_ser, 1e-4, 1),
                "o-", color="tab:blue", linewidth=2.0, markersize=5,
                label="Shift-MRC (HW)", zorder=3)
    ax.semilogy(branch_step_dbs, np.clip(sc_ser, 1e-4, 1),
                "s-", color="tab:red", linewidth=1.6, markersize=4,
                label="SC", zorder=2)
    ax.semilogy(branch_step_dbs, np.clip(bypass_ser, 1e-4, 1),
                "d-", color="gray", linewidth=1.4, markersize=4,
                label="Bypass", zorder=1)
    ax.set_xlabel("Per-branch attenuation step (dB)")
    ax.set_ylabel("Symbol Error Rate")
    ax.set_title(f"Shift-MRC vs exact/oracle  SF={SF}  NR={NR}  SNR={snr_db:+.0f} dB")
    ax.grid(True, which="both", ls="--", alpha=0.4)
    ax.legend(fontsize=8)
    ax.set_ylim(5e-4, 1.05)

    ax = axes[1]
    ax.plot(branch_step_dbs, comb_gains, "o-", color="tab:blue", label="Mean COMB_POST_GAIN")
    ax.set_xlabel("Per-branch attenuation step (dB)")
    ax.set_ylabel("Mean COMB_POST_GAIN")
    ax.set_title(f"RTL headroom policy  (adc_scale={adc_scale:.0f})")
    ax.grid(True, ls="--", alpha=0.4)
    ax.set_ylim(bottom=0)
    ax2 = ax.twinx()
    ax2.plot(branch_step_dbs, rtl_sat_rates, "s--", color="tab:red", label="Required extra shift bits")
    ax2.set_ylabel("Extra right-shift bits needed")
    ax2.set_ylim(bottom=0)

    lines, labels = ax.get_legend_handles_labels()
    lines2, labels2 = ax2.get_legend_handles_labels()
    ax.legend(lines + lines2, labels + labels2, fontsize=8, loc="upper right")

    outpath = "sim/plots/sweep_shift_mrc.png"
    fig.savefig(outpath, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  → {outpath}")
    return {
        "branch_step_dbs": branch_step_dbs,
        "exact_ser": exact_ser,
        "shift_ser": shift_ser,
        "sc_ser": sc_ser,
        "bypass_ser": bypass_ser,
        "comb_post_gain": comb_gains,
        "rtl_sat_rate": rtl_sat_rates,
    }


# ---------------------------------------------------------------------------
# Sweep 5 — Doppler (Jakes time-varying channel)
# ---------------------------------------------------------------------------

def simulate_packet_doppler(SF: int, NR: int, N0: float, mode: str,
                            f_D: float, preamble_len: int = 8) -> tuple[int, int]:
    """Like simulate_packet but with Jakes time-varying channel per branch."""
    M = 2 ** SF
    f_s = 2 ** SF * 125_000 / 128  # baseband sample rate = BW = 125 kHz (normalised)

    N_total = (preamble_len + 1) * M

    noise = lambda n: np.sqrt(N0 / 2) * (
        np.random.randn(NR, n) + 1j * np.random.randn(NR, n)
    )

    # Time-varying channel per branch
    h_time = np.array([_jakes(N_total, f_D, f_s) for _ in range(NR)])

    chirp0 = modulate(0, M)
    preamble_sig = np.tile(chirp0, preamble_len)  # (preamble_len*M,)

    rx_preamble = (h_time[:, :preamble_len * M] * preamble_sig[None, :]
                   + noise(preamble_len * M))

    b_tx = np.random.randint(0, M)
    payload_start = preamble_len * M
    rx_payload = (h_time[:, payload_start:payload_start + M] * modulate(b_tx, M)[None, :]
                  + noise(M))

    if mode == "postdet":
        fft_sum = sum(_dechirp_fft(rx_payload[j]) for j in range(NR))
        return b_tx, int(np.argmax(fft_sum))

    if mode == "oracle":
        h_pay = h_time[:, payload_start:payload_start + M].mean(axis=1)
        S = float(np.sum(np.abs(h_pay) ** 2))
        w = np.conj(h_pay) / S
    elif mode == "training":
        w = _train_weights(rx_preamble, M, preamble_len, mode="mrc")
    elif mode == "sc":
        Z, _, _ = training_accumulate(rx_preamble, 2 * M, 0, M,
                                      preamble_len=preamble_len)
        best = int(np.argmax(np.abs(Z)))
        w = np.zeros(NR, dtype=complex)
        w[best] = np.exp(-1j * np.angle(Z[best]))
    elif mode == "bypass":
        w = np.zeros(NR, dtype=complex)
        w[0] = 1.0
    else:
        raise ValueError(f"Unknown mode: {mode}")

    y = nonfft_combine(rx_payload, w)
    return b_tx, demodulate(y)


def _compare_shift_mrc_packet(
    SF: int,
    NR: int,
    N0: float,
    preamble_len: int = 8,
    branch_step_db: float = 0.0,
    adc_scale: float = 64.0,
) -> dict[str, int | float | bool]:
    """
    One packet for the shift-MRC sweep.

    This isolates the normalization choice by feeding the same training
    estimate Z_j into both exact/oracle MRC and the hardware shift-MRC path.
    """
    M = 2 ** SF
    ladder = _branch_ladder_gains(NR, branch_step_db)
    h = rayleigh_coefficients(NR) * ladder

    noise = lambda n: np.sqrt(N0 / 2) * (
        np.random.randn(NR, n) + 1j * np.random.randn(NR, n)
    )

    chirp0 = modulate(0, M)
    preamble = np.tile(chirp0, preamble_len)
    rx_preamble = h[:, None] * preamble[None, :] + noise(preamble_len * M)

    b_tx = np.random.randint(0, M)
    rx_payload = h[:, None] * modulate(b_tx, M)[None, :] + noise(M)

    Z, _, E_ref = training_accumulate(
        rx_preamble,
        2 * M,
        0,
        M,
        preamble_len=preamble_len,
    )

    w_exact = compute_exact_mrc_weights(Z, E_ref=E_ref)
    w_shift = compute_weights(Z, mode="mrc", E_ref=E_ref)
    Z_z = Z.copy()
    best = int(np.argmax(np.abs(Z_z)))
    w_sc = np.zeros(NR, dtype=complex)
    w_sc[best] = np.exp(-1j * np.angle(Z_z[best]))
    w_bypass = np.zeros(NR, dtype=complex)
    w_bypass[0] = 1.0

    b_rx_exact = int(demodulate(nonfft_combine(rx_payload, w_exact)))
    b_rx_shift = int(demodulate(nonfft_combine(rx_payload, w_shift)))
    b_rx_sc = int(demodulate(nonfft_combine(rx_payload, w_sc)))
    b_rx_bypass = int(demodulate(nonfft_combine(rx_payload, w_bypass)))

    rx_payload_rtl = adc_scale * rx_payload
    y_rtl0 = nonfft_combine_rtl_int8(rx_payload_rtl, w_shift, post_gain_shift=0)
    comb_post_gain = choose_comb_post_gain(y_rtl0)

    # Pre-saturation headroom metric: compute the raw guarded accumulator,
    # then measure how many samples would exceed int8 before clipping.
    x_i, x_q = _as_int8_pair(rx_payload_rtl)
    w_re, w_im = _quantize_q15_int(w_shift)
    acc_i = np.sum(w_re[:, None] * x_i - w_im[:, None] * x_q, axis=0)
    acc_q = np.sum(w_re[:, None] * x_q + w_im[:, None] * x_i, axis=0)
    raw_i = (acc_i >> 1) << int(comb_post_gain)
    raw_q = (acc_q >> 1) << int(comb_post_gain)
    peak = float(max(np.max(np.abs(raw_i)), np.max(np.abs(raw_q))))
    sat = float(max(0.0, np.ceil(np.log2(max(peak / 127.0, 1.0)))))
    y_rtl = nonfft_combine_rtl_int8(
        rx_payload_rtl,
        w_shift,
        post_gain_shift=comb_post_gain,
    )

    return {
        "b_tx": b_tx,
        "exact": b_rx_exact,
        "shift": b_rx_shift,
        "sc": b_rx_sc,
        "bypass": b_rx_bypass,
        "comb_post_gain": comb_post_gain,
        "rtl_sat": sat,
    }


def sweep_doppler(SF=7, NR=4, snr_db=0.0, N_packets=500,
                  fd_list=None):
    if fd_list is None:
        fd_list = [0, 1, 2, 5, 10, 20, 50, 100]

    modes  = ["oracle", "training", "sc", "postdet", "bypass"]
    labels = {"oracle":  "Oracle MRC (genie payload h)",
               "training":"Training MRC",
               "sc":      "SC",
               "postdet": "Post-det (non-coh)",
               "bypass":  "Bypass (NR=1)"}
    colours = {"oracle": "tab:green", "training": "tab:blue",
               "sc": "tab:red", "postdet": "tab:purple", "bypass": "gray"}

    N0 = 10 ** (-snr_db / 10)
    results = {m: [] for m in modes}

    for f_D in fd_list:
        print(f"  Doppler f_D={f_D} Hz", flush=True)
        for m in modes:
            errs = sum(
                b_tx != b_rx
                for b_tx, b_rx in (
                    simulate_packet_doppler(SF, NR, N0, m, f_D)
                    for _ in range(N_packets)
                )
            )
            results[m].append(errs / N_packets)

    fig, ax = plt.subplots(figsize=(8, 5))
    fd_plot = [max(f, 0.1) for f in fd_list]  # avoid log(0)
    for m in modes:
        ax.semilogx(fd_plot, results[m], "o-",
                    label=labels[m], color=colours[m])
    ax.set_xlabel("Doppler frequency f_D (Hz)")
    ax.set_ylabel("Symbol Error Rate")
    ax.set_title(f"MIMO MRC vs Doppler  SF={SF}  NR={NR}  SNR={snr_db:+.0f} dB")
    ax.legend(fontsize=9)
    ax.grid(True, which="both", ls="--", alpha=0.4)
    ax.set_ylim(0, 0.7)
    # Mark walking speed at 868 MHz
    f_walk = 868e6 * (4 / 3.6) / 3e8   # ~3.2 Hz
    ax.axvline(f_walk, ls=":", color="black", alpha=0.5, label="Walking 4 km/h")
    ax.text(f_walk * 1.1, 0.62, "walk\n4 km/h", fontsize=7, alpha=0.7)
    outpath = "sim/plots/sweep_doppler.png"
    fig.savefig(outpath, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  → {outpath}")
    return results


# ---------------------------------------------------------------------------
# Sweep 5 — Hierarchical MRC (2×NR=4 vs flat NR=8)
# ---------------------------------------------------------------------------

def simulate_hierarchical(SF: int, N0: float, NR_stage: int = 4,
                          preamble_len: int = 8) -> tuple[int, int, int]:
    """
    Two-stage hierarchical MRC: 2×NR_stage antennas total.

    Stage 1: each group of NR_stage branches combines independently.
    Stage 2: the two stage-1 outputs are treated as 2 "antennas" and
             combined with weights estimated from the stage-1 combined preambles.

    Bug fix: stage-2 training now uses the full combined preamble
    (preamble_len * M samples), not a 2-symbol slice.
    """
    NR_total = 2 * NR_stage
    M = 2 ** SF
    h = rayleigh_coefficients(NR_total)
    h_A, h_B = h[:NR_stage], h[NR_stage:]

    noise = lambda NR, n: np.sqrt(N0 / 2) * (
        np.random.randn(NR, n) + 1j * np.random.randn(NR, n)
    )

    chirp0       = modulate(0, M)
    preamble_sig = np.tile(chirp0, preamble_len)   # (preamble_len*M,)
    b_tx         = np.random.randint(0, M)
    s_pay        = modulate(b_tx, M)

    # Stage-1 received signals (single noise draw, shared by training + oracle)
    rx_preamble_A = h_A[:, None] * preamble_sig[None, :] + noise(NR_stage, preamble_len * M)
    rx_preamble_B = h_B[:, None] * preamble_sig[None, :] + noise(NR_stage, preamble_len * M)
    rx_payload_A  = h_A[:, None] * s_pay[None, :] + noise(NR_stage, M)
    rx_payload_B  = h_B[:, None] * s_pay[None, :] + noise(NR_stage, M)

    # ------------------------------------------------------------------ #
    # Training hierarchical                                               #
    # ------------------------------------------------------------------ #
    w_A = _train_weights(rx_preamble_A, M, preamble_len)
    w_B = _train_weights(rx_preamble_B, M, preamble_len)

    # Stage-1 combined outputs
    y_A = nonfft_combine(rx_payload_A, w_A)       # (M,)
    y_B = nonfft_combine(rx_payload_B, w_B)       # (M,)

    # Stage-2: train on the FULL combined preambles (preamble_len*M samples)
    y_preamble_A  = nonfft_combine(rx_preamble_A, w_A)   # (preamble_len*M,)
    y_preamble_B  = nonfft_combine(rx_preamble_B, w_B)   # (preamble_len*M,)
    rx2_preamble  = np.stack([y_preamble_A, y_preamble_B])  # (2, preamble_len*M)
    w2_train      = _train_weights(rx2_preamble, M, preamble_len=preamble_len)
    y_hier_train  = nonfft_combine(np.stack([y_A, y_B]), w2_train)
    b_rx_hier_train = demodulate(y_hier_train)

    # ------------------------------------------------------------------ #
    # Oracle hierarchical                                                 #
    # ------------------------------------------------------------------ #
    S_A = float(np.sum(np.abs(h_A) ** 2))
    S_B = float(np.sum(np.abs(h_B) ** 2))
    w_A_or = np.conj(h_A) / S_A
    w_B_or = np.conj(h_B) / S_B

    y_A_or = nonfft_combine(rx_payload_A, w_A_or)
    y_B_or = nonfft_combine(rx_payload_B, w_B_or)

    S_tot  = S_A + S_B
    w2_or  = np.array([S_A / S_tot, S_B / S_tot], dtype=complex)
    y_hier_oracle   = nonfft_combine(np.stack([y_A_or, y_B_or]), w2_or)
    b_rx_hier_oracle = demodulate(y_hier_oracle)

    return b_tx, b_rx_hier_train, b_rx_hier_oracle


def sweep_hierarchical(SF=7, N_packets=500, snr_range=None):
    if snr_range is None:
        snr_range = np.arange(-10, 8, 2, dtype=float)

    NR_stage = 4
    NR_total = 8

    ser_flat_oracle    = []
    ser_flat_train     = []
    ser_hier_oracle    = []
    ser_hier_train     = []

    for snr_db in snr_range:
        print(f"  Hierarchical SNR={snr_db:+.0f} dB", flush=True)
        N0 = 10 ** (-snr_db / 10)

        # Flat NR=8
        fo = ft = 0
        for _ in range(N_packets):
            b_tx, b_rx = simulate_packet(SF, NR_total, N0, "oracle")
            fo += (b_tx != b_rx)
            b_tx, b_rx = simulate_packet(SF, NR_total, N0, "training")
            ft += (b_tx != b_rx)
        ser_flat_oracle.append(fo / N_packets)
        ser_flat_train.append(ft / N_packets)

        # Hierarchical 2×4
        ho = ht = 0
        for _ in range(N_packets):
            b_tx, b_rx_ht, b_rx_ho = simulate_hierarchical(SF, N0, NR_stage)
            ho += (b_tx != b_rx_ho)
            ht += (b_tx != b_rx_ht)
        ser_hier_oracle.append(ho / N_packets)
        ser_hier_train.append(ht / N_packets)

    fig, ax = plt.subplots(figsize=(8, 5))
    ax.semilogy(snr_range, np.clip(ser_flat_oracle, 1e-4, 1),
                "o-",  color="tab:green",  label="Flat NR=8 oracle")
    ax.semilogy(snr_range, np.clip(ser_flat_train,  1e-4, 1),
                "o--", color="tab:blue",   label="Flat NR=8 training")
    ax.semilogy(snr_range, np.clip(ser_hier_oracle, 1e-4, 1),
                "s-",  color="tab:orange", label="Hierarchical 2×4 oracle")
    ax.semilogy(snr_range, np.clip(ser_hier_train,  1e-4, 1),
                "s--", color="tab:red",    label="Hierarchical 2×4 training")
    ax.set_xlabel("Per-antenna SNR (dB)")
    ax.set_ylabel("Symbol Error Rate")
    ax.set_title(f"Flat NR=8 vs Hierarchical 2×NR=4  SF={SF}")
    ax.legend(fontsize=9)
    ax.grid(True, which="both", ls="--", alpha=0.4)
    ax.set_ylim(5e-4, 1.05)
    outpath = "sim/plots/sweep_hierarchical.png"
    fig.savefig(outpath, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  → {outpath}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="MIMO MRC sweep simulations")
    parser.add_argument("--sweep", choices=["ber", "nr", "preamble", "shiftmrc",
                                             "doppler", "hierarchical", "all"],
                        default="all")
    parser.add_argument("-n", "--n-packets", type=int, default=500,
                        help="Monte Carlo trials per point (default 500)")
    args = parser.parse_args()

    os.makedirs("sim/plots", exist_ok=True)
    N = args.n_packets
    run = args.sweep

    if run in ("ber", "all"):
        print("\n[1/6] BER vs SNR sweep")
        sweep_ber(N_packets=N)

    if run in ("nr", "all"):
        print("\n[2/6] NR scaling sweep")
        sweep_nr(N_packets=N)

    if run in ("preamble", "all"):
        print("\n[3/6] Preamble length sweep")
        sweep_preamble(N_packets=N)

    if run in ("shiftmrc", "all"):
        print("\n[4/6] Shift-MRC sweep")
        sweep_shift_mrc(N_packets=N)

    if run in ("doppler", "all"):
        print("\n[5/6] Doppler sweep")
        sweep_doppler(N_packets=N)

    if run in ("hierarchical", "all"):
        print("\n[6/6] Hierarchical MRC sweep")
        sweep_hierarchical(N_packets=N)

    print("\nDone. Plots saved to sim/plots/sweep_*.png")


if __name__ == "__main__":
    main()
