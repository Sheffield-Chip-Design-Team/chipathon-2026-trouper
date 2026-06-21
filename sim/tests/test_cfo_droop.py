"""
test_cfo_droop.py — CIC passband droop vs carrier frequency offset

Compares two decimator operating points for 125 kHz BW LoRa:

  Natural rate (R=256): output at 125 kS/s, band edge = 62.5 kHz = Nyquist,
                        CIC-3 droop = -11.8 dB at band edge.

  2× oversample (R=128): output at 250 kS/s, band edge = 62.5 kHz = Nyquist/2,
                          CIC-3 droop = -2.74 dB, corrected to ~0 dB by 2-tap EQ.

A CFO of Δf shifts the entire chirp upward. At natural rate the top-end chirp
components (already attenuated -11.8 dB) are pushed toward/past the null.
At 2× oversample the chirp has BW/2 = 62.5 kHz of flat passband headroom before
any component reaches the droop zone.

Two measurements:
  1. Passband frequency response: tone sweep 0 → BW, all four modes.
  2. DFT peak amplitude vs CFO: LoRa symbol demodulation sensitivity.

Run standalone (saves plot):
    python -m sim.tests.test_cfo_droop

Run as pytest (assertions only, no plot):
    pytest sim/tests/test_cfo_droop.py
"""

import sys
import numpy as np
import pytest

from sim.models.decimator import SigmaDeltaDecimator, FS_ADC

BW = 125e3   # LoRa bandwidth under test
SF = 7
M  = 1 << SF  # 128 samples per symbol at natural output rate (BW sample rate)

# Four modes to compare
MODES = [
    dict(R=256, droop_eq=False, label='R=256 natural rate, no EQ',          color='tab:red',    ls='--'),
    dict(R=256, droop_eq=True,  label='R=256 natural rate + 2-tap EQ',      color='tab:orange', ls='-.'),
    dict(R=128, droop_eq=False, label='R=128 2× oversample, no EQ',         color='tab:blue',   ls='--'),
    dict(R=128, droop_eq=True,  label='R=128 2× oversample + EQ (tapeout)', color='tab:green',  ls='-'),
]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _cic_response_db(f_hz: float, R: int, stages: int = 3) -> float:
    """Analytical CIC-N passband response in dB relative to DC."""
    if abs(f_hz) < 1.0:
        return 0.0
    arg = np.pi * abs(f_hz) / FS_ADC
    H = abs(np.sin(arg * R) / (R * np.sin(arg))) ** stages
    return 20 * np.log10(max(H, 1e-12))


def _gen_chirp_32mhz(b: int, M: int, bw_hz: float = BW) -> np.ndarray:
    """
    LoRa CSS symbol b at 32 MHz sample rate.

    The chirp duration is always M/bw_hz seconds regardless of the CIC
    decimation ratio used downstream.  Total 32 MHz samples = M * R_nat
    where R_nat = FS_ADC / bw_hz (the natural-rate ratio for this BW).

    Phase matches exp(jπ(2bn + n²)/M) at natural output samples k = n/R_nat.
    """
    R_nat = int(round(FS_ADC / bw_hz))
    n = np.arange(M * R_nat)
    n_out = n / R_nat
    phi = np.pi * (2 * b * n_out + n_out ** 2) / M
    return np.exp(1j * phi)


def _apply_cfo(signal: np.ndarray, cfo_hz: float) -> np.ndarray:
    n = np.arange(len(signal))
    return signal * np.exp(1j * 2 * np.pi * cfo_hz * n / FS_ADC)


def _demod_peak(rx_out: np.ndarray, M_out: int) -> float:
    """
    DFT peak amplitude (argmax bin) after decimation.

    For 2× oversample (M_out = 2*M) the signal is downsampled by 2 before
    the standard M-point demodulator — this models what downstream firmware
    would do.

    We track the peak bin (not the transmitted bin) so integer-bin CFO shifts
    don't confound the measurement.  The amplitude at the peak bin is reduced
    when CIC droop introduces asymmetric amplitude modulation across the chirp.
    Returns amplitude normalised to 1.0 for ideal (flat passband, any integer
    CFO shift).
    """
    downsample = M_out // M
    rx = rx_out[::downsample][:M]

    n = np.arange(M)
    dechirped = rx * np.exp(-1j * np.pi * n ** 2 / M)
    spectrum = np.fft.fft(dechirped)
    return float(np.max(np.abs(spectrum))) / M


def measure_tone_amplitude(f_hz: float, dec: SigmaDeltaDecimator,
                           n_settle: int = 8) -> float:
    """
    Simulate a complex tone at f_hz through the decimator and measure
    steady-state output amplitude, normalised to the DC response.

    The tone amplitude is set to 0.5 to avoid int8 saturation with EQ boost.
    """
    R = dec.ratio
    N = R * (n_settle + 64)
    n = np.arange(N)
    tone = 0.5 * np.exp(1j * 2 * np.pi * f_hz * n / FS_ADC)
    out = dec.process(tone)
    amp_f = float(np.mean(np.abs(out[n_settle:])))

    # DC reference at same amplitude
    dc = 0.5 * np.ones(N, dtype=complex)
    out_dc = dec.process(dc)
    amp_dc = float(np.mean(np.abs(out_dc[n_settle:])))

    return amp_f / amp_dc if amp_dc > 0 else 0.0


# ---------------------------------------------------------------------------
# Sweep functions
# ---------------------------------------------------------------------------

def sweep_passband(mode: dict, n_freqs: int = 60) -> tuple[np.ndarray, np.ndarray]:
    """Sweep tone 0 → BW, return (freqs_hz, amplitude_db)."""
    dec = SigmaDeltaDecimator(ratio=mode['R'], droop_eq=mode['droop_eq'])
    # Sweep up to BW (= Nyquist of natural rate, = Nyquist/2 of 2× oversample)
    freqs = np.linspace(100.0, BW, n_freqs)
    amps_db = np.array([
        20 * np.log10(max(measure_tone_amplitude(f, dec), 1e-6))
        for f in freqs
    ])
    return freqs, amps_db


def sweep_cfo(mode: dict, n_cfo: int = 25, n_avg: int = 32,
              max_cfo_frac: float = 0.5) -> tuple[np.ndarray, np.ndarray]:
    """
    Sweep CFO 0 → max_cfo_frac × BW.

    Returns (cfo_hz, normalised_peak_amplitude).  Peak amplitude is the DFT
    bin amplitude at the transmitted symbol, averaged over n_avg random
    symbols, then normalised to the CFO=0 value of this mode.
    """
    rng = np.random.default_rng(7)
    dec = SigmaDeltaDecimator(ratio=mode['R'], droop_eq=mode['droop_eq'])
    R   = mode['R']

    # Always generate full-symbol chirp at 32 MHz (M * R_nat samples)
    R_nat = int(round(FS_ADC / BW))   # 256 for 125 kHz BW
    M_out = M * R_nat // R             # output samples per symbol: M for nat, 2M for 2×

    cfo_arr = np.linspace(0.0, max_cfo_frac * BW, n_cfo)
    peaks   = np.zeros(n_cfo)

    for i, cfo_hz in enumerate(cfo_arr):
        acc = 0.0
        for _ in range(n_avg):
            b = int(rng.integers(0, M))
            chirp = _gen_chirp_32mhz(b, M)
            chirp_cfo = _apply_cfo(chirp, cfo_hz)
            out = dec.process(chirp_cfo)
            acc += _demod_peak(out, M_out)
        peaks[i] = acc / n_avg

    # Normalise to CFO=0 so curves start at 1.0
    if peaks[0] > 0:
        peaks /= peaks[0]

    return cfo_arr, peaks


# ---------------------------------------------------------------------------
# pytest tests
# ---------------------------------------------------------------------------

def test_passband_flat_2x_oversample_eq():
    """2× oversample + EQ should be flat (>-1 dB) from 0 to 62.5 kHz."""
    mode = MODES[3]  # R=128, droop_eq=True
    freqs, amps_db = sweep_passband(mode, n_freqs=20)
    passband_mask = freqs <= BW / 2
    worst = float(np.min(amps_db[passband_mask]))
    assert worst > -1.0, (
        f"2× oversample + EQ passband droop {worst:.1f} dB at band edge, expected > -1 dB"
    )


def test_passband_droop_natural_rate():
    """Natural rate (R=256, no EQ) should have >8 dB droop at band edge."""
    mode = MODES[0]  # R=256, droop_eq=False
    freqs, amps_db = sweep_passband(mode, n_freqs=20)
    edge_idx = np.argmin(np.abs(freqs - BW / 2))
    droop_db = float(amps_db[edge_idx])
    assert droop_db < -8.0, (
        f"Natural-rate band-edge droop {droop_db:.1f} dB, expected < -8 dB"
    )


def test_cfo_tolerance_2x_better():
    """
    At CFO = 25% BW (= 31.25 kHz), 2× oversample + EQ DFT peak should be
    meaningfully higher than natural rate without EQ.
    """
    target_cfo_frac = 0.25
    _, peaks_nat  = sweep_cfo(MODES[0], n_cfo=5, n_avg=16, max_cfo_frac=target_cfo_frac)
    _, peaks_over = sweep_cfo(MODES[3], n_cfo=5, n_avg=16, max_cfo_frac=target_cfo_frac)

    # Peak at the highest CFO point
    nat_peak  = float(peaks_nat[-1])
    over_peak = float(peaks_over[-1])

    assert over_peak > nat_peak, (
        f"2× oversample peak {over_peak:.3f} not better than natural rate {nat_peak:.3f} "
        f"at CFO={target_cfo_frac*100:.0f}% BW"
    )


# ---------------------------------------------------------------------------
# Standalone: run sweeps and save plot
# ---------------------------------------------------------------------------

def _main():
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    from pathlib import Path

    print("Sweeping passband frequency response...")
    fig, axes = plt.subplots(1, 2, figsize=(13, 5))

    # --- Panel 1: passband frequency response ---
    ax = axes[0]
    for mode in MODES:
        freqs, amps_db = sweep_passband(mode, n_freqs=60)
        ax.plot(freqs / 1e3, amps_db, color=mode['color'], ls=mode['ls'],
                lw=1.8, label=mode['label'])

    # Analytical reference: CIC-3 at R=256 and R=128 (no EQ)
    f_ref = np.linspace(100, BW, 200)
    for R_ref, col in [(256, 'tab:red'), (128, 'tab:blue')]:
        cic_db = np.array([_cic_response_db(f, R_ref) for f in f_ref])
        ax.plot(f_ref / 1e3, cic_db, color=col, ls=':', lw=1, alpha=0.4,
                label=f'CIC-3 R={R_ref} theory')

    ax.axvline(BW / 2 / 1e3, color='k', ls=':', lw=0.8, alpha=0.5,
               label='Chirp band edge (62.5 kHz)')
    ax.set_xlabel('Frequency (kHz)')
    ax.set_ylabel('Response (dB)')
    ax.set_title('CIC passband response — 125 kHz BW')
    ax.set_ylim(-14, 2)
    ax.legend(fontsize=7)
    ax.grid(True, alpha=0.3)

    # --- Panel 2: DFT peak amplitude vs CFO ---
    ax = axes[1]
    print("Sweeping CFO impact on DFT peak...")
    for mode in MODES:
        cfo_arr, peaks = sweep_cfo(mode, n_cfo=25, n_avg=48, max_cfo_frac=0.5)
        ax.plot(cfo_arr / 1e3, 20 * np.log10(np.maximum(peaks, 1e-6)),
                color=mode['color'], ls=mode['ls'], lw=1.8, label=mode['label'])

    ax.axvline(BW * 0.25 / 1e3, color='k', ls=':', lw=0.8, alpha=0.5,
               label='SX1302 CFO spec (±25% BW)')
    ax.set_xlabel('CFO (kHz)')
    ax.set_ylabel('DFT peak degradation (dB, relative to CFO=0)')
    ax.set_title('Demodulated peak vs CFO — 125 kHz BW SF7')
    ax.legend(fontsize=7)
    ax.grid(True, alpha=0.3)

    fig.tight_layout()
    out = Path(__file__).parent.parent.parent / 'cfo_droop_comparison.png'
    fig.savefig(out, dpi=150)
    print(f"Plot saved to {out}")

    # Print summary table
    print("\nSummary — DFT peak degradation at CFO = 25% BW (31.25 kHz):")
    print(f"{'Mode':<45} {'Peak @ 25% BW':>14}")
    for mode in MODES:
        cfo_arr, peaks = sweep_cfo(mode, n_cfo=13, n_avg=64, max_cfo_frac=0.5)
        # Find value at 25% BW
        idx = np.argmin(np.abs(cfo_arr - 0.25 * BW))
        db = 20 * np.log10(max(peaks[idx], 1e-6))
        print(f"  {mode['label']:<43} {db:>+8.2f} dB")


if __name__ == '__main__':
    _main()
