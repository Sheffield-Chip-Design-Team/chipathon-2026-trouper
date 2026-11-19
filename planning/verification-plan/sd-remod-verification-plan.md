# ΣΔ Re-modulator (`sd_remod`) — Verification Plan

**DUT:** `src/remod/sd_remod.v` (wrapper: 2× droop-compensating interpolator,
10-bit) instantiating `src/remod/sd_remod_multiplierless.v` (3rd-order CIFF
core, saturating integrators). Byte-identical mirrors in `rtl-test/rtl/`.

**Scope:** int8 I/Q at 500 kS/s → 1-bit I/Q at 32 MS/s (OSR 64): input
latching on `in_valid`, interpolation, the CIFF3 loop with saturating state,
the `en` port, output dither/stability, in-band fidelity (SQNR, RMS error,
gain flatness) and end-to-end LoRa demodulability after re-decimation.

**Inputs reviewed:** `planning/Trouper Chip Specification.md`
(TRPR-RMD-001..010), `planning/Traceability.md` §RMD, `planning/Open Risks.md`
(#24, #65 closed, #71 item 1 resolved), `planning/sd-remod-4th-order-fix-2026-09-04.md`,
`sim/models/sd_remod.py` (`SdRemodRTL`), `src/top/trouper_top.v` (u_remod,
`en` tied high, `REMOD_BACKOFF_SHIFT`), the cocotb tests named in §2, and the
current RTL.

This is the block-level closure tracker for `sd_remod`. What the remod is
fed (MRC vs bypass stream, backoff shift, replay time-order) is decided
upstream and tracked in the `mrc_combiner`, `packet_ctrl_fsm` and
`psram_buf_ctrl` plans; it appears here only as interface rows.

---

## 1. Current methodology, and the path to constrained random

**Today:** this is the most heavily verified DSP block. It is bit-exact
against `SdRemodRTL`, and fidelity is measured directly from the RTL bitstream:
SQNR and RMS at the spec point, the SQNR-vs-amplitude cliff, gain flatness,
long constrained-random and adversarial stability, and LoRa SER over SF/BW,
AWGN and CFO. TRPR-RMD-010 was narrowed 2026-10-10 to hold-at-reset only (re-enable
equivalence was never met and `en` is tied high on-chip).

- **Bit-exact differential (standalone)** — `cocotb/remod_golden`
  (`test_golden_tones`, `test_golden_random_spacing`, `test_golden_en_toggle`)
  vs `sim/models/sd_remod.py`, no lag search.
- **Fidelity (standalone)** — `remod_sqnr` (SQNR > 40 dB, RMS < 1 LSB),
  `remod_amp_sweep` (SQNR vs amplitude, cliff/trend checks),
  `remod_flatness` (STF gain flatness), `remod_lora` (SER over SF/BW, AWGN
  margin, CFO).
- **Stability (standalone)** — `remod_stability` (long constrained-random +
  adversarial sequences), `remod_en` dither/stuck-run tests.
- **Full-top** — `remod_backoff`, `bypass_backoff`, `comb_remod_transfer`,
  `bypass_e2e`, `replay_delay`.
- **Coverage gap** — no code coverage; stability is asserted on
  output run-length (the spec's own criterion), not on loop state.

The active order is:

1. Re-point `test_in_valid_holds_sample_and_retains_dither` (row #12) at the
   interpolator-aware expectation, so it can leave `expect_fail`.
2. Coverage instrumentation on `remod_golden` / `remod_stability`.

### 1a. Coverage model

At minimum, collect:

- input amplitude bands: |x| ≤ 45, 46–89, 90 (boundary), 91–127 (out of
  contract) × I/Q;
- integrator saturation events per state variable, each sign;
- `in_valid` spacing: 64 (production), shorter, irregular;
- `en` deassert/re-assert relative to `in_valid` and to the interpolator
  phase;
- longest output run per window (stability metric) histogram.

---

## 2. List of tests

`Type`: **SPEC-SIM** = directed numbered-requirement test; **EDGE-SIM** =
robustness case from RTL review; **DIFF** = bit-exact differential;
**INTERFACE** = owned upstream.

| # | Test | Type | Testbench | Spec / gap | Status |
|---|---|---|---|---|---|
| 1 | Interpolator + CIFF3 core bit-exact vs `SdRemodRTL` on tones and random spacing | DIFF | `cocotb/remod_golden` | TRPR-RMD-001 | ✅ done (job 5822) |
| 2 | 32 MS/s output, OSR 64 at production `in_valid` cadence | SPEC-SIM | `remod_golden`, `remod_sqnr`, `remod_backoff` | TRPR-RMD-002 | ✅ done |
| 3 | Saturating integrators, no wrap; recovers after overdrive | SPEC-SIM | `remod_golden` (full-scale overdrive tone), `remod_stability` adversarial | TRPR-RMD-003 | ✅ done |
| 4 | Input < −3 dBFS is guaranteed by AGC + `REMOD_BACKOFF_SHIFT`; no on-chip over-range flag (by spec) | INTERFACE | `cocotb/remod_backoff`, `bypass_backoff` | TRPR-RMD-004 | ✅ mechanism verified; AGC is external (`P`) |
| 5 | In-band SQNR > 40 dB at −6 dBFS | SPEC-SIM | `remod_sqnr::test_remod_sqnr_tones`, `remod_amp_sweep` | TRPR-RMD-005 | ✅ done |
| 6 | Dither retained (longest identical-bit run < 100 over 8192 clocks) for every int8 in [−90, 90], transitions, bounded random | SPEC-SIM | `remod_en` (`test_all_in_spec_dc_codes_retain_dither`, `test_boundary_transitions_retain_dither`, `test_bounded_random_iq_retain_dither`, `test_boundary_stuck_run_sweep`), `remod_stability` | TRPR-RMD-006 | ✅ done |
| 7 | Re-demodulated RMS error < 1 LSB at −6 dBFS | SPEC-SIM | `remod_sqnr` (RMS_MAX_LSB = 1.0) | TRPR-RMD-007 | ✅ done |
| 8 | Mode 1 passthrough feeds the single-antenna stream directly (no backoff) | INTERFACE | `bypass_e2e`, `bypass_backoff` | TRPR-RMD-008, Open Risk #65 | ✅ done |
| 9 | Input never jumps backward in signal time (replay monotonic) | INTERFACE | `replay_delay` (`rd_ptr` monotonic watcher) | TRPR-RMD-009 (`psram_buf_ctrl`) | ✅ done |
| 10 | `en=0` holds integrators/outputs at reset values | SPEC-SIM | `remod_en::test_disable_holds_reset` | TRPR-RMD-010 (hold half) | ✅ done |
| 11 | Re-enable is bit-identical to a fresh reset | SPEC-SIM | `remod_en::test_reenable_equals_fresh_start`, `test_boundary_reenable_equals_fresh_start` | TRPR-RMD-010 (re-enable half), **Open Risk #71** | ✅ resolved 2026-10-10 by narrowing TRPR-RMD-010 (hold-at-reset only; `en` tied high). Tests stay `expect_fail` as documentation |
| 12 | `in_valid` holds the sample and dither is retained across held samples | EDGE-SIM | `remod_en::test_in_valid_holds_sample_and_retains_dither` | robustness | 🟨 `expect_fail` — white-box assert on `in_i_lat` is wrong since the interpolator front-end; rewrite to an output-side check |
| 13 | STF gain flatness across the passband | SPEC-SIM | `remod_flatness` | in-band fidelity (supports RMD-005/007) | ✅ done |
| 14 | LoRa SER after re-decimation: clean all SF/BW, AWGN margin, CFO | SPEC-SIM | `remod_lora` (3 tests) | system fidelity | ✅ done |
| 15 | Combiner → remod transfer: bypass identity, unity-MRC at several levels, signed I/Q | INTERFACE | `comb_remod_transfer` (6 tests) | TRPR-RMD-008, MRC→RMD scaling | ✅ done |
| 16 | Long constrained-random + adversarial stability (millions of clocks) | EDGE-SIM | `remod_stability` | TRPR-RMD-003/006 | ✅ done |
| 17 | Spec wording: RMD-003 instability wording vs observed failure signatures | — | — | Open Risk #24 (RMD half) | ⚠️ spec wording |

### 2a. Directed closure order

1. Row #12: replace the `in_i_lat` white-box assertion with an output-side
   criterion and drop `expect_fail`.
2. Row #17: spec wording.
3. Coverage instrumentation.

---

## 3. Regression commands

```bash
# all remod suites (cocotb/run_remod_suites_sge.sh wraps this)
export SUITES="remod_golden remod_en remod_sqnr remod_flatness remod_stability remod_lora remod_amp_sweep remod_backoff comb_remod_transfer bypass_backoff"
exec /foss/designs/cocotb/run_toplevel_regression_sge.sh
```

`remod_lora` takes ~7 min; the golden/fidelity suites import
`sim/models/sd_remod.py` and `sim/models/lora.py`.

**Last run:** full regression job 5845, 2026-10-10 (all remod suites pass;
the 3 `expect_fail` tests count as pass).

---

## 4. Explicit non-goals and interface boundaries

- What stream the remod receives (MRC vs bypass, backoff, replay order) is
  owned by `mrc_combiner`, `packet_ctrl_fsm`, `psram_buf_ctrl`, `trouper_top`.
- AGC (input amplitude) is external, under TRPR-MRC-009.
- SX1302 demodulation of the real re-modulated stream is a bench/system test.
- `en` is tied high in `trouper_top`; `en` behaviour matters only for other
  integrations (see row #11).
