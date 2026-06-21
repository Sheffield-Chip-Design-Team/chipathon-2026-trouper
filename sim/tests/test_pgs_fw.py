"""
Firmware integration test: COMB_POST_GAIN_SHIFT computation rule (Step 3).

Spec: planning/blocks/Eigenvector Weight Computation.md, Step 3.

The firmware reads ZDIAG_reg (uint16, = Z_kk >> 16) and N_ACC, then:
  1. Reconstructs E_max = (ZDIAG_reg << 16) / N_ACC  ≈ A^2
  2. A_est = isqrt(E_max)
  3. Selects pgs to target ~90 counts combined output
  4. Caps W_max_byte to prevent clipping after the pgs left-shift

All arithmetic below is integer-only, matching RV32IM firmware constraints.
"""
import math
import pytest


# ---------------------------------------------------------------------------
# Reference implementation of Step 3
# ---------------------------------------------------------------------------

def _compute_pgs_and_wmax(zdiag_reg, n_acc: int):
    """
    Python model of firmware Step 3.

    Parameters
    ----------
    zdiag_reg : iterable of 4 uint16 ZDIAG register values (= Z_kk >> 16)
    n_acc     : int, N_ACC accumulation count

    Returns
    -------
    (pgs, w_max_byte) : (int, int)
        pgs         — COMB_POST_GAIN_SHIFT, range 0..7
        w_max_byte  — weight scale cap, range 1..120
    """
    if n_acc == 0 or max(zdiag_reg) == 0:
        return 0, 120

    # Reconstruct mean squared amplitude (registers hold Z_kk >> 16)
    e_max = (max(zdiag_reg) << 16) // n_acc
    a_est = math.isqrt(e_max)

    if a_est == 0:
        return 0, 120

    # Pre-pgs output estimate using W_max_byte=120, NR=4
    y_pre_max = 120 * 4 * a_est // 256   # ≈ 1.875 × a_est

    if y_pre_max >= 90:
        pgs = 0
    else:
        # floor_log2(90 / y_pre_max) — integer version of the spec formula
        ratio = 90 // y_pre_max           # ≥ 1 since y_pre_max < 90
        pgs = max(0, min(7, ratio.bit_length() - 1))

    # Cap W_max_byte so that (w_max_byte × NR × A_est / 256) × 2^pgs ≤ 127
    # 8128 = 127 × 64 — derived from inversion of the clipping bound
    denom = a_est * (1 << pgs)
    w_max = min(120, 8128 // denom)

    return pgs, w_max


def _zdiag_reg_from_amp(a: int, n_acc: int):
    """Build a synthetic 4-element ZDIAG_reg list for 4 equal-amplitude branches."""
    z_kk = n_acc * a * a
    return [z_kk >> 16] * 4


# ---------------------------------------------------------------------------
# Guard / degenerate cases
# ---------------------------------------------------------------------------

def test_zero_n_acc():
    pgs, w_max = _compute_pgs_and_wmax([1000, 1000, 1000, 1000], n_acc=0)
    assert pgs == 0 and w_max == 120, "n_acc=0 must not divide; return safe defaults"


def test_zero_zdiag():
    pgs, w_max = _compute_pgs_and_wmax([0, 0, 0, 0], n_acc=512)
    assert pgs == 0 and w_max == 120, "all-zero ZDIAG must return safe defaults"


def test_mixed_branch_strengths_uses_max():
    """Only the strongest branch governs pgs; weaker branches are ignored."""
    # Strongest branch: A≈90 (n_acc=512, ZDIAG_reg=63) → pgs=0
    # Weak branches: ZDIAG_reg=0 → would give pgs=7 if max() were wrong
    zdiag_reg = [63, 0, 0, 0]
    pgs, _ = _compute_pgs_and_wmax(zdiag_reg, n_acc=512)
    assert pgs == 0, f"max branch should dominate; expected pgs=0, got pgs={pgs}"


# ---------------------------------------------------------------------------
# Signal-level scenarios
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("label,a_target,n_acc,expected_pgs", [
    ("strong A=90",   90,   512, 0),
    ("strong A=64",   64,   512, 0),
    ("moderate A=16", 16,   256, 1),
    ("weak-mod A=8",   8, 65536, 2),
    ("weak A=4",       4,  8192, 3),
])
def test_pgs_scenario(label, a_target, n_acc, expected_pgs):
    """Parametric table of (A_target, N_ACC) → expected pgs."""
    zdiag_reg = _zdiag_reg_from_amp(a_target, n_acc)
    pgs, _ = _compute_pgs_and_wmax(zdiag_reg, n_acc)
    a_est = math.isqrt((max(zdiag_reg) << 16) // n_acc)
    assert pgs == expected_pgs, (
        f"{label}: a_est={a_est}, expected pgs={expected_pgs}, got pgs={pgs}"
    )


def test_strong_signal_w_max_reduced():
    """For A_est ≈ 90 the combiner would clip at W_max=120; W_max_byte must drop below 120."""
    zdiag_reg = _zdiag_reg_from_amp(90, n_acc=512)
    _, w_max = _compute_pgs_and_wmax(zdiag_reg, n_acc=512)
    assert w_max < 120, f"strong signal: W_max_byte should be < 120, got {w_max}"


def test_weak_signal_w_max_stays_120():
    """For weak signals the weight scale must not be reduced."""
    zdiag_reg = _zdiag_reg_from_amp(4, n_acc=8192)
    _, w_max = _compute_pgs_and_wmax(zdiag_reg, n_acc=8192)
    assert w_max == 120, f"weak signal: expected W_max_byte=120, got {w_max}"


# ---------------------------------------------------------------------------
# No-clipping invariant: (w_max × NR × A_est / 256) << pgs ≤ 127
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("a_target,n_acc", [
    (90, 512),
    (64, 512),
    (50, 512),
    (32, 256),
    (16, 256),
    (8, 65536),
    (4, 8192),
])
def test_no_clipping_invariant(a_target, n_acc):
    """Combined output with returned pgs and W_max_byte must not exceed int8 max."""
    zdiag_reg = _zdiag_reg_from_amp(a_target, n_acc)
    pgs, w_max = _compute_pgs_and_wmax(zdiag_reg, n_acc)
    e_max = (max(zdiag_reg) << 16) // n_acc
    a_est = math.isqrt(e_max)
    if a_est == 0:
        return   # degenerate — no signal
    y_pre = w_max * 4 * a_est // 256
    y_out = y_pre << pgs
    assert y_out <= 127, (
        f"A={a_target}: clipping! y_out={y_out}>127 "
        f"(pgs={pgs}, w_max={w_max}, a_est={a_est})"
    )
