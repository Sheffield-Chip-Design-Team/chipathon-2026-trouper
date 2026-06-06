"""MRC combining test using the real LoRa capture as signal source.

The chip-rate signal from 1_packet_mingain.iq provides a realistic transmitted
waveform.  NR independent receive paths are synthesised by multiplying the
signal with independent Rayleigh fading coefficients and adding AWGN on each,
modelling a multi-antenna receiver in a scattering environment.

DSP chain per trial
-------------------
1. Synthetic channel: rx_j[n] = h_j · s[n] + w_j[n]  (j = 0 … NR-1)
   s[n] = CFO-corrected chip-rate signal from capture
   h_j  ~ CN(0,1) independent Rayleigh coefficient per antenna
   w_j  ~ CN(0,N0) AWGN, independent per antenna
2. Training accumulator:  Z_j = Σ rx_j[n] · conj(rx_0[n])  (cross-correlation)
   using the known preamble window — isolates combining from sync errors
3. Weight computation:  MRC weights from Z_j via WeightGenerator (hardware model)
4. nonfft_combine: y[n] = Σ_j w_j · rx_j[n]
5. Dechirp → FFT → argmax per payload symbol
6. SER vs truth symbols (decoded from original capture at native SNR)

Comparison modes
----------------
NR=1 (single antenna, no combining) vs NR=2 vs NR=4.

Usage
-----
python3 -m sim.tests.test_mrc_capture
python3 -m sim.tests.test_mrc_capture --nr 1 2 4 --trials 50
"""

import argparse
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

from sim.models.channel              import rayleigh_coefficients
from sim.models.receiver             import nonfft_combine
from sim.models.training_accumulator import training_accumulate, compute_weights
from sim.models.lora                 import demodulate
from sim.tests.decode_capture        import (
    load_iq, decimate_to_chiprate,
    sc_metric, find_packet_onsets,
    estimate_cfo, apply_cfo,
    N_PREAMBLE, N_SYNC_SKIP,
)

CAPTURE  = "sim/examples/1_packet_mingain.iq"
FS_FILE  = 1e6
BW       = 125e3
SF       = 7
M        = 2 ** SF   # 128


# ---------------------------------------------------------------------------
# One-time load
# ---------------------------------------------------------------------------

def load_reference() -> tuple[np.ndarray, int, list[int], float]:
    """Load, decimate, CFO-correct; return chip-rate signal, onset, truth symbols."""
    iq_chip  = decimate_to_chiprate(load_iq(CAPTURE), FS_FILE, BW)
    metric   = sc_metric(iq_chip, M)
    onset    = find_packet_onsets(metric, M, threshold=0.85)[0]
    cfo      = estimate_cfo(iq_chip, onset, M)
    iq_ref   = apply_cfo(iq_chip, cfo, M)

    # Truth symbols: decode original capture directly (no synthetic degradation)
    pay_s  = onset + (N_PREAMBLE + N_SYNC_SKIP) * M
    n_sym  = (len(iq_ref) - pay_s) // M
    ref    = np.exp(-1j * np.pi * np.arange(M) ** 2 / M)
    truth  = [demodulate(iq_ref[pay_s + k*M : pay_s + (k+1)*M]) for k in range(n_sym)]

    # Signal power over the packet region
    sig_power = float(np.mean(np.abs(iq_ref[onset:pay_s + n_sym*M]) ** 2))

    return iq_ref, onset, truth, sig_power


# ---------------------------------------------------------------------------
# Single trial
# ---------------------------------------------------------------------------

def run_trial(iq_ref: np.ndarray, onset: int, truth: list[int],
              NR: int, N0: float) -> dict:
    """Apply Rayleigh + AWGN on NR branches, run MRC, return SER.

    The known onset is used directly so that timing jitter from SC re-detection
    does not corrupt the payload alignment.  This isolates MRC combining
    performance from the sync sub-system.

    Returns
    -------
    dict with keys: ser_mrc, ser_single (per antenna), h_mag (|h_j|)
    """
    N = len(iq_ref)
    h = rayleigh_coefficients(NR)              # (NR,) complex, E[|h|²]=1

    noise = (np.sqrt(N0 / 2)
             * (np.random.randn(NR, N) + 1j * np.random.randn(NR, N))
             ).astype(np.complex64)
    rx_j = (h[:, None] * iq_ref[np.newaxis, :]).astype(np.complex64) + noise

    # Training accumulator over the known 8-symbol preamble window
    Z_j, _, E_ref = training_accumulate(rx_j, onset, onset, M, ref_sel=0)
    w = compute_weights(Z_j, mode='mrc', sf=SF, E_ref=E_ref)

    # Payload decode
    pay_s = onset + (N_PREAMBLE + N_SYNC_SKIP) * M
    n_sym = min(len(truth), (N - pay_s) // M)
    if n_sym <= 0:
        return dict(ser_mrc=1.0, ser_single=[1.0]*NR, h_mag=np.abs(h))

    payload = rx_j[:, pay_s : pay_s + n_sym * M]  # (NR, n_sym*M)

    # MRC combined decode
    mrc_syms = [
        demodulate(nonfft_combine(payload[:, k*M:(k+1)*M], w))
        for k in range(n_sym)
    ]

    # Per-antenna single decode
    single_syms = [
        [demodulate(rx_j[j, pay_s + k*M : pay_s + (k+1)*M]) for k in range(n_sym)]
        for j in range(NR)
    ]

    t = truth[:n_sym]

    def ser(syms):
        return sum(a != b for a, b in zip(syms, t)) / len(t)

    return dict(
        ser_mrc    = ser(mrc_syms),
        ser_single = [ser(s) for s in single_syms],
        h_mag      = np.abs(h),
    )


# ---------------------------------------------------------------------------
# SNR sweep
# ---------------------------------------------------------------------------

def snr_sweep(nr_list=(1, 2, 4), snr_db_range=(-5, 25),
              n_snr=13, n_trials=50) -> dict:
    """Monte Carlo SER vs per-antenna SNR for each NR.

    SNR = E[|h|²] · Ps / N0 = Ps / N0   (unit-mean Rayleigh, so E[|h|²]=1).
    """
    print("Loading capture ...")
    iq_ref, onset, truth, sig_power = load_reference()
    print(f"  Onset={onset}  payload symbols={len(truth)}"
          f"  signal power={sig_power:.5f}\n")

    snr_db_vals = np.linspace(*snr_db_range, n_snr)
    # Store mean SER per (NR, SNR) for MRC and single-best antenna
    curves_mrc    = {nr: [] for nr in nr_list}
    curves_single = {nr: [] for nr in nr_list}

    for snr_db in snr_db_vals:
        N0 = sig_power / (10 ** (snr_db / 10))
        row = [f"SNR={snr_db:+6.1f} dB"]

        for NR in nr_list:
            ser_mrc_acc    = []
            ser_single_acc = []
            for _ in range(n_trials):
                r = run_trial(iq_ref, onset, truth, NR, N0)
                ser_mrc_acc.append(r['ser_mrc'])
                # best single antenna across all NR branches this trial
                ser_single_acc.append(min(r['ser_single']))

            m_mrc = float(np.mean(ser_mrc_acc))
            m_s   = float(np.mean(ser_single_acc))
            curves_mrc[NR].append(m_mrc)
            curves_single[NR].append(m_s)
            row.append(f"NR={NR}: MRC={m_mrc:.3f} best-1={m_s:.3f}")

        print("  " + "  |  ".join(row))

    return dict(
        snr_db        = snr_db_vals,
        curves_mrc    = curves_mrc,
        curves_single = curves_single,
        truth         = truth,
        nr_list       = nr_list,
    )


# ---------------------------------------------------------------------------
# Plot
# ---------------------------------------------------------------------------

def plot_results(data: dict, save_path: str = "sim/plots/mrc_capture.png"):
    colours = ['#1f77b4', '#ff7f0e', '#2ca02c', '#d62728']
    fig, ax = plt.subplots(figsize=(8, 5))

    for i, NR in enumerate(data['nr_list']):
        c   = colours[i % len(colours)]
        mrc = np.clip(data['curves_mrc'][NR],    1e-3, 1)
        s1  = np.clip(data['curves_single'][NR], 1e-3, 1)
        ax.semilogy(data['snr_db'], mrc, color=c, lw=2,
                    label=f"NR={NR} MRC")
        ax.semilogy(data['snr_db'], s1, color=c, lw=1, ls='--', alpha=0.6,
                    label=f"NR={NR} best single ant")

    ax.set_xlabel("Per-antenna SNR (dB)  [E[|h|²]·Ps/N0, Rayleigh fading]")
    ax.set_ylabel("Symbol Error Rate")
    ax.set_title(
        f"MRC gain — real LoRa capture + synthetic Rayleigh + AWGN\n"
        f"SF={SF}, BW={BW/1e3:.0f} kHz, M={M}, {len(data['truth'])} payload symbols"
    )
    ax.legend(ncol=2, fontsize=9)
    ax.grid(True, which='both', ls=':')
    ax.set_ylim(5e-4, 1.1)
    fig.tight_layout()
    fig.savefig(save_path, dpi=150)
    print(f"\nPlot saved to {save_path}")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    p = argparse.ArgumentParser(
        description="MRC test: real LoRa capture + synthetic Rayleigh + AWGN."
    )
    p.add_argument("--nr",      type=int, nargs="+", default=[1, 2, 4])
    p.add_argument("--trials",  type=int, default=50)
    p.add_argument("--snr-min", type=float, default=-5.0)
    p.add_argument("--snr-max", type=float, default=25.0)
    p.add_argument("--n-snr",   type=int,   default=13)
    p.add_argument("--plot",    type=str,
                   default="sim/plots/mrc_capture.png")
    args = p.parse_args()

    data = snr_sweep(
        nr_list      = args.nr,
        snr_db_range = (args.snr_min, args.snr_max),
        n_snr        = args.n_snr,
        n_trials     = args.trials,
    )
    plot_results(data, save_path=args.plot)


if __name__ == "__main__":
    main()
