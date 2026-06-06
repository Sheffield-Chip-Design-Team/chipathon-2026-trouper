import numpy as np
from sim.models.lora import modulate, demodulate

def test_recovery():
    M = 128
    for b in range(M):
        s = modulate(b, M)
        b_rx = demodulate(s)
        if b != b_rx:
            print(f"Mismatch: {b} -> {b_rx}")
            return
    print("All symbols recovered correctly.")

if __name__ == "__main__":
    test_recovery()
