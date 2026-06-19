# LoRa IQ Sample Capture

Tooling for collecting labelled IQ captures of LoRa signals across a range of
spreading factors (SF), bandwidths (BW), and preamble lengths — useful for
building ML datasets, testing demodulators, or understanding the physical layer.

---

## Hardware

| Device | Role |
|--------|------|
| Heltec WiFi LoRa 32 V3 (ESP32-S3 + SX1262) | Transmitter |
| RTL-SDR Blog V4 (R828D tuner) | Receiver / IQ capture |

Antennas were co-located on the bench (< 30 cm apart) for low-power testing.
Increase separation or add an RF attenuator to reduce SNR further.

---

## Repository layout

```
lora-sample-capture/
├── capture.py          # RTL-SDR capture script
├── README.md           # this file
└── examples/           # short IQ clips with matching spectrograms
    ├── 1_packet.iq
    ├── 5_packets.iq
    └── *.png

~/Arduino/lora_tx/
└── lora_tx.ino         # transmitter sketch (Heltec V3 / RadioLib)
```

---

## 1. Transmitter — Heltec V3

### Dependencies

| Tool | Version |
|------|---------|
| arduino-cli | 1.3.0+ |
| Heltec ESP32 board support | 3.0.2 |
| RadioLib | 7.6.0+ |

Install the board package:
```sh
arduino-cli core install heltec:esp32 \
  --additional-urls https://github.com/Heltec-Aaron-Lee/WiFi_Kit_series/releases/download/0.0.7/package_heltec_esp32_index.json
```

Install RadioLib:
```sh
arduino-cli lib install RadioLib
```

### Flash

```sh
arduino-cli compile --fqbn heltec:esp32:heltec_wifi_lora_32_V3 ~/Arduino/lora_tx
arduino-cli upload  --fqbn heltec:esp32:heltec_wifi_lora_32_V3 \
                    -p /dev/ttyUSB0 ~/Arduino/lora_tx
```

### SX1262 pin mapping (V3 schematic)

| Signal | GPIO |
|--------|------|
| NSS (CS) | 8 |
| DIO1 | 14 |
| RST | 12 |
| BUSY | 13 |

TCXO voltage: 1.8 V. DIO2 configured as RF switch.

### Configuration cycling

The sketch cycles through 9 preset configurations automatically,
sending `PKTS_PER_CONFIG` (default 20) packets on each before advancing.

| Index | BW (kHz) | SF | Preamble | Purpose |
|-------|----------|----|----------|---------|
| 0 | 125 | 7 | 8 | Baseline (LoRaWAN default) |
| 1 | 125 | 9 | 8 | Medium SF |
| 2 | 125 | 12 | 8 | Maximum SF / range |
| 3 | 125 | 7 | 6 | Short preamble |
| 4 | 125 | 7 | 12 | Medium-long preamble |
| 5 | 125 | 7 | 16 | Long preamble |
| 6 | 250 | 7 | 8 | Wider BW |
| 7 | 500 | 7 | 8 | Widest BW |
| 8 | 500 | 10 | 8 | High SF + wide BW |

Fixed for all configs: 868.1 MHz, CR 4/5, −9 dBm (SX1262 hardware minimum).

Each transmitted packet carries a self-labelling payload:

```
C0#3 SF7-BW125-Pre8
 ↑ ↑  ↑
 │ │  human-readable label
 │ packet index within config
 config index
```

The serial port (115200 baud) prints a clear banner before each new config,
so you can correlate capture start times with config transitions.

### Adjusting the sketch

| Constant | Location | Purpose |
|----------|----------|---------|
| `BASE_FREQ` | top of sketch | Transmit frequency in MHz |
| `LORA_POWER` | top of sketch | TX power in dBm (−9 to +22) |
| `PKTS_PER_CONFIG` | top of sketch | Packets before advancing config |
| `TX_INTERVAL_MS` | top of sketch | Gap between packets in ms |
| `CONFIGS[]` | config table | Add / remove / modify presets |

---

## 2. Receiver — RTL-SDR V4

### Dependencies

```sh
# Ubuntu / Debian
sudo apt install rtl-sdr python3-pip
pip install numpy
```

Verify the dongle is detected:
```sh
rtl_test -t
```

### Capture script

`capture.py` wraps `rtl_sdr`, converts the output to complex64, and writes a
JSON metadata sidecar alongside each capture.

```
usage: capture.py [-h] [--freq MHz] [--sr SPS] [--gain dB]
                  [--duration SEC] [--outdir DIR] [--label LABEL]
```

| Flag | Default | Notes |
|------|---------|-------|
| `--freq` | 868.1 | Centre frequency in MHz |
| `--sr` | 2000000 | Sample rate in S/s; 2 MSPS covers BW up to 500 kHz |
| `--gain` | 0.9 | Manual gain in dB; `0` enables AGC |
| `--duration` | 60 | Capture length in seconds |
| `--outdir` | script dir | Where to save output files |
| `--label` | (empty) | Tag appended to filename, e.g. `SF12-BW125-Pre8` |

### Example workflow

Monitor the Heltec serial port to see which config is active, then start a
labelled capture for that config:

```sh
# Terminal 1 — watch serial output
arduino-cli monitor -p /dev/ttyUSB0 --config baudrate=115200

# Terminal 2 — start capture when you see "=== CONFIG 2: SF12-BW125-Pre8 ==="
python capture.py --label SF12-BW125-Pre8 --duration 40
```

Or capture the full cycle (all 9 configs × 20 packets × 2 s ≈ 6 min):
```sh
python capture.py --duration 360 --label full-cycle
```

Each run produces three files:
```
lora_20260619_120000_SF12-BW125-Pre8.iq    # raw uint8 IQ
lora_20260619_120000_SF12-BW125-Pre8.npy   # complex64 numpy array
lora_20260619_120000_SF12-BW125-Pre8.json  # metadata
```

### Gain settings

| Setting | `--gain` value | Notes |
|---------|---------------|-------|
| AGC | 0 | rtl_sdr auto-gain — NOT 0 dB |
| Minimum manual | 0.9 | Lowest manual setting on R828D |
| Good SNR | 30 | Typical starting point for bench testing |

R828D supported manual gain values (dB):  
0.9, 1.4, 2.7, 3.7, 7.7, 8.7, 12.5, 14.4, 15.7, 16.6, 19.7, 20.7, 22.9,  
25.4, 28.0, 29.7, 32.8, 33.8, 36.4, 37.2, 38.6, 40.2, 42.1, 43.4, 43.9,  
44.5, 48.0, 49.6

---

## 3. IQ file format

```
Byte layout:  I₀ Q₀ I₁ Q₁ I₂ Q₂ …
Type:         uint8, offset binary
Conversion:   complex = ((I − 127.5) + j·(Q − 127.5)) / 127.5
```

The metadata JSON documents the sample rate and centre frequency for every file.
Raw `.iq` files are compatible with inspectrum, Universal Radio Hacker (URH),
GNU Radio, and most SDR tools.

Load in Python:
```python
import numpy as np, json

meta    = json.load(open("lora_20260619_120000_SF12-BW125-Pre8.json"))
samples = np.load("lora_20260619_120000_SF12-BW125-Pre8.npy")

sr   = meta["sample_rate_sps"]      # e.g. 2000000
freq = meta["centre_freq_hz"]       # e.g. 868100000
```

Or from the raw `.iq` directly:
```python
raw     = np.fromfile("capture.iq", dtype=np.uint8).astype(np.float32)
iq      = (raw - 127.5) / 127.5
samples = iq[0::2] + 1j * iq[1::2]
```

---

## 4. Post-processing hints

### Spectrogram

```python
import matplotlib.pyplot as plt
from scipy.signal import spectrogram

f, t, Sxx = spectrogram(samples, fs=sr, nperseg=256, noverlap=240, window='hann')
plt.pcolormesh(t, (f + freq) / 1e6, 10 * np.log10(Sxx + 1e-12), cmap='inferno')
plt.ylabel("Frequency (MHz)")
plt.xlabel("Time (s)")
plt.colorbar(label="dB")
plt.show()
```

### Basic LoRa symbol demodulation (SF7 / BW125 example)

```python
bw     = 125e3
sf     = 7
n_sym  = int(sr * 2**sf / bw)   # samples per symbol (~1024 at 1 MSPS)
t_sym  = np.arange(n_sym) / sr

# Reference downchirp
downchirp = np.exp(-1j * np.pi * bw * (t_sym - t_sym**2 * bw / (2**sf / bw)))

# Demodulate first symbol starting at sample 'offset'
offset  = 0
sym_win = samples[offset : offset + n_sym]
dechirped = sym_win * downchirp
peak_bin = np.argmax(np.abs(np.fft.fft(dechirped, 2**sf)))
print(f"Symbol value: {peak_bin}")
```

### Recommended tools

| Tool | Use |
|------|-----|
| [inspectrum](https://github.com/miek/inspectrum) | Visual inspection of `.iq` files |
| [Universal Radio Hacker](https://github.com/jopohl/urh) | Protocol analysis |
| [gr-lora](https://github.com/rpp0/gr-lora) | Full GNU Radio LoRa decoder |
| [pylora](https://github.com/BastianRobben/pylora) | Python LoRa demodulator |

---

## Key observations

- SX1262 minimum TX power: **−9 dBm**
- RTL-SDR V4 minimum manual RX gain: **0.9 dB**  
  (`gain=0` in `rtl_sdr` enables AGC, it does not set 0 dB)
- At −9 dBm TX / 0.9 dB RX with antennas < 30 cm apart, packets remain
  detectable but approach the noise floor — LoRa processing gain keeps them
  demodulable well below the visual noise threshold
- 2 MSPS sample rate provides comfortable headroom for all LoRa BWs up to 500 kHz
- For BW = 500 kHz you need at least 1 MSPS (Nyquist); 2 MSPS is recommended
