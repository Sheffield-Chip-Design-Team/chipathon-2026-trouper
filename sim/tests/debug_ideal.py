import numpy as np
from sim.models.lora import modulate, demodulate
from sim.models.channel import rayleigh_coefficients
from sim.models.receiver import compute_weights, mrc_combine

def test_ideal_chain():
    SF = 7
    M = 2**SF
    # No quantization, no decimation, high SNR (effectively N0 = 1e-10)
    N0 = 1e-10
    
    b_tx = 42
    s = modulate(b_tx, M)
    h = np.array([1.0+0j, 0.5+0j, 0.2+0j, 0.1+0j]) # Flat fading
    
    # Simple MRC
    h_hat = h
    phi, c = compute_weights(h_hat, N0)
    y = mrc_combine(h[:,None] * s, phi, c)
    
    b_rx = demodulate(y)
    print(f"Ideal chain TX: {b_tx}, RX: {b_rx}")

if __name__ == "__main__":
    test_ideal_chain()
