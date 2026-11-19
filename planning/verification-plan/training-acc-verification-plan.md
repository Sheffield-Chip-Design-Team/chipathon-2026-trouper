# Training Accumulator (`training_acc`) — Verification Plan

**DUT:** `src/combiner/training_acc.v`. The `rtl-test/rtl/training_acc.v` copy
is **stale** (differs from `src/`); the legacy `rtl-test/tb/tb_training_acc_equiv.v`
and `tb_tacc_resetless_equiv.v` benches compile against `rtl-test/rtl/` and the
frozen `training_acc_ref.v` and have no runner in the current regression.

**Scope:** the all-pairs cross-correlator (6 complex `Zpair`) and diagonal
autocorrelator (4 `Zdiag`) through the paced dual-multiplier TDM pipeline;
window arming from `sc_lock`/`timing_ref` (packet mode) or `noise_trig`
(noise mode); the ≥8-symbol window clamp; saturating int32/uint32
accumulation; `n_acc`; `training_done` / `training_done_pkt` / `noise_abort`;
and the window-epoch flush of stale pipeline items.

**Inputs reviewed:** `planning/Trouper Chip Specification.md`
(TRPR-TAC-001..011), `planning/Traceability.md` §TAC, `planning/Open Risks.md`
(#63, #66, #68 closed), `planning/Register Map.md` (0x1F, 0x20–0x23,
0x27, 0x40–0x6F), `sim/models/training_accumulator.py`, `src/top/trouper_top.v`
(u_tacc), the cocotb tests named in §2, and the current RTL.

This is the block-level closure tracker for `training_acc`. Register readback
of Z/N_ACC/TRAINING_STATUS is `reg_bank`'s decode (its plan, row #5/#6);
the noise-trigger edge qualification and SC-contamination verdict live in
`trouper_top`.

---

## 1. Current methodology, and the path to constrained random

**Today:** Z, Zdiag and `n_acc` are bit-exact against
`training_accumulate_allpairs` in packet mode (timing_ref behind and ahead
of the lock, clamped and maximum windows, full-scale int8) and noise mode,
with done/pkt-done timing and re-arm zeroing asserted. Saturation, window
clamp and MCP settle have dedicated suites; noise-mode protocol and #68
epoch flush are covered at the top level.

- **Bit-exact differential (cocotb, standalone)** — `cocotb/tacc_golden`
  (6 tests), mutation-checked (Zpair_q sign and window-end off-by-one both
  caught, SGE job 5854).
- **Saturation (standalone)** — `cocotb/tacc_acc_overflow`: Zpair clamps at
  INT32_MAX, Zdiag monotonic at UINT32_MAX (Open Risk #63).
- **Window clamp (standalone)** — `cocotb/tacc_window_clamp` (live + noise).
- **MCP settle (standalone)** — `cocotb/mcp_tacc_settle`.
- **Full-top** — `noise_trig` (4 tests), `noise_window_edge` (10),
  `weight_gen_spi_flow` and `capture_two_packet` (real capture, Z → firmware
  weights, two-packet re-arm).
- **Coverage gap** — no code/functional coverage; golden windows are short
  (M ≤ 256) to stay under the saturation onset; `sc_lock` dropping
  mid-window and SF/`sample_shift` at the extremes are not exercised
  standalone.

The active order is:

1. Close the crisp directed gaps (rows #9, #10, #11).
2. Coverage instrumentation on `tacc_golden`.
3. Constrained-random windows (SF, shift, W, lock phase, timing_ref offset,
   amplitude) against the model, with saturation-aware expectation.

### 1a. Coverage model

At minimum, collect:

- packet vs noise mode × window W ∈ {clamped <8, 8, 9..14, 15};
- M = 2^(sf+shift) across 32 … 16384;
- `timing_ref` < / = / > first post-arm sample index;
- `iq_valid` landing while the TDM pipe is still busy (sample skipped by the
  `!tdm_active` guard) — must never occur at 64-clock cadence;
- `sc_lock` fall mid-window; `noise_trig` during an armed window; real lock
  pre-empting a noise window (epoch bump) with items in flight;
- saturation hit per Zpair_i / Zpair_q / Zdiag, each sign.

---

## 2. List of tests

`Type`: **SPEC-SIM** = directed numbered-requirement test; **EDGE-SIM** =
robustness case from RTL review; **DIFF** = bit-exact differential;
**INTERFACE** = observed through `reg_bank`/top.

| # | Test | Type | Testbench | Spec / gap | Status |
|---|---|---|---|---|---|
| 1 | 6 cross-pairs + 4 diagonals exact vs model, pair mapping (0,1)…(2,3) | DIFF | `cocotb/tacc_golden` (all tests) | TRPR-TAC-001 | ✅ done (job 5853) |
| 2 | Packet window = [max(first post-arm sample, timing_ref), timing_ref + W·M − 1] | DIFF | `test_packet_timing_ref_in_past`, `test_packet_timing_ref_in_future` | TRPR-TAC-002 | ✅ done |
| 3 | W < 8 behaves as 8 (module clamp); W = 15 exact | DIFF | `test_packet_window_clamp_and_max`; `cocotb/tacc_window_clamp` | TRPR-TAC-002 | ✅ done |
| 4 | `training_done` rises during the last window sample's burst; `n_acc` = window length | DIFF | all `tacc_golden` packet tests | TRPR-TAC-003 | ✅ done |
| 5 | Full-range int8 incl. −128 (multiplier and sign/zero-extension corners) | DIFF | `test_packet_full_scale_int8` | TRPR-TAC-001 | ✅ done |
| 6 | Noise mode: W·M from the trigger; `training_done` yes, `training_done_pkt` no | DIFF | `test_noise_mode_window` | TRPR-TAC-007 | ✅ done |
| 7 | Noise trigger rejected while armed / packet active; noise window pre-empted by a real lock with no false completion | INTERFACE | `cocotb/noise_trig` (4 tests), `cocotb/noise_window_edge` | TRPR-TAC-007, Open Risk #68 | ✅ done |
| 8 | Re-arm zeroes all Z/Zdiag/n_acc; second window exact | DIFF | `test_rearm_zeroes_previous_window`; `capture_two_packet` | TRPR-TAC-010 | ✅ done |
| 9 | `sc_lock` falling mid-window disarms: no `training_done`, no further accumulation, next lock re-arms cleanly | EDGE-SIM | new in `tacc_golden` | RTL disarm branch | ⬜ new |
| 10 | Epoch flush: an item in flight when a noise window is aborted is dropped even after the packet re-arm bumps the epoch | EDGE-SIM | new standalone (cycle-placed abort), complements the top-level #68 tests | Open Risk #68 (block level) | 🟨 partial — closed at top level, not cycle-targeted standalone |
| 11 | High-M exactness: SF12 / shift 2 window (M = 16384) at low amplitude (below saturation) | DIFF | new in `tacc_golden` (long) | TRPR-TAC-001/002 at max M | ⬜ new |
| 12 | Saturating accumulate: Zpair clamps at ±2³¹, Zdiag at 2³²−1, no wrap | EDGE-SIM | `cocotb/tacc_acc_overflow` | Open Risk #63 | ✅ done |
| 13 | TDM products consumed only after the MCP settle | EDGE-SIM | `cocotb/mcp_tacc_settle` | Open Risk #43 | ✅ done |
| 14 | Z/Zdiag/N_ACC/TRAINING_STATUS register readback format | INTERFACE | `test_weight_gen_spi_flow.py`, `test_noise_trig.py`, `reg_bank` plan rows #5/#6 | TRPR-TAC-004/005/008 | ✅ done |
| 15 | Z/n_acc ≈ h_k·conj(h_l) on a noiseless channel (Q1.15) | DIFF | `tacc_golden` (exact, stronger) + `test_weight_gen_spi_flow.py` | TRPR-TAC-009 | ✅ done |
| 16 | Constrained-random window/lock/amplitude regression vs model | DIFF | extend `tacc_golden` | coverage | ⬜ planned |

### 2a. Directed closure order

1. Rows #9 and #10 in one new standalone test file (both are control-path
   edge cases with cycle-precise stimulus).
2. Row #11 as a separate long-running test (or nightly suite).
3. Coverage instrumentation, then row #16.

---

## 3. Regression commands

```bash
# SGE job script (hqsub --project lora-mimo --cpus 2 --mem 8G)
export SUITES="tacc_golden tacc_acc_overflow tacc_window_clamp mcp_tacc_settle noise_trig noise_window_edge"
exec /foss/designs/cocotb/run_toplevel_regression_sge.sh
```

`weight_gen_spi_flow` and `capture_two_packet` run under
`SUITE_GROUPS=capture` (need `$SHARED_DIR` captures). `tacc_golden`
imports `sim/models/training_accumulator.py`; sync `sim/` with `src/`.

**Last run:** `tacc_golden` 6/6, SGE job 5853, 2026-10-10; the other suites
passed in the full regression job 5845.

---

## 4. Explicit non-goals and interface boundaries

- Weight computation from Z (MRC row-sum / eigenvector) is firmware
  (`sim/models/eigvec_fw.py`), not RTL.
- `timing_ref` correctness is `sc_detector`'s; this block trusts its input.
- Noise-trigger write edge-qualification, busy rejection and the
  SC-contamination (`NOISE_READY`) verdict live in `reg_bank`/`trouper_top`.
- The legacy `rtl-test` equivalence benches are historical; re-wiring them
  would only re-prove what `tacc_golden` proves against `src/`.
