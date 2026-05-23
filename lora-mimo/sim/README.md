# Simulation Framework

This directory contains the simulation environment for the LoRa MIMO ASIC. The project is organized to separate model implementations from testing and analysis scripts.

## Directory Structure

```text
sim/
├── __init__.py       # Package initialization
├── models/           # DSP component implementations
│   ├── channel.py               # Channel modeling (Rayleigh fading)
│   ├── converter.py             # ADC and Re-modulator models
│   ├── decimator.py             # ΣΔ Decimator (CIC + FIR)
│   ├── fixed.py                 # Bit-true fixed-point arithmetic primitives
│   ├── lora.py                  # LoRa CSS modulation and demodulation
│   ├── training_accumulator.py  # Non-FFT channel estimation (Z_j accumulation + weights)
│   ├── receiver.py              # Combining stages; non-FFT path + FFT path (legacy)
│   ├── stages.py                # Energy detector model
│   └── sync.py                  # Schmidl-Cox trigger / timing-ref model
└── tests/            # Verification and analysis scripts
    ├── debug_chain.py     # DSP chain integrity debug
    ├── debug_decimator.py # Decimator logic verification
    ├── debug_levels.py    # Signal level/quantization debug
    ├── debug_lora.py      # Modulation recovery verification
    ├── debug_remod.py     # Re-modulator and filtering debug
    ├── run_ber.py         # Main BER vs SNR sweep and fixed-point analysis
    ├── test_correlator.py # FFT-based preamble/channel-estimator tests (legacy)
    └── test_sync.py       # Schmidl-Cox trigger tests
```

## Running Simulations

All simulations are executed as modules from the project root:

- **Run BER Curves (default MRC):**
  `python3 -m sim.tests.run_ber --nt 1`
  
- **Run BER Curves (ALMMSE):**
  `python3 -m sim.tests.run_ber --nt 2`

- **Run Bit-Width Sweep:**
  `python3 -m sim.tests.run_ber --fixedpoint`

## Design Notes

- **Bit-True Modeling:** The simulation employs bit-true modeling to reflect ASIC hardware constraints:
  - **Fixed-Point Library:** Found in `sim/models/fixed.py`, providing primitives for quantization (`quantize`), saturation, and `Q1.15` format support.
  - **Stage-Specific Precision:** Components enforce hardware-appropriate bit-widths and handle intermediate bit-growth and truncation. Decimator output width is 12 or 16 bits (TBD); the `input_bits` parameter on `energy_detector()` and related functions should be updated once this is decided.
- **Non-FFT DSP Chain (current ASIC architecture):**
  1. ADC (Stage 1)
  2. ΣΔ Decimator (Stage 2) — outputs full-precision samples (12 or 16-bit, TBD)
  3. Schmidl-Cox trigger + energy measurement (Stage 3) — `sync.py`, `stages.py`
  4. Training accumulator — `training_accumulator.py`: `Z_j = Σ raw_j[n]·conj(chirp_ref[n mod M])`
  5. Weight computation from Z_j (MRC/EGC/SC/Bypass) — `training_accumulator.compute_weights()`
  6. Complex combining: `y[n] = Σ_j w_j·x_j[n]` — `receiver.nonfft_combine()` for float studies, or `receiver.nonfft_combine_rtl_int8()` to include RTL Q1.15 weights, fixed ÷2 guard shift, `COMB_POST_GAIN`, and int8 saturation; MRC weights are already conjugated by weight generation
  7. Re-modulator (Stage 8) — `converter.py`
- **FFT path** (`receiver.estimate_channel`, `receiver.compute_weights`) is retained for reference and comparison but is not the current ASIC architecture. See `planning/DSP Flow.md` for why it was replaced.
