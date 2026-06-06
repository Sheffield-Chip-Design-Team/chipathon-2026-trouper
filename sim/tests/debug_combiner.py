import numpy as np
from sim.models.receiver import mrc_combine

def test_combiner_power():
    NR = 4
    n_samples = 128
    rx = np.random.randn(NR, n_samples) + 1j * np.random.randn(NR, n_samples)
    phi = np.zeros(NR)
    c = np.ones(NR) / NR
    
    y = mrc_combine(rx, phi, c)
    print(f"Input power (mean): {np.mean(np.abs(rx)**2):.4f}")
    print(f"Output power (mean): {np.mean(np.abs(y)**2):.4f}")

if __name__ == "__main__":
    test_combiner_power()
