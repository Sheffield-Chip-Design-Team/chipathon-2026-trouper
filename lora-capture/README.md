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
lora-capture/
├── capture.py                # RTL-SDR one-shot capture script
├── monitor_and_capture.py    # serial monitor → auto-trigger capture per config
├── emulate_path_loss.py      # clean capture → calibrated weak-signal SNR sweep
├── firmware/
│   └── lora_tx.ino           # Heltec V3 transmitter sketch (RadioLib)
├── captures/                 # output directory (git-ignored except README)
│   ├── pathloss/             # synthetic SNR-sweep outputs (see §4)
│   └── README.md             # file format reference
└── README.md                 # this file
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

### Automated capture — `monitor_and_capture.py`

The preferred workflow. Watches the Heltec serial port line-by-line and
triggers a capture automatically when the target config banner appears.
Trigger logic is line-accurate so a TX payload and a config banner arriving
in the same serial read chunk can never cross-contaminate.

```sh
# Capture specific configs (waits up to --timeout seconds):
python monitor_and_capture.py --port /dev/ttyUSB0 \
    --configs SF7-BW250-Pre8 SF7-BW500-Pre8 \
    --duration 12 --gain 30

# Capture every distinct config once across a full cycle:
python monitor_and_capture.py --port /dev/ttyUSB0 \
    --all --duration 12 --gain 30

# Dry-run — print banners without capturing:
python monitor_and_capture.py --port /dev/ttyUSB0 --all --dry-run
```

### Manual capture — `capture.py`

For one-off recordings when you already know which config is active:

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

## 4. Emulating path loss (synthetic SNR sweep)

`emulate_path_loss.py` turns one **clean, high-SNR** capture into calibrated
weak-signal versions — the right way to make low-SNR data when you have no RF
attenuator.

### Why not just lower the gain or scale the file?

- **Scaling a capture down does nothing** — it scales the already-captured
  noise by the same factor, so the SNR is unchanged.
- **Lowering RX gain** is only a crude proxy: it moves the receiver's whole
  operating point (the R828D noise figure varies with gain, and at low gain
  the floor becomes ADC-quantisation-limited), so it is *not* a calibrated
  dB-for-dB path-loss knob.

### What the tool does

Real path loss drops the **signal** while the thermal **noise floor stays
fixed**, so the signal sinks toward the floor and SNR falls. The tool
reproduces exactly that:

```
y = g · x + w
```

where `x` is the clean capture, `g` attenuates the signal, and `w` is fresh
complex AWGN at a fixed reference floor (the capture's measured receiver
noise). Lowering the target SNR shrinks `g`.

```sh
# Drive by target output SNR (dB):
python emulate_path_loss.py captures/lora_..._SF7-BW125-Pre8.npy \
    --snr 15 10 6 3 0 -3 -6 -10 --seed 42

# Or drive by extra path loss (dB) relative to the input:
python emulate_path_loss.py captures/lora_..._SF7-BW125-Pre8.npy \
    --path-loss 10 20 30 40
```

Each target writes `.iq` + `.npy` + `.json`, with the filename label suffixed
by the target (e.g. `..._SF7-BW125-Pre8_snr-6dB.npy`). The JSON records
`derived_from`, `signal_gain_g`, `path_loss_db`, `input_snr_db`,
`achieved_snr_db`, and `seed` for full reproducibility (`--seed` makes the
noise deterministic).

| Flag | Default | Notes |
|------|---------|-------|
| `--snr dB …` | — | Target output SNR(s); mutually exclusive with `--path-loss` |
| `--path-loss dB …` | — | Extra attenuation(s) vs the input signal |
| `--seed N` | random | Deterministic AWGN |
| `--outdir DIR` | input's dir | Where to write outputs |
| `--no-iq` | off | Skip the uint8 `.iq`, write `.npy` + `.json` only |
| `--noise-pct` / `--sig-frac` | 20 / 0.5 | Envelope thresholds for the signal/noise classifier |

### Caveats

- **Feed it only genuinely clean source** (the bench captures are ≈ 41 dB
  SNR — ideal). You cannot synthesise *more* signal than is present, so
  re-attenuating an already-weak file is invalid.
- The **`.npy` (float) is authoritative.** Below ≈ 0 dB SNR the signal falls
  under 1 LSB of the uint8 `.iq`, so the `.iq` of deep-SNR sets is
  noise-dominated — use the `.npy` for sub-0 dB work.
- The script self-checks each output's *achieved* SNR using the burst
  time-positions detected on the clean source, so the readout stays valid
  even when the signal is buried.

### Reference dataset

A full sweep of all 9 captured configs × {15, 10, 6, 3, 0, −3, −6, −10} dB
(seed 42) lives under `captures/pathloss/`. Achieved SNR matches target to
within 0.1 dB across all 72 sets, with no clipping.

---

## 5. Post-processing hints

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
