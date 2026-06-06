import numpy as np
from sim.models.lora import modulate, demodulate
from sim.models.channel import apply_channel
from sim.models.converter import ADCModel
from sim.models.decimator import SigmaDeltaDecimator

def debug_signal_chain():
    M = 128
    b = 42
    s = modulate(b, M)
    
    # 1. Channel
    h = 1.0 + 1j
    rx = apply_channel(s, h, 0.0)
    print(f"Post-Channel power: {np.mean(np.abs(rx)**2):.4f}")
    
    # 2. ADC
    adc = ADCModel()
    rx_adc = adc.process(rx)
    print(f"Post-ADC power: {np.mean(np.abs(rx_adc)**2):.4f}")
    
    # 3. Demodulate directly
    b_rx = demodulate(rx_adc)
    print(f"Recovered after ADC: {b_rx}")

if __name__ == "__main__":
    debug_signal_chain()
