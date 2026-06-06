"""Quick diagnostic: per-antenna phase before and after correlator correction."""
import numpy as np
from sim.lora import upchirp
from sim.receiver import estimate_channel

SF, M, NR, N_SYM = 7, 128, 4, 8
rng = np.random.default_rng(42)

hdr = (
    f"{'Ant':>4}  {'PLL offset':>10}  {'Channel ph':>10}  "
    f"{'Total ph':>10}  {'h_hat ph':>10}  {'Residual':>10}"
)

for trial in range(3):
    h_base = (rng.standard_normal(NR) + 1j * rng.standard_normal(NR)) / np.sqrt(2)
    pll    = rng.uniform(-np.pi, np.pi, NR)
    h      = h_base * np.exp(1j * pll)

    tx    = np.tile(upchirp(M), N_SYM)
    N0    = 0.01
    noise = np.sqrt(N0 / 2) * (
        rng.standard_normal((NR, N_SYM * M))
        + 1j * rng.standard_normal((NR, N_SYM * M))
    )
    rx    = h[:, None] * tx[None, :] + noise
    h_hat = estimate_channel(rx, M, N_SYM)

    print(f"--- Trial {trial + 1}  (all angles in degrees) ---")
    print(hdr)
    print("-" * len(hdr))
    for j in range(NR):
        pll_deg   = np.degrees(pll[j])
        ch_deg    = np.degrees(np.angle(h_base[j]))
        total_deg = np.degrees(np.angle(h[j]))
        est_deg   = np.degrees(np.angle(h_hat[j]))
        resid_deg = np.degrees(np.angle(np.exp(1j * (np.angle(h_hat[j]) - np.angle(h[j])))))
        print(
            f"{j:>4}  {pll_deg:>10.1f}  {ch_deg:>10.1f}  "
            f"{total_deg:>10.1f}  {est_deg:>10.1f}  {resid_deg:>10.4f}"
        )

    spread = np.max(np.degrees(np.angle(h))) - np.min(np.degrees(np.angle(h)))
    print(f"     Phase spread across antennas (before correction): {spread:.1f} deg")
    print()
