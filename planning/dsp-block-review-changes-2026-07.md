# DSP Block Review — Planned Changes (2026-07)

Source: full `src/` DSP RTL review vs `Trouper Chip Specification.md` v0.4, 2026-07-18.
Scope: `sd_decimator_poly`, `dc_removal`, `sc_detector`, `training_acc`, `mrc_combiner`, `sd_remod`.
No new functional bugs found; items below are corner-case hardening + spec drift.

**Decision (2026-07-18): no new per-block enables.** The receive path is always-on
(decimator/DCR/SC/PSRAM must run to detect preambles); idle blocks are already
activity-gated by FSM/valid strobes; the CE16 timing lever is already pulled. Enables
would cost recirculation-mux area in an area-constrained design for cosmetic power
savings. Optional future item: one chip-level standby bit gating `iq_valid`/CE upstream
— deferred, not planned.

## 1. RTL changes (planned)

| # | Block | Change | Rationale | Status |
|---|---|---|---|---|
| R1 | `sd_remod.v` | Hold `s1..s3` integrators in reset while `!en` (or feed back true quantizer bit instead of gated output) | With `en=0`, `out=0` decodes as −127 feedback → error +127/clk → all six integrators rail at +32767 within ~256 cycles; re-enable starts from railed state with no observable instability flag (near-rail is indistinguishable from healthy — see `project_remod_backoff_test`) | **DONE 2026-07-18** — integrator hold implemented; `cocotb/remod_en/` PASS (SGE job 3451), negative control vs pre-fix RTL FAILs as expected (job 3452). Note `trouper_top` ties `en=1'b1`, so this is defensive for other integrations |
| R2 | `dc_removal.v` | Saturate output: clamp 9-bit `sample_in − dc_est` to int8 | Wrap is a threshold cliff, not a tail: with the −3 dBFS AGC contract (≤90 counts) it triggers whenever \|DC\| ≳ 38 counts at the decimator output — then it fires on every chirp-envelope peak, phase-locked to the signal (sign-flipped max-magnitude samples into SC metric + Zdiag). Below the cliff it is impossible in normal operation (reset-safe: dc_est=0 ⇒ diff fits int8). ~1 mux of area. | **GATED on AFE PCB DC measurement** (2026-07-18): measure DC vs LNA gain per channel (see `AFE Characterisation Board.md` §Bring-Up Measurements). \|DC\| < 20 counts at max gain on all channels → drop R2, close TRPR-DCR-007 by measured margin; ≥ 20 counts anywhere → implement |
| R3 | `training_acc.v` | Defensive clamp `tacc_window_eff`: `<8 → 8` (currently only `0 → 1`) | Real clamp lives in `reg_bank` 0x27 only. A direct drive of 1–3 syms with `sc_hits_req=3` puts `acc_end` before lock → `training_done` never fires (rescued only by PKT_TIMEOUT). Cheap belt-and-braces. | **DONE 2026-07-18** — clamp matches reg_bank rule; `cocotb/tacc_window_clamp/` PASS incl. bit-exact Zdiag + n_acc checks (job 3451), negative control FAILs pre-fix RTL (job 3452). Semantic note: direct-driven noise-mode windows 1–7 now run 8×M samples (longer σ² window, harmless; asserted in test) |
| R4 | `mrc_combiner.v` | Comment fixes: `clk_16m` port annotated as historical (kept to avoid netlist churn), stale R=128 budget note fixed, `26'sd0`→`18'sd0` literal width; same drift fixed in `training_acc.v` header | Doc drift; no logic change | **DONE 2026-07-18** (spec S1–S11 applied same day, spec v0.4→v0.5) |

Explicitly **not** planned:
- Decimator CIC saturation (TRPR-DEC-005 wording): wrap-around at exact 14-bit
  worst-case width is the correct CIC construction — fix the spec, not the RTL.
- Zdiag widening: 32-bit overflows by 1 count only at the pathological corner
  (SF12/125 kHz, 8-sym window, both I and Q railed at −128 = exactly 2^32). Under the
  TRPR-MRC-009 AGC contract (≤90 counts) there is 2× margin. Document, don't fix.
- sd_remod over-range detection flag (TRPR-RMD-004 "detected and flagged if
  possible"): no valid on-chip instability signal exists (integrator states near-rail
  when healthy); amend the requirement to "prevented by AGC".
- Per-block or per-branch enables (see decision above).

## 2. Spec corrections (Trouper Chip Specification.md v0.4 → **applied 2026-07-18 in v0.5**; S8 worded as measurement-gated per R2, + TRPR-RMD-010 added for the R1 `en` contract)

| # | Location | Problem | Fix |
|---|---|---|---|
| S1 | §3 / §3.1 / TRPR-SYS-003/015/016 / TRPR-PHY-014 | Describe a real `CLK_16M` generated-clock net + divide-by-2 SDC; contradicts TRPR-INT-006 (correct: single 32 MHz clock, CE gating, no CLK_16M net) and the RTL (`mrc_combiner.clk_16m` wired to `clk`; `dc_removal` port is `clk_32m`) | Rewrite clocking sections to the CE model; single canonical story |
| S2 | §2 W definition, TRPR-MRC-001, TRPR-MRC-006, TRPR-WGN-003 | Weights still int16 Q1.15; RTL + Register Map are int8/Q0.7 (high byte of shadow) | Update to int8 Q0.7 |
| S3 | TRPR-MRC-001 | Says combiner computes Σ conj(w_k)·x_k; RTL computes plain w·x, conjugation lives in firmware (TRPR-WGN-005). Behaviour validated bit-exact (job 3286) — wording only | Reword: combiner applies w·x with pre-conjugated W |
| S4 | §4.1 title | References `sd_decimator_cic_tdm8.v` | Actual file `sd_decimator_poly.v` |
| S5 | TRPR-SYS-016 | Lists `frontend_buf_ctrl` as live block; removed per §4.4, no file in `src/` | Remove from block list |
| S6 | §4.13 header | "Python-generated AHB-Lite slave" contradicts TRPR-REG-005 (hand-written, no generator — intentional) | Delete header claim |
| S7 | TRPR-DEC-005 | Mandates saturating CIC arithmetic; correct design is wrap-around at overflow-safe width | Reword: "overflow-safe width with wrap-around comb cancellation" |
| S8 | TRPR-DCR-007 | "Output bounded by construction" — false during full-scale step transients (see R2) | After R2: output saturated to int8; reword accordingly |
| S9 | TRPR-SCD-007 (or RTL header) | Hit compare uses `eval_mag_acc[27:1]` — an extra ÷2 on \|C\|² beyond the documented ÷64 `sc_thr` rescale; absorbed into calibration but undocumented (future threshold re-derivation would come out 3 dB off) | Add one sentence documenting the factor |
| S10 | TRPR-RMD-004 | "Detected and flagged if possible" — no flag exists or is feasible | Amend to "prevented by AGC" (see not-planned list) |
| S11 | §4.5 (TRPR-TAC) | Zdiag 32-bit corner-case margin (exactly 2^32 at pathological rail) undocumented | Add note referencing AGC contract margin |

## 3. Verification notes

- R1: covered by `cocotb/tests/test_remod_en.py` (unit bench, `cocotb/remod_en/`):
  integrators pinned at 0 while disabled; re-enable bitstream bit-identical to
  fresh-reset with same stimulus after heavy-activity + 600-clk disable.
- R3: covered by `cocotb/tests/test_tacc_window_clamp.py` (unit bench,
  `cocotb/tacc_window_clamp/`): windows {0,2,8,9} with 4-symbol-late lock →
  exact n_acc/Zdiag per clamped window; noise mode window 3 → n_acc == 8M.
- R2 (if implemented): directed dc_removal test: DC = ±40 counts + 90-count tone,
  assert no wrapped (sign-flipped) output sample at envelope peaks.
- SC eval-engine timing margin (watch item, no change): serial-mul eval ≈60 clks vs
  64-clk `iq_valid` period — only ~4 clks between eval finish and next symbol-boundary
  snapshot. Any future extra eval step breaks it silently; note here so it isn't
  rediscovered the hard way.

All RTL changes must be mirrored `src/` ↔ `rtl-test/rtl/` (manual sync — see
`project_rtl_tree_divergence_fixed`) and NFS-synced (full scope incl. `sim/`) before
SGE runs.
