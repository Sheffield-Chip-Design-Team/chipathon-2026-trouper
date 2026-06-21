"""
test_cic_alternatives.py — CIC passband-droop comparison for 250 kHz BW support

Historical motivation (this is why the design moved to a half-band chain):
CIC-only 250 kHz BW at natural rate (CIC-3 R=128) puts the chirp band edge at
Nyquist (125 kHz), giving ~-11.8 dB CIC droop. 2x oversample would need R=64,
which has unacceptable sigma-delta alias noise (SQNR ~9.6 dB, per
planning/cic-only-decimator-findings.md). Neither CIC-only option was
acceptable, and (as this test pins down) cascading does NOT fix the droop —
which is what motivated the fixed R=64 half-band chain now in the design
(`sd_decimator_poly`: CIC-3 R=16 → HB1 ÷2 → HB2 ÷2, droop ≈ -0.17 dB). This
test documents the CIC-only droop tradeoff that justified that migration.

Scope of this test — DROOP ONLY (analytical CIC magnitude response).
    SQNR / alias-noise cannot be predicted from a floating-point CIC model. The
    findings doc (section "Why the Python model was wrong") establishes that an
    ideal float CIC fed by a synthetic sigma-delta misses the real alias noise
    entirely and is therefore inadequate for SQNR claims at low oversampling
    ratios — RTL simulation with a real +/-1 sigma-delta stimulus is required.
    Earlier SQNR assertions here were removed for that reason.

Result this test pins down: cascading a CIC into two stages of the SAME total
ratio and order does NOT reduce passband droop. Droop is set by the total
decimation ratio and order; a cascade's only benefit is alias rejection. An
earlier version appeared to show a cascade droop reduction, but that was an
artifact of evaluating the second stage at the full ADC rate instead of its
true (already-decimated) input rate.

Run:
    pytest sim/tests/test_cic_alternatives.py -v
    python -m sim.tests.test_cic_alternatives
"""

import numpy as np
from pytest import approx

FS_ADC = 32e6   # Hz — SX1257 1-bit output rate (input to the first CIC stage)


def passband_droop_db(ratio: int, stages: int, f_hz: float,
                      fs_in: float = FS_ADC) -> float:
    """
    Analytical CIC-N passband droop at f_hz relative to DC.

    fs_in is the CIC's INPUT sample rate. For a cascaded design the second
    stage must be evaluated at its own input rate (FS_ADC / ratio1), not the
    raw ADC rate — getting this wrong is what produced the bogus "cascade
    reduces droop" result in the earlier revision of this file.
    """
    arg_top = np.pi * f_hz * ratio / fs_in
    arg_bot = np.pi * f_hz / fs_in
    H = abs(np.sin(arg_top) / (ratio * np.sin(arg_bot))) ** stages
    return 20.0 * np.log10(max(H, 1e-12))


def cascade_droop_db(splits, stages: int, f_hz: float) -> float:
    """
    Total droop of a multi-stage CIC cascade at f_hz. Each stage sees its
    input rate reduced by the product of all preceding decimation ratios.
    `splits` is the list of per-stage decimation ratios.
    """
    total = 0.0
    fs_in = FS_ADC
    for r in splits:
        total += passband_droop_db(r, stages, f_hz, fs_in)
        fs_in /= r
    return total


# ---------------------------------------------------------------------------
# Design-relevant droop facts (analytical, exact)
# ---------------------------------------------------------------------------

# Natural-rate 250 kHz BW: R=128, chirp band edge lands at full Nyquist 125 kHz.
DROOP_R128_NATURAL = passband_droop_db(128, 3, 125e3)
# 2x-oversample band edge for R=64 (fs_out = 500 kHz): 125 kHz.
DROOP_R64_2X = passband_droop_db(64, 3, 125e3)

# Cascades that split a total ratio of 64, evaluated at the same 125 kHz edge.
CASCADES = {
    "R=4x16": [4, 16],
    "R=8x8":  [8, 8],
    "R=2x32": [2, 32],
}


def test_r128_natural_droop_matches_spec():
    """CIC-3 R=128 at natural-rate 250 kHz band edge (125 kHz) ~ -11.8 dB.

    This is the documented droop limitation (see CLAUDE.md / findings doc).
    """
    assert DROOP_R128_NATURAL == \
        approx(-11.8, abs=0.2), \
        f"R=128 natural droop = {DROOP_R128_NATURAL:.2f} dB, expected ~-11.8 dB"


def test_r64_2x_droop():
    """CIC-3 R=64 2x-oversample band edge (125 kHz) ~ -2.74 dB — far milder
    than R=128 natural rate, but R=64 is ruled out by alias noise (see doc)."""
    assert DROOP_R64_2X == approx(-2.74, abs=0.05), \
        f"R=64 2x droop = {DROOP_R64_2X:.2f} dB, expected ~-2.74 dB"


def test_cascade_does_not_reduce_droop():
    """Cascading R=64 into two CIC-3 stages does NOT improve passband droop:
    total droop equals the single-stage CIC-3 R=64 droop within rounding.

    Pins the corrected conclusion against the earlier per-stage-rate bug that
    made cascades look ~2.5 dB better than they are."""
    for label, splits in CASCADES.items():
        d = cascade_droop_db(splits, 3, 125e3)
        assert d == approx(DROOP_R64_2X, abs=0.05), (
            f"Cascade {label} droop = {d:.2f} dB; should match single-stage "
            f"R=64 ({DROOP_R64_2X:.2f} dB) — cascading does not reduce droop")


# ---------------------------------------------------------------------------
# Standalone: print droop comparison table
# ---------------------------------------------------------------------------

def _main():
    print("\nCIC passband-droop comparison (analytical, at 125 kHz band edge)\n")
    print(f"{'Architecture':<28} {'Droop @125 kHz':>14}")
    print("-" * 44)
    print(f"{'CIC-3 R=128 (250kHz natural)':<28} {DROOP_R128_NATURAL:>12.2f} dB")
    print(f"{'CIC-3 R=64  (2x OVS)':<28} {DROOP_R64_2X:>12.2f} dB")
    for label, splits in CASCADES.items():
        d = cascade_droop_db(splits, 3, 125e3)
        print(f"{'Cascade CIC-3 ' + label:<28} {d:>12.2f} dB")
    print("\nNote: cascade droop == single-stage droop of the same total ratio.")
    print("Cascades help ALIAS REJECTION, not passband droop. SQNR/alias claims")
    print("require RTL simulation (see planning/cic-only-decimator-findings.md).")


if __name__ == "__main__":
    _main()
