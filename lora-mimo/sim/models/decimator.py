import numpy as np
from scipy.signal import lfilter
from .fixed import quantize

FS_ADC = 32e6  # Hz — SX1257 CLK_OUT

# 9-tap symmetric CIC compensation FIR (Q1.14 coefficients, scale = 2^14 = 16384)
# Least-squares fit of 1/sinc^3(F) over F in [0, 0.45·fs_out]; valid for all R>=32
# Combined CIC+FIR passband ripple: 0.50 dB p-p
FIR_COEFFS = np.array([470, -1111, 2623, -7089, 26862, -7089, 2623, -1111, 470],
                      dtype=np.float64) / 16384.0

# 1× Nyquist decimation ratios for each LoRa BW.
# samples/symbol = 2^SF exactly at all BWs (integer M).
# Noise penalty = 0 dB vs theoretical minimum.
# CFO immunity provided by the cross-correlation training accumulator;
# residual decimator aliasing risk is negligible with a GPS TCXO (±434 Hz at 868 MHz).
RATIO_FOR_BW = {
    125e3: 256,
    250e3: 128,
    500e3:  64,
}
BW_FOR_RATIO = {ratio: bw for bw, ratio in RATIO_FOR_BW.items()}

# R=32 → 1 MS/s: 2× oversampled 500 kHz BW (decim_ratio=3).
# Not a 1× Nyquist mode — use for debug / wideband capture only.
RATIO_1MS = 32


def decimation_ratio(bw_hz: float) -> int:
    """
    Return the 1× Nyquist CIC decimation ratio for a given LoRa bandwidth.

    Parameters
    ----------
    bw_hz : LoRa signal bandwidth in Hz (125e3, 250e3, or 500e3)

    Returns
    -------
    R : int, power-of-2 decimation ratio
    """
    if bw_hz not in RATIO_FOR_BW:
        raise ValueError(f"bw_hz must be one of {list(RATIO_FOR_BW.keys())}")
    return RATIO_FOR_BW[bw_hz]


class SigmaDeltaDecimator:
    """
    CIC + FIR decimator model for the SX1257 sigma-delta bitstream.

    Implements 1× Nyquist decimation (samples/symbol = 2^SF, integer M for
    all spreading factors). See planning/blocks/ΣΔ Decimator.md for rationale.

    Typical usage
    -------------
    dec = SigmaDeltaDecimator(ratio=decimation_ratio(125e3))  # R=256, 125 kS/s
    dec = SigmaDeltaDecimator(ratio=decimation_ratio(250e3))  # R=128, 250 kS/s
    dec = SigmaDeltaDecimator(ratio=decimation_ratio(500e3))  # R=64,  500 kS/s
    """

    def __init__(self, ratio: int, output_bits: int = 8, stages: int = 3):
        """
        Parameters
        ----------
        ratio       : CIC decimation ratio (any positive integer)
        output_bits : Output word width in bits (default 8 for SRAM path)
        stages      : Number of CIC integrator/comb stages (default 3)
        """
        if ratio < 1:
            raise ValueError("ratio must be >= 1")
        self.ratio = ratio
        self.output_bits = output_bits
        self.stages = stages
        self.fs_out = FS_ADC / ratio

    @property
    def fs_out_khz(self) -> float:
        return self.fs_out / 1e3

    @property
    def nyquist_hz(self) -> float:
        return self.fs_out / 2

    def samples_per_symbol(self, sf: int, bw_hz: float | None = None) -> int:
        """
        Samples per LoRa symbol at this decimation ratio.

        For the supported 1× Nyquist modes, samples/symbol = 2^SF exactly.
        The R=32 debug mode is the 2× oversampled 500 kHz path, so it returns
        2 * 2^SF. Custom ratios must supply bw_hz explicitly.
        """
        if sf < 0:
            raise ValueError("sf must be >= 0")

        if bw_hz is None:
            if self.ratio == RATIO_1MS:
                bw_hz = 500e3
            else:
                bw_hz = BW_FOR_RATIO.get(self.ratio)

        if bw_hz is None or bw_hz <= 0:
            raise ValueError("bw_hz must be provided for custom decimation ratios")

        return int(round((self.fs_out / bw_hz) * (2 ** sf)))

    def process(self, rx_bitstream: np.ndarray) -> np.ndarray:
        """
        Decimate the input bitstream (32 MS/s) via CIC + FIR + normalisation.

        Parameters
        ----------
        rx_bitstream : (N,) complex array at FS_ADC sample rate

        Returns
        -------
        (N // ratio,) complex array at fs_out, quantised to output_bits
        """
        n_output = len(rx_bitstream) // self.ratio

        # CIC integrators (modelled via cumsum at input rate)
        acc = rx_bitstream.astype(np.complex128)
        for _ in range(self.stages):
            acc = np.cumsum(acc)

        # Downsample
        decimated = acc[self.ratio - 1 :: self.ratio][:n_output]

        # Comb stages at output rate: (1 - z^-1)^N cancels integrator drift,
        # leaving an N-fold cascaded moving-average response.
        for _ in range(self.stages):
            decimated = np.diff(decimated, prepend=0.0 + 0.0j)

        # Normalise: remove CIC gain R^N
        normalized = decimated / (self.ratio ** self.stages)

        # 9-tap FIR compensation filter (causal, matches RTL serialised MAC)
        re_fir = lfilter(FIR_COEFFS, 1.0, normalized.real)
        im_fir = lfilter(FIR_COEFFS, 1.0, normalized.imag)

        # Quantise to output_bits
        scale = 2 ** (self.output_bits - 1)
        re = quantize(re_fir * scale, self.output_bits) / scale
        im = quantize(im_fir * scale, self.output_bits) / scale

        return re + 1j * im
