import numpy as np
from sim.models.decimator import SigmaDeltaDecimator, decimation_ratio, FS_ADC, RATIO_1MS

CYCLES = 300


def make_bitstream(n: int) -> np.ndarray:
    i = np.random.choice([-1, 1], size=n).astype(np.float64)
    q = np.random.choice([-1, 1], size=n).astype(np.float64)
    return i + 1j * q


def test_ratios():
    assert decimation_ratio(125e3) == 256
    assert decimation_ratio(250e3) == 128
    assert decimation_ratio(500e3) == 64
    print("PASS  decimation_ratio() lookup")


def test_output_length():
    for bw, expected_r in [(125e3, 256), (250e3, 128), (500e3, 64)]:
        r = decimation_ratio(bw)
        dec = SigmaDeltaDecimator(ratio=r)
        out = dec.process(make_bitstream(r * CYCLES))
        assert len(out) == CYCLES, f"BW={bw}: expected {CYCLES} samples, got {len(out)}"
    print("PASS  output length for 125/250/500 kHz BW")


def test_fs_out():
    expected = {125e3: 125e3, 250e3: 250e3, 500e3: 500e3}
    for bw, fs_exp in expected.items():
        dec = SigmaDeltaDecimator(ratio=decimation_ratio(bw))
        assert dec.fs_out == fs_exp, f"BW={bw}: fs_out={dec.fs_out}, expected {fs_exp}"
    print("PASS  fs_out matches LoRa BW (1× Nyquist)")


def test_integer_samples_per_symbol():
    for bw in [125e3, 250e3, 500e3]:
        r = decimation_ratio(bw)
        for sf in range(6, 13):
            dec = SigmaDeltaDecimator(ratio=r)
            m = dec.samples_per_symbol(sf)
            assert m == 2 ** sf, f"BW={bw/1e3}kHz SF{sf}: expected {2**sf}, got {m}"
    print("PASS  samples/symbol = 2^SF (integer) for all BW × SF combinations")


def test_dc_response():
    for bw in [125e3, 250e3, 500e3]:
        r = decimation_ratio(bw)
        bitstream = np.ones(r * CYCLES, dtype=np.complex128)
        dec = SigmaDeltaDecimator(ratio=r, output_bits=16)
        out = dec.process(bitstream)
        assert np.allclose(out[10:].real, 1.0, atol=0.01), \
            f"BW={bw}: DC response off, mean={out[10:].real.mean():.4f}"
    print("PASS  DC response ≈ 1.0 for all three BW settings")


def test_1ms_mode():
    dec = SigmaDeltaDecimator(ratio=RATIO_1MS)
    assert dec.fs_out == 1e6, f"Expected 1 MS/s, got {dec.fs_out}"
    assert RATIO_1MS == 32
    assert dec.samples_per_symbol(7) == 256
    out = dec.process(make_bitstream(RATIO_1MS * CYCLES))
    assert len(out) == CYCLES
    print("PASS  R=32 → 1 MS/s (decim_ratio=3): fs_out, output length, and 2× oversampling correct")


if __name__ == "__main__":
    test_ratios()
    test_output_length()
    test_fs_out()
    test_integer_samples_per_symbol()
    test_dc_response()
    test_1ms_mode()
