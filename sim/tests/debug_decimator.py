from sim.models.decimator import DECIMATION_RATIO, SigmaDeltaDecimator
import numpy as np


def debug_decimator_dc():
    """
    Check the current fixed R=64 half-band decimator on a constant 1-bit stream.
    """
    decimator = SigmaDeltaDecimator()
    bitstream = np.ones(DECIMATION_RATIO * 128, dtype=np.complex128)
    s_dec = decimator.process_int8(bitstream)
    print(f"ratio={DECIMATION_RATIO}, mean_i8={s_dec[32:].real.mean():.4f}, "
          f"min={s_dec[32:].real.min():.0f}, max={s_dec[32:].real.max():.0f}")
    print(s_dec[:16])


if __name__ == "__main__":
    debug_decimator_dc()
