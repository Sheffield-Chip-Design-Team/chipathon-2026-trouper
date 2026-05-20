import numpy as np
from sim.models.decimator import SigmaDeltaDecimator, decimation_ratio


def debug_decimator_dc():
    """
    Quick CIC+FIR smoke test using the one input the model should preserve:
    a constant 1-bit stream. This avoids the invalid assumption that ratio=1
    behaves like a transparent LoRa symbol path.
    """
    ratio = decimation_ratio(500e3)
    decimator = SigmaDeltaDecimator(ratio=ratio, output_bits=16)
    bitstream = np.ones(ratio * 128, dtype=np.complex128)
    s_dec = decimator.process(bitstream)
    print(f"ratio={ratio}, mean={s_dec[10:].real.mean():.4f}, "
          f"min={s_dec.real.min():.4f}, max={s_dec.real.max():.4f}")

if __name__ == "__main__":
    debug_decimator_dc()
