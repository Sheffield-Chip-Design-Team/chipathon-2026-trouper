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

## IQ-Imbalance Benchmark Reference

Use `sim/sims/compare_mrc_methods.py` as the regression benchmark for branch-dependent frontend I/Q imbalance. This benchmark exists to answer one narrow question: how much of the combining loss comes from the current linear Trouper architecture when the receive branches are no longer related by a simple complex scalar?

### Impairment model

Each branch can be passed through a widely-linear I/Q imbalance model:

```text
y_j = mu_j * x_j + nu_j * conj(x_j)
```

This is implemented in `sim/models/channel.py` by `apply_iq_imbalance()`. It is intentionally stronger than a plain gain/phase tweak because it creates an image term. A single complex calibration coefficient `cal_j` cannot cancel this in general.

### Curves reported by the benchmark

- `oracle_clean`: ideal MRC from the clean channel vector `h`; valid ceiling only when no frontend impairment is injected
- `oracle_q15`: same as `oracle_clean`, but quantized to Q1.15
- `oracle_lin_imp`: genie-aided best **linear** combiner for the actual impaired branch waveforms; this is the fair ceiling for the current Trouper combiner architecture under IQ imbalance
- `eigvec_pre`: principal eigenvector from the preamble-only Z matrix
- `eigvec_iter_float`: float power-iteration analogue of the firmware eigenvector path
- `eigvec_psram`: principal eigenvector from preamble+payload accumulation, representing the same-packet PSRAM replay path
- `eigvec_nw`: noise-whitened eigenvector upper bound
- `wk`: row-sum MRC path based on `W_k`, representing the low-cost baseline

### SX1257 reference numbers

From `resources/DS_SX1257_V1.2.pdf`:

- RX IQ gain mismatch: `0.5 dB typ`, `1 dB max`
- RX IQ phase mismatch: `1 deg typ`, `3 deg max`

The benchmark uses a centred branch profile. For `NR=4`, a command-line step `s` becomes per-branch offsets:

- branch 0: `-1.5 * s`
- branch 1: `-0.5 * s`
- branch 2: `+0.5 * s`
- branch 3: `+1.5 * s`

That means the branch **extreme** stays within datasheet limits only if:

- `iq_gain_db_step <= 0.6667`
- `iq_phase_deg_step <= 2.0`

### Baseline comparison commands

No I/Q imbalance:

```bash
python3 -m sim.sims.compare_mrc_methods   --sf 7 --nr 4 -n 500   --snr=-16,-14,-12,-10,-8   --payload 50   --iq-gain-db-step 0   --iq-phase-deg-step 0   --out sim/plots/compare_mrc_no_iq_imbalance.png
```

SX1257-typ-like branch-dependent case:

```bash
python3 -m sim.sims.compare_mrc_methods   --sf 7 --nr 4 -n 500   --snr=-16,-14,-12,-10,-8   --payload 50   --iq-gain-db-step 0.3333   --iq-phase-deg-step 0.6667   --out sim/plots/compare_mrc_iq_imbalance_sx1257_typ.png
```

This corresponds approximately to:

- gain mismatch `[-0.5, -0.1667, +0.1667, +0.5] dB`
- quadrature phase mismatch `[-1.0, -0.3333, +0.3333, +1.0] deg`

SX1257-max-bounded branch-dependent case:

```bash
python3 -m sim.sims.compare_mrc_methods   --sf 7 --nr 4 -n 500   --snr=-16,-14,-12,-10,-8   --payload 50   --iq-gain-db-step 0.6667   --iq-phase-deg-step 2.0   --out sim/plots/compare_mrc_iq_imbalance_sx1257_max.png
```

This corresponds approximately to:

- gain mismatch `[-1.0, -0.3333, +0.3333, +1.0] dB`
- quadrature phase mismatch `[-3.0, -1.0, +1.0, +3.0] deg`

Deliberate stress case used earlier:

```bash
python3 -m sim.sims.compare_mrc_methods   --sf 7 --nr 4 -n 500   --snr=-16,-14,-12,-10,-8   --payload 50   --iq-gain-db-step 1.0   --iq-phase-deg-step 5   --out sim/plots/compare_mrc_iq_imbalance.png
```

This stress case exceeds the SX1257 datasheet limits and should not be treated as the realistic baseline.

### Why `oracle_lin_imp` matters

When I/Q imbalance is enabled, `oracle_clean` is no longer a fair reference because the received branches are not just `h_j * s + n`. Comparing `eigvec_psram` or `wk` against `oracle_clean` mixes together two effects:

- true loss from the frontend impairment itself
- avoidable loss from the particular weight-estimation method

Use `oracle_lin_imp` as the comparison ceiling for the current hardware architecture. If a future fix adds explicit I/Q-imbalance correction or a widely-linear combiner, rerun the same benchmark and compare against these documented baselines first.

### Interpretation notes

Why `eigvec_psram` looks resilient in this benchmark:

- it uses the full Hermitian correlation matrix `Z`, not the row-sum shortcut `W_k = sum_l Z_kl`
- it accumulates over preamble plus payload during replay, so the spatial estimate is based on `7424` samples here instead of `1024` for the preamble-only paths
- the injected I/Q imbalance is static per branch within a packet, so longer accumulation improves the estimate of the dominant **linear** spatial mode even though the impairment itself is widely-linear

What that does **not** mean:

- `eigvec_psram` is not cancelling the image term; it is only finding a better linear weight direction than `wk` or short-window eigenvector estimation
- the current architecture still cannot implement a true widely-linear compensator
- small differences at very low SER with `500` packets per point should be treated as Monte Carlo noise, not a strong ordering claim

One more caution: `oracle_lin_imp` in this script is a least-squares linear template fit, not a full SER-optimal decoder bound. It is the right comparison ceiling for the present linear combiner architecture, but it is still a model-defined oracle rather than the last word on achievable BER.

### Reference outputs from the current baselines

No I/Q imbalance (`sim/plots/compare_mrc_no_iq_imbalance.png`):

```text
SNR=-16 dB  oracle_clean=0.1440  oracle_lin_imp=0.1440  pre=0.2820  iter_float=0.4680  psram=0.1640  nw=0.1640  wk=0.6100
SNR=-14 dB  oracle_clean=0.0380  oracle_lin_imp=0.0380  pre=0.1460  iter_float=0.2920  psram=0.0560  nw=0.0560  wk=0.4540
SNR=-12 dB  oracle_clean=0.0220  oracle_lin_imp=0.0220  pre=0.0440  iter_float=0.1020  psram=0.0260  nw=0.0260  wk=0.3040
SNR=-10 dB  oracle_clean=0.0080  oracle_lin_imp=0.0080  pre=0.0140  iter_float=0.0440  psram=0.0060  nw=0.0060  wk=0.2220
SNR=-8  dB  oracle_clean=0.0000  oracle_lin_imp=0.0000  pre=0.0020  iter_float=0.0120  psram=0.0000  nw=0.0000  wk=0.1320
```

SX1257-typ-like branch-dependent case (`sim/plots/compare_mrc_iq_imbalance_sx1257_typ.png`):

```text
SNR=-16 dB  oracle_clean=0.1420  oracle_lin_imp=0.3280  pre=0.3340  iter_float=0.4920  psram=0.1820  nw=0.1820  wk=0.6100
SNR=-14 dB  oracle_clean=0.0380  oracle_lin_imp=0.1900  pre=0.1100  iter_float=0.2660  psram=0.0520  nw=0.0520  wk=0.4320
SNR=-12 dB  oracle_clean=0.0160  oracle_lin_imp=0.1020  pre=0.0600  iter_float=0.1260  psram=0.0180  nw=0.0180  wk=0.3380
SNR=-10 dB  oracle_clean=0.0040  oracle_lin_imp=0.0360  pre=0.0080  iter_float=0.0360  psram=0.0040  nw=0.0040  wk=0.2200
SNR=-8  dB  oracle_clean=0.0020  oracle_lin_imp=0.0220  pre=0.0020  iter_float=0.0160  psram=0.0020  nw=0.0020  wk=0.1300
```

SX1257-max-bounded branch-dependent case (`sim/plots/compare_mrc_iq_imbalance_sx1257_max.png`):

```text
SNR=-16 dB  oracle_clean=0.1660  oracle_lin_imp=0.4020  pre=0.3840  iter_float=0.5520  psram=0.2180  nw=0.2180  wk=0.6560
SNR=-14 dB  oracle_clean=0.0540  oracle_lin_imp=0.1920  pre=0.1140  iter_float=0.2760  psram=0.0600  nw=0.0600  wk=0.4140
SNR=-12 dB  oracle_clean=0.0140  oracle_lin_imp=0.0880  pre=0.0460  iter_float=0.1140  psram=0.0280  nw=0.0280  wk=0.3280
SNR=-10 dB  oracle_clean=0.0040  oracle_lin_imp=0.0340  pre=0.0160  iter_float=0.0400  psram=0.0060  nw=0.0060  wk=0.1880
SNR=-8  dB  oracle_clean=0.0020  oracle_lin_imp=0.0180  pre=0.0040  iter_float=0.0120  psram=0.0020  nw=0.0020  wk=0.1200
```

Stress case exceeding SX1257 limits (`sim/plots/compare_mrc_iq_imbalance.png`):

```text
SNR=-16 dB  oracle_clean=0.1560  oracle_lin_imp=0.3560  pre=0.3180  iter_float=0.5220  psram=0.1780  nw=0.1780  wk=0.5940
SNR=-14 dB  oracle_clean=0.0420  oracle_lin_imp=0.2100  pre=0.1300  iter_float=0.3000  psram=0.0580  nw=0.0580  wk=0.4040
SNR=-12 dB  oracle_clean=0.0180  oracle_lin_imp=0.0940  pre=0.0540  iter_float=0.1360  psram=0.0320  nw=0.0320  wk=0.3340
SNR=-10 dB  oracle_clean=0.0020  oracle_lin_imp=0.0220  pre=0.0100  iter_float=0.0400  psram=0.0040  nw=0.0040  wk=0.1780
SNR=-8  dB  oracle_clean=0.0000  oracle_lin_imp=0.0080  pre=0.0020  iter_float=0.0060  psram=0.0000  nw=0.0000  wk=0.1480
```

Interpret these as regression baselines, not as final product claims. Packet counts are modest, and none of the mismatch profiles above are a measured four-branch SX1257 board characterization.

## Design Notes

`MODEL_RTL_AUDIT.md` records the current source-of-truth comparison for each
modelled RTL block, including the deliberate boundary between DSP models and
the cocotb-verified packet-control/PSRAM logic.

- **Bit-True Modeling:** The simulation employs bit-true modeling to reflect ASIC hardware constraints:
  - **Fixed-Point Library:** Found in `sim/models/fixed.py`, providing primitives for quantization (`quantize`), saturation, and `Q1.15` format support.
  - **Stage-Specific Precision:** Components enforce hardware-appropriate bit-widths and handle intermediate bit-growth and truncation. The current RTL decimator saturates to 8-bit output samples; some model internals remain higher-precision or floating-point for convenience unless a dedicated RTL model is used.
- **Non-FFT DSP Chain (current ASIC architecture):**
  1. ADC (Stage 1)
  2. ΣΔ Decimator (Stage 2) — fixed R=64 half-band chain (`CIC-3 R=16 -> HB1 /2 -> HB2 /2`) at 500 kS/s; BW only selects `sample_shift`
  3. Schmidl-Cox trigger — current RTL uses PSRAM-delayed branch-0 samples; standalone energy/noise-estimator helpers are legacy diagnostics
  4. Training accumulator — `training_accumulator.py`: current RTL path is all-pairs cross-correlation via `training_accumulate_allpairs()` plus Zdiag noise-window support
  5. Firmware/host weight computation from Zpair/Zdiag (row-sum MRC or eigenvector) — `eigvec_fw.py` models the fixed-point power-iteration path
  6. Complex combining: `y[n] = Σ_j w_j·x_j[n]` — `receiver.nonfft_combine()` for float studies, or `receiver.nonfft_combine_rtl_int8w()` to include RTL 8-bit live weights, fixed ÷2 guard shift, `COMB_POST_GAIN`, and int8 saturation; MRC weights are already conjugated by weight generation
  7. Re-modulator (Stage 8) — `converter.py`
- **FFT path** (`receiver.estimate_channel`, `receiver.compute_weights`) is retained for reference and comparison but is not the current ASIC architecture. See `planning/DSP Flow.md` for why it was replaced.
