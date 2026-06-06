import numpy as np
from sim.models.lora import modulate, demodulate
from sim.models.receiver import compute_weights, mrc_combine

def test_awgn_ber():
    SF = 7
    M = 128
    
    # 500 packets in high SNR AWGN
    N0 = 1e-4
    n_err = 0
    n_packets = 500
    
    for _ in range(n_packets):
        b_tx = np.random.randint(0, M)
        s = modulate(b_tx, M)
        # AWGN channel (h=1)
        rx = s + np.sqrt(N0/2) * (np.random.randn(M) + 1j * np.random.randn(M))
        b_rx = demodulate(rx)
        if b_tx != b_rx:
            n_err += 1
            
    print(f"AWGN BER: {n_err / n_packets:.4e}")

if __name__ == "__main__":
    test_awgn_ber()
