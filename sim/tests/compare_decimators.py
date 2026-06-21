"""
compare_decimators.py — compare sd_decimator_cic_only vs sd_decimator_cic_tdm8.

Reads VVP stdout from tb_compare_decimators.vvp (piped via stdin or subprocess),
computes DFT amplitude at each test tone for both DUTs, and prints a comparison table.

Usage (from rtl-test/):
    vvp tb_compare_decimators.vvp | python3 ../sim/tests/compare_decimators.py

Or from repo root after SGE run:
    python3 -m sim.tests.compare_decimators <path/to/vvp_output.txt>
"""

import sys
import numpy as np

FS_OUT = 32e6 / 128   # 250 kHz — output sample rate for both DUTs
AMP_IN = 64           # sigma-delta input amplitude (same as testbench AMP)


def dft_amplitude(samples: list[float], freq_hz: float, fs: float) -> float:
    """One-sided DFT amplitude at freq_hz (no windowing; works for exact-bin tones)."""
    x = np.array(samples, dtype=float)
    n = len(x)
    k = np.arange(n)
    return 2 * abs(np.sum(x * np.exp(-2j * np.pi * freq_hz / fs * k))) / n


def parse_stream(lines: list[str]) -> dict:
    """Parse VVP stdout into {freq_hz: {'CIC': ([i], [q]), 'TDM': ([i], [q])}}."""
    data = {}
    current_freq = None

    for line in lines:
        line = line.strip()
        if not line or line == "# END":
            continue
        if line.startswith("# FREQ"):
            current_freq = int(line.split()[2])
            data[current_freq] = {"CIC": ([], []), "TDM": ([], [])}
        elif line.startswith("CIC,") and current_freq is not None:
            _, i, q = line.split(",")
            data[current_freq]["CIC"][0].append(int(i))
            data[current_freq]["CIC"][1].append(int(q))
        elif line.startswith("TDM,") and current_freq is not None:
            _, i, q = line.split(",")
            data[current_freq]["TDM"][0].append(int(i))
            data[current_freq]["TDM"][1].append(int(q))

    return data


def main():
    if len(sys.argv) > 1:
        with open(sys.argv[1]) as f:
            lines = f.readlines()
    else:
        lines = sys.stdin.readlines()

    data = parse_stream(lines)

    if not data:
        print("ERROR: no data parsed. Check VVP output.")
        sys.exit(1)

    print()
    print("CIC-3 droop equalizer — RTL comparison: sd_decimator_cic_only vs sd_decimator_cic_tdm8")
    print(f"{'Freq':>10}  {'DUT':>8}  {'|I| amp':>9}  {'I dB':>8}  {'Q amp':>9}  {'Q dB':>8}")
    print("-" * 62)

    for freq_hz in sorted(data.keys()):
        for dut in ("CIC", "TDM"):
            samples_i, samples_q = data[freq_hz][dut]
            if not samples_i:
                print(f"{freq_hz/1e3:>9.2f}k  {dut:>8}  NO DATA")
                continue

            amp_i = dft_amplitude(samples_i, freq_hz, FS_OUT)
            amp_q = dft_amplitude(samples_q, freq_hz, FS_OUT)

            # Normalise to input amplitude so 0 dB = perfect flat response
            ratio_i = amp_i / AMP_IN
            ratio_q = amp_q / AMP_IN
            db_i    = 20 * np.log10(ratio_i) if ratio_i > 0 else float("-inf")
            db_q    = 20 * np.log10(ratio_q) if ratio_q > 0 else float("-inf")

            tag = f"{freq_hz/1e3:.2f} kHz"
            print(f"{tag:>10}  {dut:>8}  {amp_i:>9.3f}  {db_i:>+8.2f} dB"
                  f"  {amp_q:>9.3f}  {db_q:>+8.2f} dB")

    print()
    print("Expected (CIC-3 R=128 + 2-tap EQ, theory):")
    expected = {31250: +0.27, 50000: +0.22, 62500: -0.13}
    for hz, db in expected.items():
        print(f"  {hz/1e3:.2f} kHz  I channel: {db:+.2f} dB (both DUTs should match)")
    print()


if __name__ == "__main__":
    main()
