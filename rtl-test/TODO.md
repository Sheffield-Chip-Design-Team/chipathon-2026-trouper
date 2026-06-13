# RTL Test TODO

## MRC combiner — Q0.7 guard shift + adaptive post_gain_shift

**Context:**
`mrc_combiner.v` changed the fixed guard shift from `>>> 1` to `>>> 8` (commit on
this branch). The effective weight is now `W_byte / 128` (Q0.7). Firmware is
responsible for setting `COMB_POST_GAIN_SHIFT` (register `0x0F` bits [2:0]) per
packet based on estimated signal amplitude from `ZDIAG_k`. See
`planning/blocks/Eigenvector Weight Computation.md` Step 3 for the firmware rule.

**What needs verifying:**

- [ ] **RTL unit test — combiner arithmetic**
  Inject known int8 inputs and int8 weights via testbench; confirm that the
  accumulator output after `>>> 8` matches the expected Q0.7 value. Test both
  the coherent equal-branch case and a 20 dB spread case. Confirm `post_gain_shift`
  left-shifts the output before saturation. Target: no clipping for A ≤ 64 with
  W_max = 120 and pgs = 0.

- [ ] **RTL unit test — pgs clip boundary**
  With A = 90, W_max = 90, pgs = 0: verify output ≈ 127 (near full-scale, no
  wrap). With A = 4, W_max = 120, pgs = 3: verify output ≈ 60 counts.

- [ ] **Sim notebook — notebook 04 Test 5**
  Run `sim/notebooks/04_precision_verification.ipynb` through to Test 5 to confirm
  Q0.7 BER matches the float reference down to the practical amplitude floor
  (alpha ≈ 1–4). Expected: no BER degradation vs float for alpha ≥ 1 at high SNR.

- [ ] **Firmware integration test**
  Verify that the firmware `pgs` computation (Step 3 of eigenvector spec) produces
  correct register values against the Python model for strong (A=90), moderate
  (A=32), and weak (A=4) synthetic Z inputs.

- [ ] **End-to-end DSP chain sim**
  Run `make sim_dsp_chain` after the `>>> 8` change and confirm SC lock rate and
  MRC output quality are not regressed. Compare against the last known-good run.

**Related files:**
- `rtl/mrc_combiner.v` — guard shift changed here
- `planning/blocks/Eigenvector Weight Computation.md` — firmware rule (Steps 3–4)
- `planning/blocks/MRC Combiner.md` — block spec (COMB_POST_GAIN policy section)
- `sim/notebooks/04_precision_verification.ipynb` — Test 5 (amplitude sweep)
- `sim/q07_weight_observations.md` — background analysis
