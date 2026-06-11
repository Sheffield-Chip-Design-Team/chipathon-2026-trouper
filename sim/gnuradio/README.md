# GNU Radio MIMO MRC Flowgraph

End-to-end LoRa MIMO MRC simulation using gr-lora_sdr blocks.

## Architecture

```
TX (lora_sdr)
    └─ modulate
         └─ RayleighMIMOChannel  ──┬── branch 0 ──┐
                                   ├── branch 1 ──┤
                                   ├── branch 2 ──┤  MRCWeightBlock → MRCCombiner → RX (lora_sdr)
                                   └── branch 3 ──┘
```

**MRCWeightBlock** — detects SC preamble lock, runs
`training_accumulate_allpairs()` from `sim/models/training_accumulator.py`,
then applies the already-conjugated weights `w_j · x_j[n]` per branch.

**MRCCombiner** — sums NR weighted streams: `y[n] = Σ_j w_j · x_j[n]`.

Matches the ASIC pipeline in `planning/blocks/Training Accumulator.md` and
`planning/blocks/Weight Generation.md`.

## Requirements

```bash
# GNU Radio C extensions (pmt, gr) live in dist-packages, not site-packages
export PYTHONPATH=/usr/lib/python3/dist-packages:/usr/lib/python3.12/site-packages:$PYTHONPATH
```

## Usage

```bash
cd sim/gnuradio

# Default: SF7, 125 kHz, 10 dB SNR, 4 branches, MRC
python3 mimo_mrc.py

# Custom options
python3 mimo_mrc.py --sf 6 --snr 5 --nr 4 --mode egc

# Available combining modes: mrc | egc | sc
python3 mimo_mrc.py --mode sc --snr 0
```

## Arguments

| Flag | Default | Description |
|------|---------|-------------|
| `--sf` | 7 | Spreading factor |
| `--bw` | 125000 | Bandwidth (Hz) |
| `--snr` | 10.0 | Per-branch SNR (dB) |
| `--nr` | 4 | Number of RX branches |
| `--mode` | mrc | Combining mode (mrc/egc/sc/bypass) |
| `--payload` | Hello MIMO | Payload string |
| `--preamble` | 8 | Preamble length (symbols) |
| `--gui` | off | Show constellation sink |
