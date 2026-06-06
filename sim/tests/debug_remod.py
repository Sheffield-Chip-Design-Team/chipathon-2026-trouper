import numpy as np
from sim.models.lora import modulate, demodulate
from sim.models.converter import SigmaDeltaRemodulator

def debug_signal():
    M = 128
    b = 42
    s = modulate(b, M)
    
    remod = SigmaDeltaRemodulator()
    y_bits = np.array([remod.process(sample) for sample in s])
    
    # Simple LPF
    y_out = np.convolve(y_bits, np.ones(4)/4, mode='same')
    
    b_rx = demodulate(y_out)
    print(f"TX: {b}, RX: {b_rx}")
    
    # Check frequency peak
    dechirped = y_out * np.exp(-1j * np.pi * np.arange(M)**2 / M)
    spectrum = np.abs(np.fft.fft(dechirped))
    print(f"Peak bin: {np.argmax(spectrum)}")

if __name__ == "__main__":
    debug_signal()
