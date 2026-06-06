import numpy as np
from sim.models.lora import modulate, demodulate
from sim.models.converter import SigmaDeltaRemodulator
from scipy.signal import butter, filtfilt

def test_remod_chain():
    M = 128
    b_tx = 42
    s = modulate(b_tx, M)
    
    # Add Remodulator + Filter
    remod = SigmaDeltaRemodulator()
    b, a = butter(2, 0.2)
    
    y_bits_re = np.array([remod.process(sample).real for sample in s])
    y_bits_im = np.array([remod.process(sample).imag for sample in s])
    
    y_out_re = filtfilt(b, a, y_bits_re)
    y_out_im = filtfilt(b, a, y_bits_im)
    y_out = y_out_re + 1j * y_out_im
    
    b_rx = demodulate(y_out)
    print(f"Remod chain TX: {b_tx}, RX: {b_rx}")

if __name__ == "__main__":
    test_remod_chain()
