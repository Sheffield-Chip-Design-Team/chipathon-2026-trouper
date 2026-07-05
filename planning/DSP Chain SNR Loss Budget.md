# DSP Chain SNR / Signal-Quality Loss Budget

**Status:** Living document. Incomplete by design — most blocks in the RX
chain have not been individually quantified yet. Rows marked **Not yet
quantified** are gaps, not zero-loss confirmations.

**Purpose:** a single place to record every measured signal-degradation
contribution along the RX DSP chain (`CLAUDE.md` System Architecture
Summary, stages 1–10), so cumulative link-budget impact can be reasoned
about in one place instead of re-derived from scattered per-block docs and
notebooks each time. Each row should be traceable to the notebook cell or
planning doc that produced the number, so it can be re-verified after any
RTL change.

**How to update this doc:** when a notebook or RTL regression quantifies a
new loss (or re-measures an existing one after an RTL change), add/update a
row here with the number, the exact test conditions, and the source. Don't
duplicate the derivation — link to it.

---

## 1. ΣΔ Decimator (`sd_decimator_poly.v`)

| Effect | Measured | Conditions | Status | Reference |
|---|---|---|---|---|
| 250 kHz BW chirp-edge droop, CIC-3 R=16 stage alone | ≈ −0.17 dB | edge = 125 kHz, vs −11.8 dB for the retired R=128 CIC-only chain at the same relative edge | Verified (closed-form + Harris/`remez`) | `planning/decimator-hb-redesign.md`; `sim/notebooks/06_sd_decimator.ipynb` §1 |
| 250 kHz BW chirp-edge droop, full CIC+HB1+HB2 cascade | ≈ −0.4 dB | edge = 125 kHz | Verified | `sim/notebooks/06_sd_decimator.ipynb` §1 |
| 125 kHz BW chirp-edge response | ≈ +0.15 dB (passband ripple, not droop) | edge = 62.5 kHz | Verified | `sim/notebooks/06_sd_decimator.ipynb` §1 |
| SQNR, worst tested tone | ≈ 42 dB | RTL, 100 kHz tone, Gate 1 accept ≥ 40 dB | Partial — full spectral sweep pending | `planning/decimator-hb-migration-impact-plan.md` Gate 1 (SGE 2081/2082) |
| 125 kHz BW gain error | ≈ −0.5 dB | RTL | Partial (same Gate 1 sweep) | `planning/decimator-hb-migration-impact-plan.md` Gate 1 |
| 1× oversampling (250 kHz BW) feasibility | Infeasible — required filter order → ∞ as OS → 1× | Harris estimate + `remez` verification, 40 dB alias-rejection target | Verified (architectural floor, not adopted) | `planning/decimator-hb-redesign.md` "Why 2× is a floor…"; `sim/notebooks/06_sd_decimator.ipynb` §9 |

## 2. DC Removal (`dc_removal.v`)

| Effect | Measured | Conditions | Status | Reference |
|---|---|---|---|---|
| −3 dB corner frequency | ≈ 2.45 kHz | `alpha=1/32`, `fs=500 kS/s`, floating-point equivalent | Verified | `sim/notebooks/dc_removal.ipynb` §1 |
| AC passband droop @ 1 kHz | −8.5 dB | bit-exact model (`DCRemovalRTL`) | Verified — **contradicts** `planning/blocks/DC Removal.md`'s documented "< 0.1 dB" pass criterion at the same test point; doc review needed, not an RTL bug | `sim/notebooks/dc_removal.ipynb` §5 |
| Near-DC zero-crossing, matched-filter correlation loss | < 0.1 dB, worst case across SF7–12 × BW{125,250} kHz | every LoRa symbol's instantaneous frequency dips below the corner for ~1 sample/symbol; correlation-loss is the metric that maps to what the SC detector/dechirp correlator actually experiences | Verified — negligible | `sim/notebooks/dc_removal.ipynb` §6b |
| Near-DC zero-crossing, peak per-sample error (undiluted) | −0.3 to −8.9 dB, SF-dependent (worse at low SF) | localized to ~1 sample/symbol | Verified — locally severe but does not propagate to correlation loss above | `sim/notebooks/dc_removal.ipynb` §6b |
| Reset-recovery settling | 119 samples to ≤ 1 LSB for a 64-code offset | bit-exact model | Verified — **contradicts** `planning/blocks/DC Removal.md`'s documented "37 samples" criterion; doc review needed | `sim/notebooks/dc_removal.ipynb` §7 |

## 3. Schmidl-Cox Detector (`sc_detector.v`)

**Not yet quantified as an isolated SNR-loss contributor.** Known open risk
(not an SNR number, but affects effective sensitivity): the detector keys
lock decisions on antenna 0 only, so a deep antenna-0 fade can block
`sc_lock` even with strong signal on antennas 1–3. See
`planning/sc-detector-ant0-fading-risk.md`.

## 4. Frontend Buffer Controller (`frontend_buf_ctrl.v`)

**Not yet quantified.** No known lossy signal-path element (SRAM replay
buffer), but not yet checked for e.g. PSRAM replay timing-induced sample
staleness.

## 5. Noise Estimation (`noise_est.v`)

**Not yet quantified.** Manhattan-norm (no multiplier) noise estimate is a
known approximation vs an L2-norm estimator; the resulting bias/variance on
`energy_snap` has not been measured against an ideal estimator.

## 6. Training Accumulator (`training_acc.v`)

| Effect | Measured | Conditions | Status | Reference |
|---|---|---|---|---|
| Noiseless all-pairs correctness | matches `h_k·conj(h_l)·n_acc` to float-rounding floor (< −100 dB error) | SF7, NR4, no noise | Verified | `sim/notebooks/11_training_accumulator.ipynb` §1 |
| Baseline preamble-truncation loss (`SC_HITS_REQ=2`, `PREAMBLE_LEN=8`, 5 of 8 symbols accumulated) | ≈ −2.2 dB vs an ideal 8-symbol window | fixed, unavoidable in the baseline live path (not a fault condition) | Verified, matches doc | `sim/notebooks/11_training_accumulator.ipynb` §2 |
| Late-SC-lock additional loss (low-SNR delayed lock) | −2.2 / −4.0 / −7.0 / −10.0 dB at 5/6/7/7.5 symbols locked (on top of baseline) | reproduces `planning/blocks/Training Accumulator.md`'s published late-lock table exactly | Verified | `sim/notebooks/11_training_accumulator.ipynb` §2 |
| ZDIAG register widening (16-bit → 24-bit, `reg_bank.v` 0x64-0x6F) | Closed a ≈0.9 dB firmware combining-gain loss found in an earlier pass: −0.897 dB → −0.001 dB (noiseless test) | 500 random Rayleigh channels, baseline 5-symbol accumulation | **Fixed and verified.** RTL, `sim/models/eigvec_fw.py`, `sim/tests/test_eigvec_fw.py`, `sim/tests/test_pgs_fw.py`, `rtl-test/tb/tb_mrc_fw_precision.v`, `rtl-test/tb/test_capture_playback.py`, and all planning docs updated to match. Testing showed the gap was not recoverable by any firmware-only change (more iterations, wider int12 normalisation, warm-start) prior to the fix — the precision was discarded in hardware before firmware ever saw it. | `sim/notebooks/11_training_accumulator.ipynb` §3; `planning/blocks/Training Accumulator.md` "ZDIAG widening" |
| Residual firmware combining-gain loss at low SNR, post-ZDIAG-fix | ≈ −0.8 dB at −16 dB per-antenna SNR with 8 iterations (current firmware default); ≈ −0.3 dB with 16 iterations | noisy Z, near-degenerate eigenvalues — power-iteration convergence-rate limited, not register precision | Verified as an SNR effect — **but NOT a cheap follow-up.** More iterations were tested and found *not* to help before the ZDIAG fix (the truncation bias dominated and masked this smaller effect); post-fix they measurably do. However, a corrected timing estimate (see `planning/blocks/Eigenvector Weight Computation.md` Timing Budget, revised after finding this project's PicoRV32 configs use the slow non-`FAST_MUL` multiplier, ~31 cycles/MUL not ~1) shows 8 iterations already costs ~1.0–1.1 ms — roughly SF-independent — against a deadline that scales with SF (`4·M/500kHz`). At SF6 this **does not fit**; SF7 is break-even; 16 iterations needs roughly SF8+ to fit comfortably. My earlier claim of "large timing slack" in this row was wrong and has been corrected. PSRAM replay mode sidesteps the problem (packet-length-scaled deadline) but the baseline live-mode picture is a real, previously unflagged risk — not yet cycle-accurately verified. | `sim/notebooks/11_training_accumulator.ipynb` §3; `planning/blocks/Eigenvector Weight Computation.md` Timing Budget |
| Zpair 24-bit host-telemetry register readback error | ≈ −98 dB relative to typical Z magnitude — architecturally irrelevant to combining weights (firmware reads the un-truncated int32 accumulator directly; only host telemetry readback is truncated) | n_acc ≈ 640, int8 input | Verified — negligible, telemetry-only, unaffected by the ZDIAG fix | `sim/notebooks/11_training_accumulator.ipynb` §3 |
| Combining-method SER, firmware eigvec vs its own float reference vs legacy W_k | `eigvec_fw` far better than legacy `W_k` (~1.4x lower SER @ −16 dB) but **still worse than its own float reference** `eigvec_pre` (~1.5-2x higher SER at −16 to −12 dB, now attributable to iteration count rather than ZDIAG) | SF7, NR4, reduced 250-pkt re-run of `sim/sims/compare_mrc_methods.py` | Verified; the float-vs-fixed-point firmware gap still isn't isolated in the doc's published 2000-pkt sweep table | `sim/notebooks/11_training_accumulator.ipynb` §4 |
| Noise-mode off-diagonal leakage / diagonal accuracy | off-diagonal leakage ≈ −26 dB mean below diagonal; diagonal tracks σ²·n_acc within a few % | 8-symbol noise window (`TACC_NOISE_TRIG`), 200 trials | Verified | `sim/notebooks/11_training_accumulator.ipynb` §5 |

See also `planning/blocks/Training Accumulator.md` and Gate 6 in
`decimator-hb-migration-impact-plan.md` for `n_acc` correctness
(exactness/overflow behaviour — a separate, earlier verification pass).

**Open item surfaced by this analysis:** the ZDIAG widening closed the
dominant part of the firmware fixed-point combining-gain loss, but a
smaller, genuine low-SNR residual remains, now correctly attributed to the
8-iteration power method's convergence rate rather than register precision.
Bumping the default iteration count from 8 to 16 would close roughly half of
this residual, **but is not a free lever** — see the timing row above. Doing
so requires either restricting it to higher SFs where the deadline has
enough margin, using PSRAM replay mode (deadline scales with packet length,
not symbol length), or accepting the current 8-iteration residual at low SF
in baseline live mode. Not yet implemented, and the underlying cycle-count
estimate itself is not yet cycle-accurately verified.

## 7. Packet Control FSM (`packet_ctrl_fsm.v`)

Not applicable — control-only block, no signal path.

## 8. Weight Generation (`weight_gen.v`) / MRC Combiner (`mrc_combiner.v`)

| Effect | Measured | Conditions | Status | Reference |
|---|---|---|---|---|
| Int8 weight quantisation loss (`W_MAX=45`, deployed) | ≈ 0.00091 dB mean, ≈ 0.00174 dB p99 | NR=4 MRC, SNR spread swept 0–20 dB | Verified — effectively lossless at the deployed operating point | `sim/notebooks/07_mrc_weight_quantisation.ipynb` §6 |
| Int8 weight quantisation loss, degraded (`W_MAX=4`, ~2-bit) | ≈ 0.10 dB mean, ≈ 0.19 dB p99 | for comparison only — not the deployed setting | Verified | `sim/notebooks/07_mrc_weight_quantisation.ipynb` §6 |
| Combiner clipping risk at raw-int8 amplitude | Combiner rails at 127 well before remod backoff engages; `W_MAX=45` is **not** a safe live-hardware amplitude rule | 4 equal branches @ 90 counts each | Verified — real risk, not just a quantisation-precision question; spec/RTL tension identified | `sim/notebooks/08_mrc_output_headroom.ipynb` §5 |
| Q0.7 firmware-normalised weight failure map | Non-zero failure probability + residual loss where it does succeed, worse under coherent equal-phase combining | swept over channel phase / SNR corner cases | Verified (mapped, not a single number — see notebook for the full corner table) | `sim/notebooks/09_q07_failure_map.ipynb` §5 |
| SW (ALMMSE) vs HW (MRC) detector choice | dB gain/loss at BER targets {10%, 1%, 0.1%} per detector path | SF/NR-dependent Monte Carlo | Measured, not yet pulled into this table as a single number — see notebook | `sim/notebooks/05_sw_vs_hw_weight_gen.ipynb` §7 |

## 9. ΣΔ Re-modulator (`sd_remod.v`)

**Not yet quantified** as an isolated SNR-loss item at the current OSR=64
operating point (previously ran over-specified at OSR=128). Stability/SQNR
sweep at OSR=64 is flagged as pending in
`planning/decimator-hb-migration-impact-plan.md` Gate 9/10.

## 10. Carrier Frequency Offset (CFO), system-level

`planning/System Architecture.md` states residual CFO error is "the
complete error budget" for CFO (transmitter-only property, no SRO since all
antennas + ASIC share one TCXO) and cites `sim/notebooks/02_cfo_estimation.ipynb`
as the source.

**That notebook does not exist in the repo** (`sim/notebooks/` has no
`02_cfo_estimation.ipynb`, and it has no git history). The closest existing
coverage is a pytest regression, `sim/tests/test_cfo_droop.py` (CFO
sensitivity of the current R=64 half-band decimator's dechirp peak
amplitude under moderate CFO, both BWs) — not a notebook, and not yet
distilled into a headline dB number for this table. **This is a real
documentation gap**, not just a missing row: `System Architecture.md`
references a source of truth that isn't there. Needs either the notebook
recreated or the reference corrected to point at the actual test.

---

## Known planning-doc mismatches surfaced while building this table

These aren't RTL bugs — they're places where a verification-table pass
criterion doesn't match the same document's own stated design parameters.
Listed here so they don't get lost, pending owner review:

1. `planning/blocks/DC Removal.md` "AC passband" test claims < 0.1 dB droop
   at 1 kHz; the documented `alpha=1/32` design point gives a ~2.45 kHz
   corner, so 1 kHz sits in the transition band (measured −8.5 dB, not
   < 0.1 dB).
2. Same doc's "Reset recovery" test claims < 1 LSB within 37 samples; the
   bit-exact model gives 119 samples for a 64-code offset (reset just
   re-triggers the ordinary step response, ~74 samples to 90%).
3. `planning/System Architecture.md` cites `sim/notebooks/02_cfo_estimation.ipynb`,
   which does not exist.
4. `planning/blocks/Training Accumulator.md`'s "Combining method performance"
   table compares Oracle / Eigvec-PSRAM / Eigvec-preamble-only / W_k HW, but
   never isolates the actual RV32IM fixed-point path (`compute_eigvec_fw`)
   against its own float reference. That gap was found to be ≈0.9 dB
   combining-gain loss, root-caused to the ZDIAG register's then-16-bit
   truncation, and **fixed** by widening ZDIAG to 24 bits (see "ZDIAG
   widening" note in `planning/blocks/Training Accumulator.md`). A smaller
   residual gap remains at low SNR, now attributed to the 8-iteration power
   method's convergence rate — see §6 above. The published table itself is
   still accurate as far as it goes; the gap in coverage (never isolating
   float-vs-fixed-point) remains open.

## Related

- `planning/System Architecture.md` — pipeline stage list this table follows
- `planning/decimator-hb-migration-impact-plan.md` — Gate-based verification record for the decimator/HB migration
- `planning/blocks/` — per-block reference docs
