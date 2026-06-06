# Example IQ Captures

Real-hardware LoRa captures used for end-to-end simulation verification.

## File Format

| Property      | Value                                      |
|---------------|--------------------------------------------|
| Container     | Raw binary, no header                      |
| Sample type   | `uint8`, interleaved I/Q                   |
| Byte layout   | `I₀ Q₀ I₁ Q₁ I₂ Q₃ …`                    |
| Conversion    | `z = ((I − 127.5) + j·(Q − 127.5)) / 127.5` |
| Sample rate   | 1 000 000 S/s (1 MS/s)                     |
| Centre freq   | 868.1 MHz                                  |

The offset-binary encoding maps ADC mid-scale (128) to 0 V and places full-scale at ±1 after conversion.

### Loading in Python

```python
import numpy as np

raw = np.fromfile("capture.iq", dtype=np.uint8)
I   = (raw[0::2].astype(np.float32) - 127.5) / 127.5
Q   = (raw[1::2].astype(np.float32) - 127.5) / 127.5
iq  = (I + 1j * Q).astype(np.complex64)
```

### Decimation to chip rate

The captures are at 1 MS/s. For 125 kHz LoRa BW the oversampling ratio is R = 8.
Decimate before passing to the DSP models:

```python
from scipy.signal import resample_poly, firwin

R   = 8                                    # 1 MHz → 125 kHz
h   = firwin(64*R + 1, 1.0/R, window='hamming')
iq_chip = resample_poly(iq, 1, R, window=h).astype(np.complex64)
# iq_chip is now at 125 kHz; one symbol = M = 2^SF samples
```

## Captures

### `1_packet_mingain.iq`

| Parameter   | Value               |
|-------------|---------------------|
| Packets     | 1                   |
| SF / BW     | 7 / 125 kHz         |
| Gain        | Minimum (SDR)       |
| File size   | 240 000 B           |
| Duration    | 120 ms @ 1 MS/s     |

Simulation results (DSP chain):

| Metric               | Value          |
|----------------------|----------------|
| SC peak metric       | 0.991          |
| CFO                  | +3 bins (+2 930 Hz) |
| Channel phase        | +67.2°         |
| Payload symbols      | 85             |
| Avg dechirp SNR      | 5.43×          |

---

### `5_packets_mingain.iq`

| Parameter   | Value               |
|-------------|---------------------|
| Packets     | 5 (same payload repeated) |
| SF / BW     | 7 / 125 kHz         |
| Gain        | Minimum (SDR)       |
| File size   | 16 584 000 B        |
| Duration    | 8 292 ms @ 1 MS/s   |
| Packet spacing | ~2.04 s         |

Simulation results (per-packet DSP chain):

| Pkt | Onset (chip samp) | CFO (bins) | CFO (Hz)  | \|Z\| | Phase   | Payload syms | SNR avg |
|-----|-------------------|------------|-----------|-------|---------|--------------|---------|
| 1   | 2 444             | +28        | +27 344   | 1.055 | −19.4°  | 85           | ~2.5×   |
| 2   | 257 821           | +31        | +30 273   | 0.791 | −55.7°  | 85           | ~2.5×   |
| 3   | 513 194           | +30        | +29 297   | 0.930 | +122.8° | 85           | ~2.5×   |
| 4   | 768 567           | +29        | +28 320   | 0.970 | −28.9°  | 85           | ~2.5×   |
| 5   | 1 023 943         | +29        | +28 320   | 0.649 | −75.0°  | 85           | ~4.2×   |

CFO stability across 5 transmissions: **+28 711 ± 996 Hz** — consistent with a single free-running oscillator.
Channel phase rotates independently each packet (no phase lock between TX bursts).
