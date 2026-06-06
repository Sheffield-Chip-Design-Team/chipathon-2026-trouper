"""LoRa CSS modulation and demodulation.

Symbol b ∈ {0, …, M-1} is a cyclic frequency shift of the base upchirp:
  s_b[n] = exp(j·π·(2·b·n + n²) / M)

Dechirp by multiplying with exp(-j·π·n²/M) yields a pure tone at bin b,
detected via FFT argmax.
"""

import numpy as np


def upchirp(M: int) -> np.ndarray:
    n = np.arange(M)
    return np.exp(1j * np.pi * n ** 2 / M)


def modulate(b: int, M: int) -> np.ndarray:
    n = np.arange(M)
    return np.exp(1j * np.pi * (2 * b * n + n ** 2) / M)


def demodulate(rx: np.ndarray) -> int:
    M = len(rx)
    n = np.arange(M)
    dechirped = rx * np.exp(-1j * np.pi * n ** 2 / M)
    return int(np.argmax(np.abs(np.fft.fft(dechirped))))
