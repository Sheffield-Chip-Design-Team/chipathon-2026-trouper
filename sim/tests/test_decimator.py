import numpy as np
import pytest

from sim.models.decimator import (
    DECIMATION_RATIO,
    FS_OUT,
    SigmaDeltaDecimator,
    decimation_ratio,
    sample_shift_for_bw,
)

CYCLES = 300


def make_bitstream(n: int) -> np.ndarray:
    i = np.random.choice([-1, 1], size=n).astype(np.float64)
    q = np.random.choice([-1, 1], size=n).astype(np.float64)
    return i + 1j * q


def test_fixed_ratio_for_supported_bw():
    assert decimation_ratio(250e3) == DECIMATION_RATIO == 64
    assert decimation_ratio(125e3) == DECIMATION_RATIO == 64
    assert sample_shift_for_bw(250e3) == 1
    assert sample_shift_for_bw(125e3) == 2


@pytest.mark.parametrize("bw_hz, expected_m_sf7", [(250e3, 256), (125e3, 512)])
def test_output_rate_and_symbol_length(bw_hz, expected_m_sf7):
    dec = SigmaDeltaDecimator(bw_hz=bw_hz)
    assert dec.fs_out == FS_OUT == 500e3
    assert dec.samples_per_symbol(7) == expected_m_sf7


@pytest.mark.parametrize("bw_hz", [250e3, 125e3])
def test_output_length_fixed_r64(bw_hz):
    dec = SigmaDeltaDecimator(bw_hz=bw_hz)
    out = dec.process(make_bitstream(DECIMATION_RATIO * CYCLES))
    assert len(out) == CYCLES


def test_dc_response_settles_to_rtl_integer_gain():
    dec = SigmaDeltaDecimator()
    out_i8 = dec.process_int8(np.ones(DECIMATION_RATIO * 160, dtype=np.complex128))
    settled = out_i8[32:]
    assert np.all(settled.real == 124)
    assert np.all(settled.imag == 124)
    out = dec.process(np.ones(DECIMATION_RATIO * 160, dtype=np.complex128))
    assert np.allclose(out[32:].real, 124 / 128)


def test_rejects_stale_cic_modes():
    with pytest.raises(ValueError):
        decimation_ratio(500e3)
    with pytest.raises(ValueError):
        SigmaDeltaDecimator(ratio=128)
    with pytest.raises(TypeError):
        SigmaDeltaDecimator(droop_eq=True)


if __name__ == "__main__":
    test_fixed_ratio_for_supported_bw()
    test_output_rate_and_symbol_length(250e3, 256)
    test_output_rate_and_symbol_length(125e3, 512)
    test_output_length_fixed_r64(250e3)
    test_output_length_fixed_r64(125e3)
    test_dc_response_settles_to_rtl_integer_gain()
    test_rejects_stale_cic_modes()
    print("All current decimator tests passed")
