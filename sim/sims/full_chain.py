#!/usr/bin/env python3
"""
Full DSP chain BER simulation.

End-to-end signal path at the hardware sample rates:

    TX (LoRa modulate, M samples/symbol at BW)
      └─> upsample R× to 32 MS/s
          └─> NR-antenna Rayleigh channel + AWGN at 32 MS/s
              └─> 1st-order ΣΔ ADC per antenna (I & Q independent)
                  └─> CIC^3 + 9-tap FIR compensation decimator → 8-bit
                      └─> Training accumulator (all-pairs cross-correlation)
                          └─> Weight generator (Q1.15 shadow weights)
                              └─> MRC combine (8-bit live weights)
                                  └─> LoRa demodulate

The 1st-order ΣΔ ADC models a real noise-shaping converter so that CIC^3 + FIR
actually recovers the input signal (a sign() comparator would not — it has no
noise shaping). This produces the correct front-end behaviour for OSR=R.

The "BB reference" curve runs the same all-pairs training accumulator and
weight generation on float baseband samples, so the gap between the two curves
quantifies what the 1-bit ΣΔ → CIC+FIR → 8-bit path costs in dB.

Run:
    cd /path/to/chipathon-2026/lora-mimo
    python3 -m sim.sims.full_chain                  # default sweep
    python3 -m sim.sims.full_chain -n 100 --ratio 64
    python3 -m sim.sims.full_chain --snr -10,-6,-2,2
"""

import argparse
import os
import sys
import time
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from sim.models.lora                 import modulate, demodulate
from sim.models.channel              import rayleigh_coefficients
from sim.models.decimator            import SigmaDeltaDecimator
from sim.models.training_accumulator import training_accumulate_allpairs
from sim.models.eigvec_fw            import compute_eigvec_fw
from sim.models.receiver             import (nonfft_combine,
                                             nonfft_combine_rtl_int8w,
                                             choose_comb_post_gain)


# ---------------------------------------------------------------------------
# 1st-order ΣΔ ADC — proper noise-shaping converter (I & Q independent)
# ---------------------------------------------------------------------------

def sigma_delta_adc(x: np.ndarray, e_re_init: float = 0.0,
                    e_im_init: float = 0.0) -> np.ndarray:
    """
    1st-order ΣΔ modulator. Input must be bounded: |x| < 1 for stability.
    Returns 1-bit complex output (±1 ± 1j).

    Update law (per channel):
        u[n] = x[n] + e[n-1]
        q[n] = sign(u[n])
        e[n] = u[n] - q[n]

    Noise transfer function NTF = 1 - z^-1 (1st-order high-pass).
    With OSR = R = 256 and CIC^3 lowpass, in-band SQNR ≈ 70 dB at full scale.
    """
    n = x.size
    out = np.empty(n, dtype=np.complex128)
    e_re = e_re_init
    e_im = e_im_init
    xr = x.real
    xi = x.imag
    for i in range(n):
        u = xr[i] + e_re
        q = 1.0 if u >= 0.0 else -1.0
        e_re = u - q
        qr = q
        u = xi[i] + e_im
        q = 1.0 if u >= 0.0 else -1.0
        e_im = u - q
        out[i] = complex(qr, q)
    return out


# ---------------------------------------------------------------------------
# Full chain — one packet
# ---------------------------------------------------------------------------

def simulate_full_chain(SF: int, NR: int, snr_db_bb: float, ratio: int,
                        preamble_len: int = 8,
                        agc_target: float = 0.4,
                        use_rtl_int8: bool = False) -> tuple[int, int]:
    """
    One packet through ΣΔ ADC → CIC+FIR decimator → MRC.

    SNR convention
    --------------
    snr_db_bb is per-antenna SNR at the baseband rate (signal power = 1,
    noise variance = N0_bb). AWGN at the 32 MS/s ADC input has variance
    R·N0_bb/2 per real dimension, so CIC averaging by R recovers N0_bb
    at the baseband output rate.

    Shared-gain AGC (oracle) sets a common pre-ADC scale factor g_agc so the
    worst-case antenna stays at amplitude ≈ agc_target, well below the
    1st-order ΣΔ stability limit (|x|<1). The same g_agc applies to signal
    and noise per antenna, so per-antenna SNR is preserved.
    """
    M    = 2 ** SF
    R    = ratio
    h    = rayleigh_coefficients(NR)

    # ---- TX: baseband-rate chirps -----------------------------------------
    chirp0    = modulate(0, M)                       # (M,)
    preamble  = np.tile(chirp0, preamble_len)        # (preamble_len*M,)
    b_tx      = np.random.randint(0, M)
    payload   = modulate(b_tx, M)                    # (M,)
    s_bb      = np.concatenate([preamble, payload])  # ((preamble_len+1)*M,)

    # ---- Upsample R× to 32 MS/s by repetition (SX1257 baseband sampling) --
    # Trailing pad absorbs CIC+FIR group delay so the payload window is intact.
    TAIL_PAD_BB = 16
    s_adc = np.concatenate([
        np.repeat(s_bb, R),
        np.zeros(TAIL_PAD_BB * R, dtype=np.complex128),
    ])
    N_adc = s_adc.size

    # ---- AWGN at ADC rate --------------------------------------------------
    N0_bb        = 10 ** (-snr_db_bb / 10)
    sigma_adc    = np.sqrt(N0_bb * R / 2.0)

    noise_adc    = sigma_adc * (np.random.randn(NR, N_adc) +
                                1j * np.random.randn(NR, N_adc))
    rx_pre_agc   = h[:, None] * s_adc[None, :] + noise_adc

    # ---- Oracle shared-gain AGC to keep |ΣΔ input| ≤ agc_target -----------
    peak = max(float(np.abs(rx_pre_agc).max()), 1e-6)
    g_agc = agc_target / peak
    rx_adc = g_agc * rx_pre_agc

    # ---- 1st-order ΣΔ ADC per antenna -------------------------------------
    rx_1bit  = np.stack([sigma_delta_adc(rx_adc[j]) for j in range(NR)])

    # ---- CIC^3 + 9-tap FIR decimator per antenna --------------------------
    decims   = [SigmaDeltaDecimator(ratio=R, output_bits=8) for _ in range(NR)]
    rx_bb    = np.stack([decims[j].process(rx_1bit[j]) for j in range(NR)])
    # rx_bb shape: (NR, (preamble_len+1)*M)

    # CIC^3 group delay ≈ 1.5 output samples; symmetric 9-tap FIR adds 4 samples.
    # Empirical: GD=5 aligns preamble/payload boundaries with s_bb.
    GD = 5
    # Scale to int8 integer range so WeightGenerator shift-normalisation and
    # _as_int8_pair both see the same integer-valued sample domain as the RTL.
    rx_bb_int = rx_bb * 128.0
    rx_preamble = rx_bb_int[:, GD : GD + preamble_len * M]
    rx_payload  = rx_bb_int[:, GD + preamble_len * M : GD + (preamble_len + 1) * M]

    # ---- Training accumulator over the full preamble ----------------------
    Z, _, n_acc_pre = training_accumulate_allpairs(rx_preamble, sc_lock_sample=0,
                                                   timing_ref=0, M=M,
                                                   preamble_len=preamble_len)

    # ---- Firmware eigenvector weights (chip-accurate RV32IM path) ---------
    w = compute_eigvec_fw(Z, n_acc_pre)

    # ---- MRC combine + demodulate -----------------------------------------
    if use_rtl_int8:
        # Tune COMB_POST_GAIN from preamble window (shift=0 → observe → choose)
        y_pre = nonfft_combine_rtl_int8w(rx_preamble, w, post_gain_shift=0)
        pg    = choose_comb_post_gain(y_pre)
        y     = nonfft_combine_rtl_int8w(rx_payload, w, post_gain_shift=pg)
    else:
        y = nonfft_combine(rx_payload, w)
    b_rx = demodulate(y)
    return b_tx, b_rx


# ---------------------------------------------------------------------------
# Baseband-equivalent reference (matches mimo_sweep "training" mode)
# ---------------------------------------------------------------------------

def simulate_bb_reference(SF: int, NR: int, snr_db: float,
                          preamble_len: int = 8) -> tuple[int, int]:
    """Float baseband reference — no ADC, no decimator, no Q1.15 saturation."""
    M  = 2 ** SF
    h  = rayleigh_coefficients(NR)
    N0 = 10 ** (-snr_db / 10)

    chirp0      = modulate(0, M)
    preamble    = np.tile(chirp0, preamble_len)
    noise       = lambda n: np.sqrt(N0 / 2) * (np.random.randn(NR, n) +
                                               1j * np.random.randn(NR, n))
    rx_preamble = h[:, None] * preamble[None, :] + noise(preamble_len * M)
    b_tx        = np.random.randint(0, M)
    rx_payload  = h[:, None] * modulate(b_tx, M)[None, :] + noise(M)

    Z, _, n_acc_pre = training_accumulate_allpairs(rx_preamble, sc_lock_sample=0,
                                                   timing_ref=0, M=M,
                                                   preamble_len=preamble_len)
    w  = compute_eigvec_fw(Z, n_acc_pre)
    y  = nonfft_combine(rx_payload, w)
    return b_tx, demodulate(y)


# ---------------------------------------------------------------------------
# Monte Carlo runner
# ---------------------------------------------------------------------------

def ser_full(SF, NR, snr_db, ratio, N_packets, preamble_len=8) -> float:
    errs = 0
    for _ in range(N_packets):
        b_tx, b_rx = simulate_full_chain(SF, NR, snr_db, ratio, preamble_len)
        errs += (b_tx != b_rx)
    return errs / N_packets


def ser_rtl(SF, NR, snr_db, ratio, N_packets, preamble_len=8) -> float:
    errs = 0
    for _ in range(N_packets):
        b_tx, b_rx = simulate_full_chain(SF, NR, snr_db, ratio, preamble_len,
                                         use_rtl_int8=True)
        errs += (b_tx != b_rx)
    return errs / N_packets


def ser_bb(SF, NR, snr_db, N_packets, preamble_len=8) -> float:
    errs = 0
    for _ in range(N_packets):
        b_tx, b_rx = simulate_bb_reference(SF, NR, snr_db, preamble_len)
        errs += (b_tx != b_rx)
    return errs / N_packets


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    p = argparse.ArgumentParser(description="Full DSP chain BER simulation")
    p.add_argument("--sf",     type=int,   default=7,    help="Spreading factor (default 7)")
    p.add_argument("--nr",     type=int,   default=4,    help="RX branches (default 4)")
    p.add_argument("--ratio",  type=int,   default=64,   help="CIC decimation ratio (default 64 = 500 kHz BW)")
    p.add_argument("--snr",    type=str,   default="",   help="Comma-separated SNR list in dB")
    p.add_argument("-n", "--n-packets", type=int, default=80,
                   help="Monte Carlo trials per SNR point (default 80)")
    p.add_argument("--out", type=str, default="sim/plots/full_chain_ber.png")
    args = p.parse_args()

    if args.snr:
        snr_list = [float(s) for s in args.snr.split(",")]
    else:
        snr_list = [-10.0, -6.0, -2.0, 2.0, 6.0]

    print(f"Full DSP chain BER simulation")
    print(f"  SF={args.sf}  NR={args.nr}  R={args.ratio}  N_packets={args.n_packets}")
    print(f"  SNR points: {snr_list} dB")
    print()

    os.makedirs(os.path.dirname(args.out), exist_ok=True)

    bb_ser   = []
    full_ser = []
    rtl_ser  = []
    t0 = time.time()
    for snr_db in snr_list:
        ts = time.time()
        b = ser_bb  (args.sf, args.nr, snr_db, args.n_packets)
        f = ser_full(args.sf, args.nr, snr_db, args.ratio, args.n_packets)
        r = ser_rtl (args.sf, args.nr, snr_db, args.ratio, args.n_packets)
        bb_ser.append(b)
        full_ser.append(f)
        rtl_ser.append(r)
        gap_db = (10 * np.log10(max(f, 1e-6) / max(b, 1e-6))) if b > 0 else float("nan")
        rtl_gap = (10 * np.log10(max(r, 1e-6) / max(b, 1e-6))) if b > 0 else float("nan")
        print(f"  SNR={snr_db:+6.1f} dB   BB_SER={b:.4f}   FULL_SER={f:.4f}   "
              f"RTL_INT8_SER={r:.4f}   gap={gap_db:+5.2f}/{rtl_gap:+5.2f} dB"
              f"    ({time.time()-ts:.1f}s)")

    print(f"\nTotal runtime: {time.time()-t0:.1f}s")

    fig, ax = plt.subplots(figsize=(8, 5))
    snr_arr = np.array(snr_list, dtype=float)
    ax.semilogy(snr_arr, np.clip(bb_ser,   1e-4, 1), "o-",
                color="tab:green", label="Baseband reference (float MRC)")
    ax.semilogy(snr_arr, np.clip(full_ser, 1e-4, 1), "s-",
                color="tab:blue",
                label=f"Full chain  (ΣΔ → CIC+FIR R={args.ratio} → 8-bit → Q1.15 MRC)")
    ax.semilogy(snr_arr, np.clip(rtl_ser,  1e-4, 1), "^--",
                color="tab:orange",
                label=f"RTL int8 combiner  (+ COMB_POST_GAIN tuning)")
    ax.set_xlabel("Per-antenna baseband SNR (dB)")
    ax.set_ylabel("Symbol Error Rate")
    ax.set_title(f"Full DSP Chain vs Baseband Reference  SF={args.sf}  NR={args.nr}")
    ax.grid(True, which="both", ls="--", alpha=0.4)
    ax.set_ylim(5e-4, 1.05)
    ax.legend(fontsize=9)
    fig.savefig(args.out, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"Plot saved: {args.out}")


if __name__ == "__main__":
    main()
