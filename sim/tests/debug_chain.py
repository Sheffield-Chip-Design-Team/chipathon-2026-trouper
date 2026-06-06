import numpy as np
from sim.models.lora import modulate, demodulate
from sim.models.receiver import mrc_combine, almmse_combine
from sim.models.converter import SigmaDeltaRemodulator

def test_chain():
    M = 128
    b_tx = 42
    s = modulate(b_tx, M)
    
    # Simulate an ideal "receiver" chain
    # 1. Combine (MRC with single antenna)
    # y = MRC(s) -> s
    y = s
    
    # 2. Re-modulator
    remod = SigmaDeltaRemodulator()
    y_out = np.array([remod.process(sample) for sample in y])
    
    # 3. Demodulate
    b_rx = demodulate(y_out)
    
    print(f"TX: {b_tx}, RX: {b_rx}")
    if b_tx != b_rx:
        print("Chain Fails")
    else:
        print("Chain Works")

if __name__ == "__main__":
    test_chain()
