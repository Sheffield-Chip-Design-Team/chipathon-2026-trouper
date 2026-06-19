# IQ Captures

Raw IQ recordings from an RTL-SDR Blog V4 (R828D tuner) of LoRa packets
transmitted by a Heltec WiFi LoRa 32 V3 (SX1262) at 868.1 MHz.

Capture files are git-ignored (large binaries). This README is tracked.

---

## File naming

```
lora_<YYYYMMDD>_<HHMMSS>_<label>.iq    raw uint8 IQ
lora_<YYYYMMDD>_<HHMMSS>_<label>.npy   complex64 numpy array
lora_<YYYYMMDD>_<HHMMSS>_<label>.json  metadata sidecar
```

Label follows the Heltec config banner, e.g. `SF7-BW250-Pre8`.

---

## Formats

### `.iq` — raw uint8 offset-binary

Byte layout:

```
I₀ Q₀ I₁ Q₁ I₂ Q₂ …   (uint8, interleaved)
```

Conversion to complex baseband:

```python
import numpy as np
raw     = np.fromfile("capture.iq", dtype=np.uint8).astype(np.float32)
iq      = (raw - 127.5) / 127.5          # centre at 0, range ≈ ±1
samples = iq[0::2] + 1j * iq[1::2]
```

Compatible with inspectrum, Universal Radio Hacker, GNU Radio, and `rtl_sdr`.

### `.npy` — complex64 numpy array

The same conversion already applied; ready to use directly:

```python
import numpy as np
samples = np.load("capture.npy")         # dtype complex64, range ≈ ±1
```

### `.json` — metadata sidecar

```json
{
  "timestamp_utc":   "20260619_150102",
  "label":           "SF7-BW250-Pre8",
  "centre_freq_hz":  868100000,
  "sample_rate_sps": 2000000,
  "gain_db":         30.0,
  "gain_mode":       "manual",
  "duration_sec":    12,
  "iq_format":       "uint8 offset-binary, interleaved I Q",
  "iq_conversion":   "complex = ((I - 127.5) + j*(Q - 127.5)) / 127.5",
  "files": {
    "raw_iq": "lora_20260619_150102_SF7-BW250-Pre8.iq",
    "numpy":  "lora_20260619_150102_SF7-BW250-Pre8.npy"
  }
}
```

---

## Capture parameters

| Parameter | Value |
|-----------|-------|
| Centre frequency | 868.1 MHz (EU868 LoRa channel) |
| Sample rate | 2 MSPS (covers BW up to 500 kHz with headroom) |
| Gain (verified captures) | 29.7 dB (requested 30 dB; nearest R828D step) |
| TX power | −9 dBm (SX1262 hardware minimum) |
| Antenna separation | < 30 cm (bench) |

---

## Verified configs

Captures confirmed by autocorrelation at the expected LoRa symbol period and
chirp bandwidth measurement from the spectrogram.

| File label | SF | BW | Preamble | Symbol (samples) | Autocorr SNR | Chirp BW |
|---|---|---|---|---|---|---|
| SF7-BW125-Pre8 | 7 | 125 kHz | 8 | 2048 | 15× | 112 kHz |
| SF12-BW125-Pre8 | 12 | 125 kHz | 8 | 65536 | 1767× | 113 kHz |
| SF7-BW250-Pre8 | 7 | 250 kHz | 8 | 1024 | 35× | 212 kHz |
| SF7-BW500-Pre8 | 7 | 500 kHz | 8 | 512 | 63× | 420 kHz |

Symbol length formula: `2^SF / BW_Hz * sample_rate`

---

## Loading and plotting

```python
import numpy as np, json
from scipy.signal import spectrogram
import matplotlib.pyplot as plt

meta    = json.load(open("lora_20260619_150102_SF7-BW250-Pre8.json"))
samples = np.load("lora_20260619_150102_SF7-BW250-Pre8.npy")

sr   = meta["sample_rate_sps"]   # 2000000
freq = meta["centre_freq_hz"]    # 868100000

f, t, Sxx = spectrogram(samples, fs=sr, nperseg=256, noverlap=240, window='hann')
plt.pcolormesh(t, (f + freq) / 1e6, 10 * np.log10(Sxx + 1e-12), cmap='inferno')
plt.ylabel("Frequency (MHz)")
plt.xlabel("Time (s)")
plt.colorbar(label="dB")
plt.show()
```
