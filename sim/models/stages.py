import numpy as np
from .fixed import quantize

def energy_detector(rx_signal: np.ndarray, input_bits: int = None, output_bits: int = 16) -> np.ndarray:
    """
    Energy Detector — Σ|x|² per antenna over the input window.

    Parameters
    ----------
    rx_signal   : (NR, N_samples) complex array of full-precision decimator samples
    input_bits  : quantize input to this width before squaring (None = no quantization).
                  Hardware input width is 12 or 16 bits (TBD — see ΣΔ Decimator spec).
                  AGC energy tap must use full-precision samples, not 8-bit SRAM samples.
    output_bits : accumulator output register width (default 16, saturated)

    Returns
    -------
    energy : (NR,) real energy (quantized to output_bits)
    """
    if input_bits is not None:
        re = quantize(rx_signal.real, input_bits, signed=True)
        im = quantize(rx_signal.imag, input_bits, signed=True)
    else:
        re = rx_signal.real
        im = rx_signal.imag

    energy = np.sum(re ** 2 + im ** 2, axis=1)
    return quantize(energy, output_bits, signed=False)
