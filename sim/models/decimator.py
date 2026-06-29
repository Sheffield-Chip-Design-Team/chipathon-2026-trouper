import numpy as np

FS_ADC = 32e6  # Hz, SX1257 CLK_OUT / 1-bit sigma-delta stream rate
FS_OUT = 500e3  # Hz, active Trouper internal IQ sample rate
DECIMATION_RATIO = 64

SUPPORTED_BW = (125e3, 250e3)
SAMPLE_SHIFT_FOR_BW = {
    250e3: 1,
    125e3: 2,
}


def decimation_ratio(bw_hz: float | None = None) -> int:
    """
    Return the active Trouper decimation ratio.

    The current RTL uses a fixed R=64 half-band chain for all supported LoRa
    bandwidths. `bw_hz` is accepted for compatibility and validation only;
    bandwidth selection changes `sample_shift`, not the decimator ratio.
    """
    if bw_hz is not None and bw_hz not in SAMPLE_SHIFT_FOR_BW:
        raise ValueError(f"bw_hz must be one of {list(SAMPLE_SHIFT_FOR_BW.keys())}")
    return DECIMATION_RATIO


def sample_shift_for_bw(bw_hz: float) -> int:
    """Return the RTL `sample_shift` value selected by BW_CFG.bw_sel."""
    if bw_hz not in SAMPLE_SHIFT_FOR_BW:
        raise ValueError(f"bw_hz must be one of {list(SAMPLE_SHIFT_FOR_BW.keys())}")
    return SAMPLE_SHIFT_FOR_BW[bw_hz]


def _cic_r16_int8(bits: np.ndarray) -> np.ndarray:
    """
    CIC-3 R=16 front end from `sd_decimator_hb_poly.v`.

    The RTL maps input bit 1 -> +1 and bit 0 -> -1, then computes a CIC-3
    output `(comb3 + 16) >>> 5`, saturated to int8.
    """
    bit = np.where(np.asarray(bits).real >= 0.0, 1, -1).astype(np.int64)
    n_out = len(bit) // 16
    if n_out == 0:
        return np.zeros(0, dtype=np.int64)

    int1 = int2 = int3 = 0
    comb1_z = comb2_z = comb3_z = 0
    out = np.empty(n_out, dtype=np.int64)
    oi = 0

    for n, b in enumerate(bit[: n_out * 16]):
        int1 += int(b)
        int2 += int1
        int3 += int2
        if (n & 15) == 15:
            comb1 = int3 - comb1_z
            comb2 = comb1 - comb2_z
            comb3 = comb2 - comb3_z
            comb1_z = int3
            comb2_z = comb1
            comb3_z = comb2
            out[oi] = int(np.clip((comb3 + 16) >> 5, -128, 127))
            oi += 1

    return out


def _hb1(x: np.ndarray) -> np.ndarray:
    """
    Integer direct-form equivalent of the first RTL half-band stage.

    Coefficients match `sd_decimator_hb_poly.v`:
      [19, 0, -73, 0, 312, 512, 312, 0, -73, 0, 19] / 1024
    evaluated every other CIC output sample.
    """
    coeff = np.array([19, 0, -73, 0, 312, 512, 312, 0, -73, 0, 19], dtype=np.int64)
    delay = np.zeros(len(coeff), dtype=np.int64)
    out = []
    for n, sample in enumerate(x.astype(np.int64)):
        delay[1:] = delay[:-1]
        delay[0] = sample
        if n & 1:
            acc = int(np.dot(coeff, delay))
            out.append(int(np.clip((acc + 512) >> 10, -128, 127)))
    return np.array(out, dtype=np.int64)


def _hb2(x: np.ndarray) -> np.ndarray:
    """
    Integer direct-form equivalent of the second RTL half-band stage.

    Coefficients match `sd_decimator_hb_poly.v`:
      [-27, 0, 45, 0, -96, 0, 321, 512, 321, 0, -96, 0, 45, 0, -27] / 1024
    evaluated every other HB1 output sample.
    """
    coeff = np.array(
        [-27, 0, 45, 0, -96, 0, 321, 512, 321, 0, -96, 0, 45, 0, -27],
        dtype=np.int64,
    )
    delay = np.zeros(len(coeff), dtype=np.int64)
    out = []
    for n, sample in enumerate(x.astype(np.int64)):
        delay[1:] = delay[:-1]
        delay[0] = sample
        if n & 1:
            acc = int(np.dot(coeff, delay))
            out.append(int(np.clip((acc + 512) >> 10, -128, 127)))
    return np.array(out, dtype=np.int64)


class SigmaDeltaDecimator:
    """
    Active Trouper sigma-delta decimator model.

    Mirrors the current RTL architecture:
      CIC-3 R=16 -> half-band /2 -> half-band /2 -> int8 complex samples

    The output sample rate is fixed at 500 kS/s. LoRa bandwidth selection is
    represented by `bw_hz`/`sample_shift` and affects symbol-domain windows
    (`M = 1 << (SF + sample_shift)`), not the decimation ratio.
    """

    def __init__(
        self,
        ratio: int | None = None,
        output_bits: int = 8,
        bw_hz: float = 250e3,
        sample_shift: int | None = None,
        **legacy_kwargs,
    ):
        if legacy_kwargs:
            names = ", ".join(sorted(legacy_kwargs))
            raise TypeError(f"stale CIC-only decimator options are unsupported: {names}")
        if ratio is not None and ratio != DECIMATION_RATIO:
            raise ValueError("current Trouper RTL uses fixed decimation ratio R=64")
        if output_bits != 8:
            raise ValueError("current Trouper RTL decimator output is fixed int8")

        self.ratio = DECIMATION_RATIO
        self.output_bits = 8
        self.bw_hz = bw_hz
        self.sample_shift = sample_shift_for_bw(bw_hz) if sample_shift is None else int(sample_shift)
        if self.sample_shift not in (1, 2):
            raise ValueError("sample_shift must be 1 (250 kHz) or 2 (125 kHz)")
        self.fs_out = FS_OUT

    @property
    def fs_out_khz(self) -> float:
        return self.fs_out / 1e3

    @property
    def nyquist_hz(self) -> float:
        return self.fs_out / 2

    def samples_per_symbol(self, sf: int, bw_hz: float | None = None) -> int:
        """Return RTL symbol length, `M = 1 << (SF + sample_shift)`."""
        if sf < 0:
            raise ValueError("sf must be >= 0")
        shift = self.sample_shift if bw_hz is None else sample_shift_for_bw(bw_hz)
        return 1 << (int(sf) + shift)

    def process_int8(self, rx_bitstream: np.ndarray) -> np.ndarray:
        """
        Return complex int8-domain output samples as float complex values whose
        real and imaginary components are integer-valued in [-128, 127].
        """
        re_cic = _cic_r16_int8(np.asarray(rx_bitstream).real)
        im_cic = _cic_r16_int8(np.asarray(rx_bitstream).imag)
        n = min(len(re_cic), len(im_cic))
        re = _hb2(_hb1(re_cic[:n]))
        im = _hb2(_hb1(im_cic[:n]))
        n = min(len(re), len(im))
        return re[:n].astype(float) + 1j * im[:n].astype(float)

    def process(self, rx_bitstream: np.ndarray) -> np.ndarray:
        """
        Decimate a complex 1-bit stream and return normalised complex samples.

        The underlying RTL output is signed int8. This method returns int8 / 128
        for compatibility with existing system simulations that multiply by 128
        before feeding the integer-domain combiner/training models.
        """
        return self.process_int8(rx_bitstream) / 128.0
