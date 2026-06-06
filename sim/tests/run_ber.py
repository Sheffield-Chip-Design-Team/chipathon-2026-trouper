"""BER vs SNR sweep for the NT=1, NR=4 MRC and NT=2 ALMMSE LoRa receiver.

Running modes
-------------
python -m sim.tests.run_ber              — float BER curves (single + 4-antenna)
python -m sim.tests.run_ber --fixedpoint — wordwidth sweep (4, 6, 8, 10, 12-bit)
python -m sim.tests.run_ber --pll-test   — confirm PLL phase offsets are absorbed

SNR axis convention
-------------------
x-axis : per-antenna average SNR γ = E[|h|²]·Ps / N0  (signal power Ps = 1)
         i.e.  SNR_dB = -10·log10(N0)

Eb/N0 conversion (printed in table):
         Eb/N0 = (M / SF) · γ    where M=2^SF
"""

import argparse
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from scipy.signal import butter, filtfilt

from sim.models.lora    import upchirp, modulate, demodulate
from sim.models.channel import rayleigh_coefficients, apply_channel
from sim.models.receiver import compute_weights, mrc_combine, almmse_combine, quantise
from sim.models.decimator import SigmaDeltaDecimator
from sim.models.converter import ADCModel, SigmaDeltaRemodulator


# ---------------------------------------------------------------------------
# Single-packet simulation
# ---------------------------------------------------------------------------

def simulate_packet(SF: int, NT: int, NR: int, N0: float,
                    pll_phase_random: bool = True,
                    sample_bits: int = 0,
                    decimation_ratio: int = 0) -> list[tuple[int, int]]:
    """
    Simulate one packet end-to-end.

    Returns
    -------
    list of (b_tx, b_rx) tuples — one per transmitted stream
    """
    M = 2 ** SF
    N_PREAMBLE = 8

    # H is (NR, NT) matrix
    h = np.array([rayleigh_coefficients(NT, pll_phase_random) for _ in range(NR)])

    # ... process payload ...
    symbols = np.random.randint(0, M, NT)
    s_payload = np.array([modulate(b, M) for b in symbols])
    rx_payload = h @ s_payload + np.sqrt(N0/2) * (np.random.randn(NR, M) + 1j * np.random.randn(NR, M))
    
    if sample_bits:
        rx_payload = quantise(rx_payload, sample_bits)

    if decimation_ratio:
        # Simplified: process payload through ADC -> Decimator
        adc = ADCModel()
        rx_payload = np.stack([adc.process(rx_payload[j]) for j in range(NR)])
        decimator = SigmaDeltaDecimator(ratio=decimation_ratio, output_bits=8)
        rx_payload = np.stack([decimator.process(rx_payload[j]) for j in range(NR)])

    # --- Stage 5b + 6: phase correction and MRC/ALMMSE combining ---------
    if NT == 1:
        # MRC logic
        h_hat = h[:, 0] 
        phi, c = compute_weights(h_hat, N0)
        y = mrc_combine(rx_payload, phi, c)
        y_list = [y]
    else:
        # ALMMSE logic
        W = h.conj().T @ np.linalg.inv(h @ h.conj().T + N0 * np.eye(NR))
        y = almmse_combine(rx_payload, W)
        y_list = [y[0], y[1]]

    # --- Stage 8: ΣΔ Re-modulator & Filtering ------------------------------
    results = []
    remod = SigmaDeltaRemodulator()
    b, a = butter(2, 0.2) # 2nd order Butterworth LPF
    for i, y_node in enumerate(y_list):
        y_bits = np.array([remod.process(sample) for sample in y_node])
        # Filter I and Q independently to preserve phase
        y_out_re = filtfilt(b, a, y_bits.real)
        y_out_im = filtfilt(b, a, y_bits.imag)
        y_out = y_out_re + 1j * y_out_im
        results.append((symbols[i], demodulate(y_out)))
    return results


# ---------------------------------------------------------------------------
# Fixed-point wordwidth sweep
# ---------------------------------------------------------------------------

def fixedpoint_sweep(snr_db: float = -5.0, NT: int = 1, N_packets: int = 1000) -> dict:
    N0 = 10 ** (-snr_db / 10)
    NR = 4
    SF = 7
    
    # Float reference
    n_err = n_bits = 0
    for _ in range(N_packets):
        results = simulate_packet(SF, NT, NR, N0)
        for b_tx, b_rx in results:
            n_err += bin(b_tx ^ b_rx).count('1')
            n_bits += SF
    ber_ref = n_err / n_bits
    
    print(f"\n--- Fixed-point wordwidth sweep at SNR={snr_db:+.1f} dB ---")
    print(f"  Float reference BER: {ber_ref:.4e}")

    for bits in [4, 5, 6, 7, 8, 10, 12]:
        n_err = n_bits = 0
        for _ in range(N_packets):
            results = simulate_packet(SF, NT, NR, N0, sample_bits=bits)
            for b_tx, b_rx in results:
                n_err += bin(b_tx ^ b_rx).count('1')
                n_bits += SF
        ber = n_err / n_bits
        degradation_db = 10 * np.log10(max(ber, 1e-9) / max(ber_ref, 1e-9))
        print(f"  {bits:2d}-bit  BER={ber:.4e}  degradation={degradation_db:+.2f} dB")

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--nt", type=int, default=1)
    parser.add_argument("--n-packets", type=int, default=500)
    parser.add_argument("--fixedpoint", action="store_true")
    args = parser.parse_args()

    if args.fixedpoint:
        fixedpoint_sweep(snr_db=-5.0, NT=args.nt, N_packets=args.n_packets)
        return

    SF = 7
    NR = 4
    snr_range = np.arange(-20, 5, 2, dtype=float)

    print(f"Simulating NT={args.nt}, NR={NR}, SF={SF}...")
    
    ber_list = []
    for snr_db in snr_range:
        N0 = 10 ** (-snr_db / 10)
        n_err = n_bits = 0
        for _ in range(args.n_packets):
            results = simulate_packet(SF, args.nt, NR, N0)
            for b_tx, b_rx in results:
                n_err += bin(b_tx ^ b_rx).count('1')
                n_bits += SF
        ber = n_err / n_bits
        ber_list.append(ber)
        print(f"  SNR={snr_db:+6.1f} dB  BER={ber:.4e}")

    # Plot...
    fig, ax = plt.subplots()
    ax.semilogy(snr_range, ber_list, "o-")
    ax.set_title(f"BER: NT={args.nt}, NR={NR}")
    ax.set_xlabel("SNR (dB)")
    ax.set_ylabel("BER")
    ax.grid(True, which="both", linestyle="--", alpha=0.5)
    outfile = f"sim/plots/ber_nt{args.nt}.png"
    fig.savefig(outfile)
    print(f"Saved {outfile}")


if __name__ == "__main__":
    main()
