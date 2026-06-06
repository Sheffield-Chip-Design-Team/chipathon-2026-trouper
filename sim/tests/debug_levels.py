import numpy as np
from sim.models.lora import modulate, demodulate
from sim.models.converter import ADCModel
from sim.models.decimator import SigmaDeltaDecimator

def debug_levels():
    M = 128
    b = 42
    s = modulate(b, M)
    
    # 1. ADC
    adc = ADCModel()
    s_adc = adc.process(s)
    print(f"ADC out mean power: {np.mean(np.abs(s_adc)**2):.4f}")
    
    # 2. Decimator
    dec = SigmaDeltaDecimator(ratio=1, output_bits=8)
    s_dec = dec.process(s_adc)
    print(f"Decimator out mean power: {np.mean(np.abs(s_dec)**2):.4f}")
    print(f"Decimator range: [{np.min(s_dec.real)}, {np.max(s_dec.real)}]")

if __name__ == "__main__":
    debug_levels()
