"""Channel models: flat Rician/Rayleigh fading + AWGN.

Each antenna sees an independent unit-power complex coefficient, constant over
one packet. `K=0` reduces to Rayleigh fading. Optional random PLL phase offset
(uniform ±π) is folded into the coefficient before transmission — the preamble
FFT estimator absorbs it automatically.
"""

import numpy as np
from scipy.ndimage import shift


def iq_imbalance_coefficients(gain_db: float = 0.0, phase_deg: float = 0.0) -> tuple[complex, complex]:
    """Return widely-linear IQ-imbalance coefficients ``mu`` and ``nu``.

    The impaired complex baseband is modelled as::

        y = mu * x + nu * conj(x)

    where ``gain_db`` is the I/Q amplitude mismatch in dB and ``phase_deg`` is
    the quadrature phase error in degrees. Zero mismatch gives ``mu=1``,
    ``nu=0``.
    """
    gamma = 10 ** (gain_db / 20.0)
    phi = np.deg2rad(phase_deg)
    mu = 0.5 * (gamma * np.exp(-1j * phi / 2.0) + np.exp(1j * phi / 2.0))
    nu = 0.5 * (gamma * np.exp(-1j * phi / 2.0) - np.exp(1j * phi / 2.0))
    return complex(mu), complex(nu)



def apply_iq_imbalance(signal: np.ndarray, gain_db: float = 0.0, phase_deg: float = 0.0) -> np.ndarray:
    """Apply receiver IQ imbalance to a complex signal.

    This models branch-local analog I/Q mismatch as a widely-linear distortion.
    Use non-zero ``gain_db`` and/or ``phase_deg`` to inject image leakage.
    """
    if gain_db == 0.0 and phase_deg == 0.0:
        return signal
    mu, nu = iq_imbalance_coefficients(gain_db=gain_db, phase_deg=phase_deg)
    return mu * signal + nu * np.conj(signal)


def rician_coefficients(
    NR: int,
    K: float = 0.0,
    pll_phase_random: bool = True,
) -> np.ndarray:
    """Return NR independent unit-power complex fading coefficients.

    Parameters
    ----------
    NR : int
        Number of receive branches.
    K : float
        Linear Rician K-factor. `K=0` gives Rayleigh fading.
    pll_phase_random : bool
        Whether to fold an independent random phase offset into each branch.
    """
    if K < 0:
        raise ValueError("Rician K-factor must be non-negative")

    h_nlos = (np.random.randn(NR) + 1j * np.random.randn(NR)) / np.sqrt(2)
    h_los = np.ones(NR, dtype=np.complex128)
    h = np.sqrt(K / (K + 1.0)) * h_los + np.sqrt(1.0 / (K + 1.0)) * h_nlos

    if pll_phase_random:
        h = h * np.exp(1j * np.random.uniform(-np.pi, np.pi, NR))
    return h


def rayleigh_coefficients(NR: int, pll_phase_random: bool = True) -> np.ndarray:
    """Return NR independent unit-power Rayleigh fading coefficients."""
    return rician_coefficients(NR, K=0.0, pll_phase_random=pll_phase_random)


def apply_channel(signal: np.ndarray, h: complex, N0: float, 
                  n_off: float = 0, k_cfo: float = 0, M: int = 128) -> np.ndarray:
    """
    Apply fading, noise, timing offset, and CFO.

    Parameters
    ----------
    signal : np.ndarray
        Input signal.
    h : complex
        Channel coefficient.
    N0 : float
        Noise power.
    n_off : float
        Timing offset in samples.
    k_cfo : float
        CFO in bins (k_cfo = f_off * M / BW).
    M : int
        Samples per symbol (2^SF).
    """
    # Apply fading
    signal = h * signal

    # Apply Timing Offset (fractional)
    if n_off != 0:
        signal = shift(signal.real, n_off) + 1j * shift(signal.imag, n_off)

    # Apply CFO
    if k_cfo != 0:
        # Phase shift per sample: 2 * pi * f_off / fs.
        # Since fs = BW, phase shift per sample = 2 * pi * k_cfo / M.
        n = np.arange(len(signal))
        signal = signal * np.exp(1j * 2 * np.pi * k_cfo * n / M)

    # Add noise
    n_samples = len(signal)
    noise = np.sqrt(N0 / 2) * (np.random.randn(n_samples) + 1j * np.random.randn(n_samples))
    return signal + noise
