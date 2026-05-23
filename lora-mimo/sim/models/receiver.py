"""MRC receiver DSP chain.

This file contains two independent channel estimation paths:

NON-FFT PATH (current ASIC architecture)
-----------------------------------------
Uses the training accumulator — see training_accumulator.py.
  Stage 3 — SC preamble detection → sc_lock, timing_ref
  Stage 4 — Training accumulator: Z_j = Σ raw_j[n]·conj(chirp_ref[n mod M])
  Stage 5 — Weight computation from Z_j (MRC/EGC/SC/Bypass)
  Stage 6 — Complex combining: y[n] = Σ_j w_j · x_j[n]

FFT PATH (legacy reference — not used in current ASIC)
-------------------------------------------------------
Retained for comparison and historical reference. Uses FFT-based channel
estimation with RCTSL fractional CFO and coherent peak averaging.
See planning/DSP Flow.md for why the FFT path was replaced.
"""

import numpy as np
from .stages import energy_detector
from .fixed import quantize_q1_15
from .training_accumulator import (
    training_accumulate,
    compute_weights as compute_weights_nonfft,
)


# ---------------------------------------------------------------------------
# NON-FFT PATH — combining using training accumulator weights
# ---------------------------------------------------------------------------

def nonfft_combine(
    rx_payload: np.ndarray,
    w: np.ndarray,
) -> np.ndarray:
    """
    Complex sample-by-sample combining using weights from compute_weights_nonfft().

    y[n] = Σ_j  w_j · x_j[n]

    WeightGenerator emits already-conjugated MRC weights, matching the RTL
    multiply path in mrc_combiner.v. Do not conjugate them again here.

    Parameters
    ----------
    rx_payload : (NR, n_samples) complex array
    w          : (NR,) complex Q1.15 weights from compute_weights_nonfft()

    Returns
    -------
    y : (n_samples,) combined signal
    """
    return np.sum(w[:, None] * rx_payload, axis=0)




def _quantize_q15_int(w: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Return signed int16 Q1.15 real/imag components for complex weights."""
    wr = np.clip(np.round(w.real * (2**15)), -32768, 32767).astype(np.int64)
    wi = np.clip(np.round(w.imag * (2**15)), -32768, 32767).astype(np.int64)
    return wr, wi


def _as_int8_pair(x: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Round/saturate a complex payload to the RTL combiner's int8 inputs."""
    xi = np.clip(np.round(x.real), -128, 127).astype(np.int64)
    xq = np.clip(np.round(x.imag), -128, 127).astype(np.int64)
    return xi, xq


def _sat_int8(v: np.ndarray) -> np.ndarray:
    return np.clip(v, -128, 127).astype(np.int8)


def nonfft_combine_rtl_int8(
    rx_payload: np.ndarray,
    w: np.ndarray,
    post_gain_shift: int = 0,
    mode: str = "mrc",
    bypass_ant: int = 0,
) -> np.ndarray:
    """
    RTL-style int8 combiner model including COMB_POST_GAIN.

    The RTL path uses Q1.15 weights, int8 input samples, a fixed guard
    divide-by-2, then `post_gain_shift` bits of left-shift gain before int8
    saturation. MRC weights are already conjugated by weight generation.

    Parameters
    ----------
    rx_payload : (NR, n_samples) complex array, interpreted as int8 I/Q samples
    w : (NR,) complex Q1.15 weights
    post_gain_shift : 0..7, COMB_POST_GAIN[2:0]
    mode : "mrc" or "bypass"
    bypass_ant : branch used when mode="bypass"

    Returns
    -------
    y : (n_samples,) complex array with int8-valued I/Q components
    """
    if not (0 <= int(post_gain_shift) <= 7):
        raise ValueError("post_gain_shift must be in range 0..7")

    x_i, x_q = _as_int8_pair(rx_payload)

    if mode == "bypass":
        j = int(bypass_ant)
        return _sat_int8(x_i[j]).astype(float) + 1j * _sat_int8(x_q[j]).astype(float)
    if mode != "mrc":
        raise ValueError("mode must be 'mrc' or 'bypass'")

    w_re, w_im = _quantize_q15_int(w)
    acc_i = np.sum(w_re[:, None] * x_i - w_im[:, None] * x_q, axis=0)
    acc_q = np.sum(w_re[:, None] * x_q + w_im[:, None] * x_i, axis=0)

    shifted_i = (acc_i >> 1) << int(post_gain_shift)
    shifted_q = (acc_q >> 1) << int(post_gain_shift)
    return _sat_int8(shifted_i).astype(float) + 1j * _sat_int8(shifted_q).astype(float)


def choose_comb_post_gain(
    y: np.ndarray,
    target_peak: int = 90,
    max_shift: int = 7,
    saturation_margin: int = 120,
) -> int:
    """
    Conservative firmware/host policy for COMB_POST_GAIN.

    Choose the largest left shift that keeps the observed complex I/Q component
    peak at or below `target_peak`. If the observed output is already near
    saturation, return zero. This policy is intended for packet-to-packet tuning:
    start at zero, observe the combined int8 stream, then raise gain only when
    there is clear headroom.
    """
    peak = int(max(np.max(np.abs(np.real(y))), np.max(np.abs(np.imag(y))))) if y.size else 0
    if peak <= 0 or peak >= saturation_margin:
        return 0

    shift = 0
    while shift < int(max_shift) and (peak << (shift + 1)) <= int(target_peak):
        shift += 1
    return shift


# ---------------------------------------------------------------------------
# FFT PATH (legacy) — FFT-based channel estimation
# ---------------------------------------------------------------------------

def _cfo_frac_rctsl(rx_preamble: np.ndarray, M: int, N_sym: int) -> float:
    # FFT PATH (legacy)
    """
    Fractional CFO estimation using the RCTSL algorithm (Cui Yang et al.),
    with incoherent multi-antenna combining.

    All NR antennas share the same TCXO so the CFO ε is identical across all
    antennas — only the channel phase ∠h_j differs per antenna.  An incoherent
    sum P = Σ_j |D_j|² is used rather than coherent two-pass combining because:

    - At high SNR the (Σ|h_j|²) factor cancels out of the RCTSL formula entirely,
      giving the same sub-bin accuracy as coherent combining.
    - At low SNR, coherent two-pass introduces a correlated bias: the phase
      estimates φ_j = ∠D_j[k0] are derived from the same noisy data as the
      adjacent bins Y₁, Y₋₁, which distorts the (Y₁ − Y₋₁) ratio that RCTSL
      relies on.  The incoherent sum is bias-free.

    Mirrors gr-lora_sdr frame_sync_impl::estimate_CFO_frac() extended to NR antennas:
      - Concatenate N_sym dechirped preamble symbols (extended downchirp).
      - 2× zero-padded FFT, incoherent |·|² sum across all NR antennas.
      - RCTSL quadratic correction around the peak → ~1/20-bin accuracy.

    Returns cfo_frac in bins, range (−0.5, 0.5].
    """
    NR = rx_preamble.shape[0]
    L  = N_sym * M

    # Extended downchirp: periodic with period M across all N_sym symbols
    n_aug  = np.arange(L)
    dc_aug = np.exp(-1j * np.pi * (n_aug % M) ** 2 / M)

    # 2× zero-padded incoherent magnitude-squared sum across all antennas
    fft_len = 2 * L
    P = np.zeros(fft_len)
    for j in range(NR):
        dechirped = rx_preamble[j, :L] * dc_aug
        P += np.abs(np.fft.fft(dechirped, n=fft_len)) ** 2

    k0  = int(np.argmax(P))
    Y_1 = P[(k0 - 1) % fft_len]
    Y0  = P[k0]
    Y1  = P[(k0 + 1) % fft_len]

    # RCTSL quadratic correction — rectangular-window constants (Cui Yang Eq. 15)
    u     = 64 * M / 406.5506497
    v     = u * 2.4674
    denom = u * (Y1 + Y_1) + v * Y0
    wa    = (Y1 - Y_1) / denom if abs(denom) > 1e-12 else 0.0
    ka    = wa * M / np.pi

    # Normalise peak position back to single-symbol bins, wrap to (−0.5, 0.5]
    k_residual = ((k0 + ka) / (2.0 * N_sym)) % 1.0
    return k_residual - (1.0 if k_residual > 0.5 else 0.0)


def estimate_channel(rx_preamble: np.ndarray, M: int, N_sym: int,
                     eps_sub: float = None) -> np.ndarray:
    """
    [FFT PATH — legacy] Estimate per-antenna channel from N_sym preamble upchirps.

    Algorithm (gr-lora_sdr style)
    ------------------------------
    1. Estimate fractional CFO via RCTSL (Cui Yang et al.) unless eps_sub is
       supplied by the caller from an external estimator.
    2. Apply time-domain CFO correction: rx_corr[n] = rx[n] · exp(−j2π·ε·n/M).
    3. Incoherent peak search: sum |FFT(dechirp(rx_corr_j,s))| across all
       antennas j and symbols s → integer peak bin k_peak.
    4. Coherent average of D_j[k_peak] / M across N_sym symbols per antenna.
       No inter-symbol phase rotation needed — CFO already removed in step 2.

    Parameters
    ----------
    rx_preamble : (NR, N_sym * M) complex array
    M           : samples per symbol (2^SF)
    N_sym       : number of preamble symbols
    eps_sub     : fractional CFO in bins (−0.5, 0.5]; estimated via RCTSL if None

    Returns
    -------
    h_hat : (NR,) complex channel estimates
    """
    NR = rx_preamble.shape[0]
    L  = N_sym * M

    # Step 1: fractional CFO — RCTSL if not supplied
    if eps_sub is None:
        eps_sub = _cfo_frac_rctsl(rx_preamble, M, N_sym)

    # Step 2: time-domain CFO correction
    n_full  = np.arange(L)
    cfo_corr = np.exp(-1j * 2 * np.pi * eps_sub * n_full / M)
    rx_corr  = rx_preamble[:, :L] * cfo_corr[np.newaxis, :]

    # Step 3: incoherent peak search on CFO-corrected signal
    n   = np.arange(M)
    ref = np.exp(-1j * np.pi * n ** 2 / M)

    mag_sum = np.zeros(M)
    for j in range(NR):
        for s in range(N_sym):
            seg = rx_corr[j, s * M:(s + 1) * M]
            mag_sum += np.abs(np.fft.fft(seg * ref))
    peak_bin = int(np.argmax(mag_sum))

    # Step 4: coherent average of complex peak value per antenna
    h_hat = np.zeros(NR, dtype=complex)
    for j in range(NR):
        acc = 0j
        for s in range(N_sym):
            seg = rx_corr[j, s * M:(s + 1) * M]
            acc += np.fft.fft(seg * ref)[peak_bin]
        h_hat[j] = acc / (N_sym * M)

    return h_hat


# ---------------------------------------------------------------------------
# Stages 5a / 5c
# ---------------------------------------------------------------------------

def compute_weights(h_hat: np.ndarray, N0: float):
    """
    [FFT PATH — legacy] Return phase corrections φ and real combining coefficients c.

    N0-weighted denominator: denom = Σ_j (|H_j|² + N0)
    For the non-FFT path use compute_weights_nonfft() from training_accumulator.py
    which takes Z_j directly and does not require N0.

    Decomposed for the two-stage RTL path:
      phi_j = ∠H_j                        (Stage 5a — phase correction input)
      c_j   = |H_j| / denom               (Stage 5c — real MAC weight)

    phi is stored as a fraction of π (fits Q1.15 without clipping):
      phi_q15 = phi_rad / π  ∈ [−1, 1)

    Returns
    -------
    phi : (NR,) phase in radians (reconstructed from Q1.15 storage)
    c   : (NR,) real non-negative combining weights (Q1.15)
    """
    phi_rad = np.angle(h_hat)                          # Stage 5a, range [-π, π]
    mag     = np.abs(h_hat)

    # Spec denominator: Σ_k(|H_k|² + N0_k) — per-antenna N0, then summed
    denom = np.sum(mag ** 2) + len(h_hat) * N0        # Stage 5c

    c = mag / denom

    # phi stored as turns of π so Q1.15 spans the full [-π, π] range without clipping
    phi_q15 = quantize_q1_15(phi_rad / np.pi)         # Q1.15 in units of π
    c_q15   = quantize_q1_15(c)

    return phi_q15 * np.pi, c_q15                     # return phi back in radians


# ---------------------------------------------------------------------------
# Stage 5b + Stage 6 / 7
# ---------------------------------------------------------------------------

def mrc_combine(rx_payload: np.ndarray, phi: np.ndarray, c: np.ndarray) -> np.ndarray:
    """
    Phase-correct then coherently combine NR received sample streams.

    Parameters
    ----------
    rx_payload : (NR, n_samples) complex array
    phi        : (NR,) phase corrections
    c          : (NR,) real combining weights

    Returns
    -------
    y : (n_samples,) combined signal
    """
    x_prime = rx_payload * np.exp(-1j * phi)[:, None]   # Stage 5b
    return np.sum(c[:, None] * x_prime, axis=0)          # Stage 6

def almmse_combine(rx_payload: np.ndarray, W: np.ndarray) -> np.ndarray:
    """
    ALMMSE combining for NT=2.
    
    Parameters
    ----------
    rx_payload : (NR, n_samples) complex array
    W          : (2, NR) complex weight matrix

    Returns
    -------
    y : (2, n_samples) combined signal nodes
    """
    # Quantize W to Q1.15
    W_q = quantize_q1_15(W.real) + 1j * quantize_q1_15(W.imag)
    return W_q @ rx_payload


# ---------------------------------------------------------------------------
# Fixed-point helpers
# ---------------------------------------------------------------------------

def quantise(x: np.ndarray, bits: int) -> np.ndarray:
    """
    Saturating fixed-point quantisation with peak-normalised full scale.

    Models an AGC + ADC: the block peak sets full scale, then the signal is
    rounded to `bits` levels and the scale is restored.  This isolates
    quantisation noise from clipping so the wordwidth sweep reflects only
    the ADC resolution, not an under-range / over-range artefact.
    """
    if np.iscomplexobj(x):
        peak = np.max(np.abs(x))
        if peak == 0:
            return x
        levels = 2 ** (bits - 1) - 1
        x_n = x / peak
        re = np.clip(np.round(x_n.real * levels), -levels, levels) / levels
        im = np.clip(np.round(x_n.imag * levels), -levels, levels) / levels
        return (re + 1j * im) * peak
    peak = np.max(np.abs(x))
    if peak == 0:
        return x
    levels = 2 ** (bits - 1) - 1
    return np.clip(np.round(x / peak * levels), -levels, levels) / levels * peak
